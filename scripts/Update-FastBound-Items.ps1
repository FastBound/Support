<#
.SYNOPSIS
Script for updating items via FastBound API.

.DESCRIPTION
This script updates items in the FastBound system using its API. It reads data from a CSV file and updates items with specified fields using the provided parameters.

.PARAMETER File
Specifies the path to the CSV file containing item data. The CSV layout and format produced by Items > Download Results is required.

.PARAMETER Account
Specifies the FastBound account number.

.PARAMETER ApiKey
Specifies the API key for authentication.

.PARAMETER AuditUser
Specifies the email of a valid FastBound user for auditing purposes.

.PARAMETER Field
Specifies the fields to be updated. These fields must be allowed for updates through the API.

.PARAMETER DelaySeconds
Specifies the delay in seconds between API calls. Default is 1 second.

.PARAMETER Server
Specifies the FastBound server URL. Default is "https://cloud.fastbound.com".

.EXAMPLE
.\Update-Items.ps1 -File "items.csv" -Account 12345 -ApiKey "your_api_key" -AuditUser "user@example.com" -Field "Price", "Location"

This command updates items specified in "items.csv" for the account number 12345. It updates the "Price" and "Location" fields for each item in the CSV file.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$File,
    [Parameter(Mandatory = $true)]
    [int]$Account,
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [Parameter(Mandatory = $true)]
    [string]$AuditUser,
    [Parameter(Mandatory = $true)]
    [string[]]$Field,

    [int]$DelaySeconds = 1,
    [string]$Server = "https://cloud.fastbound.com"
)

$csvData = Import-Csv -Path $File
$resultsFileName = $File -replace '.csv$', '.results.csv'
$resultsFile = New-Item -Path $resultsFileName -ItemType File -Force
Add-Content -Path $resultsFile.FullName -Value "ID,ExternalID,ItemDetailsURL,Status,Message"

$headers = @{
    "User-Agent"    = "FastBound/Update-Items (Account $($Account))"
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($ApiKey)"))
    "X-AuditUser"   = $AuditUser
}

function Update-ItemWithRetry {
    param (
        [string]$ItemNumber,
        [hashtable]$FieldsToUpdate,
        [hashtable]$Headers,
        [string]$Server,
        [int]$DelaySeconds,
        [int]$maxRetries = 15,
        [int]$retrySeconds = 6
    )

    $url = "$($Server)/$($Account)/api/Items/$($ItemNumber)"
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        Start-Sleep -Seconds $DelaySeconds
        try {
            # GET the current data from the server
            Write-Host "Fetching current data for Item $($ItemNumber) with GET request..."
            $getResponse = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -ResponseHeadersVariable ResponseHeaders

            if ($ResponseHeaders.'X-RateLimit-Remaining' -le 2) {
                Start-Sleep -Seconds $retrySeconds
                Write-Host "Rate limit reached, retrying..."
                $retryCount++
                continue
            }

            # Compare the current data with the CSV, making everything case-insensitive
            $changesDetected = $false
            foreach ($key in $FieldsToUpdate.Keys) {
                $lowerKey = $key.ToLower()

                # Normalize both the GET response and the CSV value to handle case-insensitive field names
                $apiValue = $getResponse.PSObject.Properties[$lowerKey].Value
                $csvValue = $FieldsToUpdate[$key]

                # Compare values in a case-insensitive manner if they are strings
                if (([string]$apiValue).ToLower() -ne ([string]$csvValue).ToLower()) {
                    $changesDetected = $true
                    break
                }
            }

            if (-not $changesDetected) {
                # If no changes are detected, log 304 and skip PUT
                Write-Host "No changes detected for Item $($ItemNumber). Skipping update."
                return @{StatusCode = 304; ResponseMessage = 'Not Modified'}
            }

            # If changes are detected, update the item
            Write-Host "Changes detected for Item $($ItemNumber). Preparing to update..."
            foreach ($key in $FieldsToUpdate.Keys) {
                $lowerKey = $key.ToLower()
                $getResponse.PSObject.Properties[$lowerKey].Value = $FieldsToUpdate[$key]
            }

            Start-Sleep -Seconds $DelaySeconds
            $putResponse = Invoke-RestMethod -Uri $url -Method Put -Headers $Headers -Body ($getResponse | ConvertTo-Json) -ContentType "application/json"
            $statusCode = 200
            $responseMessage = 'Success'
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.Value__
            $responseMessage = $_.Exception.Message
            Write-Host "Error updating Item $($ItemNumber): $responseMessage (Status: $statusCode)"
            $retryCount++
            if ($statusCode -eq 429) { 
                Write-Host "Rate limit hit, retrying after $($retrySeconds) seconds."
                Start-Sleep -Seconds $retrySeconds 
            }
        }

        if ($statusCode -eq 200) {
            break
        }
    }

    return @{StatusCode = $statusCode; ResponseMessage = $responseMessage}
}

$startTime = Get-Date
$totalItems = $csvData.Count
$completedItems = 0

foreach ($row in $csvData) {
    $completedItems++
    $itemId = $row.Id
    $externalId = $row.ExternalId
    $itemDetailsURL = "$($Server)/$($Account)/Items/Details/$($itemId)"
    $fieldsToUpdate = @{}

    # Handle case-insensitive fields by converting all keys in CSV and -Field to lowercase
    foreach ($f in $Field) {
        $lowerField = $f.ToLower()
        $fieldsToUpdate[$lowerField] = $row.PSObject.Properties[$f].Value
    }

    $updateResult = Update-ItemWithRetry -ItemNumber $itemId -FieldsToUpdate $fieldsToUpdate -Headers $headers -Server $Server -DelaySeconds $DelaySeconds

    $currentTime = Get-Date
    $elapsedSeconds = ($currentTime - $startTime).TotalSeconds
    $itemsRemaining = $totalItems - $completedItems
    if ($completedItems -gt 1) {
        $estimatedTotalSeconds = ($elapsedSeconds / $completedItems) * $totalItems
        $eta = $startTime.AddSeconds($estimatedTotalSeconds)
        $etaString = $eta.ToString("g")
    } else {
        $etaString = "Calculating..."
    }

    Write-Host "$($completedItems) of $($totalItems): $($Server)/$($Account)/Items/Details/$($itemId) ETA: $($etaString)"

    Add-Content -Path $resultsFile.FullName -Value "$($itemId),$($externalId),$($itemDetailsURL),$($updateResult.StatusCode),$($updateResult.ResponseMessage)"
}

Write-Host "Update process completed. Results saved to: $($resultsFile.FullName)"
