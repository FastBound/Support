<#
.SYNOPSIS
    PowerShell script to automate the download of A&D records from one or more FastBound accounts.

.DESCRIPTION
    For users who can't or don't want to use Cloud file hosting services like Dropbox, DownloadFastBoundBooks makes it easy to manage multiple FastBound accounts stored securely in a Secret Vault and download the latest copy of your bound book A&D records daily per ATF Ruling 2016-1.
    
    https://fastb.co/DownloadFastBoundBook carries this script's latest version, instructions for scheduling it, and an alternate download method with cURL.

.LINK
    https://fastb.co/DownloadFastBoundBook

.PARAMETER Output
    The folder to download the PDF files to. Default to the current folder.

.PARAMETER Add
    Add a new FastBound account to the Secret Vault.

.PARAMETER Key
    The key for the FastBound account that will be added to the Secret Vault.

.PARAMETER Remove
    Remove the specified FastBound account from the Secret Vault.

.PARAMETER List
    Output a list of FastBound accounts stored in the Secret Vault.

.PARAMETER Download
    Download the latest bound book for each FastBound account in the Secret Vault. An exit code of 0 indicates that all downloads were successful. A non-zero exit code indicates that at least one download failed. 

.PARAMETER Help
    Show the Get-Help output for this script.

.PARAMETER SecretVault
    The name of the Secret Vault. The default is "FastBound".

.PARAMETER AuditUser
    The email address of a valid FastBound user account. Required by the -Download parameter.

.EXAMPLE
    DownloadFastBoundBooks -Add FASTBOUND_ACCOUNT -Key FASTBOUND_API_KEY
    Add FASTBOUND_ACCOUNT and FASTBOUND_API_KEY to the Secret Vault.

.EXAMPLE
    DownloadFastBoundBooks -Remove FASTBOUND_ACCOUNT
    Remove FASTBOUND_ACCOUNT from the Secret Vault.

.EXAMPLE
    DownloadFastBoundBooks -List
    Output a list of FastBound accounts stored in the Secret Vault.

.EXAMPLE
    DownloadFastBoundBooks -Download -AuditUser user@example.com
    Download the bound book for each FastBound account in the Secret Vault.
#>

param (
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$Server = "https://cloud.fastbound.com",

    [Parameter(Position = 1, Mandatory = $false)]
    [string]$Output = ".",

    [Parameter(Position = 2, Mandatory = $false)]
    [string]$Add,

    [Parameter(Position = 3, Mandatory = $false)]
    [string]$Key,

    [Parameter(Position = 4, Mandatory = $false)]
    [string]$Remove,

    [Parameter(Position = 5, Mandatory = $false)]
    [switch]$List,

    [Parameter(Position = 6, Mandatory = $false)]
    [switch]$Download,

    [Parameter(Position = 7, Mandatory = $false)]
    [switch]$Help,

    [Parameter(Position = 8, Mandatory = $false)]
    [string]$SecretVault = "FastBound",

    [Parameter(Position = 9, Mandatory = $false)]
    [string]$AuditUser
)

begin {
    # Ensure that the PowerShell version is at least 7.0 for SecretManagement + SecretStore
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "This script requires PowerShell version 7 or higher." -ForegroundColor Red
        exit 1
    }

    # Check for required modules and install them if not present
    $requiredModules = 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore'
    foreach ($module in $requiredModules) {
        if (!(Get-Module -ListAvailable -Name $module)) {
            try {
                Install-Module -Name $module -Force
            }
            catch {
                Write-Host "Failed to install module $module." -ForegroundColor Red
                exit 1
            }
        }
    }

    # Create a new SecretVault if it doesn't exist
    if (!(Get-SecretVault -Name $SecretVault -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name $SecretVault -ModuleName Microsoft.PowerShell.SecretStore
    }
}

process {
    if ($Help) {
        Get-Help $MyInvocation.MyCommand.Definition -Detailed
        return
    }
  
    if ($Add) {
        if (!$Key) {
            Write-Host "You must specify a key with -Key when adding an account." -ForegroundColor Red
            exit 1
        }
        $secret = @{
            Name   = $Add
            Secret = $Key
            Vault  = $SecretVault
        }
        Set-Secret @secret
    }

    if ($Remove) {
        Remove-Secret -Name $Remove -Vault $SecretVault
    }

    if ($List) {
        Get-SecretInfo -Vault $SecretVault | Format-Table -AutoSize
    }

    if ($Download) {
        if (-not $AuditUser) {
            Write-Host "You must specify the -AuditUser parameter when using -Download." -ForegroundColor Red
            exit 1
        }
        
        $accounts = Get-SecretInfo -Vault $SecretVault
        $exitCode = 0

        foreach ($account in $accounts) {
            $relativeUrl = "/$($account.Name)/api/Downloads/BoundBook"

            $auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($account.Name):$((Get-Secret -Name $account.Name -Vault $SecretVault -AsPlainText))"))
            $headers = @{
                Authorization = "Basic $auth"
                "X-AuditUser" = $AuditUser
            }

            try {
                $response = Invoke-RestMethod -Method Post -Uri ($Server + $relativeUrl) -Headers $headers -UserAgent "DownloadFastBoundBooks"
            
                if ($response) {
                    $pdfUrl = $response.url
                    $pdfFileName = "$Output\$($account.Name).pdf"
                    Invoke-WebRequest -Uri $pdfUrl -OutFile $pdfFileName -UserAgent "DownloadFastBoundBooks"
                    Write-Host "Download successful for account $($account.Name)" -ForegroundColor Green
                }
                elseif ($response.StatusCode -eq 204) {
                    Write-Host "Bound book for account $($account.Name) is not ready. Try again tomorrow." -ForegroundColor Yellow
                }
                else {
                    Write-Host "Download failed for account $($account.Name). Status code: $($response.StatusCode). Message: $($response.Message)" -ForegroundColor Red
                    $exitCode = 1
                }
            }
            catch {
                Write-Host "Exception occurred while downloading for account $($account.Name): $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }           
        }

        if ($exitCode -eq 0) {
            Write-Host "All downloads were successful!" -ForegroundColor Green
        }
        else {
            Write-Host "Some downloads failed!" -ForegroundColor Red
        }
        exit $exitCode
    }
}
