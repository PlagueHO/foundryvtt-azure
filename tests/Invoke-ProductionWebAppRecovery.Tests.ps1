BeforeAll {
    $script:recoveryScript = Join-Path $PSScriptRoot '..\scripts\Invoke-ProductionWebAppRecovery.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:recoveryScript, [ref]$null, [ref]$null)
    foreach ($name in @('Test-RecoveryScope', 'Test-RecoveryChange', 'Test-RecoveryOwnership', 'Get-RecoverySnapshot',
        'ConvertFrom-RecoveryProbe', 'ConvertFrom-RecoveryJson', 'Get-RecoveryContainerProbe', 'Get-RecoveryLogEvidence',
        'Remove-RecoveryCompute', 'Remove-RecoverySnapshot')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Invoke-RecoveryCli {
        param([string[]]$Arguments)
        throw "Unexpected Azure call: $($Arguments[0]) $($Arguments[1])."
    }
    function Get-RecoveryToken { return 'test-token' }
    function Invoke-RecoveryRequest {
        param([string]$Id, [string]$Method = 'Get', [string]$ApiVersion, [switch]$AllowMissing)
        throw "Unexpected management request: $Id $Method $ApiVersion $AllowMissing."
    }
    function Save-RecoveryManifest { throw 'Unexpected manifest write.' }
    $script:valid = @{
        subscriptionId='00000000-0000-0000-0000-000000000001'; environmentName='example'
        resourceGroupName='example-rg'; storageAccountName='example'; vaultName='kvexample'
        recoveryId='00000000-0000-0000-0000-000000000002'; location='newzealandnorth'
        sku='P0v3'; capacity=1; budgetNzd=5; computeMinutes=90; snapshotHours=24
        shareName='foundryvttdata'; foundryImageTag='release'; deployProxy=$true
        repository='example/repository'
    }
}

Describe 'Safe production application-container evidence' {
    BeforeEach {
        $script:probe = @{
            phase='Recovery';privateDnsMatches=$true;smbTcpConnected=$true;keyResolved=$true
            dnsError='';smbTcpError='';fileRestError='';fileRestStatus=200;mountInfo=''
        }
    }

    It 'does not treat successful FileREST access as an SMB mount' {
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        (ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example').runtimeMountVerified | Should -BeFalse
    }

    It 'requires the exact account and share for the CIFS mount' {
        $script:probe.mountInfo = '1 2 0:1 / /data rw - cifs //other.file.core.windows.net/foundryvttdata rw'
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        (ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example').runtimeMountVerified | Should -BeFalse
    }

    It 'accepts the exact CIFS mount without exporting mount options' {
        $script:probe.mountInfo = '1 2 0:1 / /data rw - cifs //example.file.core.windows.net/foundryvttdata rw,[redacted]'
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        $result = ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example'
        $result.runtimeMountVerified | Should -BeTrue
        $result.ContainsKey('mountInfo') | Should -BeFalse
    }

    It 'rejects string booleans' {
        $script:probe.keyResolved = 'true'
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        { ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example' } | Should -Throw '*boolean*'
    }

    It 'rejects arbitrary error text' {
        $script:probe.fileRestError = 'untrusted text'
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        { ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example' } | Should -Throw '*error code*'
    }

    It 'rejects a frame from another recovery attempt' {
        $frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:probe | ConvertTo-Json)))
        { ConvertFrom-RecoveryProbe -Frame $frame -StorageAccountName 'example' -ExpectedPhase 'Recovery-another-attempt' } |
        Should -Throw '*Invalid application-container probe frame*'
    }
}

Describe 'Application log collection and confirmed cleanup' {
    BeforeEach {
        $script:m = @{ storageAccountName='example'; recoveryId='this-run'; computeMinutes=90
        probePhase='Recovery'; computeStartedAt=[DateTime]::UtcNow.ToString('o') }
        $script:appId = 'app'
        $script:computeIds = @('app')
        $script:shareId = 'share'
        $script:storageId = 'storage'
        $script:vaultId = 'vault'
        $script:workspaceId = 'workspace'
        $script:subnetId = 'subnet'
        Mock Save-RecoveryManifest {}
        Mock Start-Sleep {}
    }

    It 'captures actual mount evidence directly when monitoring ingestion has no frame' {
        $payload = @{
        phase='Recovery';privateDnsMatches=$true;smbTcpConnected=$true;keyResolved=$true
        dnsError='';smbTcpError='';fileRestError='';fileRestStatus=200
        mountInfo='1 2 0:1 / /data rw - cifs //example.file.core.windows.net/foundryvttdata rw'
        }
        $script:frame = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json)))
        Mock Invoke-RecoveryRequest { "FVTT_ACCESSINFO:$script:frame" }
        Get-RecoveryContainerProbe
        $script:m.runtimeMountVerified | Should -BeTrue
        $script:m.probe.keyResolved | Should -BeTrue
        $script:m.containerProbeCount | Should -Be 1
    }

    It 'does not claim a mount when the application log request times out' {
        Mock Invoke-RecoveryRequest { throw [System.Threading.Tasks.TaskCanceledException]::new('timeout') }
        Get-RecoveryContainerProbe -WarningAction SilentlyContinue
        $script:m.runtimeMountVerified | Should -Not -BeTrue
    }

    It 'verifies deletion after a lost response without sending another delete' {
        $script:deleteSent = $false
        Mock Invoke-RecoveryRequest {
        param($Id, $Method)
        if ($Method -eq 'Delete') {
            $script:deleteSent = $true
            throw [System.Threading.Tasks.TaskCanceledException]::new('timeout')
        }
        if ($Id -eq 'app') {
            if ($script:deleteSent) { return $null }
            return @{id='app';tags=@{'fvtt-recovery-id'='this-run'}}
        }
        return @{id='existing'}
        }
        Remove-RecoveryCompute -Confirm:$false -WarningAction SilentlyContinue
        $script:deleteSent | Should -BeTrue
        $script:m.computeCleanupVerified | Should -BeTrue
        $script:m.computeCleanupWithinLimit | Should -BeTrue
    }

    It 'checks ownership again after a throttled delete' {
        $script:deleteCount = 0
        $script:ownershipReads = 0
        Mock Invoke-RecoveryRequest {
            param($Id, $Method)
            if ($Method -eq 'Delete') {
                $script:deleteCount++
                if ($script:deleteCount -eq 1) {
                    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('throttled', $response)
                }
                return
            }
            if ($Id -eq 'app') {
                if ($script:deleteCount -ge 2) { return $null }
                $script:ownershipReads++
                return @{id='app';tags=@{'fvtt-recovery-id'='this-run'}}
            }
            return @{id='existing'}
        }
        Remove-RecoveryCompute -Confirm:$false -WarningAction SilentlyContinue
        $script:ownershipReads | Should -Be 2
        $script:m.computeCleanupVerified | Should -BeTrue
    }

    It 'preserves the first verified compute cleanup time on repeated checks' {
        $script:m.computeStartedAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
        $completed = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        $script:m.computeCleanupCompletedAt = $completed
        Mock Invoke-RecoveryRequest {
            param($Id)
            if ($Id -eq 'app') { return $null }
            return @{id='existing'}
        }
        Remove-RecoveryCompute -Confirm:$false
        $script:m.computeCleanupCompletedAt | Should -BeExactly $completed
        $script:m.computeCleanupWithinLimit | Should -BeTrue
    }

    It 'retains mount proof and resolved-key evidence from different log frames' {
        $script:groupId = '/subscriptions/test/resourceGroups/example-rg'
        $script:m.appPrincipalId = 'principal'
        $script:m.workspaceCustomerId = 'workspace'
        $payload = @{
            phase='Recovery';privateDnsMatches=$true;smbTcpConnected=$true;keyResolved=$true
            dnsError='';smbTcpError='';fileRestError='';fileRestStatus=200;mountInfo=''
        }
        $resolved = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json)))
        $payload.keyResolved = $false
        $payload.fileRestStatus = $null
        $payload.fileRestError = 'StorageKeyNotResolved'
        $payload.mountInfo = '1 2 0:1 / /data rw - cifs //example.file.core.windows.net/foundryvttdata rw'
        $mounted = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json)))
        $rows = [Collections.Generic.List[object]]::new()
        $rows.Add(@('AppServiceConsoleLogs', '', $resolved, '', '', '', '', $false, $false, 1))
        $rows.Add(@('AzureDiagnostics', '', $mounted, '', '', '', '', $false, $false, 1))
        $script:logResult = [pscustomobject]@{ tables=@([pscustomobject]@{ rows=$rows.ToArray() }) }
        Mock Invoke-RestMethod { return $script:logResult }
        Get-RecoveryLogEvidence
        $script:m.runtimeMountVerified | Should -BeTrue
        $script:m.probe.keyResolved | Should -BeTrue
        $script:m.logEvidence.Count | Should -Be 2
        $script:m.logEvidence[1].Table | Should -Be 'AzureDiagnostics'
        $script:m.logEvidence[0].PSObject.Properties.Name | Should -Not -Contain 'Frame'
    }

    It 'does not hide a monitoring permission failure as a transport failure' {
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('forbidden', $response)
        }
        { Get-RecoveryLogEvidence } | Should -Throw '*forbidden*'
        $script:m.runtimeMountVerified | Should -Not -BeTrue
    }
}

Describe 'Exact production snapshot cleanup' {
    BeforeEach {
        $script:m = @{ snapshot=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); snapshotHours=24
            resourceGroupName='example-rg'; storageAccountName='example' }
        $script:shareId = 'share'
        $script:deleted = $false
        Mock Save-RecoveryManifest {}
        Mock Invoke-RecoveryRequest { return @{ id='share' } }
        Mock Invoke-RecoveryCli {
            param($Arguments)
            switch ($Arguments[2]) {
                'list' {
                    if (-not $script:deleted) { @{id='share';snapshotTime=$script:m.snapshot} }
                    @{id='share';snapshotTime='another-snapshot'}
                    @{id='share'}
                }
                'show' { @{id='share';snapshotTime=$script:m.snapshot} }
                'delete' { $script:deleted = $true }
                default { throw 'Unexpected snapshot operation.' }
            }
        }
    }

    It 'deletes only the exact snapshot and verifies the live share' {
        Remove-RecoverySnapshot
        $script:m.snapshotCleanupVerified | Should -BeTrue
        $script:m.snapshotCleanupWithinLimit | Should -BeTrue
        Should -Invoke Invoke-RecoveryCli -Times 1 -Exactly -ParameterFilter {
            $Arguments[2] -eq 'delete' -and $Arguments[4] -eq $script:shareId -and
            $Arguments[5] -eq '--snapshot' -and $Arguments[6] -ceq $script:m.snapshot
        }
    }

    It 'verifies an already absent snapshot without deleting another target' {
        $script:deleted = $true
        Remove-RecoverySnapshot
        $script:m.snapshotCleanupVerified | Should -BeTrue
        $script:m.snapshotCleanupAlreadyAbsent | Should -BeTrue
        Should -Invoke Invoke-RecoveryCli -Times 0 -Exactly -ParameterFilter { $Arguments[2] -eq 'delete' }
    }

    It 'does not delete or mark a retained snapshot complete under WhatIf' {
        Remove-RecoverySnapshot -WhatIf
        $script:m.snapshotCleanupVerified | Should -Not -BeTrue
        Should -Invoke Invoke-RecoveryCli -Times 0 -Exactly -ParameterFilter { $Arguments[2] -eq 'delete' }
    }

    It 'does not claim success when the snapshot remains after deletion' {
        Mock Invoke-RecoveryCli { @{id='share';snapshotTime=$script:m.snapshot} }
        { Remove-RecoverySnapshot } | Should -Throw '*deletion was not verified*'
        $script:m.snapshotCleanupVerified | Should -Not -BeTrue
    }

    It 'does not claim success when the live share cannot be verified' {
        Mock Invoke-RecoveryRequest { return @{id='another-share'} }
        { Remove-RecoverySnapshot } | Should -Throw '*live production share was not verified*'
        $script:m.snapshotCleanupVerified | Should -Not -BeTrue
    }
}

Describe 'Production recovery scope' {
    It 'rejects changed <Field> limits before any Azure call' -TestCases @(
        @{ Field='capacity'; Value=2 }
        @{ Field='budgetNzd'; Value=10 }
        @{ Field='computeMinutes'; Value=180 }
        @{ Field='snapshotHours'; Value=48 }
        @{ Field='location'; Value='eastus' }
        @{ Field='foundryImageTag'; Value='latest' }
    ) {
        param($Field, $Value)
        $invalid = $script:valid.Clone()
        $invalid[$Field] = $Value
        { Test-RecoveryScope $invalid } | Should -Throw '*approved resource and cost limits*'
    }

    It 'refuses compute allocation without cleanup registration' {
        $path = Join-Path $TestDrive 'manifest.json'
        $script:valid | ConvertTo-Json | Set-Content $path
        { & $script:recoveryScript -ManifestPath $path -Mode Run -Confirm:$false } |
            Should -Throw '*Register and verify snapshot expiry cleanup*'
    }
}

Describe 'Production recovery what-if allowlist' {
    BeforeEach { $script:appId = '/subscriptions/test/resourceGroups/example-rg/providers/Microsoft.Web/sites/example' }

    It 'rejects a storage change' {
        $changes = @(@{changeType='Modify';resourceId='/subscriptions/test/resourceGroups/example-rg/providers/Microsoft.Storage/storageAccounts/example'})
        { Test-RecoveryChange -Changes $changes -ComputeIds @($script:appId) } | Should -Throw '*unapproved change*'
    }

    It 'rejects changes to an existing app' {
        { Test-RecoveryChange -Changes @(@{changeType='Modify';resourceId=$script:appId}) -ComputeIds @($script:appId) } |
            Should -Throw '*unapproved change*'
    }

    It 'accepts only the new app and its configuration' {
        Test-RecoveryChange -Changes @(
            @{changeType='Create';resourceId=$script:appId}
            @{changeType='Create';resourceId="$script:appId/config/azurestorageaccounts"}
        ) -ComputeIds @($script:appId)
    }

    It 'does not accept a similar resource name' {
        { Test-RecoveryChange -Changes @(@{changeType='Create';resourceId="$script:appId-other"}) -ComputeIds @($script:appId) } |
            Should -Throw '*unapproved change*'
    }

    It 'permits ignored existing data but rejects its redeployment' {
        $storageId = '/subscriptions/test/resourceGroups/example-rg/providers/Microsoft.Storage/storageAccounts/example'
        Test-RecoveryChange -Changes @(
            @{changeType='Create';resourceId=$script:appId}
            @{changeType='Ignore';resourceId=$storageId;after=@{id=$storageId;name='example';type='Microsoft.Storage/storageAccounts'}}
        ) -ComputeIds @($script:appId) -PreservedIds @($storageId)
        { Test-RecoveryChange -Changes @(@{changeType='NoChange';resourceId=$storageId}) -ComputeIds @($script:appId) -PreservedIds @($storageId) } |
            Should -Throw '*unapproved change*'
    }

    It 'rejects incomplete compute expansion' {
        { Test-RecoveryChange -Changes @(@{changeType='Create';resourceId="$script:appId/config/logs"}) -ComputeIds @($script:appId) } |
            Should -Throw '*did not establish creation*'
    }
}

Describe 'Production recovery cleanup ownership' {
    It 'preserves the exact snapshot identifier during JSON reads' {
        $result = ConvertFrom-RecoveryJson -Json '{"snapshot":"2026-11-14T01:23:45.1234567Z"}' -AsHashtable
        $result.snapshot | Should -BeOfType [string]
        $result.snapshot | Should -BeExactly '2026-11-14T01:23:45.1234567Z'
    }

    It 'refuses a different owner tag' {
        { Test-RecoveryOwnership -Resource @{id='app';tags=@{'fvtt-recovery-id'='someone-else'}} -ExpectedId 'app' -RecoveryId 'this-run' } |
            Should -Throw '*Refusing deletion*'
    }

    It 'refuses an unrecorded resource' {
        { Test-RecoveryOwnership -Resource @{id='other';tags=@{'fvtt-recovery-id'='this-run'}} -ExpectedId 'app' -RecoveryId 'this-run' } |
            Should -Throw '*Refusing deletion*'
    }

    It 'cannot delete a live share in place of an absent snapshot' {
        $script:m = @{ snapshot='' }
        { Get-RecoverySnapshot } | Should -Throw '*No exact recovery snapshot*'
    }
}
