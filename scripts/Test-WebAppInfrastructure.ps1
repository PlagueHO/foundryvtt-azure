#Requires -Version 7.0
<#
.SYNOPSIS
    Checks routing, Key Vault references, and readiness of a test Foundry Web App.

.DESCRIPTION
    Uses the existing azd login for read-only Azure Resource Manager checks.
    Checks the Azure Files configuration and the Foundry HTTP response.
    An optional mountinfo file must come from the running application container,
    not the SCM container. Without this evidence, runtime mount verification
    remains blocked. The script does not deploy resources or change access.

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

    $app = Invoke-RestMethod -Uri "$appUri`?api-version=$apiVersion" -Headers $headers -TimeoutSec 30
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

    $storage = Invoke-RestMethod -Method Post -Uri "$appUri/config/azurestorageaccounts/list?api-version=$apiVersion" -Headers $headers -TimeoutSec 30
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
        foreach ($referenceName in $referenceNames) {
            $reference = Invoke-RestMethod -Uri "$appUri/config/configreferences/appsettings/$referenceName`?api-version=$apiVersion" -Headers $headers -TimeoutSec 30
            if ($reference.properties.status -ne 'Resolved') {
                $unresolved += $referenceName
            }
        }

        $ready = $false
        if ($unresolved.Count -eq 0) {
            try {
                $response = Invoke-WebRequest -Uri "https://$($app.properties.defaultHostName)/" -SkipHttpErrorCheck -TimeoutSec 30
                $ready = $response.StatusCode -eq 200 -and $response.Content -match '<title>[^<]*Foundry Virtual Tabletop[^<]*</title>'
            } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
                Write-Warning "The Web App HTTP request failed on attempt ${attempt}: $($_.Exception.Message). Retrying within the configured limit."
            }
        }
        if ($ready) {
            break
        }
        Write-Information "Readiness attempt $attempt/$RetryCount. Unresolved references: $($unresolved -join ', ')." -InformationAction Continue
        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds $RetryIntervalSeconds
        }
    }
    if (-not $ready) {
        throw "The test Web App did not resolve all four Key Vault references and serve Foundry within $RetryCount attempts."
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
    Remove-Variable -Name token, headers, storage, mount, reference -Force -ErrorAction SilentlyContinue
}
