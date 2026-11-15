[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester uses these variables across its setup, test, and cleanup scriptblocks.')]
[CmdletBinding()]
param()

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $checkScript = Join-Path $repoRoot 'scripts\Test-WebAppInfrastructure.ps1'
    $originalLastExitCode = $global:LASTEXITCODE

    function azd {
        throw 'The azd command must be mocked during these unit tests.'
    }
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

    It 'sets Key Vault public access explicitly for both networking modes' {
        $template.resources.keyVault.properties.parameters.publicNetworkAccess |
            Should -Be "[if(variables('effectiveDeployNetworking'), createObject('value', 'Disabled'), createObject('value', 'Enabled'))]"
        $template.resources.keyVault.properties.parameters.networkAcls.value.defaultAction |
            Should -Be "[if(variables('effectiveDeployNetworking'), 'Deny', 'Allow')]"
    }

    It 'keeps extra tags opt-in and scoped to the group while preserving required tags' {
        @($template.parameters.resourceGroupTags.defaultValue.PSObject.Properties).Count | Should -Be 0
        $template.resources.rg.tags | Should -Be "[union(parameters('resourceGroupTags'), variables('tags'))]"
        $template.resources.storageAccount.properties.parameters.tags.value | Should -Be "[variables('tags')]"
        $template.resources.keyVault.properties.parameters.tags.value | Should -Be "[variables('tags')]"
        $deployment.properties.parameters.tags.value | Should -Be "[variables('tags')]"
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
        $storageAccountProperties = @{ allowSharedKeyAccess = $true }
        $referenceState = @{ Status = 'Resolved'; Reads = 0 }

        Mock azd { $global:LASTEXITCODE = 0; 'test-token' }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/providers/Microsoft.Storage/storageAccounts/fvtttest?*') {
                return @{ properties = $storageAccountProperties }
            }
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

    It 'rejects disabled Shared Key access before readiness polling with networking <Networking>' -TestCases @(
        @{ Networking = 'Enabled' }
        @{ Networking = 'Disabled' }
    ) {
        param($Networking)
        $checkParameters.Networking = $Networking
        $appProperties.outboundVnetRouting.allTraffic = $Networking -eq 'Enabled'
        if ($Networking -eq 'Disabled') {
            $appProperties.virtualNetworkSubnetId = $null
        }
        $storageAccountProperties.allowSharedKeyAccess = $false
        $storageAccountProperties.privateResponse = 'private-response-marker'

        $failure = { & $checkScript @checkParameters } |
            Should -Throw '*allowSharedKeyAccess=false*Review effective Azure Policy*runtime /data mount remain unverified*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'private-response-marker'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
            $Uri -like '*/config/azurestorageaccounts/list?*' -or
                $Uri -like '*/config/configreferences/appsettings/*'
        }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Write-Information -Times 0 -Exactly
    }

    It 'accepts the documented null default for Shared Key access' {
        $storageAccountProperties.allowSharedKeyAccess = $null
        (& $checkScript @checkParameters).FoundryHttpReady | Should -BeTrue
    }

    It 'does not treat an unreadable storage account as compatible' {
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Storage account read forbidden.', $response)
        } -ParameterFilter { $Uri -like '*/providers/Microsoft.Storage/storageAccounts/fvtttest?*' }
        { & $checkScript @checkParameters } | Should -Throw '*Storage account read forbidden*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects a storage account response without properties' {
        Mock Invoke-RestMethod { @{} } -ParameterFilter {
            $Uri -like '*/providers/Microsoft.Storage/storageAccounts/fvtttest?*'
        }
        { & $checkScript @checkParameters } | Should -Throw '*response has no properties*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'stops after the retry limit when any Key Vault reference remains unresolved' {
        $referenceState.Status = 'AccessToKeyVaultDenied'
        { & $checkScript @checkParameters } |
            Should -Throw '*within 2 attempts*Last readiness result: Key Vault references are unresolved.*FOUNDRY_USERNAME=AccessToKeyVaultDenied*STORAGE_ACCOUNT_KEY=AccessToKeyVaultDenied*'
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

    It 'retries a reset management connection within the readiness limit' {
        Mock Invoke-RestMethod {
            $referenceState.Reads++
            if ($referenceState.Reads -eq 1) {
                throw [System.IO.IOException]::new('Connection reset by peer.')
            }
            @{ properties = @{ status = 'Resolved' } }
        } -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        (& $checkScript @checkParameters).KeyVaultReferencesVerified | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*management request failed*FOUNDRY_USERNAME*' }
    }

    It 'reports an unreadable reference status when management connections keep resetting' {
        Mock Invoke-RestMethod {
            throw [System.IO.IOException]::new('Connection reset by peer.')
        } -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        { & $checkScript @checkParameters } |
            Should -Throw '*within 2 attempts*Last readiness result: Key Vault reference status request failed.*FOUNDRY_USERNAME=ManagementRequestFailed*'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'does not treat a management permission error as a reset connection' {
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Management access forbidden.', $response)
        } -ParameterFilter { $Uri -like '*/config/configreferences/appsettings/*' }
        { & $checkScript @checkParameters } | Should -Throw '*Management access forbidden*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'does not accept an HTTP 200 platform page as Foundry readiness' {
        Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<title>App Service</title>private-response-marker' } }
        { & $checkScript @checkParameters } |
            Should -Throw '*within 2 attempts*Last readiness result: HTTP 200 response does not identify Foundry.*'
        Should -Invoke Write-Information -Times 2 -Exactly -ParameterFilter {
            $MessageData -like '*HTTP 200 response does not identify Foundry.*' -and
                $MessageData -notlike '*private-response-marker*'
        }
    }

    It 'reports HTTP <StatusCode> without printing the response body' -TestCases @(
        @{ StatusCode = 403 }
        @{ StatusCode = 503 }
    ) {
        param($StatusCode)
        $httpFailure = @{ StatusCode = $StatusCode; Content = 'private-response-marker' }
        Mock Invoke-WebRequest { $httpFailure }
        { & $checkScript @checkParameters } |
            Should -Throw "*within 2 attempts*Last readiness result: HTTP status $StatusCode.*"
        Should -Invoke Write-Information -Times 2 -Exactly -ParameterFilter {
            $MessageData -like "*HTTP status $StatusCode.*" -and
                $MessageData -notlike '*private-response-marker*'
        }
    }

    It 'retries an HTTP timeout before Foundry becomes ready' {
        $httpState = @{ Attempts = 0 }
        Mock Invoke-WebRequest {
            $httpState.Attempts++
            if ($httpState.Attempts -eq 1) {
                throw [System.Threading.Tasks.TaskCanceledException]::new('HTTP request timed out.')
            }
            @{ StatusCode = 200; Content = '<title>Foundry Virtual Tabletop</title>' }
        }
        (& $checkScript @checkParameters).FoundryHttpReady | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*HTTP request failed*' }
    }

    It 'stops at the retry limit when HTTP requests keep timing out' {
        Mock Invoke-WebRequest {
            throw [System.Threading.Tasks.TaskCanceledException]::new('HTTP request timed out.')
        }
        { & $checkScript @checkParameters } |
            Should -Throw '*within 2 attempts*Last readiness result: HTTP request failed.*'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
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

Describe 'Isolated Web App workflow scope' {
    BeforeAll {
        $workflow = Get-Content (Join-Path $repoRoot '.github\workflows\test-infrastructure.yml') -Raw
        $scopeMatch = [regex]::Match($workflow, '(?s)- name: Validate isolated Web App scope.*?run: \|\r?\n(?<code>(?:          [^\r\n]*(?:\r?\n|$))+)')
        if (-not $scopeMatch.Success) {
            throw 'Cannot find the isolated Web App scope check.'
        }
        $scopeCheck = [scriptblock]::Create(($scopeMatch.Groups['code'].Value -replace '(?m)^          ', ''))
    }

    BeforeEach {
        $scopeEnvironment = @{
            GITHUB_RUN_ID = '123'
            GITHUB_RUN_ATTEMPT = '1'
            AZURE_COMPUTE_SERVICE = 'Web App'
            AZURE_ENV_NAME = 'fvtt-asp-on-123-1'
            AZURE_RESOURCE_GROUP_NAME = 'rg-fvtt-asp-on-123-1'
        }
        $originalScopeEnvironment = @{}
        foreach ($environmentName in $scopeEnvironment.Keys) {
            $originalScopeEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
            [Environment]::SetEnvironmentVariable($environmentName, $scopeEnvironment[$environmentName])
        }
    }

    AfterEach {
        foreach ($environmentName in $originalScopeEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($environmentName, $originalScopeEnvironment[$environmentName])
        }
    }

    It 'accepts the unique names for either networking case' {
        { & $scopeCheck } | Should -Not -Throw
        $env:AZURE_ENV_NAME = 'fvtt-asp-off-123-1'
        $env:AZURE_RESOURCE_GROUP_NAME = 'rg-fvtt-asp-off-123-1'
        { & $scopeCheck } | Should -Not -Throw
    }

    It 'rejects a target outside this run for <Name>' -TestCases @(
        @{ Name = 'AZURE_RESOURCE_GROUP_NAME'; Value = 'production-group' }
        @{ Name = 'AZURE_ENV_NAME'; Value = 'fvtt-asp-on-122-1' }
        @{ Name = 'AZURE_COMPUTE_SERVICE'; Value = 'Container Instance' }
    ) {
        param($Name, $Value)
        [Environment]::SetEnvironmentVariable($Name, $Value)
        { & $scopeCheck } | Should -Throw '*require the unique Web App and resource group names*'
    }
}
