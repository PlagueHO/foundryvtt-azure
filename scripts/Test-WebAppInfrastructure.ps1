#Requires -Version 7.0
<#
.SYNOPSIS
    Checks routing, Key Vault references, and readiness of a test Foundry Web App.

.DESCRIPTION
    Uses the existing azd login for read-only Azure Resource Manager checks.
    Checks effective Shared Key access, the Azure Files configuration, and the Foundry HTTP response.
    Reports readiness failure reasons without printing HTTP response bodies.
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

.PARAMETER CaptureRuntimeMount
    Read /proc/self/mountinfo through the authenticated application-container
    terminal. Fail if live CIFS mount evidence cannot be obtained.

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

    [switch]$CaptureRuntimeMount,

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
$storageAccountUri = "https://management.azure.com/subscriptions/$([uri]::EscapeDataString($SubscriptionId))/resourceGroups/$([uri]::EscapeDataString($ResourceGroupName))/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
$apiVersion = '2025-03-01'
$referenceNames = @('FOUNDRY_USERNAME', 'FOUNDRY_PASSWORD', 'FOUNDRY_ADMIN_KEY', 'STORAGE_ACCOUNT_KEY')

function Get-ApplicationMountEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$ScmHostName,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$ExpectedStorageAccount
    )

    $nonce = [guid]::NewGuid().ToString('N')
    $remoteScript = @"
const fs = require('node:fs');
const lines = fs.readFileSync('/proc/self/mountinfo', 'utf8').trim().split('\n');
const mounts = lines.map(line => {
  const fields = line.split(' ');
  const separator = fields.indexOf('-');
  return { mountPoint: fields[4], fileSystem: fields[separator + 1], source: fields[separator + 2] };
}).filter(mount => mount.mountPoint === '/data');
process.stdout.write('FVTT_MOUNT_$nonce ' + JSON.stringify({ mounts }) + '\n');
"@
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
    $command = "printf '\n'; node -e `"eval(Buffer.from('$encodedScript','base64').toString('utf8'))`"; exit`n"
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(60))
    try {
        $socket.Options.SetRequestHeader('Authorization', "Bearer $AccessToken")
        # With no target override, App Service connects to the main application container.
        [void]$socket.ConnectAsync([uri]"wss://$ScmHostName/exec/shell?shell=/bin/sh", $timeout.Token).GetAwaiter().GetResult()
        $commandBytes = [Text.Encoding]::UTF8.GetBytes($command)
        [void]$socket.SendAsync([ArraySegment[byte]]::new($commandBytes), [Net.WebSockets.WebSocketMessageType]::Binary, $true, $timeout.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(4096)
        $decoder = [Text.Encoding]::UTF8.GetDecoder()
        $characters = [char[]]::new(4096)
        $output = [Text.StringBuilder]::new()
        while ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            $frame = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $timeout.Token).GetAwaiter().GetResult()
            if ($frame.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                break
            }
            $characterCount = $decoder.GetChars($buffer, 0, $frame.Count, $characters, 0)
            [void]$output.Append($characters, 0, $characterCount)
            if ($output.Length -gt 65536) {
                throw 'Application-container mount capture exceeded its output limit. Raw terminal output is not printed.'
            }
            $record = [regex]::Match($output.ToString(), "(?m)^FVTT_MOUNT_$nonce (?<data>\{[^\r\n]+\})\r?\n")
            if ($record.Success) {
                $evidence = $record.Groups['data'].Value | ConvertFrom-Json
                $sourcePattern = '^//{0}\.file\.[^/\s]+/foundryvttdata$' -f [regex]::Escape($ExpectedStorageAccount)
                $matchingMounts = @($evidence.mounts | Where-Object {
                    $_.mountPoint -ceq '/data' -and $_.fileSystem -ceq 'cifs' -and $_.source -cmatch $sourcePattern
                })
                if ($matchingMounts.Count -ne 1 -or @($evidence.mounts).Count -ne 1) {
                    throw 'The live application-container mountinfo does not show the expected Azure Files CIFS mount at /data.'
                }
                return [pscustomobject]@{
                    MountPoint = '/data'
                    FileSystem = 'cifs'
                    Source = $matchingMounts[0].source
                    CapturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    CaptureMethod = 'AppServiceApplicationTerminal'
                }
            }
        }
        throw 'The application-container terminal closed without current mount evidence. Runtime /data verification is blocked.'
    } catch [OperationCanceledException] {
        throw 'Application-container mount capture timed out. Runtime /data verification is blocked.'
    } catch [Net.WebSockets.WebSocketException] {
        throw 'Cannot access the application-container terminal. Check SCM network access and existing permissions. Runtime /data verification is blocked.'
    } finally {
        $socket.Dispose()
        $timeout.Dispose()
        Remove-Variable -Name AccessToken, output -Force -ErrorAction SilentlyContinue
    }
}

if ($CaptureRuntimeMount -and $MountInfoPath) {
    throw 'Choose live application-container capture or a supplied mountinfo file, not both.'
}

try {
    $token = & azd auth token --tenant-id $TenantId --scope 'https://management.azure.com/.default' --no-prompt
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Cannot obtain an Azure Resource Manager token from azd.'
    }
    $headers = @{ Authorization = "Bearer $token" }

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

    $storageAccount = Invoke-RestMethod -Uri "$storageAccountUri`?api-version=2024-01-01" -Headers $headers -TimeoutSec 30 -MaximumRetryCount 3 -RetryIntervalSec 5
    if ($null -eq $storageAccount.properties) {
        throw 'Cannot check Shared Key access: the test storage account response has no properties.'
    }
    if ($storageAccount.properties.allowSharedKeyAccess -eq $false) {
        throw 'The test storage account has allowSharedKeyAccess=false. This deployment uses an account key for the Azure Files mount. Review effective Azure Policy and storage configuration with the environment owner, or use an approved compatible test environment. Do not bypass policy or change production. Foundry readiness and the runtime /data mount remain unverified.'
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
    $runtimeMountEvidence = $null
    if ($CaptureRuntimeMount) {
        $expectedScmHostName = $app.properties.defaultHostName -creplace '^([^.]+)\.', '$1.scm.'
        $scmHostName = @($app.properties.enabledHostNames | Where-Object {
            $_ -ceq $expectedScmHostName
        })
        if ($scmHostName.Count -ne 1) {
            throw 'Cannot identify the expected SCM hostname from the test Web App response.'
        }
        $runtimeMountEvidence = Get-ApplicationMountEvidence -ScmHostName $scmHostName[0] -AccessToken $token -ExpectedStorageAccount $StorageAccountName
        $runtimeMountVerified = $true
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
        RuntimeMountEvidence = $runtimeMountEvidence
    }
} finally {
    Remove-Variable -Name token, headers, storage, mount, reference -Force -ErrorAction SilentlyContinue
}
