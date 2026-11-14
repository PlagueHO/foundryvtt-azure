#Requires -Version 7.0
<#
.SYNOPSIS
    Runs a bounded, compute-only recovery against an approved production manifest.
.DESCRIPTION
    Requires an existing Azure CLI login. Uses a verified share snapshot and
    registered expiry cleanup before allocation. Never deploys storage or vault
    secrets. Cleanup targets only tagged compute, its role, and its diagnostics.
.PARAMETER ManifestPath
    Absolute path to the approved scope and durable ownership manifest.
.PARAMETER Mode
    Preflight, Snapshot, Run, CleanupCompute, or CleanupSnapshot.
.PARAMETER CleanupAutomationId
    Verified one-time cleanup registration. Required when starting compute.
.EXAMPLE
    .\Invoke-ProductionWebAppRecovery.ps1 -ManifestPath 'C:\evidence\recovery.json' -Mode Preflight
.NOTES
    Snapshot cleanup requires the existing execution host and Azure login.
    Operating limits are not cloud-enforced billing or retention guarantees.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Snapshot', 'Run', 'CleanupCompute', 'CleanupSnapshot')]
    [string]$Mode,

    [ValidateNotNullOrEmpty()]
    [string]$CleanupAutomationId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-RecoveryScope {
    param([Parameter(Mandatory)]$Manifest)
    if ($Manifest.subscriptionId -notmatch '^[0-9a-fA-F-]{36}$' -or
        $Manifest.environmentName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,49}$' -or
        $Manifest.resourceGroupName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._()-]{0,89}$' -or
        $Manifest.storageAccountName -notmatch '^[a-z0-9]{3,24}$' -or
        $Manifest.vaultName -notmatch '^[a-zA-Z0-9-]{3,24}$' -or
        $Manifest.repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or
        $Manifest.recoveryId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Invalid recovery scope. No Azure operation was started.'
    }
    if ($Manifest.location -ne 'newzealandnorth' -or $Manifest.sku -ne 'P0v3' -or
        $Manifest.capacity -ne 1 -or $Manifest.budgetNzd -ne 5 -or
        $Manifest.computeMinutes -ne 90 -or $Manifest.snapshotHours -ne 24 -or
        $Manifest.shareName -ne 'foundryvttdata' -or $Manifest.foundryImageTag -ne 'release' -or
        $Manifest.deployProxy -isnot [bool] -or $Manifest.deployProxy -ne $true) {
        throw 'The recovery manifest does not match the approved resource and cost limits.'
    }
}

function ConvertFrom-RecoveryJson {
    param([Parameter(Mandatory)][string]$Json, [switch]$AsHashtable)
    $options = @{ Depth=100; AsHashtable=$AsHashtable.IsPresent }
    # Snapshot identifiers must keep their exact timestamp text on PowerShell 7.5.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    return ConvertFrom-Json -InputObject $Json @options
}

function Invoke-RecoveryCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments --subscription $m.subscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI operation failed: $($Arguments[0]) $($Arguments[1])." }
    if ($result) { return ConvertFrom-RecoveryJson -Json ($result -join "`n") }
}

function Get-RecoveryToken {
    param([string]$Resource = 'https://management.azure.com/')
    $result = Invoke-RecoveryCli @('account', 'get-access-token', '--resource', $Resource)
    if ([string]::IsNullOrWhiteSpace($result.accessToken)) { throw 'Azure returned no recovery access token.' }
    return $result.accessToken
}

function Save-RecoveryManifest {
    $temporary = "$ManifestPath.tmp"
    $m | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $ManifestPath -Force
}

function Invoke-RecoveryRequest {
    param([Parameter(Mandatory)][string]$Id, [string]$Method = 'Get',
        [string]$ApiVersion = '2025-03-01', $Body, [switch]$AllowMissing)
    if (-not $Id.StartsWith("$groupId/", [StringComparison]::OrdinalIgnoreCase) -and $Id -ne $groupId) {
        throw 'The management request is outside the approved resource group.'
    }
    $arguments = @{
        Uri = "https://management.azure.com$Id`?api-version=$ApiVersion"
        Method = $Method
        Headers = @{ Authorization = "Bearer $(Get-RecoveryToken)" }
        TimeoutSec = 30
    }
    if ($Method -eq 'Get') {
        $arguments.MaximumRetryCount = 3
        $arguments.RetryIntervalSec = 10
    }
    if ($null -ne $Body) {
        $arguments.Body = $Body | ConvertTo-Json -Depth 100 -Compress
        $arguments.ContentType = 'application/json'
    }
    try { return Invoke-RestMethod @arguments }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ($AllowMissing -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-RecoverySnapshot {
    if ([string]::IsNullOrWhiteSpace($m.snapshot)) { throw 'No exact recovery snapshot is recorded.' }
    $time = [DateTimeOffset]::Parse($m.snapshot)
    if ($time.Offset -ne [TimeSpan]::Zero) { throw 'The snapshot timestamp is not UTC.' }
    $snapshot = Invoke-RecoveryCli @('storage', 'share-rm', 'show', '--ids', $shareId, '--snapshot', $m.snapshot)
    $stamp = $snapshot.snapshotTime ?? $snapshot.properties.snapshotTime ?? $snapshot.snapshot
    if ($snapshot.id -ne $shareId) { throw 'The returned snapshot has a different share resource ID.' }
    if ($stamp -ne $m.snapshot) { throw 'The returned share snapshot does not match the ownership manifest.' }
    return $snapshot
}

function Test-RecoveryPreflight {
    foreach ($workflow in @('deploy-production.yml', 'delete-production-compute.yml')) {
        foreach ($status in @('in_progress', 'queued')) {
            $runs = & gh run list --repo $m.repository --workflow $workflow --status $status --limit 10 --json databaseId
            if ($LASTEXITCODE -ne 0) { throw 'Cannot verify conflicting production workflow activity.' }
            if (@($runs | ConvertFrom-Json).Count -gt 0) { throw 'Another production deployment or cleanup is active.' }
        }
    }
    $group = Invoke-RecoveryRequest $groupId -ApiVersion '2024-03-01'
    if ($group.location -ne $m.location) { throw 'Production region does not match the approved region.' }
    $permission = Invoke-RecoveryRequest "$groupId/providers/Microsoft.Authorization/permissions" -ApiVersion '2022-04-01'
    foreach ($action in @('Microsoft.Resources/deployments/write', 'Microsoft.Web/sites/write', 'Microsoft.Web/sites/delete',
        'Microsoft.Web/serverfarms/write', 'Microsoft.Web/serverfarms/delete', 'Microsoft.Authorization/roleAssignments/write',
        'Microsoft.Authorization/roleAssignments/delete', 'Microsoft.Insights/diagnosticSettings/write',
        'Microsoft.Insights/diagnosticSettings/delete', 'Microsoft.Storage/storageAccounts/fileServices/shares/write',
        'Microsoft.Storage/storageAccounts/fileServices/shares/delete')) {
        $allowed = @($permission.value | Where-Object {
            @($_.actions | Where-Object { $action -like $_ }).Count -gt 0 -and
            @($_.notActions | Where-Object { $action -like $_ }).Count -eq 0
        }).Count -gt 0
        if (-not $allowed) { throw "The current production identity lacks the required recovery action: $action." }
    }
    $resources = Invoke-RecoveryCli @('resource', 'list', '--resource-group', $m.resourceGroupName)
    if (@($resources | Where-Object { $_.type -in @('Microsoft.Web/sites', 'Microsoft.Web/serverfarms') }).Count -ne 0) {
        throw 'Production compute already exists. Refusing to take ownership or create another plan.'
    }
    $m.preservedResourceIds = @($resources | ForEach-Object id)
    $storage = Invoke-RecoveryRequest $storageId -ApiVersion '2025-06-01'
    $share = Invoke-RecoveryRequest $shareId -ApiVersion '2025-06-01'
    if ($storage.kind -ne 'FileStorage' -or $storage.sku.name -ne 'Premium_LRS' -or
        $storage.properties.allowSharedKeyAccess -ne $true -or $storage.properties.publicNetworkAccess -ne 'Disabled' -or
        $share.properties.shareQuota -ne 100 -or $share.properties.enabledProtocols -ne 'SMB') {
        throw 'Existing storage does not match the approved private Premium SMB share.'
    }
    $vault = Invoke-RecoveryRequest $vaultId -ApiVersion '2026-02-01'
    if ($vault.properties.enableRbacAuthorization -ne $true) { throw 'The existing vault does not use RBAC.' }
    foreach ($service in @($storage, $vault)) {
        if (@($service.properties.privateEndpointConnections | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
        }).Count -eq 0) { throw 'An existing data service has no approved private endpoint.' }
    }
    $subnet = Invoke-RecoveryRequest $subnetId -ApiVersion '2024-05-01'
    if (@($subnet.properties.delegations | Where-Object { $_.properties.serviceName -eq 'Microsoft.Web/serverFarms' }).Count -eq 0) {
        throw 'The existing Web App subnet lacks its required delegation.'
    }
    $workspace = Invoke-RecoveryRequest $workspaceId -ApiVersion '2023-09-01'
    $m.workspaceCustomerId = $workspace.properties.customerId
    $dns = Invoke-RecoveryRequest "$groupId/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net/A/$($m.storageAccountName)" -ApiVersion '2018-09-01'
    $m.privateIps = @($dns.properties.aRecords | ForEach-Object ipv4Address)
    if ($m.privateIps.Count -eq 0) { throw 'The existing private storage DNS record is empty.' }
    foreach ($zone in @('privatelink.file.core.windows.net', 'privatelink.vaultcore.azure.net')) {
        $links = Invoke-RecoveryRequest "$groupId/providers/Microsoft.Network/privateDnsZones/$zone/virtualNetworkLinks" -ApiVersion '2018-09-01'
        if (@($links.value | Where-Object {
            $_.properties.virtualNetwork.id -eq "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-$($m.environmentName)" -and
            $_.properties.virtualNetworkLinkState -eq 'Completed'
        }).Count -eq 0) { throw 'An existing private DNS zone lacks its completed production VNet link.' }
    }
    $m.shareResourceId = $shareId
    $m.computeResourceIds = $computeIds
    Save-RecoveryManifest
}

function Test-RecoveryChange {
    param([Parameter(Mandatory)]$Changes, [Parameter(Mandatory)][string[]]$ComputeIds, [string[]]$PreservedIds = @())
    foreach ($change in $Changes) {
        $preserved = @($PreservedIds | Where-Object {
            $change.resourceId -eq $_ -or $change.resourceId.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        $ignoredMetadata = $null -eq $change.after -or
            ($change.after.id -eq $change.resourceId -and $null -eq $change.after.properties)
        if ($change.changeType -eq 'Ignore' -and $preserved -and $ignoredMetadata -and
            ($null -eq $change.delta -or @($change.delta).Count -eq 0)) {
            continue
        }
        $allowed = @($ComputeIds | Where-Object {
            $change.resourceId -eq $_ -or $change.resourceId.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $allowed -or $change.changeType -ne 'Create') {
            throw "Recovery what-if contains an unapproved change: $($change.changeType) $($change.resourceId)."
        }
    }
    foreach ($id in $ComputeIds) {
        if (@($Changes | Where-Object { $_.resourceId -eq $id -and $_.changeType -eq 'Create' }).Count -ne 1) {
            throw "Recovery what-if did not establish creation of the exact compute resource: $id."
        }
    }
}

function Test-RecoveryOwnership {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$ExpectedId, [Parameter(Mandatory)][string]$RecoveryId)
    if ($Resource.id -ne $ExpectedId -or $Resource.tags.'fvtt-recovery-id' -ne $RecoveryId) {
        throw 'Resource ownership differs from this recovery attempt. Refusing deletion.'
    }
}

function Get-RecoveryDeployment {
    $program = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'webapp-access-probe.mjs') -Raw
    $ips = ConvertTo-Json -InputObject @($m.privateIps) -Compress
    $m.probePhase = "Recovery-$($m.recoveryId)"
    $program += "`nawait collectWebAppAccessEvidence('$($m.storageAccountName)', $ips, '$($m.probePhase)');"
    $parameters = @{
        environmentName=$m.environmentName; storageAccountName=$m.storageAccountName; vaultName=$m.vaultName
        subnetResourceId=$subnetId; workspaceResourceId=$workspaceId; recoveryId=$m.recoveryId
        probeBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($program))
        foundryImageTag=$m.foundryImageTag; deployProxy=$m.deployProxy
    }
    $compiled = Join-Path (Split-Path $ManifestPath) "recovery-$($m.recoveryId).arm.json"
    if (Get-Command bicep -ErrorAction SilentlyContinue) {
        & bicep build (Join-Path $PSScriptRoot '..\infra\recovery.bicep') --outfile $compiled
    } else {
        & az bicep build --file (Join-Path $PSScriptRoot '..\infra\recovery.bicep') --outfile $compiled
    }
    if ($LASTEXITCODE -ne 0) { throw 'Recovery Bicep build failed before allocation.' }
    $parametersFile = "$compiled.parameters.json"
    $values = @{}
    foreach ($key in $parameters.Keys) { $values[$key] = @{ value = $parameters[$key] } }
    @{ parameters=$values } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parametersFile -Encoding utf8NoBOM
    $preview = Invoke-RecoveryCli @('deployment','group','what-if','--resource-group',$m.resourceGroupName,
        '--template-file',$compiled,'--parameters',"@$parametersFile",'--mode','Incremental','--no-pretty-print')
    $m.whatIf = @($preview.changes | Select-Object resourceId, changeType)
    Save-RecoveryManifest
    Test-RecoveryChange -Changes $preview.changes -ComputeIds $computeIds -PreservedIds $m.preservedResourceIds
    return @{ compiled=$compiled; parameters=$values }
}

function ConvertFrom-RecoveryProbe {
    param([Parameter(Mandatory)][string]$Frame, [Parameter(Mandatory)][string]$StorageAccountName,
        [ValidateNotNullOrEmpty()][string]$ExpectedPhase = 'Recovery')
    if ($Frame.Length -gt 8192) { throw 'Oversized application-container probe frame.' }
    $probe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Frame)) | ConvertFrom-Json
    if ($probe.phase -ne $ExpectedPhase -or $probe.mountInfo -isnot [string] -or $probe.mountInfo.Length -gt 4096) {
        throw 'Invalid application-container probe frame.'
    }
    foreach ($field in @('privateDnsMatches', 'smbTcpConnected', 'keyResolved')) {
        if ($probe.$field -isnot [bool]) { throw 'Invalid application-container probe boolean.' }
    }
    if ($null -ne $probe.fileRestStatus -and
        (($probe.fileRestStatus -isnot [int] -and $probe.fileRestStatus -isnot [long]) -or
         $probe.fileRestStatus -lt 100 -or $probe.fileRestStatus -gt 599)) {
        throw 'Invalid application-container HTTP status.'
    }
    foreach ($field in @('dnsError', 'smbTcpError', 'fileRestError')) {
        if ($probe.$field -notin @('', 'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT', 'ECONNREFUSED', 'ECONNRESET',
            'ENETUNREACH', 'EHOSTUNREACH', 'TransportError', 'AuthenticationFailed', 'AuthorizationFailure',
            'AuthorizationPermissionMismatch', 'KeyBasedAuthenticationNotPermitted', 'ShareNotFound',
            'AccountIsDisabled', 'InvalidHeaderValue', 'UnclassifiedStorageError', 'StorageKeyNotResolved')) {
            throw 'Invalid application-container error code.'
        }
    }
    $source = [regex]::Escape($StorageAccountName)
    return @{
        privateDnsMatches=$probe.privateDnsMatches; dnsError=$probe.dnsError
        smbTcpConnected=$probe.smbTcpConnected; smbTcpError=$probe.smbTcpError
        keyResolved=$probe.keyResolved; fileRestStatus=$probe.fileRestStatus; fileRestError=$probe.fileRestError
        runtimeMountVerified=$probe.mountInfo -match "^\d+ \d+ \S+ \S+ /data \S+.* - cifs //$source\.file\.core\.windows\.net/foundryvttdata\s"
    }
}

function Remove-RecoveryCompute {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($id in $computeIds) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $resource = Invoke-RecoveryRequest $id -AllowMissing
                if ($null -eq $resource) { break }
                Test-RecoveryOwnership -Resource $resource -ExpectedId $id -RecoveryId $m.recoveryId
                if (-not $PSCmdlet.ShouldProcess($id, 'Delete this recovery-owned compute resource')) { break }
                $until = [DateTime]::UtcNow.AddMinutes(5)
                try { Invoke-RecoveryRequest $id -Method Delete | Out-Null }
                catch [Microsoft.PowerShell.Commands.HttpResponseException] { throw }
                catch [System.IO.IOException], [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
                    Write-Warning 'Compute delete confirmation was lost. Checking the recorded ID before any further delete.'
                }
                do {
                    Start-Sleep -Seconds 5
                    $remaining = Invoke-RecoveryRequest $id -AllowMissing
                } while ($null -ne $remaining -and [DateTime]::UtcNow -lt $until)
                if ($null -ne $remaining) { throw 'Compute deletion was not verified within its reserved window.' }
                break
            } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
                if ([int]$_.Exception.Response.StatusCode -in @(429, 503) -and $attempt -lt 3) {
                    Write-Warning 'Compute cleanup was throttled. Waiting 30 seconds, then checking ownership again.'
                    Start-Sleep -Seconds 30
                    continue
                }
                $failures.Add($id)
                Write-Warning "Cleanup failed for the recorded compute resource: $id. $($_.Exception.Message)"
                break
            } catch {
                $failures.Add($id)
                Write-Warning "Cleanup failed for the recorded compute resource: $id. $($_.Exception.Message)"
                break
            }
        }
    }
    foreach ($item in @(@{ Id = $m.roleId; Api = '2022-04-01' }, @{ Id = $m.diagnosticId; Api = '2021-05-01-preview' })) {
        if ([string]::IsNullOrWhiteSpace($item.Id)) { continue }
        try {
            $setting = Invoke-RecoveryRequest $item.Id -ApiVersion $item.Api -AllowMissing
            if ($null -eq $setting) { continue }
            if ($item.Id -eq $expectedRoleId -and $setting.properties.principalId -ne $m.appPrincipalId) {
                throw 'The recorded secrets role has a different principal. Refusing deletion.'
            }
            if ($item.Id -eq $expectedDiagnosticId -and $setting.properties.workspaceId -ne $workspaceId) {
                throw 'The recorded diagnostic setting has a different workspace. Refusing deletion.'
            }
            if ($PSCmdlet.ShouldProcess($item.Id, 'Delete this recorded recovery setting')) {
                Invoke-RecoveryRequest $item.Id -Method Delete -ApiVersion $item.Api -AllowMissing | Out-Null
            }
        }
        catch { $failures.Add($item.Id); Write-Warning "Recorded recovery setting cleanup failed: $($item.Id)." }
    }
    Invoke-RecoveryRequest $shareId -ApiVersion '2025-06-01' | Out-Null
    Invoke-RecoveryRequest $storageId -ApiVersion '2025-06-01' | Out-Null
    Invoke-RecoveryRequest $vaultId -ApiVersion '2026-02-01' | Out-Null
    Invoke-RecoveryRequest $workspaceId -ApiVersion '2023-09-01' | Out-Null
    Invoke-RecoveryRequest $subnetId -ApiVersion '2024-05-01' | Out-Null
    $m.computeCleanupVerified = $failures.Count -eq 0
    if ($m.computeCleanupVerified) {
        if (-not $m.computeCleanupCompletedAt) { $m.computeCleanupCompletedAt = [DateTime]::UtcNow.ToString('o') }
        $m.computeCleanupWithinLimit = -not $m.computeStartedAt -or
            [DateTimeOffset]::Parse($m.computeCleanupCompletedAt) -le [DateTimeOffset]::Parse($m.computeStartedAt).AddMinutes($m.computeMinutes)
    }
    Save-RecoveryManifest
    if ($failures.Count -gt 0) { throw 'Recovery cleanup is incomplete. Only recorded attempt-owned resources were targeted.' }
    if (-not $m.computeCleanupWithinLimit) { throw 'Compute is deleted, but cleanup exceeded the approved time limit.' }
}

function Remove-RecoverySnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ([string]::IsNullOrWhiteSpace($m.snapshot)) { throw 'No exact recovery snapshot is recorded.' }
    $shares = Invoke-RecoveryCli @('storage', 'share-rm', 'list', '--resource-group', $m.resourceGroupName,
        '--storage-account', $m.storageAccountName, '--include-snapshot')
    $owned = @($shares | Where-Object {
        $_.id -eq $shareId -and ($_.snapshotTime ?? $_.properties.snapshotTime ?? $_.snapshot) -ceq $m.snapshot
    })
    if ($owned.Count -gt 1) { throw 'More than one snapshot matches the recorded recovery target.' }
    if ($owned.Count -eq 1) {
        Get-RecoverySnapshot | Out-Null
        if (-not $PSCmdlet.ShouldProcess("$shareId snapshot $($m.snapshot)", 'Delete only the recorded recovery snapshot')) { return }
        Invoke-RecoveryCli @('storage', 'share-rm', 'delete', '--ids', $shareId, '--snapshot', $m.snapshot) | Out-Null
        $shares = Invoke-RecoveryCli @('storage', 'share-rm', 'list', '--resource-group', $m.resourceGroupName,
            '--storage-account', $m.storageAccountName, '--include-snapshot')
        if (@($shares | Where-Object {
            $_.id -eq $shareId -and ($_.snapshotTime ?? $_.properties.snapshotTime ?? $_.snapshot) -ceq $m.snapshot
        }).Count -gt 0) { throw 'The recovery snapshot deletion was not verified.' }
    } else {
        $m.snapshotCleanupAlreadyAbsent = $true
    }
    $live = Invoke-RecoveryRequest $shareId -ApiVersion '2025-06-01'
    if ($live.id -ne $shareId) { throw 'The live production share was not verified after snapshot cleanup.' }
    $m.snapshotCleanupVerified = $true
    if (-not $m.snapshotCleanupCompletedAt) { $m.snapshotCleanupCompletedAt = [DateTime]::UtcNow.ToString('o') }
    $m.snapshotCleanupWithinLimit =
        [DateTimeOffset]::Parse($m.snapshotCleanupCompletedAt) -le [DateTimeOffset]::Parse($m.snapshot).AddHours($m.snapshotHours)
    Save-RecoveryManifest
    if (-not $m.snapshotCleanupWithinLimit) { throw 'The snapshot is absent, but cleanup exceeded the approved retention limit.' }
    Write-Output 'The exact recovery snapshot is absent. The live share remains.'
}

function Get-RecoveryContainerProbe {
    $logs = $null
    try {
        $logs = Invoke-RecoveryRequest "$appId/containerlogs" -Method Post
        $probes = @(foreach ($frame in [regex]::Matches([string]$logs, 'FVTT_ACCESSINFO:([A-Za-z0-9+/=]+)')) {
            ConvertFrom-RecoveryProbe -Frame $frame.Groups[1].Value -StorageAccountName $m.storageAccountName `
                -ExpectedPhase ($m.probePhase ?? 'Recovery')
        })
        if ($probes.Count -eq 0) {
            Write-Warning 'Application-container probe is unavailable. No mount claim was made.'
            return
        }
        $m.probe = $probes | Where-Object keyResolved | Select-Object -First 1
        if ($null -eq $m.probe) { $m.probe = $probes[-1] }
        $m.runtimeMountVerified = @($probes | Where-Object runtimeMountVerified).Count -gt 0
        $m.containerProbeCount = $probes.Count
        Save-RecoveryManifest
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        Write-Warning 'Application-container logs are unavailable (HTTP 404). No mount claim was made.'
    } catch [System.IO.IOException], [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
        Write-Warning 'Application-container logs are unavailable due to transport or timeout. No mount claim was made.'
    } finally { Remove-Variable logs -Force -ErrorAction SilentlyContinue }
}

function Get-RecoveryLogEvidence {
    $end = $m.computeCleanupCompletedAt ?? [DateTime]::UtcNow.ToString('o')
    $query = @"
union isfuzzy=true withsource=Table AppServicePlatformLogs, AppServiceConsoleLogs, StorageFileLogs, AzureDiagnostics
| where TimeGenerated between (datetime($($m.computeStartedAt)) .. datetime($end))
| where _ResourceId startswith '$groupId/'
| where _ResourceId =~ '$appId' or _ResourceId startswith '$storageId/' or _ResourceId =~ '$vaultId'
| extend M=coalesce(tostring(column_ifexists('Message','')),tostring(column_ifexists('ResultDescription','')),tostring(column_ifexists('Message_s','')))
| extend Signal=extract(@'(BYOSFailure|mount error\(\d+\)|STATUS_[A-Z_]+|ImagePullFailure|ContainerStartFailure)',0,M), Frame=extract(@'FVTT_ACCESSINFO:([A-Za-z0-9+/=]+)',1,M)
| extend Operation=tostring(column_ifexists('OperationName','')), Protocol=tostring(column_ifexists('Protocol','')), SmbCode=tostring(column_ifexists('SmbStatusCode','')), Result=tostring(column_ifexists('ResultSignature',''))
| extend Principal=coalesce(tostring(column_ifexists('identity_claim_oid_g','')),tostring(column_ifexists('identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g','')))
| where _ResourceId !~ '$vaultId' or (Principal =~ '$($m.appPrincipalId)' and Operation == 'SecretGet')
| extend Description=tostring(column_ifexists('ResultDescription',''))
| extend VaultFirewallDenied=(Description contains 'Client address is not authorized'), VaultRbacDenied=(Description contains 'Caller is not authorized to perform action')
| summarize Records=count() by Table, Signal, Frame, Operation, Protocol, SmbCode, Result, VaultFirewallDenied, VaultRbacDenied
| take 100
"@
    $token = Get-RecoveryToken 'https://api.loganalytics.io'
    try {
        $result = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$($m.workspaceCustomerId)/query" `
            -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
            -Body (@{ query = $query } | ConvertTo-Json) -TimeoutSec 30
        if ($null -eq $result.tables -or $result.error) { throw 'Recovery log query returned incomplete evidence.' }
        $rows = @($result.tables[0].rows)
        $safe = foreach ($row in $rows) {
            [pscustomobject]@{ Table=$row[0]; Signal=$row[1]; Operation=$row[3]; Protocol=$row[4]; SmbCode=$row[5]; Result=$row[6]; VaultFirewallDenied=$row[7]; VaultRbacDenied=$row[8]; Records=$row[9] }
            if ($row[2]) {
                $probe = ConvertFrom-RecoveryProbe -Frame $row[2] -StorageAccountName $m.storageAccountName `
                    -ExpectedPhase ($m.probePhase ?? 'Recovery')
                if ($null -eq $m.probe -or $probe.keyResolved) { $m.probe = $probe }
                $m.runtimeMountVerified = $m.runtimeMountVerified -eq $true -or $probe.runtimeMountVerified
            }
        }
        $m.logEvidence = @($safe)
        Save-RecoveryManifest
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] { throw }
    catch [System.IO.IOException], [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
        Write-Warning 'Optional recovery log evidence is unavailable due to a transport failure. No mount claim was made.'
    } finally { Remove-Variable token -Force -ErrorAction SilentlyContinue }
}

$m = ConvertFrom-RecoveryJson -Json (Get-Content -LiteralPath $ManifestPath -Raw) -AsHashtable
Test-RecoveryScope $m
$groupId = "/subscriptions/$($m.subscriptionId)/resourceGroups/$($m.resourceGroupName)"
$storageId = "$groupId/providers/Microsoft.Storage/storageAccounts/$($m.storageAccountName)"
$shareId = "$storageId/fileServices/default/shares/foundryvttdata"
$vaultId = "$groupId/providers/Microsoft.KeyVault/vaults/$($m.vaultName)"
$subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-$($m.environmentName)/subnets/webApp"
$workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/log-$($m.environmentName)"
$appId = "$groupId/providers/Microsoft.Web/sites/$($m.environmentName)"
$proxyId = "$groupId/providers/Microsoft.Web/sites/$($m.environmentName)ddbproxy"
$planId = "$groupId/providers/Microsoft.Web/serverfarms/app-$($m.environmentName)"
$computeIds = @($appId) + $(if ($m.deployProxy) { @($proxyId) } else { @() }) + @($planId)
$expectedRoleId = "$vaultId/providers/Microsoft.Authorization/roleAssignments/$($m.recoveryId)"
$expectedDiagnosticId = "$storageId/fileServices/default/providers/Microsoft.Insights/diagnosticSettings/fvtt-recovery-$($m.recoveryId)"
if (($m.roleId -and $m.roleId -ne $expectedRoleId) -or
    ($m.diagnosticId -and $m.diagnosticId -ne $expectedDiagnosticId) -or
    ($m.shareResourceId -and $m.shareResourceId -ne $shareId)) {
    throw 'The recorded cleanup target differs from this recovery scope.'
}
if (-not $PSCmdlet.ShouldProcess($m.resourceGroupName, "Recovery mode $Mode within the approved manifest")) { return }

switch ($Mode) {
    Preflight {
        Test-RecoveryPreflight
        Get-RecoveryDeployment | Out-Null
        Write-Output 'Recovery preflight and exact what-if passed. No resource was created.'
    }
    Snapshot {
        if ($m.snapshot -or $m.snapshotCreationRequestedAt) { throw 'A recovery snapshot was already requested. Inspect its state instead of creating another.' }
        Test-RecoveryPreflight
        $m.snapshotCreationRequestedAt = [DateTime]::UtcNow.ToString('o')
        Save-RecoveryManifest
        $snapshot = Invoke-RecoveryCli @('storage', 'share-rm', 'snapshot', '--ids', $shareId)
        $m.snapshot = $snapshot.snapshotTime ?? $snapshot.properties.snapshotTime ?? $snapshot.snapshot
        Save-RecoveryManifest
        Get-RecoverySnapshot | Out-Null
        $m.snapshotExpiresAt = [DateTimeOffset]::Parse($m.snapshot).AddHours(24).ToString('o')
        Save-RecoveryManifest
        Write-Output "Verified one recovery snapshot: $($m.snapshot). Expiry: $($m.snapshotExpiresAt)."
    }
    CleanupSnapshot { Remove-RecoverySnapshot }
    CleanupCompute { Remove-RecoveryCompute }
    Run {
        if ([string]::IsNullOrWhiteSpace($CleanupAutomationId)) { throw 'Register and verify snapshot expiry cleanup before allocating compute.' }
        if ($m.computeStartedAt) { throw 'This manifest already started compute. Refusing an implicit replay.' }
        Get-RecoverySnapshot | Out-Null
        if ([DateTimeOffset]::Parse($m.snapshot).AddHours(24) -le [DateTimeOffset]::UtcNow.AddMinutes(90)) {
            throw 'The snapshot expiry does not leave the approved compute window.'
        }
        Test-RecoveryPreflight
        $m.cleanupAutomationId = $CleanupAutomationId
        $setup = Get-RecoveryDeployment
        $m.computeStartedAt = [DateTime]::UtcNow.ToString('o')
        Save-RecoveryManifest
        $deadline = [DateTime]::UtcNow.AddMinutes(70)
        try {
            $deploymentId = "$groupId/providers/Microsoft.Resources/deployments/recovery-$($m.recoveryId)"
            Invoke-RecoveryRequest $deploymentId -Method Put -ApiVersion '2025-04-01' -Body @{
                properties=@{ mode='Incremental'; template=(Get-Content $setup.compiled -Raw | ConvertFrom-Json -Depth 100); parameters=$setup.parameters }
            } | Out-Null
            $provisionDeadline = [DateTime]::UtcNow.AddMinutes(20)
            do {
                Start-Sleep -Seconds 10
                $deployment = Invoke-RecoveryRequest $deploymentId -ApiVersion '2025-04-01'
                if ($deployment.properties.provisioningState -in @('Failed','Canceled')) { throw 'Compute-only deployment failed.' }
                if ([DateTime]::UtcNow -gt $provisionDeadline) { throw 'Compute provisioning exceeded its reserved window.' }
            } while ($deployment.properties.provisioningState -ne 'Succeeded')
            $app = Invoke-RecoveryRequest $appId
            Test-RecoveryOwnership -Resource $app -ExpectedId $appId -RecoveryId $m.recoveryId
            if ($app.properties.enabled -ne $false -or $app.properties.outboundVnetRouting.allTraffic -ne $true -or
                $app.properties.virtualNetworkSubnetId -ne $subnetId) { throw 'Disabled-first routing checks failed.' }
            $plan = Invoke-RecoveryRequest $planId
            if ($plan.sku.name -ne 'P0v3' -or $plan.sku.capacity -ne 1) { throw 'Actual plan exceeded its approved limit.' }
            $m.roleId = $expectedRoleId
            $m.appPrincipalId = $app.identity.principalId
            Save-RecoveryManifest
            Invoke-RecoveryRequest $m.roleId -Method Put -ApiVersion '2022-04-01' -Body @{
                properties=@{ principalId=$app.identity.principalId; principalType='ServicePrincipal'
                    roleDefinitionId="/subscriptions/$($m.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6" }
            } | Out-Null
            $role = Invoke-RecoveryRequest $m.roleId -ApiVersion '2022-04-01'
            if ($role.properties.principalId -ne $app.identity.principalId -or
                $role.properties.roleDefinitionId -notlike '*/4633458b-17de-408a-b874-0445c86b69e6') {
                throw 'The new app secrets role was not verified before startup.'
            }
            $m.diagnosticId = $expectedDiagnosticId
            Save-RecoveryManifest
            Invoke-RecoveryRequest $m.diagnosticId -Method Put -ApiVersion '2021-05-01-preview' -Body @{
                properties=@{ workspaceId=$workspaceId; logAnalyticsDestinationType='Dedicated'
                    logs=@(@{category='StorageRead';enabled=$true},@{category='StorageWrite';enabled=$true},@{category='StorageDelete';enabled=$true}) }
            } | Out-Null
            Get-RecoverySnapshot | Out-Null
            Invoke-RecoveryRequest $appId -Method Patch -Body @{ properties=@{enabled=$true} } | Out-Null
            Invoke-RecoveryRequest "$appId/start" -Method Post | Out-Null
            Invoke-RecoveryRequest "$appId/config/configreferences/appsettings/refresh" -Method Post | Out-Null
            if ($m.deployProxy) {
                Invoke-RecoveryRequest $proxyId -Method Patch -Body @{properties=@{enabled=$true}} | Out-Null
                Invoke-RecoveryRequest "$proxyId/start" -Method Post | Out-Null
            }
            $startupDeadline = [DateTime]::UtcNow.AddSeconds(1800)
            $attempt = 0
            do {
                $attempt++
                $states = @{}
                foreach ($name in @('FOUNDRY_USERNAME','FOUNDRY_PASSWORD','FOUNDRY_ADMIN_KEY','STORAGE_ACCOUNT_KEY')) {
                    $reference = Invoke-RecoveryRequest "$appId/config/configreferences/appsettings/$name"
                    $states[$name] = $reference.properties.status
                }
                $m.references = $states
                if (@($states.Values | Where-Object { $_ -ne 'Resolved' }).Count -gt 0 -and $attempt % 4 -eq 0) {
                    Invoke-RecoveryRequest "$appId/config/configreferences/appsettings/refresh" -Method Post | Out-Null
                }
                $m.httpStatus = $null
                $m.foundryHttpReady = $false
                try {
                    $response = Invoke-WebRequest -Uri "https://$($app.properties.defaultHostName)/" -SkipHttpErrorCheck -TimeoutSec 15
                    $m.httpStatus = [int]$response.StatusCode
                    $m.foundryHttpReady = $response.StatusCode -eq 200 -and $response.Content -match '<title>[^<]*Foundry Virtual Tabletop[^<]*</title>'
                } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
                    Write-Warning 'Foundry HTTP probe failed due to transport or timeout.'
                }
                if ($m.foundryHttpReady -and -not $m.runtimeMountVerified) { Get-RecoveryContainerProbe }
                if ($attempt -eq 1 -or $attempt % 4 -eq 0 -or $m.foundryHttpReady) { Get-RecoveryLogEvidence }
                Save-RecoveryManifest
                Write-Output "Recovery attempt $attempt. HTTP=$($m.httpStatus). References=$($states | ConvertTo-Json -Compress). MountVerified=$($m.runtimeMountVerified -eq $true)."
                if (@($states.Values | Where-Object { $_ -ne 'Resolved' }).Count -eq 0 -and
                    $m.foundryHttpReady -and $m.runtimeMountVerified) { $m.recoveryPassed=$true; break }
                Start-Sleep -Seconds 30
            } while ([DateTime]::UtcNow -lt $startupDeadline -and [DateTime]::UtcNow -lt $deadline)
            Get-RecoveryLogEvidence
            if (-not $m.recoveryPassed) { throw 'Controlled recovery did not establish resolved references, Foundry readiness, and the actual CIFS mount.' }
        } finally {
            Remove-RecoveryCompute
        }
    }
}
