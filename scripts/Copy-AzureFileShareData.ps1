#Requires -Modules Az.Storage
<#
.SYNOPSIS
    Copies all data between Azure File Shares using AzCopy with SAS tokens.

.DESCRIPTION
    This script creates SAS tokens for source and destination Azure File Shares and uses AzCopy 
    to perform the copy operation. The script supports cross-tenant/subscription scenarios where 
    the storage accounts exist in different Azure tenants and subscriptions.
    
    The script automatically checks and enables public network access on both storage accounts
    if required, as AzCopy with SAS tokens requires public network access to function properly.

.PARAMETER SourceSubscriptionId
    The Azure subscription ID containing the source storage account.

.PARAMETER SourceStorageAccountName
    The name of the source Azure storage account.

.PARAMETER SourceFileShareName
    The name of the source file share.

.PARAMETER SourceResourceGroupName
    The resource group name containing the source storage account.

.PARAMETER DestinationSubscriptionId
    The Azure subscription ID containing the destination storage account.

.PARAMETER DestinationStorageAccountName
    The name of the destination Azure storage account.

.PARAMETER DestinationFileShareName
    The name of the destination file share.

.PARAMETER DestinationResourceGroupName
    The resource group name containing the destination storage account.

.PARAMETER SasTokenExpiryHours
    Number of hours from now when the SAS tokens should expire. Default is 24 hours.

.PARAMETER Overwrite
    If specified, uses --overwrite=true when re-running the command.

.PARAMETER CheckMD5
    If specified, uses --check-md5 for integrity verification during large transfers.

.PARAMETER LogLevel
    AzCopy log level. Valid values: DEBUG, INFO, WARNING, ERROR, PANIC, FATAL. Default is INFO.

.PARAMETER DryRun
    If specified, only displays the AzCopy command that would be executed without running it.

.PARAMETER SkipNetworkAccessCheck
    If specified, skips checking and modifying public network access settings on storage accounts.
    Use this if you want to manually manage network access or if the accounts already have proper access configured.

.EXAMPLE
    .\Copy-AzureFileShareData.ps1 -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
                                  -SourceStorageAccountName "srcstorage" `
                                  -SourceFileShareName "myshare" `
                                  -SourceResourceGroupName "source-rg" `
                                  -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
                                  -DestinationStorageAccountName "dststorage" `
                                  -DestinationFileShareName "backupshare" `
                                  -DestinationResourceGroupName "dest-rg"

.EXAMPLE
    .\Copy-AzureFileShareData.ps1 -SourceSubscriptionId "11111111-1111-1111-1111-111111111111" `
                                  -SourceStorageAccountName "srcstorage" `
                                  -SourceFileShareName "myshare" `
                                  -SourceResourceGroupName "source-rg" `
                                  -DestinationSubscriptionId "22222222-2222-2222-2222-222222222222" `
                                  -DestinationStorageAccountName "dststorage" `
                                  -DestinationFileShareName "backupshare" `
                                  -DestinationResourceGroupName "dest-rg" `
                                  -Overwrite `
                                  -CheckMD5 `
                                  -SasTokenExpiryHours 48

.NOTES
    - Requires Az.Storage PowerShell module
    - Requires authentication to both source and destination Azure subscriptions
    - AzCopy must be installed and accessible in PATH
    - File share names are case-sensitive
    - SAS tokens are created with minimum required permissions for the operation
    - The script automatically checks and enables public network access on storage accounts if needed
    - Public network access changes may take up to 30 seconds to propagate
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceStorageAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceFileShareName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationStorageAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationFileShareName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 168)] # Maximum 7 days (168 hours) for user delegation SAS
    [int]$SasTokenExpiryHours = 24,

    [Parameter(Mandatory = $false)]
    [switch]$Overwrite,

    [Parameter(Mandatory = $false)]
    [switch]$CheckMD5,

    [Parameter(Mandatory = $false)]
    [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'PANIC', 'FATAL')]
    [string]$LogLevel = 'INFO',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkAccessCheck
)

# Error handling
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    
    $originalColor = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $Color
    Write-Output $Message
    $Host.UI.RawUI.ForegroundColor = $originalColor
}

# Function to validate AzCopy installation
function Test-AzCopyInstallation {
    try {
        $azCopyVersion = & azcopy --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput "✓ AzCopy is installed: $($azCopyVersion[0])" -Color Green
            return $true
        }
    }
    catch {
        # AzCopy not found
    }
    
    Write-ColorOutput "✗ AzCopy is not installed or not in PATH" -Color Red
    Write-ColorOutput "Please install AzCopy from: https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10" -Color Yellow
    return $false
}

# Function to check and enable public network access
function Test-StorageAccountNetworkAccess {
    param(
        [string]$SubscriptionId,
        [string]$StorageAccountName,
        [string]$ResourceGroupName
    )
    
    try {
        Write-ColorOutput "Checking network access for storage account: $StorageAccountName" -Color Yellow
        
        # Switch to the correct subscription
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        
        # Get the storage account
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
        
        # Check public network access setting
        $publicNetworkAccess = $storageAccount.PublicNetworkAccess
        
        if ($publicNetworkAccess -eq 'Disabled') {
            Write-ColorOutput "⚠️  Public network access is disabled for storage account: $StorageAccountName" -Color Yellow
            Write-ColorOutput "Enabling public network access for AzCopy operation..." -Color Yellow
            
            # Enable public network access
            Set-AzStorageAccount -ResourceGroupName $ResourceGroupName `
                                -Name $StorageAccountName `
                                -PublicNetworkAccess Enabled
            
            Write-ColorOutput "✓ Public network access enabled for storage account: $StorageAccountName" -Color Green
            return $true
        }
        elseif ($publicNetworkAccess -eq 'Enabled') {
            Write-ColorOutput "✓ Public network access is already enabled for storage account: $StorageAccountName" -Color Green
            return $false
        }
        else {
            Write-ColorOutput "✓ Public network access setting: $publicNetworkAccess for storage account: $StorageAccountName" -Color Green
            return $false
        }
    }
    catch {
        Write-Error "Failed to check/enable public network access for storage account '$StorageAccountName' in subscription '$SubscriptionId': $($_.Exception.Message)"
        throw
    }
}

# Function to create SAS token for file share
function New-FileShareSasToken {
    param(
        [string]$SubscriptionId,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [string]$ResourceGroupName,
        [string]$Permission,
        [DateTime]$ExpiryTime
    )
    
    try {
        Write-ColorOutput "Switching to subscription: $SubscriptionId" -Color Yellow
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        
        Write-ColorOutput "Getting storage account context for: $StorageAccountName" -Color Yellow
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
        $storageContext = $storageAccount.Context
        
        Write-ColorOutput "Creating SAS token for file share: $FileShareName with permissions: $Permission" -Color Yellow
        
        # Create account-level SAS token for file service
        $sasToken = New-AzStorageAccountSASToken `
            -Service File `
            -ResourceType Service,Container,Object `
            -Permission $Permission `
            -ExpiryTime $ExpiryTime `
            -Context $storageContext
        
        # Construct the full URL with SAS token
        $fileShareUrl = "https://$StorageAccountName.file.core.windows.net/$FileShareName$sasToken"
        
        return $fileShareUrl
    }
    catch {
        Write-Error "Failed to create SAS token for storage account '$StorageAccountName' in subscription '$SubscriptionId': $($_.Exception.Message)"
        throw
    }
}

# Function to execute AzCopy command
function Invoke-AzCopyCommand {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$SourceUrl,
        [string]$DestinationUrl,
        [string[]]$AdditionalParameters
    )
    
    # Build the AzCopy command
    $azCopyArgs = @(
        'copy'
        "`"$SourceUrl`""
        "`"$DestinationUrl`""
        '--recursive=true'
        "--log-level=$LogLevel"
    )
    
    # Add additional parameters
    $azCopyArgs += $AdditionalParameters
    
    $command = "azcopy $($azCopyArgs -join ' ')"
    
    Write-ColorOutput "`nAzCopy command to be executed:" -Color Cyan
    Write-ColorOutput $command -Color White
    
    if ($DryRun) {
        Write-ColorOutput "`n✓ Dry run mode - command displayed above but not executed" -Color Yellow
        return $true
    }
    
    if ($PSCmdlet.ShouldProcess("File share data copy", "Execute AzCopy command")) {
        Write-ColorOutput "`nExecuting AzCopy command..." -Color Green
        
        try {
            # Execute AzCopy
            $startTime = Get-Date
            & azcopy @azCopyArgs
            $endTime = Get-Date
            $duration = $endTime - $startTime
            
            if ($LASTEXITCODE -eq 0) {
                Write-ColorOutput "`n✓ AzCopy operation completed successfully in $($duration.ToString('hh\:mm\:ss'))" -Color Green
                return $true
            }
            else {
                Write-ColorOutput "`n✗ AzCopy operation failed with exit code: $LASTEXITCODE" -Color Red
                return $false
            }
        }
        catch {
            Write-Error "Failed to execute AzCopy command: $($_.Exception.Message)"
            return $false
        }
    }
    
    return $false
}

# Main script execution
try {
    Write-ColorOutput "=== Azure File Share Data Copy Script ===" -Color Cyan
    Write-ColorOutput "Starting file share copy operation..." -Color White
    
    # Validate AzCopy installation
    if (-not (Test-AzCopyInstallation)) {
        exit 1
    }
    
    # Calculate expiry time
    $expiryTime = (Get-Date).AddHours($SasTokenExpiryHours)
    Write-ColorOutput "`nSAS tokens will expire at: $($expiryTime.ToString('yyyy-MM-dd HH:mm:ss UTC'))" -Color Yellow
    
    # Check and ensure public network access is enabled for both storage accounts
    if (-not $SkipNetworkAccessCheck) {
        Write-ColorOutput "`n--- Verifying Storage Account Network Access ---" -Color Cyan
        
        # Track if we modified any network access settings
        $sourceNetworkAccessModified = Test-StorageAccountNetworkAccess -SubscriptionId $SourceSubscriptionId `
                                                                        -StorageAccountName $SourceStorageAccountName `
                                                                        -ResourceGroupName $SourceResourceGroupName
        
        $destinationNetworkAccessModified = Test-StorageAccountNetworkAccess -SubscriptionId $DestinationSubscriptionId `
                                                                             -StorageAccountName $DestinationStorageAccountName `
                                                                             -ResourceGroupName $DestinationResourceGroupName
        
        # If we modified network access settings, wait a moment for the changes to propagate
        if ($sourceNetworkAccessModified -or $destinationNetworkAccessModified) {
            Write-ColorOutput "⏳ Waiting 30 seconds for network access changes to propagate..." -Color Yellow
            Start-Sleep -Seconds 30
        }
    }
    else {
        Write-ColorOutput "`n--- Skipping Network Access Check (as requested) ---" -Color Yellow
    }
    
    # Create SAS token for source file share (read and list permissions)
    Write-ColorOutput "`n--- Creating Source SAS Token ---" -Color Cyan
    $sourceUrl = New-FileShareSasToken -SubscriptionId $SourceSubscriptionId `
                                       -StorageAccountName $SourceStorageAccountName `
                                       -FileShareName $SourceFileShareName `
                                       -ResourceGroupName $SourceResourceGroupName `
                                       -Permission "rl" `
                                       -ExpiryTime $expiryTime
    
    # Create SAS token for destination file share (create, write, list, and delete permissions)
    Write-ColorOutput "`n--- Creating Destination SAS Token ---" -Color Cyan
    $destinationUrl = New-FileShareSasToken -SubscriptionId $DestinationSubscriptionId `
                                            -StorageAccountName $DestinationStorageAccountName `
                                            -FileShareName $DestinationFileShareName `
                                            -ResourceGroupName $DestinationResourceGroupName `
                                            -Permission "cwld" `
                                            -ExpiryTime $expiryTime
    
    # Build additional AzCopy parameters
    $additionalParams = @()
    
    if ($Overwrite) {
        $additionalParams += '--overwrite=true'
        Write-ColorOutput "✓ Overwrite mode enabled" -Color Yellow
    }
    
    if ($CheckMD5) {
        $additionalParams += '--check-md5'
        Write-ColorOutput "✓ MD5 integrity checking enabled" -Color Yellow
    }
    
    # Execute the copy operation
    Write-ColorOutput "`n--- Executing File Share Copy ---" -Color Cyan
    $success = Invoke-AzCopyCommand -SourceUrl $sourceUrl -DestinationUrl $destinationUrl -AdditionalParameters $additionalParams
    
    if ($success) {
        Write-ColorOutput "`n=== Copy Operation Completed Successfully ===" -Color Green
        Write-ColorOutput "Source: $SourceStorageAccountName/$SourceFileShareName (Subscription: $SourceSubscriptionId)" -Color White
        Write-ColorOutput "Destination: $DestinationStorageAccountName/$DestinationFileShareName (Subscription: $DestinationSubscriptionId)" -Color White
    }
    else {
        Write-ColorOutput "`n=== Copy Operation Failed ===" -Color Red
        exit 1
    }
}
catch {
    Write-ColorOutput "`n=== Script Execution Failed ===" -Color Red
    Write-ColorOutput "Error: $($_.Exception.Message)" -Color Red
    Write-ColorOutput "Stack Trace: $($_.ScriptStackTrace)" -Color Yellow
    exit 1
}
finally {
    # Clean up any sensitive information from memory
    if (Get-Variable -Name sourceUrl -ErrorAction SilentlyContinue) {
        Remove-Variable -Name sourceUrl -Force
    }
    if (Get-Variable -Name destinationUrl -ErrorAction SilentlyContinue) {
        Remove-Variable -Name destinationUrl -Force
    }
}
