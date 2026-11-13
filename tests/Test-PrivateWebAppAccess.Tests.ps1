BeforeAll {
    $privateScript = Join-Path $PSScriptRoot '..\scripts\Test-PrivateWebAppAccess.ps1'
    $script:parameters = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000001'
        TenantId = '00000000-0000-0000-0000-000000000002'
        WebAppName = 'fvtt-asp-on-123-1'
        ResourceGroupName = 'rg-fvtt-asp-on-123-1'
        EvidencePath = Join-Path $TestDrive 'access.txt'
        WhatIf = $true
    }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($privateScript, [ref]$null, [ref]$null)
    foreach ($functionName in @('Get-TestLog', 'Get-TestProbe')) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $false)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    function Invoke-TestManagementRequest {
        param([string]$ResourceId, [string]$Method)
        throw "Unexpected management request: $Method $ResourceId"
    }
    function Write-TestEvidence { param([string]$Message) throw "Unexpected evidence write: $Message" }
}

Describe 'Private access test scope' {
    It 'refuses production names before Azure access' {
        $invalid = $script:parameters.Clone()
        $invalid.WebAppName = 'production'
        { & $privateScript @invalid } | Should -Throw '*does not match*'
    }

    It 'refuses a different resource group before Azure access' {
        $invalid = $script:parameters.Clone()
        $invalid.ResourceGroupName = 'rg-production'
        { & $privateScript @invalid } | Should -Throw '*does not match the isolated private test*'
    }
}

Describe 'Private access log collection' {
    BeforeEach {
        $script:appId = '/subscriptions/test/resourceGroups/rg-fvtt-asp-on-123-1/providers/Microsoft.Web/sites/fvtt-asp-on-123-1'
        Mock Write-TestEvidence {}
    }

    It 'reports <FailureType> as unavailable without blocking access diagnosis' -TestCases @(
        @{ FailureType = [System.Threading.Tasks.TaskCanceledException] }
        @{ FailureType = [System.Net.Http.HttpRequestException] }
        @{ FailureType = [System.Net.WebException] }
    ) {
        param($FailureType)
        $script:logFailureType = $FailureType
        Mock Invoke-TestManagementRequest {
            throw [Activator]::CreateInstance($script:logFailureType, 'Private log transport failed.')
        }
        Get-TestLog -Phase Baseline | Should -BeNullOrEmpty
        Should -Invoke Write-TestEvidence -Times 1 -Exactly -ParameterFilter {
            $Message -like '*unavailable (transport failure or timeout)*No access or mount claim*'
        }
    }

    It 'preserves management permission errors' {
        Mock Invoke-TestManagementRequest {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Management access forbidden.', $response)
        }
        { Get-TestLog -Phase Baseline } | Should -Throw '*Management access forbidden*'
        Should -Invoke Write-TestEvidence -Times 0 -Exactly
    }
}

Describe 'Private access probe startup evidence' {
    BeforeEach {
        $script:logReads = 0
        $script:mountedInfo = '41 31 0:44 / /data rw - cifs //fvttaspon1231.file.core.windows.net/foundryvttdata rw'
        $script:probe = @{
            phase = 'Restored'
            mountInfo = ''
            privateDnsMatches = $true
            smbTcpConnected = $true
            keyResolved = $true
            fileRestStatus = 200
            dnsError = ''
            smbTcpError = ''
            fileRestError = ''
        }
        Mock Start-Sleep {}
        Mock Write-TestEvidence {}
        Mock Get-TestLog {
            $script:logReads++
            $frame = $script:probe.Clone()
            if ($script:logReads -gt 1) { $frame.mountInfo = $script:mountedInfo }
            $json = $frame | ConvertTo-Json -Compress
            'FVTT_ACCESSINFO:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        }
    }

    It 'waits past a mount-free startup frame after restoration' {
        $result = Get-TestProbe -Phase Restored
        $result.mountInfo | Should -BeExactly $script:mountedInfo
        $script:logReads | Should -Be 2
    }

    It 'keeps mount-free access evidence in the <Phase> phase' -TestCases @(
        @{ Phase = 'Baseline' }
        @{ Phase = 'Control' }
    ) {
        param($Phase)
        $script:probe.phase = $Phase
        $result = Get-TestProbe -Phase $Phase
        $result.mountInfo | Should -BeExactly ''
        $result.fileRestStatus | Should -Be 200
        $script:logReads | Should -Be 1
    }
}
