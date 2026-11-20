<#
.SYNOPSIS
    Validates, inspects, or removes an exact GitHub Actions test resource group.
.DESCRIPTION
    Uses azd authentication and ARM requests independently of azd deployment outputs.
    Deletion requires run-specific names and the expected azd-env-name tag.
    Only HTTP 404 proves that the resource group is absent.
.PARAMETER SubscriptionId
    Subscription that contains the test deployment.
.PARAMETER TenantId
    Tenant used for azd authentication.
.PARAMETER EnvironmentName
    Exact test environment name for this run and attempt.
.PARAMETER ResourceGroupName
    Exact resource group name for this test environment.
.PARAMETER ComputeService
    Compute mode for the test case.
.PARAMETER RunId
    GitHub Actions run ID.
.PARAMETER RunAttempt
    GitHub Actions run attempt.
.PARAMETER ValidateOnly
    Rejects an existing target before provisioning. Does not change Azure.
.PARAMETER StopDeploymentsOnly
    Prints safe deployment metadata and stops matching active ARM deployments.
.PARAMETER TimeoutSeconds
    Deadline for ARM requests and deletion polling, excluding token acquisition.
.PARAMETER EvidencePath
    Run-local file used to carry service-managed group names across cleanup steps.
.EXAMPLE
    .\Remove-TestInfrastructure.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId `
        -EnvironmentName fvtt-aca-123-1 -ResourceGroupName rg-fvtt-aca-123-1 `
        -ComputeService 'Container App' -RunId 123 -RunAttempt 1
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Cleanup')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateSet('Web App', 'Container App', 'Container Instance')]
    [string]$ComputeService,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]+$')]
    [string]$RunId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]+$')]
    [string]$RunAttempt,

    [Parameter(Mandatory, ParameterSetName = 'Validate')]
    [switch]$ValidateOnly,

    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [switch]$StopDeploymentsOnly,

    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    # Leave headroom within the workflow step for authentication and error reporting.
    [ValidateRange(1, 1500)]
    [int]$TimeoutSeconds = 1080
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$prefixes = switch ($ComputeService) {
    'Web App' { 'fvtt-asp-on'; 'fvtt-asp-off' }
    'Container App' { 'fvtt-aca' }
    'Container Instance' { 'fvtt-aci' }
}
$allowedNames = @($prefixes | ForEach-Object { "$_-$RunId-$RunAttempt" })
if ($EnvironmentName -cnotin $allowedNames -or $ResourceGroupName -cne "rg-$EnvironmentName") {
    throw 'Rejected test cleanup scope: exact names for this run, attempt, and compute mode are required.'
}

$subscriptionPath = "/subscriptions/$([uri]::EscapeDataString($SubscriptionId))"
$groupPath = "$subscriptionPath/resourceGroups/$([uri]::EscapeDataString($ResourceGroupName))"
$apiVersion = '2021-04-01'

function Invoke-TestArmRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Delete')]
        [string]$Method,
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$AllowConflict
    )

    $remainingSeconds = [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 1) {
        throw "Test cleanup deadline reached. Group deletion is not verified: $ResourceGroupName."
    }
    $response = Invoke-WebRequest -Method $Method -Uri "https://management.azure.com$Path" `
        -Headers $headers -SkipHttpErrorCheck -TimeoutSec ([Math]::Min(30, $remainingSeconds))
    if ([int]$response.StatusCode -notin @(200, 201, 202, 204, 404) -and
        -not ($AllowConflict -and $response.StatusCode -eq 409)) {
        throw "ARM $Method failed with HTTP $([int]$response.StatusCode) for $Path. Group deletion is not verified."
    }
    return $response
}

function Get-TestArmCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    while ($Path) {
        $response = Invoke-TestArmRequest -Method Get -Path $Path
        if ($response.StatusCode -eq 404) {
            return
        }
        $page = $response.Content | ConvertFrom-Json
        $page.value
        $Path = $null
        if ($page.nextLink) {
            $next = [uri]$page.nextLink
            if ($next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or
                -not $next.AbsolutePath.StartsWith("$subscriptionPath/", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Rejected an ARM pagination link outside the test subscription.'
            }
            $Path = $next.PathAndQuery
        }
    }
}

try {
    $token = & azd auth token --tenant-id $TenantId --scope 'https://management.azure.com/.default' --no-prompt
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Cannot obtain an ARM token for test cleanup.'
    }
    $headers = @{ Authorization = "Bearer $token" }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $groupResponse = Invoke-TestArmRequest -Method Get -Path "$groupPath`?api-version=$apiVersion"

    if ($ValidateOnly) {
        if ($groupResponse.StatusCode -ne 404) {
            throw "Rejected existing test resource group: $ResourceGroupName."
        }
        return
    }

    if ($groupResponse.StatusCode -ne 404) {
        $group = $groupResponse.Content | ConvertFrom-Json
        if ($group.tags.'azd-env-name' -cne $EnvironmentName) {
            throw "Rejected test resource group with a missing or incorrect azd-env-name tag: $ResourceGroupName."
        }
    }

    if ($StopDeploymentsOnly) {
        if ($Env:GITHUB_OUTPUT) {
            'scope_validated=true' | Add-Content -LiteralPath $Env:GITHUB_OUTPUT
        }
        $deployments = [Collections.Generic.List[object]]::new()
        $namePattern = '^' + [regex]::Escape($EnvironmentName) + '-[0-9]+$'
        foreach ($candidate in (Get-TestArmCollection -Path "$subscriptionPath/providers/Microsoft.Resources/deployments?api-version=$apiVersion")) {
            if ($candidate.name -cnotmatch $namePattern) {
                continue
            }
            $path = "$subscriptionPath/providers/Microsoft.Resources/deployments/$([uri]::EscapeDataString($candidate.name))"
            $detail = Invoke-TestArmRequest -Method Get -Path "$path`?api-version=$apiVersion"
            if ($detail.StatusCode -eq 404) {
                continue
            }
            $deployment = $detail.Content | ConvertFrom-Json
            if ($deployment.properties.parameters.environmentName.value -cne $EnvironmentName -or
                $deployment.properties.parameters.resourceGroupName.value -cne $ResourceGroupName) {
                throw "Rejected subscription deployment with mismatched test parameters: $($candidate.name)."
            }
            $deployments.Add(@{ Path = $path; Deployment = $deployment })
        }
        if ($groupResponse.StatusCode -ne 404) {
            foreach ($deployment in (Get-TestArmCollection -Path "$groupPath/providers/Microsoft.Resources/deployments?api-version=$apiVersion")) {
                $path = "$groupPath/providers/Microsoft.Resources/deployments/$([uri]::EscapeDataString($deployment.name))"
                $deployments.Add(@{ Path = $path; Deployment = $deployment })
            }
        }
        foreach ($item in $deployments) {
            $deployment = $item.Deployment
            [ordered]@{
                deploymentName = $deployment.name
                resourceGroup = $ResourceGroupName
                state = $deployment.properties.provisioningState
                correlationId = $deployment.properties.correlationId
                errorCode = $deployment.properties.error.code
            } | ConvertTo-Json -Compress | Write-Information -InformationAction Continue
            if ($deployment.properties.provisioningState -in @('Accepted', 'Running')) {
                if (-not $PSCmdlet.ShouldProcess($item.Path, 'Cancel active test deployment')) {
                    continue
                }
                $cancelResponse = Invoke-TestArmRequest -Method Post -Path "$($item.Path)/cancel?api-version=$apiVersion" -AllowConflict
                do {
                    $status = Invoke-TestArmRequest -Method Get -Path "$($item.Path)?api-version=$apiVersion"
                    if ($status.StatusCode -eq 404) { break }
                    $state = ($status.Content | ConvertFrom-Json).properties.provisioningState
                    if ($state -in @('Succeeded', 'Failed', 'Canceled')) { break }
                    if ($cancelResponse.StatusCode -eq 409) {
                        throw "ARM cancellation returned HTTP 409 for $($item.Path), but the deployment is still $state."
                    }
                    Start-Sleep -Seconds 5
                } while ($true)
            }
        }
        if ($EvidencePath -and $ComputeService -eq 'Container App') {
            $managedGroups = @()
            if ($groupResponse.StatusCode -ne 404) {
                $abbreviations = Get-Content (Join-Path $PSScriptRoot '..\infra\abbreviations.json') -Raw | ConvertFrom-Json
                $managedEnvironmentName = "$($abbreviations.appManagedEnvironments)$EnvironmentName"
                $managedEnvironment = Invoke-TestArmRequest -Method Get `
                    -Path "$groupPath/providers/Microsoft.App/managedEnvironments/$([uri]::EscapeDataString($managedEnvironmentName))?api-version=2025-10-02-preview"
                if ($managedEnvironment.StatusCode -ne 404) {
                    $managedGroup = ($managedEnvironment.Content | ConvertFrom-Json).properties.infrastructureResourceGroup
                    if (-not [string]::IsNullOrWhiteSpace($managedGroup)) {
                        $managedGroups = @($managedGroup)
                        Write-Information "Service-managed infrastructure group: $managedGroup." -InformationAction Continue
                    }
                }
            }
            @{ environmentName = $EnvironmentName; resourceGroupName = $ResourceGroupName; managedGroups = $managedGroups } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $EvidencePath
        }
        return
    }

    if ($groupResponse.StatusCode -ne 404) {
        if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete remaining test resource group')) {
            Write-Warning 'Deletion was not attempted. Group deletion is not verified.'
            return
        }
        Write-Warning "azd cleanup left the test group deployed. Requesting guarded ARM deletion: $ResourceGroupName."
        $null = Invoke-TestArmRequest -Method Delete -Path "$groupPath`?api-version=$apiVersion"
        do {
            $groupResponse = Invoke-TestArmRequest -Method Get -Path "$groupPath`?api-version=$apiVersion"
            if ($groupResponse.StatusCode -eq 404) { break }
            Start-Sleep -Seconds 10
        } while ($true)
    }
    $message = "Test resource group deletion: verified (HTTP 404). Group: $ResourceGroupName."
    Write-Information $message -InformationAction Continue
    if ($Env:GITHUB_STEP_SUMMARY) {
        $message | Add-Content -LiteralPath $Env:GITHUB_STEP_SUMMARY
    }
    if ($EvidencePath -and $ComputeService -eq 'Container App') {
        if (-not (Test-Path -LiteralPath $EvidencePath)) {
            throw 'Test group is absent, but service-managed group evidence is missing. Inspect Container Apps provider cleanup.'
        }
        $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
        if ($evidence.environmentName -cne $EnvironmentName -or $evidence.resourceGroupName -cne $ResourceGroupName) {
            throw 'Rejected service-managed group evidence for a different test target.'
        }
        foreach ($managedGroup in $evidence.managedGroups) {
            $managedGroupPath = "$subscriptionPath/resourceGroups/$([uri]::EscapeDataString($managedGroup))"
            $managedGroupResponse = Invoke-TestArmRequest -Method Get -Path "$managedGroupPath`?api-version=$apiVersion"
            if ($managedGroupResponse.StatusCode -ne 404) {
                Write-Warning "Service-managed infrastructure group is still deployed: $managedGroup. Waiting for Azure provider cleanup; no direct deletion will be attempted."
                do {
                    Start-Sleep -Seconds 10
                    $managedGroupResponse = Invoke-TestArmRequest -Method Get -Path "$managedGroupPath`?api-version=$apiVersion"
                } while ($managedGroupResponse.StatusCode -ne 404)
            }
            Write-Information "Service-managed group deletion: verified (HTTP 404). Group: $managedGroup." -InformationAction Continue
        }
    }
} finally {
    Remove-Variable -Name token, headers, response, groupResponse, group, detail, deployment, deployments, candidate, item -Force -WhatIf:$false -Confirm:$false -ErrorAction SilentlyContinue
}
