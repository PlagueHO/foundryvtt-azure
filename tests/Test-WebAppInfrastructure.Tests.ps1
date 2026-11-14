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

    It 'collects live diagnostic settings and fixed log markers without printing secrets or checking readiness' {
        $checkParameters.DiagnosticsOnly = $true
        $appProperties.state = 'Running'
        Mock Invoke-RestMethod {
            @{ properties = @{ allowSharedKeyAccess = $false; publicNetworkAccess = 'Disabled'; accessKey = 'private-response-marker' } }
        } -ParameterFilter { $Uri -like '*/storageAccounts/fvtttest?*' }
        Mock Invoke-RestMethod {
            @{ properties = @{ enabledProtocols = 'SMB' } }
        } -ParameterFilter { $Uri -like '*/shares/foundryvttdata?*' }
        Mock Invoke-WebRequest {
            @{ StatusCode = 200; Content = 'BYOSFailure private-response-marker test-token' }
        }

        $result = & $checkScript @checkParameters
        $result.Settings.AppState | Should -Be 'Running'
        $result.Settings.SharedKeyAccess | Should -BeFalse
        $result.Settings.StoragePublicNetworkAccess | Should -Be 'Disabled'
        $result.Settings.ShareProtocol | Should -Be 'SMB'
        $result.ContainerLogStatus | Should -Be 'Read'
        $result.FailureMarkers | Should -Contain 'BYOSFailure'
        $result.RuntimeMountVerified | Should -BeFalse
        ($result | ConvertTo-Json -Depth 3) | Should -Not -Match 'private-response-marker|test-token'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like 'https://management.azure.com/*/sites/fvtt-test/containerlogs?*'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*/config/*' }
        Should -Invoke Write-Information -Times 0 -Exactly -ParameterFilter { $MessageData -match 'private-response-marker|test-token' }
    }

    It 'reports diagnostic permission errors while continuing the remaining diagnostic reads' {
        $checkParameters.DiagnosticsOnly = $true
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('private-response-marker test-token', $response)
        } -ParameterFilter { $Uri -like '*/storageAccounts/fvtttest?*' }
        Mock Invoke-WebRequest { @{ StatusCode = 200; Content = 'ImagePullFailure' } }

        { & $checkScript @checkParameters } | Should -Throw '*diagnostic requests failed*original readiness or provisioning failure*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*/shares/foundryvttdata?*' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*StorageAccount*HTTP 403*' }
        Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -match 'private-response-marker|test-token' }
    }

    It 'reports unavailable logs without treating them as runtime mount evidence' -TestCases @(
        @{ StatusCode = 200 }
        @{ StatusCode = 204 }
    ) {
        param($StatusCode)
        $checkParameters.DiagnosticsOnly = $true
        $emptyLogs = @{ StatusCode = $StatusCode; Content = '' }
        Mock Invoke-WebRequest { $emptyLogs }

        $result = & $checkScript @checkParameters
        $result.ContainerLogStatus | Should -Be 'Unavailable'
        $result.FailureMarkers.Count | Should -Be 0
        $result.RuntimeMountVerified | Should -BeFalse
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*logs are unavailable*' }
    }

    It 'rejects <Format> container log content without printing it' -TestCases @(
        @{ Format = 'archive'; Content = [byte[]](80, 75, 3, 4) }
        @{ Format = 'invalid UTF-8'; Content = [byte[]](255, 254) }
    ) {
        param($Content)
        $checkParameters.DiagnosticsOnly = $true
        $unsupportedLogs = @{ StatusCode = 200; Content = $Content }
        Mock Invoke-WebRequest { $unsupportedLogs }

        { & $checkScript @checkParameters } | Should -Throw '*diagnostic requests failed*'
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*unsupported response format*' }
    }

    It 'reads UTF-8 container logs returned as octet-stream content' {
        $checkParameters.DiagnosticsOnly = $true
        Mock Invoke-WebRequest {
            @{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes('BYOSFailure private-response-marker') }
        }

        $result = & $checkScript @checkParameters
        $result.ContainerLogStatus | Should -Be 'Read'
        $result.FailureMarkers | Should -Contain 'BYOSFailure'
        Should -Invoke Write-Information -Times 0 -Exactly -ParameterFilter { $MessageData -like '*private-response-marker*' }
    }

    It 'limits log classification to the tail and does not invent a failure marker' {
        $checkParameters.DiagnosticsOnly = $true
        $longLogs = @{ StatusCode = 200; Content = 'ImagePullFailure' + ('x' * 70000) + ' ContainerStartFailure private-response-marker' }
        Mock Invoke-WebRequest { $longLogs }

        $result = & $checkScript @checkParameters
        $result.FailureMarkers | Should -Contain 'ContainerStartFailure'
        $result.FailureMarkers | Should -Not -Contain 'ImagePullFailure'
        Should -Invoke Write-Information -Times 0 -Exactly -ParameterFilter { $MessageData -like '*private-response-marker*' }
    }

    It 'does not print unknown live property values' {
        $checkParameters.DiagnosticsOnly = $true
        Mock Invoke-RestMethod {
            @{ properties = @{
                state = 'private-response-marker'
                allowSharedKeyAccess = 'test-token'
                publicNetworkAccess = 'private-response-marker'
                enabledProtocols = 'test-token'
            } }
        }
        Mock Invoke-WebRequest { @{ StatusCode = 200; Content = 'No known failure marker.' } }

        $result = & $checkScript @checkParameters
        $result.Settings.AppState | Should -Be 'Unknown'
        $result.Settings.SharedKeyAccess | Should -Be 'Unknown'
        $result.Settings.StoragePublicNetworkAccess | Should -Be 'Unknown'
        $result.Settings.ShareProtocol | Should -Be 'Unknown'
        $result.FailureMarkers.Count | Should -Be 0
        Should -Invoke Write-Information -Times 0 -Exactly -ParameterFilter { $MessageData -match 'private-response-marker|test-token' }
    }

    It 'keeps a container log transport failure separate from the original test failure' {
        $checkParameters.DiagnosticsOnly = $true
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('private-response-marker test-token') }

        { & $checkScript @checkParameters } | Should -Throw '*diagnostic requests failed*original readiness or provisioning failure*'
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Container log diagnostic request failed*' }
        Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -match 'private-response-marker|test-token' }
    }

    It 'rejects an unexpected container log HTTP response without printing its body' {
        $checkParameters.DiagnosticsOnly = $true
        Mock Invoke-WebRequest { @{ StatusCode = 202; Content = 'private-response-marker' } }

        { & $checkScript @checkParameters } | Should -Throw '*diagnostic requests failed*'
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*returned HTTP 202*' }
        Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -like '*private-response-marker*' }
    }
}
