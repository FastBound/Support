<#
.SYNOPSIS
    Imports contacts from a CSV file into a FastBound account.

.DESCRIPTION
    This script reads contacts from a CSV file and creates them in FastBound via the API.
    It supports custom field mapping, validates required fields based on contact type
    (FFL, Organization, or Individual), and handles API rate limiting.

.PARAMETER File
    Path to the source CSV file containing contact data.

.PARAMETER Map
    Optional path to a CSV mapping file with "Source" and "Destination" columns.
    If not specified, source column names are assumed to match FastBound field names.

.PARAMETER Account
    FastBound account number (integer).

.PARAMETER ApiKey
    FastBound API key for authentication.

.PARAMETER AuditUser
    Email address of a FastBound user for audit purposes.

.EXAMPLE
    .\Import-FastBoundContacts.ps1 -File "contacts.csv" -Account 12345 -ApiKey "your-api-key" -AuditUser "user@example.com"

.EXAMPLE
    .\Import-FastBoundContacts.ps1 -File "contacts.csv" -Map "mapping.csv" -Account 12345 -ApiKey "your-api-key" -AuditUser "user@example.com"

.NOTES
    Rate limiting: The API has rate limits. This script monitors X-RateLimit-Remaining
    and X-RateLimit-Reset headers and pauses when necessary.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$File,

    [Parameter(Mandatory = $false)]
    [string]$Map,

    [Parameter(Mandatory = $false)]
    [string]$Server = "https://cloud.fastbound.com",

    [Parameter(Mandatory = $true)]
    [int]$Account,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true)]
    [string]$AuditUser,

    [Parameter(Mandatory = $false)]
    [switch]$SkipInvalidContacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# FastBound Contact API field names
$ValidFastBoundFields = @(
    "externalId",
    "fflNumber",
    "fflExpires",
    "lookupFFL",
    "licenseName",
    "tradeName",
    "sotein",
    "sotClass",
    "businessType",
    "organizationName",
    "firstName",
    "middleName",
    "lastName",
    "suffix",
    "premiseAddress1",
    "premiseAddress2",
    "premiseCity",
    "premiseCounty",
    "premiseState",
    "premiseZipCode",
    "premiseCountry",
    "phoneNumber",
    "fax",
    "emailAddress"
)

# Required fields documentation reference: https://fastbound.help/en/articles/3963657-contacts
# Contact types are mutually exclusive:
# - FFL Contact: requires fflNumber
# - Organization: requires organizationName (without fflNumber)
# - Individual: requires firstName AND lastName (without fflNumber or organizationName)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Test-SourceFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Source file not found: $Path"
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLower()
    if ($extension -ne ".csv") {
        throw "Source file must be a CSV file. Got: $extension"
    }

    return $true
}

function Get-FieldMapping {
    param(
        [string]$MapFile,
        [string[]]$SourceHeaders
    )

    $mapping = @{}

    if ($MapFile) {
        # Load mapping from file
        if (-not (Test-Path $MapFile)) {
            throw "Mapping file not found: $MapFile"
        }

        $mapData = Import-Csv $MapFile

        # Validate mapping file has required columns
        $mapHeaders = $mapData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        if ("Source" -notin $mapHeaders -or "Destination" -notin $mapHeaders) {
            throw "Mapping file must contain 'Source' and 'Destination' columns"
        }

        foreach ($row in $mapData) {
            $source = $row.Source.Trim()
            $dest = $row.Destination.Trim()

            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($dest)) {
                continue
            }

            # Validate destination is a valid FastBound field
            if ($dest -notin $ValidFastBoundFields) {
                throw "Invalid FastBound field in mapping: '$dest'. Valid fields are: $($ValidFastBoundFields -join ', ')"
            }

            # Validate source exists in source file
            if ($source -notin $SourceHeaders) {
                throw "Source field '$source' not found in source file. Available columns: $($SourceHeaders -join ', ')"
            }

            $mapping[$source] = $dest
        }
    }
    else {
        # Use source headers as-is if they match FastBound fields
        foreach ($header in $SourceHeaders) {
            $trimmed = $header.Trim()
            if ($trimmed -in $ValidFastBoundFields) {
                $mapping[$trimmed] = $trimmed
            }
        }
    }

    return $mapping
}

function Test-RequiredFields {
    param(
        [hashtable]$Mapping,
        [string[]]$SourceHeaders
    )

    # Get all destination fields that will be mapped
    $mappedDestinations = $Mapping.Values | Sort-Object -Unique

    # Check for mutually exclusive contact type fields
    $hasFflNumber = "fflNumber" -in $mappedDestinations
    $hasOrgName = "organizationName" -in $mappedDestinations
    $hasFirstName = "firstName" -in $mappedDestinations
    $hasLastName = "lastName" -in $mappedDestinations

    # At least one contact type must be identifiable from the mapping
    # The actual validation per-row happens during import
    if (-not $hasFflNumber -and -not $hasOrgName -and -not ($hasFirstName -and $hasLastName)) {
        Write-Log "WARNING: No contact identification fields mapped. Each contact must have either:" "WARN"
        Write-Log "  - fflNumber (for FFL contacts)" "WARN"
        Write-Log "  - organizationName (for organizations)" "WARN"
        Write-Log "  - firstName AND lastName (for individuals)" "WARN"
        Write-Log "Contacts without valid identification will fail validation." "WARN"
    }

    return $true
}

function Test-ContactData {
    param(
        [hashtable]$ContactData,
        [int]$LineNumber
    )

    $errors = @()

    $hasFfl = -not [string]::IsNullOrWhiteSpace($ContactData["fflNumber"])
    $hasOrg = -not [string]::IsNullOrWhiteSpace($ContactData["organizationName"])
    $hasFirst = -not [string]::IsNullOrWhiteSpace($ContactData["firstName"])
    $hasLast = -not [string]::IsNullOrWhiteSpace($ContactData["lastName"])
    $hasIndividualName = $hasFirst -or $hasLast

    # Validate mutual exclusivity of contact types
    # FFL, Organization, and Individual names are mutually exclusive
    if ($hasFfl) {
        if ($hasOrg) {
            $errors += "FFL contacts cannot have organizationName"
        }
        if ($hasIndividualName) {
            $errors += "FFL contacts cannot have firstName/lastName (use licenseName instead)"
        }
        # FFL requires license name
        if ([string]::IsNullOrWhiteSpace($ContactData["licenseName"])) {
            $errors += "FFL contacts require licenseName"
        }
        # FFL requires expiration date
        $fflExpires = $ContactData["fflExpires"]
        if ([string]::IsNullOrWhiteSpace($fflExpires)) {
            $errors += "FFL contacts require fflExpires"
        }
        else {
            try {
                $expiresDate = [DateTime]::Parse($fflExpires)
                $minDate = [DateTime]::new(1968, 1, 1)
                $maxDate = (Get-Date).AddMonths(42)
                if ($expiresDate -lt $minDate) {
                    $errors += "fflExpires cannot be before 1/1/1968"
                }
                elseif ($expiresDate -gt $maxDate) {
                    $errors += "fflExpires cannot be more than 42 months from today ($($maxDate.ToString('MM/dd/yyyy')))"
                }
            }
            catch {
                $errors += "fflExpires is not a valid date: $fflExpires"
            }
        }
    }
    elseif ($hasOrg) {
        if ($hasIndividualName) {
            $errors += "Organization contacts cannot have firstName/lastName"
        }
    }
    elseif ($hasFirst -and $hasLast) {
        # Individual - valid
    }
    elseif ($hasFirst -or $hasLast) {
        # Partial individual name
        $errors += "Individual contacts require both firstName AND lastName"
    }
    else {
        # No identification
        $errors += "Contact must have fflNumber, organizationName, or both firstName and lastName"
    }

    # Required address fields for all contacts
    $requiredFields = @{
        "premiseAddress1" = "Address 1"
        "premiseCity" = "City"
        "premiseState" = "State"
        "premiseZipCode" = "Postal/Zip"
    }
    foreach ($field in $requiredFields.Keys) {
        if ([string]::IsNullOrWhiteSpace($ContactData[$field])) {
            $errors += "Missing required field: $($requiredFields[$field]) ($field)"
        }
    }

    # Validate field lengths per swagger spec
    $maxLengths = @{
        "externalId" = 100
        "fflNumber" = 20
        "licenseName" = 100
        "tradeName" = 100
        "sotein" = 50
        "organizationName" = 100
        "firstName" = 100
        "middleName" = 100
        "lastName" = 100
        "suffix" = 4
        "premiseAddress1" = 100
        "premiseAddress2" = 100
        "premiseCity" = 100
        "premiseCounty" = 100
        "premiseState" = 100
        "premiseZipCode" = 100
        "premiseCountry" = 100
        "phoneNumber" = 50
        "fax" = 50
        "emailAddress" = 255
    }

    foreach ($field in $ContactData.Keys) {
        $value = $ContactData[$field]
        if ($null -ne $value -and $maxLengths.ContainsKey($field)) {
            if ($value.Length -gt $maxLengths[$field]) {
                $errors += "Field '$field' exceeds max length of $($maxLengths[$field]) (got $($value.Length))"
            }
        }
    }

    # Validate enum fields
    if ($ContactData["sotClass"]) {
        $validSotClass = @("Importer", "Manufacturer", "Dealer")
        if ($ContactData["sotClass"] -notin $validSotClass) {
            $errors += "Invalid sotClass value '$($ContactData["sotClass"])'. Must be one of: $($validSotClass -join ', ')"
        }
    }

    if ($ContactData["businessType"]) {
        $validBusinessType = @("SoleProprietor", "Partnership", "Corporation")
        if ($ContactData["businessType"] -notin $validBusinessType) {
            $errors += "Invalid businessType value '$($ContactData["businessType"])'. Must be one of: $($validBusinessType -join ', ')"
        }
    }

    # Note: Phone number formatting is handled in Convert-RowToContact
    # The API pattern is: ^\(?([0-9]{3})\)?[- ]?([0-9]{3})[- ]?([0-9]{4})$
    # We auto-format 10-digit numbers, so validation here is minimal

    return $errors
}

function Convert-RowToContact {
    param(
        [PSCustomObject]$Row,
        [hashtable]$Mapping
    )

    $contact = @{}

    foreach ($sourceField in $Mapping.Keys) {
        $destField = $Mapping[$sourceField]
        $value = $Row.$sourceField

        # Skip null or empty values
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $value = $value.Trim()

        # Handle special field transformations
        switch ($destField) {
            "fflExpires" {
                # Convert date string to ISO 8601 format
                try {
                    $date = [DateTime]::Parse($value)
                    $value = $date.ToString("yyyy-MM-ddT00:00:00Z")
                }
                catch {
                    # Leave as-is if parsing fails, API will validate
                }
            }
            "lookupFFL" {
                # Convert to boolean
                $value = $value -eq "true" -or $value -eq "1" -or $value -eq "yes" -or $value -eq "y"
            }
            { $_ -in @("phoneNumber", "fax") } {
                # Format phone numbers - strip non-digits first
                $digits = $value -replace "[^0-9]", ""
                if ($digits.Length -eq 10) {
                    # Format as (XXX) XXX-XXXX
                    $value = "($($digits.Substring(0,3))) $($digits.Substring(3,3))-$($digits.Substring(6,4))"
                }
                elseif ($digits.Length -eq 11 -and $digits[0] -eq "1") {
                    # Strip leading 1 and format
                    $digits = $digits.Substring(1)
                    $value = "($($digits.Substring(0,3))) $($digits.Substring(3,3))-$($digits.Substring(6,4))"
                }
                # Otherwise leave as-is for API to validate
            }
            "premiseZipCode" {
                # Clean up zip codes - remove trailing dots/spaces
                $value = $value -replace "[\s.]+$", ""
            }
            "premiseState" {
                # Clean up state - remove trailing dots/spaces
                $value = $value -replace "[\s.]+$", ""
            }
        }

        $contact[$destField] = $value
    }

    return $contact
}

function Invoke-FastBoundApi {
    param(
        [string]$Server,
        [int]$Account,
        [string]$ApiKey,
        [string]$AuditUser,
        [hashtable]$ContactData
    )

    $uri = "$Server/$Account/api/Contacts"

    $headers = @{
        "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ApiKey}:")))"
        "X-AuditUser" = $AuditUser
        "Content-Type" = "application/json"
    }

    $body = $ContactData | ConvertTo-Json -Depth 10

    $result = @{
        Success = $false
        StatusCode = 0
        Message = ""
        RateLimitRemaining = -1
        RateLimitReset = $null
    }

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -UseBasicParsing

        $result.StatusCode = $response.StatusCode
        $result.Success = $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
        $result.Message = "Created successfully"

        # Extract rate limit headers (handle both single values and arrays)
        try {
            $remaining = $response.Headers["X-RateLimit-Remaining"]
            if ($remaining) {
                if ($remaining -is [array]) { $remaining = $remaining[0] }
                $result.RateLimitRemaining = [int]$remaining
            }
        }
        catch { }
        try {
            $reset = $response.Headers["X-RateLimit-Reset"]
            if ($reset) {
                if ($reset -is [array]) { $reset = $reset[0] }
                # Reset is UTC epoch seconds
                $result.RateLimitReset = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).UtcDateTime
            }
        }
        catch { }
    }
    catch {
        # PowerShell Core error handling - save error record first
        $errorRecord = $_
        $statusCode = 0
        $errorBody = $null

        # Try to get status code from exception response
        try {
            if ($null -ne $errorRecord.Exception.Response) {
                $statusCode = [int]$errorRecord.Exception.Response.StatusCode
            }
        }
        catch {
            # Ignore errors accessing Response
        }

        # Try to get error body from ErrorDetails (PowerShell Core)
        try {
            if ($null -ne $errorRecord.ErrorDetails -and $errorRecord.ErrorDetails.Message) {
                $errorBody = $errorRecord.ErrorDetails.Message
            }
        }
        catch {
            # Ignore errors accessing ErrorDetails
        }

        $result.StatusCode = $statusCode

        if ($errorBody) {
            try {
                $errorJson = $errorBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errorJson.errors) {
                    $errorMessages = $errorJson.errors | ForEach-Object {
                        if ($_.field) { "$($_.field): $($_.message)" } else { $_.message }
                    }
                    $result.Message = $errorMessages -join "; "
                }
                else {
                    $result.Message = $errorBody
                }
            }
            catch {
                $result.Message = $errorBody
            }
        }
        else {
            $result.Message = $errorRecord.Exception.Message
        }
    }

    return $result
}

function Wait-ForRateLimit {
    param(
        [int]$Remaining,
        [DateTime]$ResetTime
    )

    if ($Remaining -le 0 -and $ResetTime) {
        $waitTime = ($ResetTime - [DateTime]::UtcNow).TotalSeconds
        if ($waitTime -gt 0) {
            Write-Log "Rate limit reached. Waiting $([Math]::Ceiling($waitTime)) seconds until $ResetTime" "WARN"
            Start-Sleep -Seconds ([Math]::Ceiling($waitTime) + 1)
        }
    }
    elseif ($Remaining -le 5 -and $Remaining -gt 0) {
        # Proactively slow down when approaching limit
        Write-Log "Rate limit low ($Remaining remaining). Slowing down..." "WARN"
        Start-Sleep -Seconds 2
    }
}

# Main execution
try {
    Write-Log "FastBound Contact Import Script Started"
    if ($Server -ne "https://cloud.fastbound.com") { Write-Log "Server: $Server" }
    Write-Log "Account: $Account"
    Write-Log "Source File: $File"
    if ($Map) { Write-Log "Mapping File: $Map" }

    # Validate source file
    Test-SourceFile -Path $File | Out-Null
    Write-Log "Source file validated"

    # Import source data
    $sourceData = Import-Csv $File
    $sourceHeaders = $sourceData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    $totalRows = ($sourceData | Measure-Object).Count
    Write-Log "Loaded $totalRows contacts from source file"
    Write-Log "Source columns: $($sourceHeaders -join ', ')"

    # Get field mapping
    $mapping = Get-FieldMapping -MapFile $Map -SourceHeaders $sourceHeaders
    Write-Log "Field mapping configured:"
    foreach ($key in $mapping.Keys) {
        Write-Log "  $key -> $($mapping[$key])"
    }

    if ($mapping.Count -eq 0) {
        throw "No valid field mappings found. Ensure source columns match FastBound field names or provide a mapping file."
    }

    # Validate required fields are mappable
    Test-RequiredFields -Mapping $mapping -SourceHeaders $sourceHeaders | Out-Null

    # Prepare results file
    $resultsFile = [System.IO.Path]::ChangeExtension($File, ".results.csv")
    $results = @()

    # Pre-validate all contacts before making any API calls
    Write-Log "Pre-validating all contacts..."
    $validationResults = @{}  # Line -> error message (or $null if valid)
    $lineNum = 2  # Start at 2 because line 1 is header
    $invalidCount = 0

    foreach ($row in $sourceData) {
        $contactData = Convert-RowToContact -Row $row -Mapping $mapping
        $errors = @(Test-ContactData -ContactData $contactData -LineNumber $lineNum)

        if ($errors.Count -gt 0) {
            $validationResults[$lineNum] = $errors -join "; "
            $invalidCount++
            Write-Log "  Line ${lineNum}: $($validationResults[$lineNum])" "WARN"
        }
        else {
            $validationResults[$lineNum] = $null
        }
        $lineNum++
    }

    if ($invalidCount -gt 0) {
        Write-Log "Validation failed for $invalidCount of $totalRows contacts" "WARN"
        if (-not $SkipInvalidContacts) {
            throw "Pre-validation failed. Use -SkipInvalidContacts to import valid contacts only."
        }
        Write-Log "SkipInvalidContacts is enabled. Will skip invalid contacts and import the rest." "WARN"
    }
    else {
        Write-Log "All contacts passed pre-validation"
    }

    # Process each contact
    $lineNum = 2
    $successCount = 0
    $failCount = 0
    $skippedCount = 0

    foreach ($row in $sourceData) {
        $validationError = $validationResults[$lineNum]

        # Skip invalid contacts if validation failed
        if ($null -ne $validationError) {
            Write-Log "Skipping line $lineNum (validation failed)" "WARN"
            $results += [PSCustomObject]@{
                Line = $lineNum
                Success = "N"
                Message = "Skipped: $validationError"
            }
            $skippedCount++
            $lineNum++
            continue
        }

        $contactData = Convert-RowToContact -Row $row -Mapping $mapping

        Write-Log "Processing line $lineNum of $($totalRows + 1)..."

        # Make API call
        $apiResult = Invoke-FastBoundApi -Server $Server -Account $Account -ApiKey $ApiKey -AuditUser $AuditUser -ContactData $contactData

        # Handle rate limiting
        if ($apiResult.StatusCode -eq 429) {
            Write-Log "Rate limited (429). Waiting for reset..." "WARN"
            if ($apiResult.RateLimitReset) {
                Wait-ForRateLimit -Remaining 0 -ResetTime $apiResult.RateLimitReset
            }
            else {
                # Default wait of 60 seconds if no reset time provided
                Write-Log "No reset time provided. Waiting 60 seconds..." "WARN"
                Start-Sleep -Seconds 60
            }

            # Retry the request
            $apiResult = Invoke-FastBoundApi -Server $Server -Account $Account -ApiKey $ApiKey -AuditUser $AuditUser -ContactData $contactData
        }

        # Record result
        $successFlag = if ($apiResult.Success) { "Y" } else { "N" }
        $results += [PSCustomObject]@{
            Line = $lineNum
            Success = $successFlag
            Message = $apiResult.Message
        }

        if ($apiResult.Success) {
            $successCount++
            Write-Log "  SUCCESS: $($apiResult.Message)"
        }
        else {
            $failCount++
            Write-Log "  FAILED ($($apiResult.StatusCode)): $($apiResult.Message)" "ERROR"
        }

        # Check rate limits for next request
        if ($apiResult.RateLimitRemaining -ge 0 -and $apiResult.RateLimitReset) {
            Wait-ForRateLimit -Remaining $apiResult.RateLimitRemaining -ResetTime $apiResult.RateLimitReset
        }

        $lineNum++
    }

    # Write results file
    $results | Export-Csv -Path $resultsFile -NoTypeInformation
    Write-Log "Results written to: $resultsFile"

    # Summary
    Write-Log "Import completed!"
    Write-Log "  Total: $totalRows"
    Write-Log "  Success: $successCount"
    Write-Log "  Failed: $failCount"
    Write-Log "  Skipped: $skippedCount"
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
