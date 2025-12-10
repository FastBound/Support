<#
.SYNOPSIS
    Import items into FastBound via API, including acquisitions and dispositions.

.DESCRIPTION
    This script imports items from a CSV file into FastBound. It:
    - Downloads and caches existing contacts
    - Creates new contacts as needed
    - Creates acquisitions for each item
    - Creates dispositions for items with a DisposeDate
    - Implements dynamic rate limiting based on API response headers
    - Handles large imports efficiently with memory-conscious contact matching

.PARAMETER Server
    The base URL for the FastBound API. Defaults to https://cloud.fastbound.com

.PARAMETER Account
    The FastBound account number

.PARAMETER ApiKey
    The API key for authentication

.PARAMETER OwnerEmail
    Email address for the X-AuditUser header (required for all write operations)

.PARAMETER ItemsFile
    Path to the items CSV file. Defaults to {Account}-items.csv

.PARAMETER ContactsFile
    Path to the contacts cache CSV file. Defaults to {Account}-contacts.csv

.PARAMETER DontSuppressUnknownUserEmail
    If specified, sends X-SuppressUnknownUserEmail: false header to disposition requests.
    By default (when not specified), sends X-SuppressUnknownUserEmail: true to suppress notification emails during bulk imports.

.PARAMETER ImportEmails
    If specified, includes email addresses when creating contacts. Default is false (emails are excluded).

.EXAMPLE
    .\Import-FastBoundItems.ps1 -Account "12345" -ApiKey "your-api-key" -OwnerEmail "user@example.com"

.EXAMPLE
    .\Import-FastBoundItems.ps1 -Account "12345" -ApiKey "your-api-key" -OwnerEmail "user@example.com" -DontSuppressUnknownUserEmail

.EXAMPLE
    .\Import-FastBoundItems.ps1 -Account "12345" -ApiKey "your-api-key" -OwnerEmail "user@example.com" -ImportEmails

.NOTES
    Rate Limiting: The script dynamically tracks rate limits from API response headers.
    CSV Format: Must follow FastBound import format with 37 columns (see FastBound documentation).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Server = "https://cloud.fastbound.com",

    [Parameter(Mandatory=$true)]
    [string]$Account,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [Parameter(Mandatory=$true)]
    [string]$OwnerEmail,

    [Parameter(Mandatory=$false)]
    [string]$ItemsFile = "$Account-items.csv",

    [Parameter(Mandatory=$false)]
    [string]$ContactsFile = "$Account-contacts.csv",

    [Parameter(Mandatory=$false)]
    [switch]$DontSuppressUnknownUserEmail,

    [Parameter(Mandatory=$false)]
    [switch]$ImportEmails
)

# Script-level variables for rate limiting
$script:RateLimitLimit = 60
$script:RateLimitRemaining = 60
$script:RateLimitReset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Statistics
$script:Stats = @{
    ItemsProcessed = 0
    AcquisitionsCreated = 0
    DispositionsCreated = 0
    ContactsCreated = 0
    Errors = 0
    ErrorDetails = @()
}

# Import log tracking (CSV export)
$script:ImportLog = @()

#region Helper Functions

function Write-Progress-Status {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Current = 0,
        [int]$Total = 0
    )

    if ($Total -gt 0) {
        $percentComplete = [int](($Current / $Total) * 100)
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $percentComplete
    } else {
        Write-Progress -Activity $Activity -Status $Status
    }
}

function Invoke-FastBoundApi {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Method,

        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [Parameter(Mandatory=$false)]
        [object]$Body = $null,

        [Parameter(Mandatory=$false)]
        [hashtable]$QueryParams = @{},

        [Parameter(Mandatory=$false)]
        [hashtable]$AdditionalHeaders = @{}
    )

    # Wait if we're approaching rate limit
    Wait-ForRateLimit

    # Build URL (use Get-Variable to access script scope)
    $serverUrl = Get-Variable -Name Server -Scope Script -ValueOnly
    $accountNum = Get-Variable -Name Account -Scope Script -ValueOnly
    $url = "$serverUrl/$accountNum$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $queryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $url = $url + "?" + $queryString
    }

    Write-Verbose "API Request: $Method $url"

    # Build headers
    $apiKey = Get-Variable -Name ApiKey -Scope Script -ValueOnly
    $ownerEmail = Get-Variable -Name OwnerEmail -Scope Script -ValueOnly
    $headers = @{
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$apiKey"))
        "X-AuditUser" = $ownerEmail
    }

    if ($Method -in @('POST', 'PUT', 'PATCH')) {
        $headers["Content-Type"] = "application/json"
    }

    # Add any additional headers
    foreach ($key in $AdditionalHeaders.Keys) {
        $headers[$key] = $AdditionalHeaders[$key]
    }

    try {
        $params = @{
            Uri = $url
            Method = $Method
            Headers = $headers
        }

        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }

        $response = Invoke-WebRequest @params

        # Update rate limit info from headers
        Update-RateLimitInfo -Headers $response.Headers

        # Return parsed JSON if there's content
        if ($response.Content) {
            return ($response.Content | ConvertFrom-Json)
        }

        # If no content but we have a Location header (e.g., 201 Created with no body),
        # extract the ID from the Location header and return a minimal object
        if ($response.Headers['Location']) {
            # Location header value is returned as a string array, convert to string
            $location = [string]$response.Headers['Location']
            Write-Verbose "Location header: $location"
            # Extract GUID from the end of the URL (e.g., "/77144/api/Contacts/12345678-1234-1234-1234-123456789012")
            if ($location -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
                $id = $matches[1]
                Write-Verbose "Extracted contact ID from Location header: $id"
                return @{ id = $id }
            }
            else {
                Write-Warning "Failed to extract ID from Location header: $location"
            }
        }

        return $null
    }
    catch {
        # Check for 429 Too Many Requests
        if ($_.Exception.Response.StatusCode -eq 429) {
            Write-Warning "Rate limit exceeded (429). Waiting for reset..."

            # Update rate limit from error response if available
            if ($_.Exception.Response.Headers) {
                Update-RateLimitInfo -Headers $_.Exception.Response.Headers
            }

            # Wait for reset + 1 second buffer
            $waitSeconds = ([DateTimeOffset]::FromUnixTimeSeconds($script:RateLimitReset) - [DateTimeOffset]::UtcNow).TotalSeconds + 1
            if ($waitSeconds -gt 0) {
                Start-Sleep -Seconds $waitSeconds
            }

            # Retry the request
            return Invoke-FastBoundApi -Method $Method -Endpoint $Endpoint -Body $Body -QueryParams $QueryParams -AdditionalHeaders $AdditionalHeaders
        }

        # Check for plan limit exceeded (400 with "Maximum limit has been reached")
        if ($_.Exception.Response.StatusCode -eq 400 -and $_.ErrorDetails.Message -like "*Maximum limit has been reached*") {
            $serverUrl = Get-Variable -Name Server -Scope Script -ValueOnly
            $accountNum = Get-Variable -Name Account -Scope Script -ValueOnly
            $plansUrl = "$serverUrl/$accountNum/plans"

            # Calculate how many items in the import have acquisition dates within the last 365 days
            $cutoffDate = (Get-Date).AddDays(-365)
            $recentItemCount = 0
            $csvItems = Get-Variable -Name items -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if ($csvItems) {
                foreach ($csvItem in $csvItems) {
                    if ($csvItem.Acquire_Date) {
                        try {
                            $acquireDate = [DateTime]::Parse($csvItem.Acquire_Date)
                            if ($acquireDate -ge $cutoffDate) {
                                $recentItemCount++
                            }
                        }
                        catch {
                            # Skip items with invalid dates
                        }
                    }
                }
            }

            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "  PLAN LIMIT REACHED" -ForegroundColor Red
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Your FastBound account has reached its maximum item limit." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "FastBound plans are based on acquisitions in the last 365 days." -ForegroundColor Cyan
            if ($recentItemCount -gt 0) {
                $formattedCount = $recentItemCount.ToString("N0")
                Write-Host ""
                Write-Host "This import contains $formattedCount items with acquisition dates" -ForegroundColor White
                Write-Host "within the last 365 days. You'll need a plan that can accommodate" -ForegroundColor White
                Write-Host "your existing items PLUS these $formattedCount items." -ForegroundColor White
            }
            Write-Host ""
            Write-Host "To continue importing:" -ForegroundColor Cyan
            Write-Host "  1. Go to: $plansUrl" -ForegroundColor White
            Write-Host "  2. Select a plan with a higher item limit" -ForegroundColor White
            Write-Host ""
            Write-Host "If you don't see the plan you need, contact FastBound Support" -ForegroundColor Yellow
            Write-Host "as there are many more plans not listed on that page." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Once your limit has been increased:" -ForegroundColor Green
            Write-Host "  - Type 'continue' and press Enter to retry" -ForegroundColor Green
            Write-Host "  - Press Ctrl+C to quit" -ForegroundColor Green
            Write-Host ""

            do {
                $response = Read-Host "Type 'continue' to retry"
            } while ($response -ne "continue")

            Write-Host "Retrying request..." -ForegroundColor Cyan

            # Retry the request
            return Invoke-FastBoundApi -Method $Method -Endpoint $Endpoint -Body $Body -QueryParams $QueryParams -AdditionalHeaders $AdditionalHeaders
        }

        # Build error message
        $errorMessage = "$Method $Endpoint failed: $($_.Exception.Message)"

        if ($_.Exception.Response.StatusCode) {
            $errorMessage += " (Status: $($_.Exception.Response.StatusCode.value__))"
        }

        if ($_.ErrorDetails.Message) {
            try {
                $apiError = ($_.ErrorDetails.Message | ConvertFrom-Json)
                $errorMessage += " API Error: $($apiError | ConvertTo-Json -Compress)"
            }
            catch {
                $errorMessage += " API Error: $($_.ErrorDetails.Message)"
            }
        }

        throw $errorMessage
    }
}

function Update-RateLimitInfo {
    param([object]$Headers)

    if ($Headers['X-RateLimit-Limit']) {
        $script:RateLimitLimit = [int]$Headers['X-RateLimit-Limit'][0]
    }

    if ($Headers['X-RateLimit-Remaining']) {
        $script:RateLimitRemaining = [int]$Headers['X-RateLimit-Remaining'][0]
    }

    if ($Headers['X-RateLimit-Reset']) {
        $script:RateLimitReset = [long]$Headers['X-RateLimit-Reset'][0]
    }
}

function Wait-ForRateLimit {
    # If we have fewer than 5 requests remaining, wait for the reset
    if ($script:RateLimitRemaining -lt 5) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $waitSeconds = $script:RateLimitReset - $now + 1

        if ($waitSeconds -gt 0) {
            Write-Host "Rate limit approaching ($script:RateLimitRemaining remaining). Waiting $waitSeconds seconds for reset..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitSeconds

            # Reset our counter
            $script:RateLimitRemaining = $script:RateLimitLimit
        }
    }
}

function Get-AllContacts {
    Write-Host "Downloading all contacts from FastBound..." -ForegroundColor Cyan

    $allContacts = @()
    $take = 100
    $skip = 0

    do {
        Write-Progress-Status -Activity "Downloading Contacts" -Status "Retrieved $($allContacts.Count) contacts..." -Current $skip -Total ($skip + $take)

        $response = Invoke-FastBoundApi -Method GET -Endpoint "/api/Contacts" -QueryParams @{
            take = $take
            skip = $skip
        }

        Write-Verbose "Response type: $($response.GetType().FullName)"
        Write-Verbose "Response properties: $($response | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name)"

        # Log records metadata if present
        if ($response.records) {
            Write-Verbose "Total records available: $($response.records)"
        }

        # Check if response is wrapped in an object with contacts property
        if ($response.contacts) {
            $contacts = $response.contacts
        }
        elseif ($response -is [Array]) {
            $contacts = $response
        }
        else {
            $contacts = @($response)
        }

        Write-Verbose "Contacts in this page: $($contacts.Count)"

        if ($contacts -and $contacts.Count -gt 0) {
            $allContacts += $contacts
            $skip += 1  # skip is number of PAGES to skip, not items
        }
        else {
            break
        }

    } while ($contacts -and $contacts.Count -ge $take)

    Write-Progress -Activity "Downloading Contacts" -Completed
    Write-Host "Downloaded $($allContacts.Count) contacts" -ForegroundColor Green

    return $allContacts
}

function Save-ContactsToCache {
    param([array]$Contacts)

    Write-Host "Saving contacts to cache file: $ContactsFile" -ForegroundColor Cyan

    # Convert to CSV-friendly format
    $contacts | Export-Csv -Path $ContactsFile -NoTypeInformation -Encoding UTF8

    Write-Host "Saved $($Contacts.Count) contacts to cache" -ForegroundColor Green
}

function Normalize-ContactString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    # Trim whitespace, convert to uppercase, normalize spaces
    return ($Value.Trim() -replace '\s+', ' ').ToUpper()
}

function Find-MatchingContact {
    param(
        [array]$Contacts,
        [hashtable]$ContactInfo
    )

    foreach ($contact in $Contacts) {
        # Try FFL match first (normalize hyphens)
        if ($ContactInfo.fflNumber -and $contact.fflNumber) {
            $searchFFL = $ContactInfo.fflNumber -replace '-', ''
            $contactFFL = $contact.fflNumber -replace '-', ''

            Write-Verbose "  Comparing FFL: '$searchFFL' vs '$contactFFL'"

            if ($searchFFL -eq $contactFFL) {
                Write-Verbose "  FFL Match found!"
                return $contact
            }
        }

        # Try person match (firstName/middleName/lastName + address)
        if ($ContactInfo.firstName -and $ContactInfo.lastName -and $contact.firstName -and $contact.lastName) {
            # Normalize names for comparison
            $firstNameMatch = (Normalize-ContactString $contact.firstName) -eq (Normalize-ContactString $ContactInfo.firstName)
            $lastNameMatch = (Normalize-ContactString $contact.lastName) -eq (Normalize-ContactString $ContactInfo.lastName)

            # Middle name matching: if either side is empty, consider it a match (FastBound treats these as same person)
            $contactMiddle = Normalize-ContactString $contact.middleName
            $searchMiddle = Normalize-ContactString $ContactInfo.middleName
            $middleNameMatch = ($contactMiddle -eq $searchMiddle) -or ($contactMiddle -eq "") -or ($searchMiddle -eq "")

            $nameMatch = $firstNameMatch -and $lastNameMatch -and $middleNameMatch

            if ($nameMatch) {
                # Normalize addresses for comparison
                $addressMatch = (
                    (Normalize-ContactString $contact.premiseAddress1) -eq (Normalize-ContactString $ContactInfo.premiseAddress1) -and
                    (Normalize-ContactString $contact.premiseCity) -eq (Normalize-ContactString $ContactInfo.premiseCity) -and
                    (Normalize-ContactString $contact.premiseState) -eq (Normalize-ContactString $ContactInfo.premiseState) -and
                    (Normalize-ContactString $contact.premiseZipCode) -eq (Normalize-ContactString $ContactInfo.premiseZipCode)
                )

                if ($addressMatch) {
                    return $contact
                }
            }
        }

        # Try organization match (organizationName + address)
        if ($ContactInfo.organizationName -and $contact.organizationName) {
            # Normalize organization name for comparison
            $orgMatch = (Normalize-ContactString $contact.organizationName) -eq (Normalize-ContactString $ContactInfo.organizationName)

            if ($orgMatch) {
                # Normalize addresses for comparison
                $addressMatch = (
                    (Normalize-ContactString $contact.premiseAddress1) -eq (Normalize-ContactString $ContactInfo.premiseAddress1) -and
                    (Normalize-ContactString $contact.premiseCity) -eq (Normalize-ContactString $ContactInfo.premiseCity) -and
                    (Normalize-ContactString $contact.premiseState) -eq (Normalize-ContactString $ContactInfo.premiseState) -and
                    (Normalize-ContactString $contact.premiseZipCode) -eq (Normalize-ContactString $ContactInfo.premiseZipCode)
                )

                if ($addressMatch) {
                    return $contact
                }
            }
        }
    }

    return $null
}

function New-Contact {
    param([hashtable]$ContactInfo)

    Write-Host "Creating new contact: $($ContactInfo.displayName)" -ForegroundColor Yellow

    # Build contact request
    $contactRequest = @{}

    # Map all possible fields
    $fieldMapping = @{
        fflNumber = 'fflNumber'
        fflExpires = 'fflExpires'
        licenseName = 'licenseName'
        tradeName = 'tradeName'
        organizationName = 'organizationName'
        firstName = 'firstName'
        middleName = 'middleName'
        lastName = 'lastName'
        suffix = 'suffix'
        premiseAddress1 = 'premiseAddress1'
        premiseAddress2 = 'premiseAddress2'
        premiseCity = 'premiseCity'
        premiseState = 'premiseState'
        premiseZipCode = 'premiseZipCode'
        premiseCountry = 'premiseCountry'
        emailAddress = 'emailAddress'
    }

    # Valid suffix values according to FastBound API
    $validSuffixes = @('JR', 'SR', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X')

    foreach ($key in $fieldMapping.Keys) {
        if ($ContactInfo.ContainsKey($key) -and $ContactInfo[$key]) {
            $value = $ContactInfo[$key]

            # Validate suffix field
            if ($key -eq 'suffix') {
                $normalizedSuffix = $value.Trim().ToUpper()
                if ($validSuffixes -contains $normalizedSuffix) {
                    $contactRequest[$fieldMapping[$key]] = $normalizedSuffix
                }
                # Skip invalid suffixes - don't add them to the request
            }
            else {
                $contactRequest[$fieldMapping[$key]] = $value
            }
        }
    }

    # FFL lookup logic: Always set lookupFFL = false
    # All FFL data was already enriched by Validate-Items.ps1, so no need for API to look them up
    if ($contactRequest.fflNumber) {
        $contactRequest['lookupFFL'] = $false
        Write-Verbose "  FFL contact - setting lookupFFL = false"

        # FastBound API business rule: FFL contacts use licenseName (not person name fields)
        # Person name fields must be empty for FFL contacts
        Write-Verbose "  FFL contact - removing person name fields (using licenseName instead)"
        $contactRequest.Remove('firstName')
        $contactRequest.Remove('middleName')
        $contactRequest.Remove('lastName')
        $contactRequest.Remove('suffix')
    }

    try {
        $result = Invoke-FastBoundApi -Method POST -Endpoint "/api/Contacts" -Body $contactRequest

        Write-Verbose "Contact creation result type: $($result.GetType().FullName)"
        Write-Verbose "Contact creation result: $($result | ConvertTo-Json -Depth 3 -Compress)"

        # Check if the API returned contact data with an ID
        if ($result -and $result.id) {
            Write-Host "  Contact created with ID: $($result.id)" -ForegroundColor Green
            $script:Stats.ContactsCreated++
            return $result
        }

        # Check if result is a contacts list (wrapped response)
        if ($result -and $result.contacts -and $result.contacts.Count -gt 0) {
            Write-Verbose "  Contact created with ID: $($result.contacts[0].id)"
            $script:Stats.ContactsCreated++
            return $result.contacts[0]
        }

        # Fallback: the contact was created but we need to retrieve it
        # This happens when API returns 201 with Location header but no body
        Write-Host "  Contact created but no ID in response, retrieving details..." -ForegroundColor Gray

        # Fetch ALL contacts with proper pagination (just like the error handler does)
        $contacts = Get-AllContacts

        $newContact = Find-MatchingContact -Contacts $contacts -ContactInfo $ContactInfo

        if ($newContact) {
            Write-Verbose "  Found contact with ID: $($newContact.id)"
            $script:Stats.ContactsCreated++
            return $newContact
        }

        # Last resort: contact was created but we can't retrieve it - this is an error
        Write-Error "  Contact created but details could not be retrieved. Cannot proceed without valid contact ID."
        throw "Failed to retrieve contact ID for: $($ContactInfo.displayName)"
    }
    catch {
        # If contact already exists, try to find it
        if ($_ -like "*already exists*") {
            Write-Host "  Contact already exists, searching for it..." -ForegroundColor Yellow

            # Fetch ALL contacts with proper pagination
            $allContacts = Get-AllContacts

            $existingContact = Find-MatchingContact -Contacts $allContacts -ContactInfo $ContactInfo

            if ($existingContact) {
                return $existingContact
            }
        }

        Write-Error "Failed to create contact: $_"
        throw
    }
}

function Get-OrCreateContact {
    param(
        [array]$Contacts,
        [hashtable]$ContactInfo
    )

    # Try to find existing contact
    $contact = Find-MatchingContact -Contacts $Contacts -ContactInfo $ContactInfo

    if ($contact) {
        return $contact
    }

    # Create new contact
    $newContact = New-Contact -ContactInfo $ContactInfo

    # Add to contacts array and save to cache
    $Contacts += $newContact
    Save-ContactsToCache -Contacts $Contacts

    return $newContact
}

function Parse-FastBoundDate {
    param([string]$DateString)

    if ([string]::IsNullOrWhiteSpace($DateString)) {
        return $null
    }

    try {
        $date = [DateTime]::Parse($DateString)
        return $date.ToString("yyyy-MM-ddTHH:mm:ss")
    }
    catch {
        Write-Warning "Invalid date format: $DateString"
        return $null
    }
}

function Build-ContactInfo {
    param(
        [object]$Row,
        [string]$Prefix,  # "Acquire" or "Dispose"
        [bool]$IncludeEmails = $false
    )

    $contact = @{}

    # FFL fields (CSV uses Acquire_License not AcquireFFLNumber)
    if ($Row."${Prefix}_License") { $contact.fflNumber = $Row."${Prefix}_License" }
    if ($Row."${Prefix}_LicenseExpires") { $contact.fflExpires = Parse-FastBoundDate $Row."${Prefix}_LicenseExpires" }
    if ($Row."${Prefix}_LicenseName") { $contact.licenseName = $Row."${Prefix}_LicenseName" }
    if ($Row."${Prefix}_TradeName") { $contact.tradeName = $Row."${Prefix}_TradeName" }

    # Person fields
    if ($Row."${Prefix}_FirstName") { $contact.firstName = $Row."${Prefix}_FirstName" }
    if ($Row."${Prefix}_MiddleName") { $contact.middleName = $Row."${Prefix}_MiddleName" }
    if ($Row."${Prefix}_LastName") { $contact.lastName = $Row."${Prefix}_LastName" }
    if ($Row."${Prefix}_Suffix") { $contact.suffix = $Row."${Prefix}_Suffix" }

    # Organization
    if ($Row."${Prefix}_Organization") { $contact.organizationName = $Row."${Prefix}_Organization" }

    # Address fields (CSV uses Acquire_Postal not Acquire_Zip)
    if ($Row."${Prefix}_Address1") { $contact.premiseAddress1 = $Row."${Prefix}_Address1" }
    if ($Row."${Prefix}_Address2") { $contact.premiseAddress2 = $Row."${Prefix}_Address2" }
    if ($Row."${Prefix}_City") { $contact.premiseCity = $Row."${Prefix}_City" }
    if ($Row."${Prefix}_State") { $contact.premiseState = $Row."${Prefix}_State" }
    if ($Row."${Prefix}_Postal") { $contact.premiseZipCode = $Row."${Prefix}_Postal" }
    if ($Row."${Prefix}_Country") { $contact.premiseCountry = $Row."${Prefix}_Country" }

    # Email address (only if ImportEmails flag is enabled)
    if ($IncludeEmails -and $Row."${Prefix}_EmailAddress") {
        $contact.emailAddress = $Row."${Prefix}_EmailAddress"
    }

    # Create display name for logging
    if ($contact.organizationName) {
        $contact.displayName = $contact.organizationName
    }
    elseif ($contact.firstName -or $contact.lastName) {
        $contact.displayName = "$($contact.firstName) $($contact.lastName)".Trim()
    }
    elseif ($contact.fflNumber) {
        $contact.displayName = "FFL: $($contact.fflNumber)"
    }
    else {
        $contact.displayName = "Unknown Contact"
    }

    return $contact
}

function Test-ContactInfoValid {
    param(
        [hashtable]$ContactInfo,
        [string]$Prefix  # "Acquire" or "Dispose" (for error messages)
    )

    $missingFields = @()

    # Determine contact type (mutually exclusive)
    $hasFFL = $ContactInfo.fflNumber
    $hasOrganization = $ContactInfo.organizationName
    $hasIndividual = $ContactInfo.firstName -or $ContactInfo.lastName

    # Validate contact identity (must be ONE of: FFL, Organization, or Individual)
    if ($hasFFL) {
        # FFL Contact: requires licenseName + fflNumber + fflExpires
        if (-not $ContactInfo.licenseName) { $missingFields += "${Prefix}_LicenseName" }
        if (-not $ContactInfo.fflNumber) { $missingFields += "${Prefix}_License" }
        if (-not $ContactInfo.fflExpires) { $missingFields += "${Prefix}_LicenseExpires" }
    }
    elseif ($hasOrganization) {
        # Organization Contact: requires organizationName
        if (-not $ContactInfo.organizationName) { $missingFields += "${Prefix}_Organization" }
    }
    elseif ($hasIndividual) {
        # Individual Contact: requires firstName + lastName
        if (-not $ContactInfo.firstName) { $missingFields += "${Prefix}_FirstName" }
        if (-not $ContactInfo.lastName) { $missingFields += "${Prefix}_LastName" }
    }
    else {
        # No contact identity provided
        $missingFields += "${Prefix}_License OR ${Prefix}_Organization OR (${Prefix}_FirstName AND ${Prefix}_LastName)"
    }

    # ALL contact types require address fields
    if (-not $ContactInfo.premiseAddress1) { $missingFields += "${Prefix}_Address1" }
    if (-not $ContactInfo.premiseCity) { $missingFields += "${Prefix}_City" }
    if (-not $ContactInfo.premiseState) { $missingFields += "${Prefix}_State" }
    if (-not $ContactInfo.premiseZipCode) { $missingFields += "${Prefix}_Postal" }

    if ($missingFields.Count -gt 0) {
        return @{
            Valid = $false
            MissingFields = $missingFields
        }
    }

    return @{
        Valid = $true
        MissingFields = @()
    }
}

function New-Acquisition {
    param(
        [object]$Row,
        [string]$ContactId
    )

    # Build acquisition request (CSV uses Acquire_Date and AcquisitionType)
    $acquisition = @{
        contactId = $ContactId
        type = $Row.AcquisitionType
        date = Parse-FastBoundDate $Row.Acquire_Date
        items = @(
            @{
                manufacturer = $Row.Manufacturer
                model = $Row.Model
                serial = $Row.Serial
                caliber = $Row.Caliber
                type = $Row.Type
            }
        )
    }

    # Add optional fields
    if ($Row.Importer) { $acquisition.items[0].importer = $Row.Importer }
    if ($Row.CountryOfManufacture) { $acquisition.items[0].countryOfManufacture = $Row.CountryOfManufacture }
    if ($Row.BarrelLength) { $acquisition.items[0].barrelLength = [double]$Row.BarrelLength }
    if ($Row.OverallLength) { $acquisition.items[0].totalLength = [double]$Row.OverallLength }
    if ($Row.ItemNumber) { $acquisition.items[0].itemNumber = $Row.ItemNumber }
    if ($Row.Condition) { $acquisition.items[0].condition = $Row.Condition }
    if ($Row.Cost) { $acquisition.items[0].cost = $Row.Cost }
    if ($Row.Price) { $acquisition.items[0].price = $Row.Price }
    if ($Row.MPN) { $acquisition.items[0].mpn = $Row.MPN }
    if ($Row.UPC) { $acquisition.items[0].upc = $Row.UPC }
    if ($Row.SKU) { $acquisition.items[0].sku = $Row.SKU }
    if ($Row.Location) { $acquisition.items[0].location = $Row.Location }
    if ($Row.Note) { $acquisition.items[0].note = $Row.Note }
    if ($Row.ExternalId) { $acquisition.items[0].externalId = $Row.ExternalId }

    # Manufacturing acquisition?
    if ($Row.ManufacturingAcquireType) {
        $acquisition.isManufacturingAcquisition = $true
        $acquisition.type = $Row.ManufacturingAcquireType
    }

    try {
        $result = Invoke-FastBoundApi -Method POST -Endpoint "/api/Acquisitions/CreateAndCommit" -Body $acquisition -QueryParams @{ listAcquiredItems = $true }
        $script:Stats.AcquisitionsCreated++
        return $result
    }
    catch {
        Write-Error "Failed to create acquisition for serial $($Row.Serial): $_"
        throw
    }
}

function New-Disposition {
    param(
        [object]$Row,
        [string]$ContactId,
        [string]$ItemId
    )

    # Map CSV disposition types to API requestType values
    $dispositionTypeMapping = @{
        'Sale' = 'Regular'
        'Transfer' = 'Regular'
        'Hey Pee Eye' = 'Regular'  # Likely means "HPI" or similar - using Regular
        'New Contact' = 'Regular'
        'Manufacturing' = 'Regular'
        'Unknown' = 'Regular'  # Default value from validation script
        'NFA' = 'NFA'
        'TheftLoss' = 'TheftLoss'
        'Theft' = 'TheftLoss'
        'Loss' = 'TheftLoss'
        'Destroyed' = 'Destroyed'
        'Regular' = 'Regular'
    }

    $csvType = $Row.DispositionType
    $requestType = if ($dispositionTypeMapping.ContainsKey($csvType)) {
        $dispositionTypeMapping[$csvType]
    } else {
        Write-Warning "Unknown disposition type '$csvType', defaulting to 'Regular'"
        'Regular'
    }

    # Build disposition request (CSV uses Dispose_Date and DispositionType)
    $disposition = @{
        contactId = $ContactId
        requestType = $requestType
        date = Parse-FastBoundDate $Row.Dispose_Date
        items = @(
            @{
                id = $ItemId
            }
        )
    }

    # Add type field - use the original CSV value as the type description
    # (type is required for Regular and NFA requestTypes)
    if ($requestType -in @('Regular', 'NFA')) {
        $disposition.type = $csvType
    }

    # Add price if available
    if ($Row.Price) {
        $disposition.items[0].price = [double]$Row.Price
    }

    # Build additional headers for disposition emails
    # By default, suppress unknown user emails during bulk imports
    # Only allow emails if DontSuppressUnknownUserEmail switch is specified
    $additionalHeaders = @{}
    $dontSuppressFlag = Get-Variable -Name DontSuppressUnknownUserEmail -Scope Script -ValueOnly
    if ($dontSuppressFlag) {
        $additionalHeaders["X-SuppressUnknownUserEmail"] = "false"
    } else {
        $additionalHeaders["X-SuppressUnknownUserEmail"] = "true"
    }

    try {
        $result = Invoke-FastBoundApi -Method POST -Endpoint "/api/Dispositions/CreateAndCommit" -Body $disposition -QueryParams @{ listDisposedItems = $true } -AdditionalHeaders $additionalHeaders
        $script:Stats.DispositionsCreated++
        return $result
    }
    catch {
        Write-Error "Failed to create disposition for item $ItemId : $_"
        throw
    }
}

#endregion


#region Main Script

Write-Host "`n=== FastBound Item Import ===" -ForegroundColor Cyan
Write-Host "Server: $Server"
Write-Host "Account: $Account"
Write-Host "Owner: $OwnerEmail"
Write-Host "Items File: $ItemsFile"
Write-Host "Contacts File: $ContactsFile"
Write-Host ""

# Validate files
if (-not (Test-Path $ItemsFile)) {
    Write-Error "Items file not found: $ItemsFile"
    exit 1
}

# Download and cache contacts
try {
    $contacts = @(Get-AllContacts)
    Save-ContactsToCache -Contacts $contacts
}
catch {
    Write-Error "Failed to download contacts: $_"
    exit 1
}

# Load items CSV
Write-Host "Loading items from CSV..." -ForegroundColor Cyan
try {
    $items = Import-Csv -Path $ItemsFile
    Write-Host "Loaded $($items.Count) items" -ForegroundColor Green
}
catch {
    Write-Error "Failed to load items CSV: $_"
    exit 1
}

# Validate required FastBound columns are present
Write-Host "`nValidating CSV columns..." -ForegroundColor Cyan

if ($items.Count -eq 0) {
    Write-Error "CSV file is empty"
    exit 1
}

$firstItem = $items[0]
$csvColumns = $firstItem.PSObject.Properties.Name

# Required item columns
$requiredItemColumns = @('Manufacturer', 'Model', 'Serial', 'Caliber', 'Type', 'AcquisitionType', 'Acquire_Date')

# Required acquisition contact address columns
$requiredAcquireAddressColumns = @('Acquire_Address1', 'Acquire_City', 'Acquire_State', 'Acquire_Postal')

# At least ONE of these acquisition contact identity groups must be present
$acquireIdentityGroups = @(
    @('Acquire_License', 'Acquire_LicenseExpires', 'Acquire_LicenseName'),  # FFL Contact
    @('Acquire_Organization'),                                              # Organization Contact
    @('Acquire_FirstName', 'Acquire_LastName')                             # Individual Contact
)

# Check required item columns
$missingColumns = @()
foreach ($col in $requiredItemColumns) {
    if ($csvColumns -notcontains $col) {
        $missingColumns += $col
    }
}

# Check required acquisition address columns
foreach ($col in $requiredAcquireAddressColumns) {
    if ($csvColumns -notcontains $col) {
        $missingColumns += $col
    }
}

# Check that at least ONE acquisition identity group is present
$hasAcquireIdentity = $false
foreach ($group in $acquireIdentityGroups) {
    $groupComplete = $true
    foreach ($col in $group) {
        if ($csvColumns -notcontains $col) {
            $groupComplete = $false
            break
        }
    }
    if ($groupComplete) {
        $hasAcquireIdentity = $true
        break
    }
}

if (-not $hasAcquireIdentity) {
    $missingColumns += "Acquire_License+Acquire_LicenseExpires+Acquire_LicenseName OR Acquire_Organization OR Acquire_FirstName+Acquire_LastName"
}

if ($missingColumns.Count -gt 0) {
    Write-Host "`nColumn validation FAILED - Missing required FastBound columns:" -ForegroundColor Red
    foreach ($col in $missingColumns) {
        Write-Host "  - $col" -ForegroundColor Red
    }
    Write-Host "`nThe input CSV must be pre-validated using Validate-Items.ps1" -ForegroundColor Yellow
    Write-Host "Please run: .\Validate-Items.ps1 -InputFile <your-file.csv>" -ForegroundColor Yellow
    exit 1
}

Write-Host "Column validation passed - all required FastBound columns present" -ForegroundColor Green

# Collect all unique contacts from CSV
Write-Host "`nCollecting unique contacts from CSV..." -ForegroundColor Cyan
$uniqueContactsHash = @{}

foreach ($item in $items) {
    # Build acquisition contact
    $acquireContact = Build-ContactInfo -Row $item -Prefix "Acquire" -IncludeEmails $ImportEmails

    # Create unique key based on matching criteria (FFL, or person+address, or org+address)
    # Use normalization to reduce duplicates
    $contactKey = ""
    if ($acquireContact.fflNumber) {
        $contactKey = "FFL:$($acquireContact.fflNumber -replace '-', '')"
    }
    elseif ($acquireContact.firstName -and $acquireContact.lastName) {
        # Note: Middle name excluded from key - FastBound treats "John Smith" and "John Q Smith" as same person
        $firstName = Normalize-ContactString $acquireContact.firstName
        $lastName = Normalize-ContactString $acquireContact.lastName
        $address1 = Normalize-ContactString $acquireContact.premiseAddress1
        $city = Normalize-ContactString $acquireContact.premiseCity
        $state = Normalize-ContactString $acquireContact.premiseState
        $zip = Normalize-ContactString $acquireContact.premiseZipCode
        $contactKey = "PERSON:${firstName}:${lastName}:${address1}:${city}:${state}:${zip}"
    }
    elseif ($acquireContact.organizationName) {
        $orgName = Normalize-ContactString $acquireContact.organizationName
        $address1 = Normalize-ContactString $acquireContact.premiseAddress1
        $city = Normalize-ContactString $acquireContact.premiseCity
        $state = Normalize-ContactString $acquireContact.premiseState
        $zip = Normalize-ContactString $acquireContact.premiseZipCode
        $contactKey = "ORG:${orgName}:${address1}:${city}:${state}:${zip}"
    }

    if ($contactKey -and -not $uniqueContactsHash.ContainsKey($contactKey)) {
        $uniqueContactsHash[$contactKey] = $acquireContact
    }

    # Build disposition contact if item is disposed
    if ($item.Dispose_Date) {
        $disposeContact = Build-ContactInfo -Row $item -Prefix "Dispose" -IncludeEmails $ImportEmails

        $contactKey = ""
        if ($disposeContact.fflNumber) {
            $contactKey = "FFL:$($disposeContact.fflNumber -replace '-', '')"
        }
        elseif ($disposeContact.firstName -and $disposeContact.lastName) {
            # Note: Middle name excluded from key - FastBound treats "John Smith" and "John Q Smith" as same person
            $firstName = Normalize-ContactString $disposeContact.firstName
            $lastName = Normalize-ContactString $disposeContact.lastName
            $address1 = Normalize-ContactString $disposeContact.premiseAddress1
            $city = Normalize-ContactString $disposeContact.premiseCity
            $state = Normalize-ContactString $disposeContact.premiseState
            $zip = Normalize-ContactString $disposeContact.premiseZipCode
            $contactKey = "PERSON:${firstName}:${lastName}:${address1}:${city}:${state}:${zip}"
        }
        elseif ($disposeContact.organizationName) {
            $orgName = Normalize-ContactString $disposeContact.organizationName
            $address1 = Normalize-ContactString $disposeContact.premiseAddress1
            $city = Normalize-ContactString $disposeContact.premiseCity
            $state = Normalize-ContactString $disposeContact.premiseState
            $zip = Normalize-ContactString $disposeContact.premiseZipCode
            $contactKey = "ORG:${orgName}:${address1}:${city}:${state}:${zip}"
        }

        if ($contactKey -and -not $uniqueContactsHash.ContainsKey($contactKey)) {
            $uniqueContactsHash[$contactKey] = $disposeContact
        }
    }
}

Write-Host "Found $($uniqueContactsHash.Count) unique contacts in CSV" -ForegroundColor Green

# Match or create all unique contacts
Write-Host "`nMatching/creating contacts..." -ForegroundColor Cyan
$contactMap = @{}
$contactsCreated = 0

foreach ($key in $uniqueContactsHash.Keys) {
    $contactInfo = $uniqueContactsHash[$key]

    # Try to find existing contact
    $existingContact = Find-MatchingContact -Contacts $contacts -ContactInfo $contactInfo

    if ($existingContact) {
        Write-Verbose "  Found existing: $($contactInfo.displayName)"
        $contactMap[$key] = $existingContact
    }
    else {
        Write-Host "  Creating: $($contactInfo.displayName)" -ForegroundColor Yellow
        $newContact = New-Contact -ContactInfo $contactInfo
        $contacts += $newContact
        $contactMap[$key] = $newContact
        $contactsCreated++
    }
}

Write-Host "Contacts ready: $($contacts.Count) total ($contactsCreated created)" -ForegroundColor Green

# Helper function to get contact from map
function Get-ContactFromMap {
    param([hashtable]$ContactInfo)

    # Use same normalization as contact key generation
    $contactKey = ""
    if ($ContactInfo.fflNumber) {
        $contactKey = "FFL:$($ContactInfo.fflNumber -replace '-', '')"
    }
    elseif ($ContactInfo.firstName -and $ContactInfo.lastName) {
        # Note: Middle name excluded from key - FastBound treats "John Smith" and "John Q Smith" as same person
        $firstName = Normalize-ContactString $ContactInfo.firstName
        $lastName = Normalize-ContactString $ContactInfo.lastName
        $address1 = Normalize-ContactString $ContactInfo.premiseAddress1
        $city = Normalize-ContactString $ContactInfo.premiseCity
        $state = Normalize-ContactString $ContactInfo.premiseState
        $zip = Normalize-ContactString $ContactInfo.premiseZipCode
        $contactKey = "PERSON:${firstName}:${lastName}:${address1}:${city}:${state}:${zip}"
    }
    elseif ($ContactInfo.organizationName) {
        $orgName = Normalize-ContactString $ContactInfo.organizationName
        $address1 = Normalize-ContactString $ContactInfo.premiseAddress1
        $city = Normalize-ContactString $ContactInfo.premiseCity
        $state = Normalize-ContactString $ContactInfo.premiseState
        $zip = Normalize-ContactString $ContactInfo.premiseZipCode
        $contactKey = "ORG:${orgName}:${address1}:${city}:${state}:${zip}"
    }

    return $contactMap[$contactKey]
}

# Process each item
$itemNumber = 0
foreach ($item in $items) {
    $itemNumber++
    $csvLineNumber = $itemNumber + 1  # +1 for CSV header row

    # Create import log entry for this item
    $logEntry = [PSCustomObject]@{
        Row = $csvLineNumber
        Success = $null  # Will be $true or $false, converted to Y/N on export
        ItemId = ""
        AcquisitionId = ""
        DispositionId = ""
        Note = ""
    }

    try {
        Write-Progress-Status -Activity "Processing Items" -Status "Processing item $itemNumber of $($items.Count) (Serial: $($item.Serial))" -Current $itemNumber -Total $items.Count

        Write-Host "`n[$itemNumber/$($items.Count)] Processing: $($item.Manufacturer) $($item.Model) S/N: $($item.Serial)" -ForegroundColor Cyan

        # Build acquisition contact info and get from map
        $acquireContact = Build-ContactInfo -Row $item -Prefix "Acquire" -IncludeEmails $ImportEmails
        $acquireContactObj = Get-ContactFromMap -ContactInfo $acquireContact
        Write-Host "  Acquisition Contact: $($acquireContact.displayName) (ID: $($acquireContactObj.id))" -ForegroundColor Gray

        # Create acquisition
        Write-Host "  Creating acquisition..." -ForegroundColor Gray
        $itemId = $null
        $acquisitionExists = $false

        try {
            $acquisition = New-Acquisition -Row $item -ContactId $acquireContactObj.id
            $itemId = $acquisition.items[0].id
            $logEntry.ItemId = $itemId
            if ($acquisition.acquisitionId) {
                $logEntry.AcquisitionId = $acquisition.acquisitionId
            }
            Write-Host "  Acquisition created (Item ID: $itemId)" -ForegroundColor Green
        }
        catch {
            # Check if item already exists
            if ($_ -like "*already been acquired*") {
                Write-Host "  Item already acquired, skipping acquisition..." -ForegroundColor Yellow
                $acquisitionExists = $true
                $logEntry.Note = "Item already acquired"

                # Try to find the existing item by serial number
                # We'll need to search for it in the inventory
                Write-Host "  Looking up existing item by serial number..." -ForegroundColor Gray
                $searchResult = Invoke-FastBoundApi -Method GET -Endpoint "/api/Items" -QueryParams @{
                    serial = $item.Serial
                }

                if ($searchResult.items -and $searchResult.items.Count -gt 0) {
                    $itemId = $searchResult.items[0].id
                    $logEntry.ItemId = $itemId
                    Write-Host "  Found existing item (ID: $itemId)" -ForegroundColor Gray
                }
                else {
                    Write-Warning "  Could not find existing item with serial $($item.Serial)"
                }
            }
            else {
                # Re-throw if it's a different error
                throw
            }
        }

        # Check if disposition is needed (CSV uses Dispose_Date)
        if ($item.Dispose_Date -and $itemId) {
            Write-Host "  Item has disposal date, creating disposition..." -ForegroundColor Gray

            # Build disposition contact info
            $disposeContact = Build-ContactInfo -Row $item -Prefix "Dispose" -IncludeEmails $ImportEmails

            # Get disposition contact from pre-created map
            $disposeContactObj = Get-ContactFromMap -ContactInfo $disposeContact
            if (-not $disposeContactObj) {
                Write-Error "  Could not find disposition contact in pre-created contact map"
                throw "Disposition rejected: Contact not found in map"
            }
            Write-Host "  Disposition Contact: $($disposeContact.displayName) (ID: $($disposeContactObj.id))" -ForegroundColor Gray

            # Create disposition
            $disposition = New-Disposition -Row $item -ContactId $disposeContactObj.id -ItemId $itemId
            $dispId = if ($disposition.dispositionId) { $disposition.dispositionId } elseif ($disposition.id) { $disposition.id } else { "" }
            $logEntry.DispositionId = $dispId
            Write-Host "  Disposition created (ID: $dispId)" -ForegroundColor Green
        }

        # Mark as successful
        $logEntry.Success = $true
        $script:Stats.ItemsProcessed++

        Write-Host "  Rate Limit: $script:RateLimitRemaining / $script:RateLimitLimit remaining" -ForegroundColor DarkGray
    }
    catch {
        # Mark as failed
        $logEntry.Success = $false
        $logEntry.Note = if ($logEntry.Note) { "$($logEntry.Note); $($_.Exception.Message)" } else { $_.Exception.Message }

        $script:Stats.Errors++
        $script:Stats.ErrorDetails += @{
            ItemNumber = $itemNumber
            Serial = $item.Serial
            Error = $_.Exception.Message
        }

        Write-Error "Error processing item $itemNumber (Serial: $($item.Serial)): $_"

        # Continue to next item
        continue
    }
    finally {
        # Always add log entry to the import log
        $script:ImportLog += $logEntry
    }
}

Write-Progress -Activity "Processing Items" -Completed

# Print summary
Write-Host "`n=== Import Summary ===" -ForegroundColor Cyan
Write-Host "Items Processed: $($script:Stats.ItemsProcessed) / $($items.Count)"
Write-Host "Acquisitions Created: $($script:Stats.AcquisitionsCreated)" -ForegroundColor Green
Write-Host "Dispositions Created: $($script:Stats.DispositionsCreated)" -ForegroundColor Green
Write-Host "Contacts Created: $($script:Stats.ContactsCreated)" -ForegroundColor Yellow
Write-Host "Errors: $($script:Stats.Errors)" -ForegroundColor $(if ($script:Stats.Errors -gt 0) { "Red" } else { "Green" })

if ($script:Stats.Errors -gt 0) {
    Write-Host "`nError Details:" -ForegroundColor Red
    foreach ($errorDetail in $script:Stats.ErrorDetails) {
        Write-Host "  Item #$($errorDetail.ItemNumber) (S/N: $($errorDetail.Serial)): $($errorDetail.Error)" -ForegroundColor Red
    }
}

# Export import results CSV
Write-Host "`nExporting import results..." -ForegroundColor Cyan
$logFile = $ItemsFile -replace '\.csv$', '-import-results.csv'

try {
    # Convert boolean Success values to Y/N for export
    $script:ImportLog | Select-Object Row, `
        @{Name='Success'; Expression={if ($_.Success) {'Y'} else {'N'}}}, `
        ItemId, `
        AcquisitionId, `
        DispositionId, `
        Note | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8

    Write-Host "Import results exported to: $logFile" -ForegroundColor Green
    Write-Host "Results contain $($script:ImportLog.Count) rows (same count as source file)" -ForegroundColor Cyan
}
catch {
    Write-Warning "Failed to export import results: $_"
}

Write-Host "`nImport complete!" -ForegroundColor Cyan

#endregion
