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

# Header row of our Items Download Search Results file
$csvFields = @(
    "ItemNumber",
    "Status",
    "Manufacturer",
    "Importer",
    "CountryOfManufacture",
    "Model",
    "Type",
    "Caliber",
    "Serial",
    "BarrelLength",
    "OverallLength",
    "MPN",
    "UPC",
    "SKU",
    "Condition",
    "Location",
    "Cost",
    "Price",
    "LocationVerifiedUtc",
    "DoNotDispose",
    "Acquire_Date",
    "AcquisitionType",
    "Acquire_License",
    "Acquire_LicenseName",
    "Acquire_LicenseExpires",
    "Acquire_TradeName",
    "Acquire_Organization",
    "Acquire_FirstName",
    "Acquire_MiddleName",
    "Acquire_LastName",
    "Acquire_Address1",
    "Acquire_Address2",
    "Acquire_City",
    "Acquire_State",
    "Acquire_Postal",
    "Acquire_Country",
    "Acquire_PhoneNumber",
    "Acquire_Fax",
    "Acquire_EmailAddress",
    "Acquire_PurchaseOrderNumber",
    "Acquire_InvoiceNumber",
    "Acquire_ShipmentTrackingNumber",
    "Dispose_Date",
    "DispositionType",
    "Dispose_License",
    "Dispose_LicenseName",
    "Dispose_LicenseExpires",
    "Dispose_TradeName",
    "Dispose_Organization",
    "Dispose_FirstName",
    "Dispose_MiddleName",
    "Dispose_LastName",
    "Dispose_Address1",
    "Dispose_Address2",
    "Dispose_City",
    "Dispose_State",
    "Dispose_Postal",
    "Dispose_Country",
    "Dispose_PhoneNumber",
    "Dispose_Fax",
    "Dispose_EmailAddress",
    "TTSN",
    "OTSN",
    "Dispose_PurchaseOrderNumber",
    "Dispose_InvoiceNumber",
    "Dispose_ShipmentTrackingNumber",
    "SubmissionDate",
    "TheftLoss_DiscoveredDate",
    "TheftLoss_Type",
    "TheftLoss_ATFIssuedIncidentNumber",
    "TheftLoss_PoliceIncidentNumber",
    "Destroyed_Date",
    "Destroyed_Description",
    "Destroyed_Witness1",
    "Destroyed_Witness2",
    "DeleteType",
    "DeleteNote",
    "UndeleteNote",
    "LightspeedSystemID",
    "LightspeedItemID",
    "LightspeedSerialID",
    "LightspeedSaleID",
    "Id",
    "ExternalId",
    "Notes"
)

# Fields you can update through the API
$allowedFields = @(
    "Acquire_InvoiceNumber",
    "Acquire_PurchaseOrderNumber",
    "Acquire_ShipmentTrackingNumber",
    "AcquisitionType",
    "BarrelLength",
    "Condition",
    "Cost",
    "Dispose_InvoiceNumber",
    "Dispose_PurchaseOrderNumber",
    "Dispose_ShipmentTrackingNumber",
    "DispositionType",
    "DoNotDispose",
    "ExternalId",
    "ItemNumber",
    "Location",
    "MPN",
    "Notes",
    "OverallLength",
    "Price",
    "SKU",
    "UPC"
)

$invalidFields = $Field | Where-Object { $_ -notin $allowedFields }
if ($invalidFields.Count -gt 0) {
    Write-Host "Error: The following fields cannot be updated with this tool:`n$($invalidFields -join ', ')`n"
    Write-Host "Allowed fields:`n$($allowedFields -join ', ')`n"
    exit
}

# Import CSV, skipping the header row
$csvData = Import-Csv -Path $File # -Header $csvFields # | Select-Object -Skip 1

$headerFields = $csvData[0].PSObject.Properties.Name

if (-not (($headerFields -join ',') -eq ($csvFields -join ','))) {
#if (-not ($headerFields -eq $csvFields)) {
    Write-Host "Error: The header row of the CSV file does not match the expected fields."
    Write-Host "Expected fields: $($csvFields -join ', ')"
    Write-Host "Actual fields: $($headerFields -join ', ')"
    exit
}

# Common headers for GET and PUT
$headers = @{
    "User-Agent"    = "FastBound/Update-Items (Account $($Account))"
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ApiKey"))
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
        $getResponse = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -ResponseHeadersVariable ResponseHeaders

        # Check X-RateLimit-Remaining header and retry if needed
        if ($ResponseHeaders.'X-RateLimit-Remaining' -le 2) {
            Write-Host "Rate limit exceeded. Sleeping for $($retrySeconds) seconds and retrying..."
            Start-Sleep -Seconds $retrySeconds
            $retryCount++
            Write-Host "Retry $($retryCount) of $($maxRetries - 1)..."
            continue
        }

        foreach ($key in $FieldsToUpdate.Keys) {
            $getResponse.$key = $FieldsToUpdate[$key]
        }

        Start-Sleep -Seconds $DelaySeconds
        $putResponse = Invoke-RestMethod -Uri $url -Method Put -Headers $Headers -Body ($getResponse | ConvertTo-Json) -ContentType "application/json"

        # Break out of the retry loop if the update was successful
        break
    }
}


$totalRows = $csvData.Count

Write-Host "1 of $($totalRows): Skip header row"

# Iterate through CSV rows and update items
foreach ($index in 1..($totalRows - 1)) {

    $row = $csvData[$index]

    $itemId = $row.Id

    Write-Host "$($index + 1) of $($totalRows): $($Server)/$($Account)/Items/Details/$($itemId)"

    $fieldsToUpdate = @{}

    foreach ($f in $Field) {
        $fieldsToUpdate[$f] = $row.$f
    }

    Update-ItemWithRetry -ItemNumber $itemId -FieldsToUpdate $fieldsToUpdate -Headers $headers -Server $Server -DelaySeconds $DelaySeconds
}
