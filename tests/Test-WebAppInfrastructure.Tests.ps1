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

    function Get-TestWebSocket {
        $state = @{
            Mounts = @(@{ mountPoint = '/data'; fileSystem = 'cifs'; source = '//fvtttest.file.core.windows.net/foundryvttdata' })
            FragmentSize = 17
            SplitAfterMountObject = $false
            LineEnding = "`r`n"
            Offset = 0
            Disposed = $false
            CloseWithoutRecord = $false
            FailConnect = $false
            CancelConnect = $false
        }
        $options = [pscustomobject]@{}
        $options | Add-Member ScriptMethod SetRequestHeader {
            param($Name, $Value)
            if ($Name -ne 'Authorization' -or $Value -notlike 'Bearer *') {
                throw 'Expected bearer authentication.'
            }
        }
        $socket = [pscustomobject]@{
            Options = $options
            State = [Net.WebSockets.WebSocketState]::Open
            TestState = $state
        }
        $socket | Add-Member ScriptMethod ConnectAsync {
            param($Uri, $CancellationToken)
            $CancellationToken.ThrowIfCancellationRequested()
            $completion = [Threading.Tasks.TaskCompletionSource[bool]]::new()
            if ($this.TestState.FailConnect) {
                $completion.SetException([Net.WebSockets.WebSocketException]::new('private-transport-error'))
            } elseif ($this.TestState.CancelConnect) {
                $completion.SetCanceled()
            } else {
                $completion.SetResult($true)
            }
            $this.TestState.Uri = $Uri
            return $completion.Task
        }
        $socket | Add-Member ScriptMethod SendAsync {
            param($Buffer, $MessageType, $EndOfMessage, $CancellationToken)
            $CancellationToken.ThrowIfCancellationRequested()
            if ($MessageType -ne [Net.WebSockets.WebSocketMessageType]::Binary -or -not $EndOfMessage) {
                throw 'Expected a complete binary terminal command.'
            }
            $command = [Text.Encoding]::UTF8.GetString($Buffer.Array, $Buffer.Offset, $Buffer.Count)
            $encodedScript = [regex]::Match($command, "Buffer\.from\('(?<script>[A-Za-z0-9+/=]+)'").Groups['script'].Value
            $this.TestState.RemoteScript = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedScript))
            $marker = [regex]::Match($this.TestState.RemoteScript, 'FVTT_MOUNT_[a-f0-9]{32}').Value
            $data = @{ mounts = @($this.TestState.Mounts) } | ConvertTo-Json -Compress -Depth 4
            $prefix = "$command`r`n$marker "
            $this.TestState.Bytes = [Text.Encoding]::UTF8.GetBytes("$prefix$data$($this.TestState.LineEnding)")
            if ($this.TestState.SplitAfterMountObject) {
                $this.TestState.SplitOffset = [Text.Encoding]::UTF8.GetByteCount($prefix + $data.Substring(0, $data.LastIndexOf(']}')))
            }
            return [Threading.Tasks.Task]::CompletedTask
        }
        $socket | Add-Member ScriptMethod ReceiveAsync {
            param($Buffer, $CancellationToken)
            $CancellationToken.ThrowIfCancellationRequested()
            $remaining = $this.TestState.Bytes.Length - $this.TestState.Offset
            if ($this.TestState.CloseWithoutRecord -or $remaining -eq 0) {
                $result = [Net.WebSockets.WebSocketReceiveResult]::new(0, [Net.WebSockets.WebSocketMessageType]::Close, $true)
            } else {
                $count = [Math]::Min($this.TestState.FragmentSize, $remaining)
                if ($this.TestState.SplitAfterMountObject -and $this.TestState.Offset -lt $this.TestState.SplitOffset) {
                    $count = [Math]::Min($count, $this.TestState.SplitOffset - $this.TestState.Offset)
                }
                [Array]::Copy($this.TestState.Bytes, $this.TestState.Offset, $Buffer.Array, $Buffer.Offset, $count)
                $this.TestState.Offset += $count
                $result = [Net.WebSockets.WebSocketReceiveResult]::new($count, [Net.WebSockets.WebSocketMessageType]::Binary, $false)
            }
            $completion = [Threading.Tasks.TaskCompletionSource[Net.WebSockets.WebSocketReceiveResult]]::new()
            $completion.SetResult($result)
            return $completion.Task
        }
        $socket | Add-Member ScriptMethod Dispose { $this.TestState.Disposed = $true }
        return $socket
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
            enabledHostNames = @('fvtt-test.azurewebsites.net', 'fvtt-test.scm.azurewebsites.net')
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

    It 'captures current application mount evidence across fragmented terminal frames without mount options' {
        $socket = Get-TestWebSocket
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        $result = & $checkScript @checkParameters
        $result.RuntimeMountVerified | Should -BeTrue
        $result.RuntimeMountEvidence.Source | Should -Be '//fvtttest.file.core.windows.net/foundryvttdata'
        $result.RuntimeMountEvidence.CaptureMethod | Should -Be 'AppServiceApplicationTerminal'
        $socket.TestState.Uri.AbsoluteUri | Should -Be 'wss://fvtt-test.scm.azurewebsites.net/exec/shell?shell=/bin/sh'
        $socket.TestState.Disposed | Should -BeTrue
        Should -Invoke Write-Warning -Times 0 -Exactly

        $fixture = Join-Path $TestDrive 'application-mountinfo'
        '102 99 0:73 / /data rw,private-option - cifs //fvtttest.file.core.windows.net/foundryvttdata rw,private-option' |
            Set-Content -LiteralPath $fixture
        $fixtureScript = $socket.TestState.RemoteScript.Replace("fs.readFileSync('/proc/self/mountinfo', 'utf8')", "fs.readFileSync(process.argv[1], 'utf8')")
        $actualRecord = & node -e $fixtureScript $fixture
        $LASTEXITCODE | Should -Be 0
        $actualRecord | Should -Match '^FVTT_MOUNT_[a-f0-9]{32} '
        $actualRecord | Should -Not -Match 'private-option'
        $actualMount = ($actualRecord -replace '^FVTT_MOUNT_[a-f0-9]{32} ', '') | ConvertFrom-Json
        $actualMount.mounts[0].source | Should -Be '//fvtttest.file.core.windows.net/foundryvttdata'
    }

    It 'waits for the complete mount record after an inner closing brace with <EndingName>' -TestCases @(
        @{ EndingName = 'CRLF'; LineEnding = "`r`n" }
        @{ EndingName = 'LF'; LineEnding = "`n" }
    ) {
        param($LineEnding)
        $socket = Get-TestWebSocket
        $socket.TestState.SplitAfterMountObject = $true
        $socket.TestState.LineEnding = $LineEnding
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        (& $checkScript @checkParameters).RuntimeMountVerified | Should -BeTrue
        $socket.TestState.Offset | Should -Be $socket.TestState.Bytes.Length
        $socket.TestState.Disposed | Should -BeTrue
    }

    It 'rejects a complete mount record without a terminating newline' {
        $socket = Get-TestWebSocket
        $socket.TestState.LineEnding = ''
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        { & $checkScript @checkParameters } | Should -Throw '*closed without current mount evidence*'
        $socket.TestState.Disposed | Should -BeTrue
    }

    It 'rejects live evidence for <FileSystem> on <Source>' -TestCases @(
        @{ FileSystem = 'ext4'; Source = '/dev/sda1' }
        @{ FileSystem = 'cifs'; Source = '//anotheraccount.file.core.windows.net/foundryvttdata' }
    ) {
        param($FileSystem, $Source)
        $socket = Get-TestWebSocket
        $socket.TestState.Mounts[0].fileSystem = $FileSystem
        $socket.TestState.Mounts[0].source = $Source
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        { & $checkScript @checkParameters } | Should -Throw '*live application-container mountinfo does not show*'
        $socket.TestState.Disposed | Should -BeTrue
    }

    It 'does not accept a terminal connection without a fresh mount record' {
        $socket = Get-TestWebSocket
        $socket.TestState.CloseWithoutRecord = $true
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        { & $checkScript @checkParameters } | Should -Throw '*closed without current mount evidence*'
        $socket.TestState.Disposed | Should -BeTrue
    }

    It 'reports denied terminal access without printing raw transport details' {
        $socket = Get-TestWebSocket
        $socket.TestState.FailConnect = $true
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        $failure = { & $checkScript @checkParameters } | Should -Throw '*Cannot access the application-container terminal*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'private-transport-error'
        $socket.TestState.Disposed | Should -BeTrue
    }

    It 'does not send credentials to an unexpected SCM hostname' {
        $appProperties.enabledHostNames = @('unexpected.example.com')
        $checkParameters.CaptureRuntimeMount = $true
        { & $checkScript @checkParameters } | Should -Throw '*Cannot identify the expected SCM hostname*'
    }

    It 'fails explicitly when the terminal capture deadline expires' {
        $socket = Get-TestWebSocket
        $socket.TestState.CancelConnect = $true
        Mock New-Object { $socket } -ParameterFilter { $TypeName -eq 'System.Net.WebSockets.ClientWebSocket' }
        $checkParameters.CaptureRuntimeMount = $true
        { & $checkScript @checkParameters } | Should -Throw '*mount capture timed out*'
        $socket.TestState.Disposed | Should -BeTrue
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
            AZURE_RESOURCE_GROUP_TAGS = '{}'
            REQUESTED_TEST_RESOURCE_GROUP_TAGS = ''
            CONFIGURED_TEST_RESOURCE_GROUP_TAGS = '{}'
            GITHUB_ENV = (Join-Path $TestDrive 'scope-github-env')
        }
        New-Item -ItemType File -Path $scopeEnvironment.GITHUB_ENV -Force | Out-Null
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

    It 'accepts approved tags only with the unique Web App test scope' {
        $env:CONFIGURED_TEST_RESOURCE_GROUP_TAGS = '{"testApproval":"approved"}'
        { & $scopeCheck } | Should -Not -Throw
        $env:AZURE_RESOURCE_GROUP_NAME = 'production-group'
        { & $scopeCheck } | Should -Throw '*require the unique Web App and resource group names*'
    }

    It 'selects <Selection> tags and passes compact JSON to later deployment steps' -TestCases @(
        @{ Selection = 'environment'; Requested = ''; Expected = '{"testApproval":"approved"}' }
        @{ Selection = 'explicit'; Requested = '{"manualApproval":"approved"}'; Expected = '{"manualApproval":"approved"}' }
        @{ Selection = 'disabled'; Requested = '{}'; Expected = '{}' }
    ) {
        param($Requested, $Expected)
        $env:CONFIGURED_TEST_RESOURCE_GROUP_TAGS = "{`n  `"testApproval`": `"approved`"`n}"
        $env:REQUESTED_TEST_RESOURCE_GROUP_TAGS = $Requested
        & $scopeCheck
        @(Get-Content -LiteralPath $env:GITHUB_ENV).Count | Should -Be 1
        (Get-Content -LiteralPath $env:GITHUB_ENV) | Should -Be "AZURE_RESOURCE_GROUP_TAGS=$Expected"
    }

    It 'rejects non-object resource group tags <Tags> from <Setting>' -TestCases @(
        @{ Tags = '[]'; Setting = 'REQUESTED_TEST_RESOURCE_GROUP_TAGS' }
        @{ Tags = '"tag"'; Setting = 'REQUESTED_TEST_RESOURCE_GROUP_TAGS' }
        @{ Tags = 'null'; Setting = 'REQUESTED_TEST_RESOURCE_GROUP_TAGS' }
        @{ Tags = '[{"testApproval":"approved"}]'; Setting = 'REQUESTED_TEST_RESOURCE_GROUP_TAGS' }
        @{ Tags = '[{"testApproval":"approved"}]'; Setting = 'CONFIGURED_TEST_RESOURCE_GROUP_TAGS' }
    ) {
        param($Tags, $Setting)
        [Environment]::SetEnvironmentVariable($Setting, $Tags)
        { & $scopeCheck } | Should -Throw '*must be a JSON object*'
        Get-Content -LiteralPath $env:GITHUB_ENV | Should -BeNullOrEmpty
    }

    It 'rejects malformed resource group tags before deployment' {
        $env:REQUESTED_TEST_RESOURCE_GROUP_TAGS = '{'
        { & $scopeCheck } | Should -Throw
        Get-Content -LiteralPath $env:GITHUB_ENV | Should -BeNullOrEmpty
    }

    It 'handles cleanup with exact target check outcome <Outcome>' -TestCases @(
        @{ Outcome = 'success'; ScopeValidated = 'true'; Expected = $true }
        @{ Outcome = 'success'; ScopeValidated = 'false'; Expected = $false }
        @{ Outcome = 'skipped'; ScopeValidated = ''; Expected = $false }
        @{ Outcome = 'failure'; ScopeValidated = ''; Expected = $false }
        @{ Outcome = 'cancelled'; ScopeValidated = ''; Expected = $false }
    ) {
        param($Outcome, $ScopeValidated, $Expected)
        $condition = [regex]::Match($workflow, '- name: Delete Infrastructure\r?\n        if: (?<condition>[^\r\n]+)').Groups['condition'].Value
        $condition | Should -Not -BeNullOrEmpty
        $condition = $condition.Replace('always()', '$true').Replace('steps.test_scope.outcome', "'$Outcome'").
            Replace('steps.cleanup_scope.outputs.scope_validated', "'$ScopeValidated'").
            Replace('&&', '-and').Replace('==', '-eq')
        (& ([scriptblock]::Create($condition))) | Should -Be $Expected
    }
}
