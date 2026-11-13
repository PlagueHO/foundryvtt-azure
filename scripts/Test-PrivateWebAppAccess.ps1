#Requires -Version 7.0
<#
.SYNOPSIS
    Separates network, identity, and storage access failures in an isolated private test.

.DESCRIPTION
    Uses the existing azd login. Captures scoped access metadata before readiness checks.
    Enables bounded filesystem logs. If startup fails after references resolve, compares
    an explicit restart and an approved temporary mount-removal control. Restores the
    original mount and app settings. The owner workflow must always delete the test group.
    Prints only safe evidence, not credentials, authorization headers, or raw logs.

.PARAMETER SubscriptionId
    Subscription containing the isolated test.
.PARAMETER TenantId
    Tenant for the existing azd login.
.PARAMETER WebAppName
    Exact fvtt-asp-on run name. Production names are refused.
.PARAMETER ResourceGroupName
    Exact rg-<WebAppName> group.
.PARAMETER EvidencePath
    File for safe diagnostic evidence.
.EXAMPLE
    .\Test-PrivateWebAppAccess.ps1 -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
        -TenantId $env:AZURE_TENANT_ID -WebAppName $env:AZURE_ENV_NAME `
        -ResourceGroupName $env:AZURE_RESOURCE_GROUP_NAME -EvidencePath '.\access.txt'
.NOTES
    Requires separate paid-test and temporary mount-control approval.
    A repaired or mount-free startup is not unchanged-deployment acceptance.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^fvtt-asp-on-\d+-\d+$')][string]$WebAppName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($ResourceGroupName -ne "rg-$WebAppName") {
    throw 'The resource group does not match the isolated private test. No Azure access was started.'
}
if (-not $PSCmdlet.ShouldProcess($WebAppName, 'Capture access evidence and run the approved temporary mount control')) {
    return
}
$scopeId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$appId = "$scopeId/providers/Microsoft.Web/sites/$WebAppName"
$storageName = $WebAppName.Replace('-', '').ToLowerInvariant()
$storageName = $storageName.Substring(0, [Math]::Min(24, $storageName.Length))
$storageId = "$scopeId/providers/Microsoft.Storage/storageAccounts/$storageName"
$vaultName = "kv$storageName"
$vaultName = $vaultName.Substring(0, [Math]::Min(24, $vaultName.Length))
$vaultId = "$scopeId/providers/Microsoft.KeyVault/vaults/$vaultName"
$deadline = [DateTime]::UtcNow.AddMinutes(35)

function Write-TestEvidence {
    param([Parameter(Mandatory)][string]$Message)
    $Message | Add-Content -LiteralPath $EvidencePath
    if ($Env:GITHUB_STEP_SUMMARY) { $Message | Add-Content -LiteralPath $Env:GITHUB_STEP_SUMMARY }
    Write-Information $Message -InformationAction Continue
}

function Invoke-TestManagementRequest {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [ValidateSet('Get', 'Post', 'Put')][string]$Method = 'Get',
        [string]$Version = '2025-03-01',
        [object]$Body
    )
    if (-not $ResourceId.StartsWith("$scopeId/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The management request is outside the approved test group.'
    }
    if ([DateTime]::UtcNow -gt $deadline -and -not $restoring) { throw 'The diagnostic time budget expired.' }
    $parameters = @{
        Uri = "https://management.azure.com${ResourceId}?api-version=$Version"
        Method = $Method; Headers = $headers; TimeoutSec = 20
        MaximumRetryCount = 2; RetryIntervalSec = 5
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20
    }
    Invoke-RestMethod @parameters
}

function Get-TestLog {
    param([Parameter(Mandatory)][string]$Phase)
    try {
        $logs = Invoke-TestManagementRequest "$appId/containerlogs" -Method Post
        $tokens = [regex]::Matches([string]$logs,
            '(?i)mount error\(\d+\)|STATUS_[A-Z_]+|BYOSFailure|cifs_mount failed w/return code = -?\d+|ImagePullFailure|ContainerStartFailure|AppSettingRef|KeyVaultReference|Authentication failed|permission denied|connection timed out|no route to host|toomanyrequests|Starting launcher') |
            ForEach-Object Value | Sort-Object -Unique
        Write-TestEvidence "${Phase} log tokens: $($tokens -join ', ')."
        return [string]$logs
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        Write-TestEvidence "${Phase} container logs: unavailable (HTTP 404)."
        return $null
    } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
        Write-TestEvidence "${Phase} container logs: unavailable (transport failure or timeout). No access or mount claim was made."
        return $null
    }
}

function Test-FoundryResponse {
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'The diagnostic time budget expired.' }
        try {
            $response = Invoke-WebRequest -Uri "https://$($app.properties.defaultHostName)/" -SkipHttpErrorCheck -TimeoutSec 15
            if ($response.StatusCode -eq 200 -and $response.Content -match '<title>[^<]*Foundry Virtual Tabletop[^<]*</title>') {
                return $true
            }
            Write-TestEvidence "Restart HTTP attempt ${attempt}: status=$([int]$response.StatusCode)."
        } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
            Write-TestEvidence "Restart HTTP attempt ${attempt}: transport failed."
        }
        if ($attempt -lt 12) { Start-Sleep -Seconds 30 }
    }
    return $false
}

function Set-TestProbe {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Baseline', 'Control', 'Restored')][string]$Phase)
    if (-not $PSCmdlet.ShouldProcess($WebAppName, "Install the $Phase access probe")) { return }
    $program = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'webapp-access-probe.mjs') -Raw
    $ips = ConvertTo-Json -InputObject @($expectedIps) -Compress
    $program += "`nawait collectWebAppAccessEvidence('$storageName', $ips, '$Phase');"
    $settings = Invoke-TestManagementRequest "$appId/config/appsettings/list" -Method Post
    $nodeOptions = '--import=data:text/javascript;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($program))
    $settings.properties | Add-Member -NotePropertyName NODE_OPTIONS -NotePropertyValue $nodeOptions -Force
    Invoke-TestManagementRequest "$appId/config/appsettings" -Method Put -Body @{ properties = $settings.properties } | Out-Null
}

function Get-TestProbe {
    param([Parameter(Mandatory)][ValidateSet('Baseline', 'Control', 'Restored')][string]$Phase)
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $logs = Get-TestLog $Phase
        foreach ($match in [regex]::Matches([string]$logs, 'FVTT_ACCESSINFO:([A-Za-z0-9+/=]+)')) {
            if ($match.Groups[1].Length -gt 8192) { throw 'The access probe returned oversized evidence.' }
            $probe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
            if ($probe.phase -ne $Phase) { continue }
            if ($probe.mountInfo -isnot [string] -or $probe.mountInfo.Length -gt 4096) {
                throw 'The access probe returned invalid mount evidence.'
            }
            foreach ($field in @('privateDnsMatches', 'smbTcpConnected', 'keyResolved')) {
                if ($probe.$field -isnot [bool]) { throw 'The access probe returned an invalid boolean.' }
            }
            if ($null -ne $probe.fileRestStatus -and
                (($probe.fileRestStatus -isnot [int] -and $probe.fileRestStatus -isnot [long]) -or
                 $probe.fileRestStatus -lt 100 -or $probe.fileRestStatus -gt 599)) {
                throw 'The access probe returned an invalid HTTP status.'
            }
            foreach ($field in @('dnsError', 'smbTcpError', 'fileRestError')) {
                if ($probe.$field -notin @('', 'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT', 'ECONNREFUSED', 'ECONNRESET',
                    'ENETUNREACH', 'EHOSTUNREACH', 'TransportError', 'AuthenticationFailed', 'AuthorizationFailure',
                    'AuthorizationPermissionMismatch', 'KeyBasedAuthenticationNotPermitted', 'ShareNotFound',
                    'AccountIsDisabled', 'InvalidHeaderValue', 'UnclassifiedStorageError', 'StorageKeyNotResolved')) {
                    throw 'The access probe returned an unsupported error code.'
                }
            }
            Write-TestEvidence "${Phase} application-container access: privateDnsMatches=$($probe.privateDnsMatches); dnsError=$($probe.dnsError); tcp445=$($probe.smbTcpConnected); tcpError=$($probe.smbTcpError); keyResolved=$($probe.keyResolved); fileRestStatus=$($probe.fileRestStatus); fileRestError=$($probe.fileRestError)."
            if ($Phase -eq 'Restored' -and [string]::IsNullOrWhiteSpace($probe.mountInfo)) { continue }
            return $probe
        }
        if ($attempt -lt 12) { Start-Sleep -Seconds 15 }
    }
    Write-TestEvidence "${Phase} application-container probe: unavailable; no network or key-authentication claim was made."
    return $null
}

try {
    $token = & azd auth token --tenant-id $TenantId --scope 'https://management.azure.com/.default' --no-prompt
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Cannot obtain the diagnostic management token.' }
    $headers = @{ Authorization = "Bearer $token" }
    $app = Invoke-TestManagementRequest $appId
    $plan = Invoke-TestManagementRequest $app.properties.serverFarmId
    $storage = Invoke-TestManagementRequest $storageId -Version '2025-06-01'
    $share = Invoke-TestManagementRequest "$storageId/fileServices/default/shares/foundryvttdata" -Version '2025-06-01'
    if ($app.location.Replace(' ', '') -ne 'NewZealandNorth' -or $plan.sku.name -ne 'P0v3' -or
        $plan.sku.capacity -ne 1 -or $storage.sku.name -ne 'Premium_LRS' -or $share.properties.shareQuota -ne 100) {
        throw 'The actual test resources do not match the approved region, compute, and storage limits.'
    }
    $vault = Invoke-TestManagementRequest $vaultId -Version '2026-02-01'
    $roles = Invoke-TestManagementRequest "$vaultId/providers/Microsoft.Authorization/roleAssignments" -Version '2022-04-01'
    $hasRole = @($roles.value | Where-Object {
        $_.properties.principalId -eq $app.identity.principalId -and
        $_.properties.roleDefinitionId -like '*/4633458b-17de-408a-b874-0445c86b69e6'
    }).Count -gt 0
    $hasSubnet = -not [string]::IsNullOrWhiteSpace($app.properties.virtualNetworkSubnetId)
    Write-TestEvidence "Initial identity/network: systemIdentity=$($app.identity.type -match 'SystemAssigned'); secretsRole=$hasRole; allTraffic=$($app.properties.outboundVnetRouting.allTraffic); hasSubnet=$hasSubnet; vaultPublicAccess=$($vault.properties.publicNetworkAccess); vaultRbac=$($vault.properties.enableRbacAuthorization)."
    $approved = @($storage.properties.privateEndpointConnections | Where-Object {
        $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
    }).Count
    Write-TestEvidence "Initial storage access: publicAccess=$($storage.properties.publicNetworkAccess); sharedKeyAllowed=$($storage.properties.allowSharedKeyAccess); approvedPrivateEndpoints=$approved."
    $fileService = Invoke-TestManagementRequest "$storageId/fileServices/default" -Version '2025-06-01'
    Write-TestEvidence "Initial SMB settings: versions=$($fileService.properties.protocolSettings.smb.versions); authentication=$($fileService.properties.protocolSettings.smb.authenticationMethods); encryption=$($fileService.properties.protocolSettings.smb.channelEncryption)."
    if (-not $hasRole) {
        Write-TestEvidence 'Access classification: the expected app secrets role is missing.'
        throw 'The identity permission check failed before startup controls.'
    }
    if ($app.properties.outboundVnetRouting.allTraffic -ne $true -or -not $hasSubnet -or $approved -eq 0) {
        Write-TestEvidence 'Access classification: the required private network configuration is missing.'
        throw 'The network check failed before startup controls.'
    }
    $dns = Invoke-TestManagementRequest "$scopeId/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net/A/$storageName" -Version '2018-09-01'
    $expectedIps = @($dns.properties.aRecords.ipv4Address)
    if ($expectedIps.Count -eq 0) { throw 'The expected private storage DNS record has no address.' }
    $originalMount = Invoke-TestManagementRequest "$appId/config/azurestorageaccounts/list" -Method Post
    $mapping = $originalMount.properties.foundrydata
    if (@($originalMount.properties.PSObject.Properties).Count -ne 1 -or $mapping.accountName -ne $storageName -or
        $mapping.shareName -ne 'foundryvttdata' -or $mapping.mountPath -ne '/data' -or $mapping.type -ne 'AzureFiles' -or
        $mapping.protocol -ne 'Smb' -or $mapping.accessKey -ne '@AppSettingRef(STORAGE_ACCOUNT_KEY)') {
        throw 'The storage mapping does not match the approved test control.'
    }
    Write-TestEvidence "Initial storage mapping: state=$($mapping.state); expectedReference=True."
    foreach ($name in @('FOUNDRY_USERNAME', 'FOUNDRY_PASSWORD', 'FOUNDRY_ADMIN_KEY', 'STORAGE_ACCOUNT_KEY')) {
        $reference = Invoke-TestManagementRequest "$appId/config/configreferences/appsettings/$name"
        $tokens = [regex]::Matches(($reference | ConvertTo-Json -Depth 10),
            'ForbiddenByFirewall|ForbiddenByRbac|PublicNetworkAccessDisabled') | ForEach-Object Value | Sort-Object -Unique
        Write-TestEvidence "Initial reference ${name}: status=$($reference.properties.status); denialTokens=$($tokens -join ',')."
    }
    $logsBody = @{ properties = @{
        applicationLogs = @{ fileSystem = @{ level = 'Information' } }
        httpLogs = @{ fileSystem = @{ enabled = $true; retentionInMb = 35; retentionInDays = 1 } }
    } }
    Invoke-TestManagementRequest "$appId/config/logs" -Method Put -Body $logsBody | Out-Null
    Write-TestEvidence 'Enabled test filesystem logging without adding a storage or monitoring resource.'
    $baselineReady = $false
    try {
        & (Join-Path $PSScriptRoot 'Test-WebAppInfrastructure.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId `
            -ResourceGroupName $ResourceGroupName -WebAppName $WebAppName -StorageAccountName $storageName `
            -Networking Enabled -RetryCount 20 | Out-Null
        $baselineReady = $true
    } catch {
        if (-not $_.Exception.Message.StartsWith('The test Web App did not resolve all four Key Vault references and serve Foundry within')) { throw }
        Write-TestEvidence 'Baseline readiness failed within 20 checks. The access evidence was captured before cleanup.'
    }
    foreach ($name in @('FOUNDRY_USERNAME', 'FOUNDRY_PASSWORD', 'FOUNDRY_ADMIN_KEY', 'STORAGE_ACCOUNT_KEY')) {
        $reference = Invoke-TestManagementRequest "$appId/config/configreferences/appsettings/$name"
        Write-TestEvidence "Baseline reference ${name}: status=$($reference.properties.status)."
        if ($reference.properties.status -ne 'Resolved') {
            throw 'Secret retrieval remains unresolved. Refusing a mount-free startup with unavailable credentials.'
        }
    }
    Write-TestEvidence 'Identity classification: all four secrets resolve through the app identity. Missing Key Vault permission does not explain the remaining startup failure.'
    $null = Get-TestLog 'Baseline'
    $originalSettings = Invoke-TestManagementRequest "$appId/config/appsettings/list" -Method Post
    if ($originalSettings.properties.PSObject.Properties.Name -contains 'NODE_OPTIONS') {
        throw 'The test already has NODE_OPTIONS. Refusing to replace it.'
    }
    $originalMount.properties.foundrydata.PSObject.Properties.Remove('state')
    if (-not $baselineReady) {
        Invoke-TestManagementRequest "$appId/config/configreferences/appsettings/refresh" -Method Post | Out-Null
        Invoke-TestManagementRequest "$appId/restart" -Method Post | Out-Null
        $baselineReady = Test-FoundryResponse
        Write-TestEvidence "Explicit restart after resolved references: FoundryReady=$baselineReady. No role, network, or mapping was changed."
        $null = Get-TestLog 'Restart'
    }
    $phase = if ($baselineReady) { 'Baseline' } else { 'Control' }
    $settingsChanged = $true
    Set-TestProbe $phase
    if (-not $baselineReady) {
        $mountRemoved = $true
        Invoke-TestManagementRequest "$appId/config/azurestorageaccounts" -Method Put -Body @{ properties = @{} } | Out-Null
        Write-TestEvidence 'Removed only the approved test mapping. This control is not deployment acceptance.'
    }
    $probe = Get-TestProbe $phase
    if ($probe -and (-not $probe.privateDnsMatches -or -not $probe.smbTcpConnected)) {
        Write-TestEvidence 'Access classification: application-container storage DNS or TCP 445 failed. This is network evidence, not a missing Key Vault role.'
    } elseif ($probe -and $probe.fileRestStatus -ne 200) {
        Write-TestEvidence 'Access classification: TCP 445 and private DNS work, but signed storage access did not return HTTP 200. Use the reported HTTP status and safe error code; do not assume an identity or authentication cause.'
    } elseif ($probe) {
        Write-TestEvidence 'Access classification: application-container private DNS, TCP 445, and signed storage-key access work. The remaining fault is in the platform mount/startup path, not the app Key Vault role. FileREST success does not prove SMB authentication.'
    }
    if ($mountRemoved) {
        Invoke-TestManagementRequest "$appId/config/azurestorageaccounts" -Method Put -Body @{ properties = $originalMount.properties } | Out-Null
        $mountRemoved = $false
        Set-TestProbe 'Restored'
        Write-TestEvidence 'Restored the original test mapping and started a separately labelled probe.'
        $probe = Get-TestProbe 'Restored'
    }
    if ($probe -and $probe.mountInfo -match " - cifs //$([regex]::Escape($storageName))\.file\.[^/\s]+/foundryvttdata\s") {
        $mountPath = Join-Path (Split-Path -Parent $EvidencePath) "$WebAppName-mountinfo.txt"
        $probe.mountInfo -replace '(?i)(username|user|domain|password|pass|key|secret)=[^,\s]*', '[redacted]' |
            Set-Content -LiteralPath $mountPath
        & (Join-Path $PSScriptRoot 'Test-WebAppInfrastructure.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId `
            -ResourceGroupName $ResourceGroupName -WebAppName $WebAppName -StorageAccountName $storageName `
            -Networking Enabled -MountInfoPath $mountPath -RetryCount 12 | Out-Null
        Write-TestEvidence 'Instrumented private runtime: actual CIFS mount and Foundry HTTP readiness verified. This does not prove unchanged cold-deployment acceptance.'
    } else {
        $null = Get-TestLog 'Restored'
        throw 'The original private mount/startup remains unverified. Safe access evidence was preserved.'
    }
} finally {
    $restoring = $true
    try {
        try {
            if ($mountRemoved) {
                Invoke-TestManagementRequest "$appId/config/azurestorageaccounts" -Method Put -Body @{ properties = $originalMount.properties } | Out-Null
                Write-TestEvidence 'Restored the test mapping during failure cleanup.'
            }
        } finally {
            if ($settingsChanged) {
                Invoke-TestManagementRequest "$appId/config/appsettings" -Method Put -Body @{ properties = $originalSettings.properties } | Out-Null
                Write-TestEvidence 'Restored the original test app settings. Owner resource cleanup must still run.'
            }
        }
    } finally {
        Remove-Variable -Name token, headers, originalSettings, originalMount, mapping, reference, logsBody -Force -ErrorAction SilentlyContinue
    }
}
