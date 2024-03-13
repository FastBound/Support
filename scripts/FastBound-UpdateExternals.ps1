<#
.SYNOPSIS
This PowerShell script processes a CSV file, constructs JSON payloads, and sends PUT requests to the FastBound API to set external IDs for items.

.DESCRIPTION
This script accepts a CSV file containing item data and updates the external IDs of these items on the FastBound platform using the FastBound API. It can also generate external IDs if the -GenerateExternals switch is passed.

.LINK
    https://fastb.co/UpdateExternals

.PARAMETER CsvFile
The path to the CSV file containing item data.

.PARAMETER FastBoundIdColumnName
The name of the column in the CSV file that contains FastBound item IDs. Default is "Id".

.PARAMETER ExternalIdColumnName
The name of the column in the CSV file that contains external IDs to be set. Default is "ExternalId".

.PARAMETER AccountNumber
The FastBound account number where the items will be updated. Mandatory when -UpdateItems is used.

.PARAMETER ApiKey
The API key for authentication with the FastBound API. Mandatory when -UpdateItems is used.

.PARAMETER ApiKey
The FastBound user who updated the item(s). Mandatory when -UpdateItems is used.

.PARAMETER UpdateItems
A switch parameter. When present, the script will issue PUT requests to update the items. External IDs that are null/empty/whitespace will be set to NULL.

.PARAMETER GenerateExternals
A switch parameter. When present, the script will generate external IDs if all existing external IDs are null/empty/whitespace and save them back to the CSV file.

.PARAMETER FirstExternalId
The starting numerical ID -GenerateExternals will generate external IDs from. Default is 100.

.EXAMPLE
.\FastBound-UpdateExternals.ps1 -CsvFile "items.csv" -UpdateItems -AccountNumber 12345 -ApiKey "your-api-key"

This example processes "items.csv" to update external IDs for items with the specified FastBound account number and API key. It requires both AccountNumber and ApiKey to be provided due to the -UpdateItems switch.

.EXAMPLE
.\FastBound-UpdateExternals.ps1 -CsvFile "items.csv" -GenerateExternals

This example processes "items.csv" to generate external IDs and save them back to the CSV file. They are NOT updated on the server without -UpdateItems.

.EXAMPLE
.\FastBound-UpdateExternals.ps1 -CsvFile "items.csv" -GenerateExternals -UpdateItems -UpdateItems -AccountNumber 123456 -ApiKey "your-api-key"

This example processes "items.csv" to generate external IDs, save them back to the CSV file, and update FastBound account 123456.

#>

param (
    [Parameter()]
    [string]$CsvFile,

    [Parameter()]
    [string]$FastBoundIdColumnName = "Id", # Set default value for FastBoundIdColumnName

    [Parameter()]
    [string]$ExternalIdColumnName = "ExternalId", # Set default value for ExternalIdColumnName

    [Parameter(DontShow = $true)]
    [string]$Server = "https://cloud.fastbound.com",

    [Parameter()]
    [int]$AccountNumber,

    [Parameter()]
    [string]$ApiKey,

    [Parameter()]
    [string]$AuditUser,

    [Parameter()]
    [Switch]$Help,

    [Parameter()]
    [Switch]$UpdateItems,

    [Parameter()]
    [Switch]$GenerateExternals,

    [Parameter()]
    [int]$FirstExternalId = 100
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    return
}

# Check if the running PowerShell version is at least 5.1 (minimum required version)
$requiredVersion = [Version]::new("5.1")
$currentVersion = $PSVersionTable.PSVersion

if ($currentVersion -lt $requiredVersion) {
    Write-Host "This script requires PowerShell version 5.1 or later. You are currently running PowerShell version $($currentVersion.ToString())."
    exit 1
}

# Check if the CSV file exists
if (-not (Test-Path -Path $CsvFile -PathType Leaf)) {
    Write-Error "CSV file not found: $CsvFile"
    exit 1
}

# Read the CSV file
$csvData = Import-Csv $CsvFile

# Check if FastBoundIdColumnName and ExternalIdColumnName exist in the CSV headers
if (-not ($csvData[0].PSObject.Properties.Name -contains $FastBoundIdColumnName -and $csvData[0].PSObject.Properties.Name -contains $ExternalIdColumnName)) {
    Write-Error "Column(s) not found in CSV: $FastBoundIdColumnName, $ExternalIdColumnName"
    Write-Output "Available columns: $($csvData[0].PSObject.Properties.Name -join ', ')"
    exit 1
}

# Initialize an empty array for JSON payloads
$jsonPayloads = @()

# Initialize a flag to determine if all ExternalIDs are null/empty/whitespace
$allExternalsEmpty = $true

# Check if AccountNumber and ApiKey are mandatory when -UpdateItems is used
if ($UpdateItems -and (-not $AccountNumber -or -not $ApiKey -or -not $AuditUser)) {
    Write-Error "AccountNumber, ApiKey, and AuditUser are mandatory when using -UpdateItems switch."
    exit 1
}

# Iterate through the CSV data and construct JSON payloads
foreach ($row in $csvData) {
    $jsonPayload = @{
        "id"         = $row.$FastBoundIdColumnName
        "externalId" = $row.$ExternalIdColumnName
    }

    # Check if externalId is null, empty, or whitespace and set it to null
    if ([string]::IsNullOrWhiteSpace($jsonPayload.externalId)) {
        $jsonPayload.externalId = $null
    }
    else {
        $allExternalsEmpty = $false  # At least one ExternalID is not empty
    }

    $jsonPayloads += $jsonPayload
}

# Generate external IDs if the -GenerateExternals switch is passed and all existing ExternalIDs are null/empty/whitespace
if ($GenerateExternals -and !$allExternalsEmpty) {
    Write-Error "In order to -GenerateExternals, all $($ExternalIdColumnName) values must be empty."
    exit 1
}
elseif ($GenerateExternals -and $allExternalsEmpty) {
    $currentExternalId = $FirstExternalId

    # Iterate through the CSV data and assign numerical ExternalIDs
    foreach ($row in $csvData) {
        $row.$ExternalIdColumnName = $currentExternalId++
    }

    # Export the modified CSV data back to the original CSV file
    $csvData | Export-Csv -Path $CsvFile -NoTypeInformation
}

# Issue PUT requests to update items only if the -UpdateItems switch is present
if ($UpdateItems) {
    # Split JSON payloads into chunks of 1000 items (API limit)
    $chunkedPayloads = $jsonPayloads | Group-Object -Property { [math]::Floor([array]::IndexOf($jsonPayloads, $_) / 1000) }

    # Create headers with the custom User-Agent
    $headers = @{
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ApiKey"))
        "User-Agent"    = "UpdateExternals/1.0"
        "X-AuditUser"   = $AuditUser
    }

    # Iterate through each chunk and make PUT requests with custom User-Agent
    foreach ($chunk in $chunkedPayloads) {
        $jsonChunk = @{
            "items" = $chunk.Group
        } | ConvertTo-Json

        $url = "$Server/$AccountNumber/api/Items/SetExternalIds"
        Invoke-RestMethod -Uri $url -Method Put -Headers $headers -Body $jsonChunk -ContentType "application/json"

        Write-Host "Processed $($chunk.Group.Count) items from $($chunk.Group[0].id) to $($chunk.Group[-1].id)"

        # API requests are rate-limited to 60 per minute. This will help avoid the rate limit if the chunks are small.
        Start-Sleep -Seconds 1
    }
}

