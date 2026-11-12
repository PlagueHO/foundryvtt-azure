[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester uses these variables across its setup, test, and cleanup scriptblocks.')]
[CmdletBinding()]
param()

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $checkScript = Join-Path $repoRoot 'scripts\Test-WebAppInfrastructure.ps1'
    $originalLastExitCode = $global:LASTEXITCODE
}

AfterAll {
    $global:LASTEXITCODE = $originalLastExitCode
}

Describe 'Compiled Foundry Web App routing' {
    BeforeAll {
        $template = Get-Content (Join-Path $repoRoot 'infra\main.json') -Raw | ConvertFrom-Json
        $deployment = $template.resources.webAppFoundryVtt
    }

    It 'passes the effective networking flag to the site-level routing property' {
        $deployment.properties.parameters.outboundVnetRouting.value.allTraffic |
            Should -Be "[variables('effectiveDeployNetworking')]"
        $deployment.properties.template.resources.app.properties.outboundVnetRouting |
            Should -Be "[parameters('outboundVnetRouting')]"
        ($deployment.properties.parameters.siteConfig.value.PSObject.Properties.Name -contains 'vnetRouteAllEnabled') |
            Should -BeFalse
    }
}

Describe 'Test Web App checks' {
    BeforeEach {
        $checkParameters = @{
            SubscriptionId = 'test-subscription'
            TenantId = 'test-tenant'
            ResourceGroupName = 'rg-test'
            WebAppName = 'fvtt-test'
            StorageAccountName = 'fvtttest'
            Networking = 'Enabled'
            RetryCount = 2
            RetryIntervalSeconds = 1
        }
        $appProperties = @{
            outboundVnetRouting = @{ allTraffic = $true }
            virtualNetworkSubnetId = '/subscriptions/test-subscription/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/test/subnets/webApp'
            defaultHostName = 'fvtt-test.azurewebsites.net'
        }
        $mountProperties = @{
            accountName = 'fvtttest'
            shareName = 'foundryvttdata'
            mountPath = '/data'
            type = 'AzureFiles'
            protocol = 'Smb'
        }
        $referenceState = @{ Status = 'Resolved'; Reads = 0 }

        Mock azd { $global:LASTEXITCODE = 0; 'test-token' }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/config/azurestorageaccounts/list?*') {
                return @{ properties = @{ foundrydata = $mountProperties } }
            }
            if ($Uri -like '*/config/configreferences/appsettings/*') {
                return @{ properties = @{ status = $referenceState.Status } }
            }
            return @{ properties = $appProperties }
        }
        Mock Invoke-WebRequest {
            @{ StatusCode = 200; Content = '<html><title>Foundry Virtual Tabletop</title></html>' }
        }
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Write-Information {}
    }

    It 'reports runtime mount verification as blocked when no evidence is supplied' {
        $result = & $checkScript @checkParameters
        $result.RoutingVerified | Should -BeTrue
        $result.KeyVaultReferencesVerified | Should -BeTrue
        $result.FoundryHttpReady | Should -BeTrue
        $result.RuntimeMountVerified | Should -BeFalse
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*BLOCKED*' }
    }

    It 'accepts networking disabled only when routing is false and integration is absent' {
        $checkParameters.Networking = 'Disabled'
        $appProperties.outboundVnetRouting.allTraffic = $false
        $appProperties.virtualNetworkSubnetId = $null
        (& $checkScript @checkParameters).RoutingVerified | Should -BeTrue

        $appProperties.outboundVnetRouting.allTraffic = $true
        { & $checkScript @checkParameters } | Should -Throw '*allTraffic*'
    }

    It 'rejects missing routing and mismatched VNet integration' {
        $appProperties.outboundVnetRouting = $null
        { & $checkScript @checkParameters } | Should -Throw '*allTraffic*'
        $appProperties.outboundVnetRouting = @{ allTraffic = $true }
        $appProperties.virtualNetworkSubnetId = $null
        { & $checkScript @checkParameters } | Should -Throw '*VNet integration*'
    }

    It 'rejects an incorrect Azure Files mount configuration' {
        $mountProperties.mountPath = '/other'
        { & $checkScript @checkParameters } | Should -Throw '*expected Azure Files SMB mount*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'stops after the retry limit when any Key Vault reference remains unresolved' {
        $referenceState.Status = 'AccessToKeyVaultDenied'
        { & $checkScript @checkParameters } | Should -Throw '*within 2 attempts*'
        Should -Invoke Invoke-RestMethod -Times 8 -Exactly -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'retries reference resolution before requesting Foundry' {
        Mock Invoke-RestMethod {
            $referenceState.Reads++
            $status = if ($referenceState.Reads -le 4) { 'AccessToKeyVaultDenied' } else { 'Resolved' }
            @{ properties = @{ status = $status } }
        } -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        (& $checkScript @checkParameters).KeyVaultReferencesVerified | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not accept an HTTP 200 platform page as Foundry readiness' {
        Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<title>App Service</title>' } }
        { & $checkScript @checkParameters } | Should -Throw '*within 2 attempts*'
    }

    It 'accepts only mountinfo for the expected CIFS share at /data' {
        $mountInfoPath = Join-Path $TestDrive 'mountinfo'
        '102 99 0:73 / /data rw,relatime - cifs //fvtttest.file.core.windows.net/foundryvttdata rw' |
            Set-Content -LiteralPath $mountInfoPath
        $checkParameters.MountInfoPath = $mountInfoPath
        (& $checkScript @checkParameters).RuntimeMountVerified | Should -BeTrue
        Should -Invoke Write-Warning -Times 0 -Exactly

        '102 99 0:73 / /data rw,relatime - ext4 /dev/sda1 rw' |
            Set-Content -LiteralPath $mountInfoPath
        { & $checkScript @checkParameters } | Should -Throw '*CIFS mount at /data*'
    }

    It 'surfaces authentication failure without running Azure checks' {
        Mock azd { $global:LASTEXITCODE = 1 }
        { & $checkScript @checkParameters } | Should -Throw '*Cannot obtain*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
