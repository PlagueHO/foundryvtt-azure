[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares setup variables with test scriptblocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-TestResponse creates only in-memory test data.')]
[CmdletBinding()]
param()

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $cleanupScript = Join-Path $repoRoot 'scripts\Remove-TestInfrastructure.ps1'
    $originalLastExitCode = $global:LASTEXITCODE
    $originalSummary = $Env:GITHUB_STEP_SUMMARY
    $originalOutput = $Env:GITHUB_OUTPUT
    function azd { throw 'azd must be mocked in these tests.' }
    function New-TestResponse {
        param([int]$StatusCode = 200, [object]$Body = @{})
        @{ StatusCode = $StatusCode; Content = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    }
}

AfterAll {
    $global:LASTEXITCODE = $originalLastExitCode
    $Env:GITHUB_STEP_SUMMARY = $originalSummary
    $Env:GITHUB_OUTPUT = $originalOutput
}

Describe 'Guarded test infrastructure cleanup' {
    BeforeEach {
        $cleanupParameters = @{
            SubscriptionId = 'test-subscription'
            TenantId = 'test-tenant'
            EnvironmentName = 'fvtt-aca-123-1'
            ResourceGroupName = 'rg-fvtt-aca-123-1'
            ComputeService = 'Container App'
            RunId = '123'
            RunAttempt = '1'
            Confirm = $false
        }
        $ownedGroup = @{ tags = @{ 'azd-env-name' = 'fvtt-aca-123-1' } }
        $parent = @{
            name = 'fvtt-aca-123-1-1234567890'
            properties = @{
                parameters = @{
                    environmentName = @{ value = 'fvtt-aca-123-1' }
                    resourceGroupName = @{ value = 'rg-fvtt-aca-123-1' }
                }
                provisioningState = 'Running'
            }
        }
        $responses = $script:responses = [Collections.Generic.Queue[object]]::new()
        $requests = $script:requests = [Collections.Generic.List[object]]::new()
        $Env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive "$([guid]::NewGuid()).md"
        $Env:GITHUB_OUTPUT = Join-Path $TestDrive "$([guid]::NewGuid()).output"
        Mock azd { $global:LASTEXITCODE = 0; 'test-token' }
        Mock Start-Sleep {}
        Mock Invoke-WebRequest {
            param($Method, $Uri)
            $requests.Add(@{ Method = $Method; Uri = $Uri })
            if ($responses.Count -eq 0) { throw "Unexpected ARM request: $Method $Uri" }
            $responses.Dequeue()
        }
    }

    It 'rejects names from another run, attempt, compute mode, or group before authentication' -ForEach @(
        @{ Field = 'EnvironmentName'; Value = 'fvtt-aca-456-1' }
        @{ Field = 'EnvironmentName'; Value = 'fvtt-aca-123-2' }
        @{ Field = 'ComputeService'; Value = 'Web App' }
        @{ Field = 'ResourceGroupName'; Value = 'rg-production' }
    ) {
        $cleanupParameters[$Field] = $Value
        { & $cleanupScript @cleanupParameters } | Should -Throw '*Rejected test cleanup scope*'
        Should -Invoke azd -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'rejects an existing target before provisioning' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        { & $cleanupScript @cleanupParameters -ValidateOnly } | Should -Throw '*existing test resource group*'
        @($script:requests | Where-Object Method -NE Get).Count | Should -Be 0
    }

    It 'accepts a new exact test target without changing Azure' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        & $cleanupScript @cleanupParameters -ValidateOnly
        $script:requests.Count | Should -Be 1
        $script:requests[0].Method | Should -Be 'Get'
    }

    It 'does not delete an already absent group' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        & $cleanupScript @cleanupParameters
        $script:requests.Count | Should -Be 1
        Get-Content $Env:GITHUB_STEP_SUMMARY -Raw | Should -Match 'verified \(HTTP 404\)'
    }

    It 'allows a request within the supported one-second deadline' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        & $cleanupScript @cleanupParameters -TimeoutSeconds 1
        $script:requests.Count | Should -Be 1
    }

    It 'removes remaining resources even when azd discovered nothing' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -StatusCode 202))
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        & $cleanupScript @cleanupParameters
        $deletes = @($script:requests | Where-Object Method -EQ Delete)
        $deletes.Count | Should -Be 1
        $deletes[0].Uri | Should -Be 'https://management.azure.com/subscriptions/test-subscription/resourceGroups/rg-fvtt-aca-123-1?api-version=2021-04-01'
        Should -Invoke Start-Sleep -Times 1
        $script:requests[-1].Method | Should -Be 'Get'
        Get-Content $Env:GITHUB_STEP_SUMMARY -Raw | Should -Match 'verified \(HTTP 404\)'
    }

    It 'rejects a missing or incorrect ownership tag without deleting anything' -ForEach @(
        @{ Tags = @{} }
        @{ Tags = @{ 'azd-env-name' = 'production' } }
    ) {
        $script:responses.Enqueue((New-TestResponse -Body @{ tags = $Tags }))
        { & $cleanupScript @cleanupParameters } | Should -Throw '*azd-env-name tag*'
        @($script:requests | Where-Object Method -NE Get).Count | Should -Be 0
    }

    It 'fails on ARM authorization or transport errors instead of claiming absence' -ForEach @(
        @{ Status = 401 }
        @{ Status = 403 }
        @{ Status = 500 }
    ) {
        $script:responses.Enqueue((New-TestResponse -StatusCode $Status))
        { & $cleanupScript @cleanupParameters } | Should -Throw "*HTTP $Status*"
        Test-Path $Env:GITHUB_STEP_SUMMARY | Should -BeFalse
    }

    It 'fails when group deletion is denied' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -StatusCode 403))
        { & $cleanupScript @cleanupParameters } | Should -Throw '*HTTP 403*'
        Test-Path $Env:GITHUB_STEP_SUMMARY | Should -BeFalse
    }

    It 'does not convert a network failure into a successful absence check' {
        Mock Invoke-WebRequest { throw 'Network unavailable.' }
        { & $cleanupScript @cleanupParameters } | Should -Throw '*Network unavailable*'
        Test-Path $Env:GITHUB_STEP_SUMMARY | Should -BeFalse
    }

    It 'does not treat accepted deletion as completed deletion' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -StatusCode 202))
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        Mock Start-Sleep { [Threading.Thread]::Sleep(2100) }
        { & $cleanupScript @cleanupParameters -TimeoutSeconds 2 } | Should -Throw '*deadline reached*not verified*'
        Test-Path $Env:GITHUB_STEP_SUMMARY | Should -BeFalse
    }

    It 'does not change Azure when WhatIf is set' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        & $cleanupScript @cleanupParameters -WhatIf
        @($script:requests | Where-Object Method -NE Get).Count | Should -Be 0
        Test-Path $Env:GITHUB_STEP_SUMMARY | Should -BeFalse
    }

    It 'fails without using a missing or failed authentication token' {
        Mock azd { $global:LASTEXITCODE = 1 }
        { & $cleanupScript @cleanupParameters } | Should -Throw '*Cannot obtain an ARM token*'
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'cancels the exact parent and group deployments without printing secret fields' {
        $parent.properties.parameters.foundryPassword = @{ value = 'do-not-print-secret' }
        $parent.properties.error = @{ code = 'TestCode'; message = 'do-not-print-error-body' }
        $child = @{ name = 'container-app-environment-deployment'; properties = @{ provisioningState = 'Running' } }
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @($parent) }))
        $script:responses.Enqueue((New-TestResponse -Body $parent))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @($child) }))
        $script:responses.Enqueue((New-TestResponse -StatusCode 202))
        $script:responses.Enqueue((New-TestResponse -Body @{ properties = @{ provisioningState = 'Canceled' } }))
        $script:responses.Enqueue((New-TestResponse -StatusCode 202))
        $script:responses.Enqueue((New-TestResponse -Body @{ properties = @{ provisioningState = 'Canceled' } }))
        $output = & $cleanupScript @cleanupParameters -StopDeploymentsOnly 6>&1 | Out-String
        $output | Should -Match 'container-app-environment-deployment'
        $output | Should -Not -Match 'do-not-print'
        $posts = @($script:requests | Where-Object Method -EQ Post)
        $posts.Count | Should -Be 2
        $posts[0].Uri | Should -Match '/subscriptions/test-subscription/providers/'
        $posts[1].Uri | Should -Match '/resourceGroups/rg-fvtt-aca-123-1/'
    }

    It 'does not cancel a subscription deployment with mismatched parameters' {
        $candidate = @{
            name = 'fvtt-aca-123-1-1234567890'
            properties = @{ parameters = @{ environmentName = @{ value = 'production' } } }
        }
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @($candidate) }))
        $script:responses.Enqueue((New-TestResponse -Body $candidate))
        { & $cleanupScript @cleanupParameters -StopDeploymentsOnly } | Should -Throw '*mismatched test parameters*'
        @($script:requests | Where-Object Method -NE Get).Count | Should -Be 0
    }

    It 'checks later deployment pages even when the test group is already absent' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        $script:responses.Enqueue((New-TestResponse -Body @{
            value = @()
            nextLink = 'https://management.azure.com/subscriptions/test-subscription/providers/Microsoft.Resources/deployments?api-version=2021-04-01&skiptoken=next'
        }))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @($parent) }))
        $script:responses.Enqueue((New-TestResponse -Body $parent))
        $script:responses.Enqueue((New-TestResponse -StatusCode 202))
        $script:responses.Enqueue((New-TestResponse -Body @{ properties = @{ provisioningState = 'Canceled' } }))
        & $cleanupScript @cleanupParameters -StopDeploymentsOnly
        @($script:requests | Where-Object Method -EQ Post).Count | Should -Be 1
    }

    It 'accepts a cancellation conflict only when the deployment is already terminal' -ForEach @(
        @{ State = 'Succeeded'; Fails = $false }
        @{ State = 'Running'; Fails = $true }
    ) {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @($parent) }))
        $script:responses.Enqueue((New-TestResponse -Body $parent))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @() }))
        $script:responses.Enqueue((New-TestResponse -StatusCode 409))
        $script:responses.Enqueue((New-TestResponse -Body @{ properties = @{ provisioningState = $State } }))
        if ($Fails) {
            { & $cleanupScript @cleanupParameters -StopDeploymentsOnly } | Should -Throw '*HTTP 409*'
        } else {
            & $cleanupScript @cleanupParameters -StopDeploymentsOnly
        }
    }

    It 'does not authorize azd teardown after ownership validation fails' {
        $script:responses.Enqueue((New-TestResponse -Body @{ tags = @{ 'azd-env-name' = 'production' } }))
        { & $cleanupScript @cleanupParameters -StopDeploymentsOnly } | Should -Throw '*azd-env-name tag*'
        Test-Path $Env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'authorizes azd teardown even when later diagnostics fail' {
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -StatusCode 403))
        { & $cleanupScript @cleanupParameters -StopDeploymentsOnly } | Should -Throw '*HTTP 403*'
        Get-Content $Env:GITHUB_OUTPUT -Raw | Should -Match 'scope_validated=true'
    }

    It 'rejects pagination outside the subscription without forwarding its token' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        $script:responses.Enqueue((New-TestResponse -Body @{
            value = @()
            nextLink = 'https://example.com/collect-token'
        }))
        { & $cleanupScript @cleanupParameters -StopDeploymentsOnly } | Should -Throw '*pagination link*'
        $script:requests.Count | Should -Be 2
    }

    It 'records only the service-managed group name for the later verification step' {
        $evidencePath = Join-Path $TestDrive 'capture.json'
        $script:responses.Enqueue((New-TestResponse -Body $ownedGroup))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @() }))
        $script:responses.Enqueue((New-TestResponse -Body @{ value = @() }))
        $script:responses.Enqueue((New-TestResponse -Body @{
            properties = @{ infrastructureResourceGroup = 'ME_test'; sensitiveData = 'do-not-save' }
        }))
        & $cleanupScript @cleanupParameters -StopDeploymentsOnly -EvidencePath $evidencePath
        $evidence = Get-Content -LiteralPath $evidencePath -Raw
        $evidence | Should -Not -Match 'do-not-save'
        ($evidence | ConvertFrom-Json).managedGroups | Should -Contain 'ME_test'
    }

    It 'waits for provider cleanup without deleting the service-managed group directly' {
        $evidencePath = Join-Path $TestDrive 'managed-group.json'
        @{
            environmentName = 'fvtt-aca-123-1'
            resourceGroupName = 'rg-fvtt-aca-123-1'
            managedGroups = @('ME_test')
        } | ConvertTo-Json | Set-Content -LiteralPath $evidencePath
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        $script:responses.Enqueue((New-TestResponse))
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        & $cleanupScript @cleanupParameters -EvidencePath $evidencePath
        @($script:requests | Where-Object Method -NE Get).Count | Should -Be 0
        Should -Invoke Start-Sleep -Times 1
    }

    It 'reports missing service-managed group evidence after checking the target group' {
        $script:responses.Enqueue((New-TestResponse -StatusCode 404))
        { & $cleanupScript @cleanupParameters -EvidencePath (Join-Path $TestDrive 'missing.json') } |
            Should -Throw '*service-managed group evidence is missing*'
        $script:requests.Count | Should -Be 1
    }
}

Describe 'Compiled Container App secret deployment order' {
    BeforeAll {
        $template = Get-Content (Join-Path $repoRoot 'infra\main.json') -Raw | ConvertFrom-Json
        $app = $template.resources.containerAppFoundryVtt
        $vault = $template.resources.keyVault
        $identity = $template.resources.containerAppIdentity
    }

    It 'prepares the vault and identity before creating the app' {
        $app.dependsOn | Should -Contain 'keyVault'
        $app.dependsOn | Should -Contain 'containerAppIdentity'
        $vault.dependsOn | Should -Contain 'containerAppIdentity'
        $vault.dependsOn | Should -Not -Contain 'containerAppFoundryVtt'
        $identity.condition | Should -Be "[equals(parameters('computeService'), 'Container App')]"
        $app.properties.parameters.managedIdentities.value.systemAssigned | Should -BeTrue
        $app.properties.parameters.managedIdentities.value.userAssignedResourceIds[0] |
            Should -Match "containerAppIdentity.*'outputs'.*'resourceId'"
    }

    It 'uses the authorized user-assigned identity for every Key Vault reference' {
        $secrets = $app.properties.parameters.secrets.value
        $secrets.Count | Should -Be 3
        foreach ($secret in $secrets) {
            $secret.identity | Should -Match "containerAppIdentity.*'outputs'.*'resourceId'"
            $secret.keyVaultUrl | Should -Match 'secrets/'
        }
        $vault.properties.parameters.roleAssignments.value | Should -Match "containerAppIdentity.*'outputs'.*'principalId'"
    }

}

Describe 'Workflow cleanup after provisioning failure' {
    It 'allows bounded time for slow azd deletion and fallback verification' {
        $workflow = Get-Content (Join-Path $repoRoot '.github\workflows\test-infrastructure.yml') -Raw
        $workflow | Should -Match '(?s)name: Delete Infrastructure\s+if: always\(\).*?timeout-minutes: 20'
        $workflow | Should -Match '(?s)name: Verify test group deletion and remove remaining resources\s+if: always\(\).*?timeout-minutes: 30.*?-TimeoutSeconds 1500'
        $workflow | Should -Not -Match 'continue-on-error: true'
    }
}
