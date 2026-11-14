#Requires -Version 7.0
<#
.SYNOPSIS
    Checks routing, Key Vault references, and readiness of a test Foundry Web App.

.DESCRIPTION
    Uses the existing azd login for read-only Azure Resource Manager checks.
    Checks the Azure Files configuration and the Foundry HTTP response.
    Reports readiness failure reasons without printing HTTP response bodies.
    An optional mountinfo file must come from the running application container,
    not the SCM container. Without this evidence, runtime mount verification
    remains blocked. The script does not deploy resources or change access.
    DiagnosticsOnly reports selected live settings and fixed container-log
    failure markers. It does not print raw logs or confirm a startup cause.

.PARAMETER SubscriptionId
    The subscription containing the test Web App.

.PARAMETER TenantId
    The tenant used by the existing azd login.

.PARAMETER ResourceGroupName
    The resource group containing the test Web App.

.PARAMETER WebAppName
    The name of the test Foundry Web App.

.PARAMETER StorageAccountName
    The expected Azure Files storage account.

.PARAMETER Networking
    Whether VNet routing and integration must be enabled or disabled.

.PARAMETER MountInfoPath
    A local file containing /proc/self/mountinfo from the application container.

.PARAMETER DiagnosticsOnly
    Collects bounded read-only failure diagnostics instead of readiness checks.

.PARAMETER RetryCount
    Maximum number of reference and readiness checks.

.PARAMETER RetryIntervalSeconds
    Delay between checks.

.EXAMPLE
    .\Test-WebAppInfrastructure.ps1 -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
        -TenantId $env:AZURE_TENANT_ID -ResourceGroupName 'rg-test' `
        -WebAppName 'fvtt-test' -StorageAccountName 'fvtttest' -Networking Enabled

.NOTES
    Requires azd and permission to read the test app and its configuration.
    Does not print tokens, storage keys, or secret values.
    HTTP readiness and storage configuration alone do not prove a runtime mount.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WebAppName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [ValidateSet('Enabled', 'Disabled')]
    [string]$Networking,

    [ValidateNotNullOrEmpty()]
    [string]$MountInfoPath,

    [switch]$DiagnosticsOnly,

    [ValidateRange(1, 60)] # At most 60 polling attempts.
    [int]$RetryCount = 60,

    [ValidateRange(1, 60)] # At most one minute between attempts.
    [int]$RetryIntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedRouting = $Networking -eq 'Enabled'
$appResourceId = "/subscriptions/$([uri]::EscapeDataString($SubscriptionId))/resourceGroups/$([uri]::EscapeDataString($ResourceGroupName))/providers/Microsoft.Web/sites/$([uri]::EscapeDataString($WebAppName))"
$appUri = "https://management.azure.com$appResourceId"
$apiVersion = '2025-03-01'
$referenceNames = @('FOUNDRY_USERNAME', 'FOUNDRY_PASSWORD', 'FOUNDRY_ADMIN_KEY', 'STORAGE_ACCOUNT_KEY')

try {
    $token = & azd auth token --tenant-id $TenantId --scope 'https://management.azure.com/.default' --no-prompt
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Cannot obtain an Azure Resource Manager token from azd.'
    }
    $headers = @{ Authorization = "Bearer $token" }

    if ($DiagnosticsOnly) {
        $diagnosticsFailed = $false
        $diagnosticSettings = [ordered]@{
            AppState = 'Unknown'
            SharedKeyAccess = 'Unknown'
            StoragePublicNetworkAccess = 'Unknown'
            ShareProtocol = 'Unknown'
        }
        $storageUri = "https://management.azure.com/subscriptions/$([uri]::EscapeDataString($SubscriptionId))/resourceGroups/$([uri]::EscapeDataString($ResourceGroupName))/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
        foreach ($target in @(
            @{ Name = 'App'; Uri = "$appUri`?api-version=$apiVersion" }
            @{ Name = 'StorageAccount'; Uri = "$storageUri`?api-version=2024-01-01" }
            @{ Name = 'Share'; Uri = "$storageUri/fileServices/default/shares/foundryvttdata?api-version=2024-01-01" }
        )) {
            try {
                $details = Invoke-RestMethod -Uri $target.Uri -Headers $headers -TimeoutSec 30
                switch ($target.Name) {
                    'App' {
                        if ($details.properties.state -in @('Running', 'Stopped')) {
                            $diagnosticSettings.AppState = $details.properties.state
                        }
                    }
                    'StorageAccount' {
                        if ($details.properties.allowSharedKeyAccess -is [bool]) {
                            $diagnosticSettings.SharedKeyAccess = $details.properties.allowSharedKeyAccess
                        }
                        if ($details.properties.publicNetworkAccess -in @('Enabled', 'Disabled', 'SecuredByPerimeter')) {
                            $diagnosticSettings.StoragePublicNetworkAccess = $details.properties.publicNetworkAccess
                        }
                    }
                    'Share' {
                        if ($details.properties.enabledProtocols -in @('SMB', 'NFS')) {
                            $diagnosticSettings.ShareProtocol = $details.properties.enabledProtocols
                        }
                    }
                }
            } catch {
                $diagnosticsFailed = $true
                $failureStatus = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                    "HTTP $([int]$_.Exception.Response.StatusCode)"
                } else { 'Request failed' }
                Write-Warning "$($target.Name) diagnostic request failed ($failureStatus). Response details are not printed."
            }
        }
        $diagnosticSettings.GetEnumerator() | ForEach-Object {
            Write-Information "Startup diagnostic $($_.Key): $($_.Value)." -InformationAction Continue
        }

        $logStatus = 'Unavailable'
        $failureMarkers = @()
        try {
            $logResponse = Invoke-WebRequest -Method Post -Uri "$appUri/containerlogs?api-version=$apiVersion" -Headers $headers -TimeoutSec 30 -MaximumRedirection 0
            $startupLogs = $null
            if ($logResponse.StatusCode -notin @(200, 204)) {
                $diagnosticsFailed = $true
                Write-Warning "Container log diagnostic request returned HTTP $([int]$logResponse.StatusCode). Response details are not printed."
            } elseif ($logResponse.StatusCode -eq 204 -or [string]::IsNullOrWhiteSpace($logResponse.Content)) {
                Write-Warning 'Container logs are unavailable. The startup cause remains unconfirmed.'
            } else {
                if ($logResponse.Content -is [string]) {
                    $startupLogs = $logResponse.Content
                } elseif ($logResponse.Content -is [byte[]]) {
                    try {
                        $startupLogs = [System.Text.UTF8Encoding]::new($false, $true).GetString($logResponse.Content)
                    } catch [System.Text.DecoderFallbackException] {
                        $startupLogs = $null
                    }
                }
                if ($null -eq $startupLogs -or $startupLogs -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
                    $diagnosticsFailed = $true
                    $startupLogs = $null
                    Write-Warning 'Container logs have an unsupported response format. Raw content is not printed.'
                }
            }
            if ($null -ne $startupLogs) {
                $logStatus = 'Read'
                $startupLogs = $startupLogs.Substring([Math]::Max(0, $startupLogs.Length - 65536))
                foreach ($marker in @('BYOSFailure', 'ImagePullFailure', 'ContainerStartFailure')) {
                    if ($startupLogs -match "\b$marker\b") {
                        $failureMarkers += $marker
                    }
                }
                $markerSummary = if ($failureMarkers.Count -gt 0) { $failureMarkers -join ', ' } else { 'None detected in the inspected log tail' }
                Write-Information "Container log failure markers: $markerSummary. These observations do not confirm the startup cause or the runtime mount." -InformationAction Continue
            }
        } catch {
            $diagnosticsFailed = $true
            $failureStatus = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                "HTTP $([int]$_.Exception.Response.StatusCode)"
            } else { 'Request failed' }
            Write-Warning "Container log diagnostic request failed ($failureStatus). Response details are not printed."
        }
        Write-Warning 'Runtime /data mount verification remains BLOCKED in diagnostic mode. Application-container mountinfo is still required.'
        if ($diagnosticsFailed) {
            throw 'One or more startup diagnostic requests failed. These failures do not replace the original readiness or provisioning failure.'
        }
        [pscustomobject]@{
            Settings = [pscustomobject]$diagnosticSettings
            ContainerLogStatus = $logStatus
            FailureMarkers = $failureMarkers
            RuntimeMountVerified = $false
        }
        return
    }

    $app = Invoke-RestMethod -Uri "$appUri`?api-version=$apiVersion" -Headers $headers -TimeoutSec 30 -MaximumRetryCount 3 -RetryIntervalSec 5
    if ($app.properties.outboundVnetRouting.allTraffic -ne $expectedRouting) {
        throw "The Web App allTraffic routing setting does not match Networking=$Networking."
    }
    $hasSubnet = -not [string]::IsNullOrWhiteSpace($app.properties.virtualNetworkSubnetId)
    if ($hasSubnet -ne $expectedRouting) {
        throw "The Web App VNet integration does not match Networking=$Networking."
    }
    if ([string]::IsNullOrWhiteSpace($app.properties.defaultHostName)) {
        throw 'The Web App response has no default hostname.'
    }

    $storage = Invoke-RestMethod -Method Post -Uri "$appUri/config/azurestorageaccounts/list?api-version=$apiVersion" -Headers $headers -TimeoutSec 30 -MaximumRetryCount 3 -RetryIntervalSec 5
    $mount = $storage.properties.foundrydata
    if ($mount.accountName -ne $StorageAccountName -or $mount.shareName -ne 'foundryvttdata' -or
        $mount.mountPath -ne '/data' -or $mount.type -ne 'AzureFiles' -or $mount.protocol -ne 'Smb') {
        throw 'The foundrydata configuration does not match the expected Azure Files SMB mount at /data.'
    }

    $runtimeMountVerified = $false
    if ($MountInfoPath) {
        $mountInfo = Get-Content -LiteralPath $MountInfoPath
        $sourcePattern = '//{0}\.file\.[^/\s]+/foundryvttdata' -f [regex]::Escape($StorageAccountName)
        if (-not ($mountInfo -match "^\d+ \d+ \S+ \S+ /data \S+.* - cifs $sourcePattern\s")) {
            throw 'The application mountinfo evidence does not show the expected Azure Files CIFS mount at /data.'
        }
        $runtimeMountVerified = $true
    }

    $ready = $false
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $unresolved = @()
        $referenceRequestFailed = $false
        foreach ($referenceName in $referenceNames) {
            try {
                $reference = Invoke-RestMethod -Uri "$appUri/config/configreferences/appsettings/$referenceName`?api-version=$apiVersion" -Headers $headers -TimeoutSec 30 -MaximumRetryCount 3 -RetryIntervalSec 5
            } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
                throw
            } catch [System.IO.IOException], [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
                $referenceRequestFailed = $true
                $unresolved += "$referenceName=ManagementRequestFailed"
                Write-Warning "The Azure management request failed for $referenceName on attempt ${attempt}. Retrying within the configured readiness limit."
                break
            }
            if ($reference.properties.status -ne 'Resolved') {
                $unresolved += "$referenceName=$($reference.properties.status)"
            }
        }

        $ready = $false
        $readinessStatus = if ($referenceRequestFailed) { 'Key Vault reference status request failed.' } else { 'Key Vault references are unresolved.' }
        if ($unresolved.Count -eq 0) {
            try {
                $response = Invoke-WebRequest -Uri "https://$($app.properties.defaultHostName)/" -SkipHttpErrorCheck -TimeoutSec 30
                if ($response.StatusCode -ne 200) {
                    $readinessStatus = "HTTP status $([int]$response.StatusCode)."
                } elseif ($response.Content -notmatch '<title>[^<]*Foundry Virtual Tabletop[^<]*</title>') {
                    $readinessStatus = 'HTTP 200 response does not identify Foundry.'
                } else {
                    $ready = $true
                }
            } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
                $readinessStatus = 'HTTP request failed.'
                Write-Warning "The Web App HTTP request failed on attempt ${attempt}: $($_.Exception.Message). Retrying within the configured limit."
            }
        }
        if ($ready) {
            break
        }
        Write-Information "Readiness attempt $attempt/$RetryCount. $readinessStatus Unresolved or unchecked references: $($unresolved -join ', ')." -InformationAction Continue
        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds $RetryIntervalSeconds
        }
    }
    if (-not $ready) {
        throw "The test Web App did not resolve all four Key Vault references and serve Foundry within $RetryCount attempts. Last readiness result: $readinessStatus Unresolved or unchecked references: $($unresolved -join ', ')."
    }
    if (-not $runtimeMountVerified) {
        Write-Warning 'Runtime /data mount verification is BLOCKED: supply mountinfo from the application container. Routing, configuration, and HTTP readiness do not prove the mount.'
    }
    [pscustomobject]@{
        RoutingVerified = $true
        KeyVaultReferencesVerified = $true
        StorageConfigurationVerified = $true
        FoundryHttpReady = $true
        RuntimeMountVerified = $runtimeMountVerified
    }
} finally {
    Remove-Variable -Name token, headers, storage, mount, reference, details, logResponse, startupLogs -Force -ErrorAction SilentlyContinue
}
