<#
.SYNOPSIS
    Download a single, compliant A&D bound book from a single FastBound account.

.DESCRIPTION
    A simple script to download a single, compliant A&D bound book from a single FastBound account per ATF Ruling 2016-1.

    SECURITY WARNING: This script requires your API key to be passed as a command-line argument. On multi-user systems, command-line arguments are visible to all users via process listing tools (e.g., ps, Task Manager, Get-Process). If you schedule this script as a task on a shared system, other users may be able to see your API key. For shared or multi-user environments, consider using Download-BoundBooks.ps1 instead, which stores credentials securely in a PowerShell Secret Vault.

    https://fastb.co/DownloadFastBoundBook carries this script's latest version, instructions for scheduling it, and an alternate download method with cURL.

.LINK
    https://fastb.co/DownloadFastBoundBook

.PARAMETER Account
    The FastBound account name.

.PARAMETER Key
    The FastBound API key.

.PARAMETER AuditUser
    The email address of a valid FastBound user account.

.PARAMETER Output
    The output file path. Defaults to ACCOUNT.pdf in the current directory.

.EXAMPLE
    Download-BoundBook -Account myaccount -Key my-api-key -AuditUser user@example.com
    Download the bound book to myaccount.pdf in the current directory.

.EXAMPLE
    Download-BoundBook -Account myaccount -Key my-api-key -AuditUser user@example.com -Output C:\Books\mybook.pdf
    Download the bound book to a specific file path.
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Account,

    [Parameter(Mandatory = $false)]
    [string]$Key,

    [Parameter(Mandatory = $false)]
    [string]$AuditUser,

    [Parameter(Mandatory = $false)]
    [string]$Output,

    [Parameter(Mandatory = $false)]
    [string]$Server = "https://cloud.fastbound.com"
)

if (-not $Account -or -not $Key -or -not $AuditUser) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    exit 1
}

if (-not $Output) {
    $Output = Join-Path "." "$Account.pdf"
}

if ($Key.Length -ne 43) {
    Write-Host "Warning: Your API key doesn't look right--did you just copy part of the key?" -ForegroundColor Yellow
}

$relativeUrl = "/$Account/api/Downloads/BoundBook"
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${Account}:${Key}"))
$headers = @{
    Authorization  = "Basic $auth"
    "X-AuditUser" = $AuditUser
}

try {
    $response = Invoke-RestMethod -Method Post -Uri ($Server + $relativeUrl) -Headers $headers -UserAgent "DownloadFastBoundBook"

    if ($response) {
        $pdfUrl = $response.url
        Invoke-WebRequest -Uri $pdfUrl -OutFile $Output -UserAgent "DownloadFastBoundBook"
        Write-Host "Download successful: $Output" -ForegroundColor Green
        exit 0
    }
    elseif ($response.StatusCode -eq 204) {
        Write-Host "Bound book is not ready. Try again tomorrow." -ForegroundColor Yellow
        exit 1
    }
    else {
        Write-Host "Download failed. Status code: $($response.StatusCode). Message: $($response.Message)" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "Exception occurred: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
