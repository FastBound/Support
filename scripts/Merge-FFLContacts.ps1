<#
.SYNOPSIS
    Merge duplicate FFL contacts by RDS (Region-District-Sequence).

.DESCRIPTION
    This script downloads all contacts from FastBound, groups FFL contacts by their RDS
    (first digit + next 2 digits + last 5 digits of the FFL number), validates that
    expiration dates match the embedded code in the FFL number, and merges older FFLs
    into the newest valid FFL for each group.

    FFL Number Format (15 characters): e.g., 154000010B39639
    - Position 1: Region (1 digit)
    - Positions 2-3: District (2 digits)
    - Positions 4-8: Type/other info
    - Positions 9-10: Expiration code (Year digit + Month letter)
    - Positions 11-15: Sequence (5 digits)

    RDS = Region (1) + District (2) + Sequence (5) = 8 characters

    Expiration Code:
    - Position 9: Year digit (0-9) - the last digit of the expiration year
    - Position 10: Month letter (A-M, skipping I)
      A=Jan, B=Feb, C=Mar, D=Apr, E=May, F=Jun, G=Jul, H=Aug, J=Sep, K=Oct, L=Nov, M=Dec

.PARAMETER Server
    The base URL for the FastBound API. Defaults to https://cloud.fastbound.com

.PARAMETER Account
    The FastBound account number

.PARAMETER ApiKey
    The API key for authentication

.PARAMETER OwnerEmail
    Email address for the X-AuditUser header (required for all write operations)

.PARAMETER WhatIf
    If specified, shows what merges would be performed without actually merging.

.PARAMETER OutputFile
    Optional path to export the merge plan/results CSV.

.EXAMPLE
    .\Merge-FFLContacts.ps1 -Account "12345" -ApiKey "your-api-key" -OwnerEmail "user@example.com" -WhatIf

.EXAMPLE
    .\Merge-FFLContacts.ps1 -Account "12345" -ApiKey "your-api-key" -OwnerEmail "user@example.com"

.NOTES
    Rate Limiting: The script dynamically tracks rate limits from API response headers.
#>

[CmdletBinding(SupportsShouldProcess)]
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
    [string]$OutputFile
)

# Script-level variables for rate limiting (updated dynamically from API response headers)
$script:RateLimitLimit = 60
$script:RateLimitRemaining = 60
$script:RateLimitReset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Statistics
$script:Stats = @{
    TotalContacts = 0
    FFLContacts = 0
    ValidFFLContacts = 0
    InvalidFFLContacts = 0
    RDSGroups = 0
    GroupsWithMultiple = 0
    MergesPlanned = 0
    MergesCompleted = 0
    MergesSkipped = 0
    MergesFailed = 0
}

# Merge log
$script:MergeLog = @()

# Progress tracking
$script:Progress = @{
    StartTime = $null
    TotalGroups = 0
    ProcessedGroups = 0
    TotalMerges = 0
    ProcessedMerges = 0
    ApiRequests = 0
}

#region Helper Functions

function Update-StatusBar {
    param(
        [string]$Phase = "Processing",
        [int]$Current = 0,
        [int]$Total = 0
    )

    # Calculate percentage
    $percent = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }

    # Calculate ETA
    $eta = "calculating..."
    if ($script:Progress.StartTime -and $Current -gt 0 -and $Total -gt 0) {
        $elapsed = (Get-Date) - $script:Progress.StartTime
        $itemsRemaining = $Total - $Current
        $secondsPerItem = $elapsed.TotalSeconds / $Current
        $secondsRemaining = $itemsRemaining * $secondsPerItem

        $hours = [int]($secondsRemaining / 3600)
        $minutes = [int](($secondsRemaining % 3600) / 60)
        $seconds = [int]($secondsRemaining % 60)

        if ($hours -gt 0) {
            $eta = "{0}h{1}m" -f $hours, $minutes
        } elseif ($minutes -gt 0) {
            $eta = "{0}m{1}s" -f $minutes, $seconds
        } else {
            $eta = "{0}s" -f $seconds
        }
    }

    # Build status line
    $status = "{0}% done ({1}/{2} {3}; {4} requests) -- ETA {5}" -f `
        $percent, $Current, $Total, $Phase, $script:Progress.ApiRequests, $eta

    # Pad to overwrite previous content
    $status = $status.PadRight(80)

    # Write to console (overwrite current line)
    Write-Host "`r$status" -NoNewline -ForegroundColor Cyan
}

function Complete-StatusBar {
    # Move to new line after status bar is done
    Write-Host ""
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
        [hashtable]$QueryParams = @{}
    )

    # Wait if we're approaching rate limit
    Wait-ForRateLimit

    # Track API request count
    $script:Progress.ApiRequests++

    # Build URL
    $url = "$Server/$Account$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $queryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $url = $url + "?" + $queryString
    }

    Write-Verbose "API Request: $Method $url"

    # Build headers
    $headers = @{
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$ApiKey"))
        "X-AuditUser" = $OwnerEmail
    }

    if ($Method -in @('POST', 'PUT', 'PATCH')) {
        $headers["Content-Type"] = "application/json"
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

        return $null
    }
    catch {
        # Check for 429 Too Many Requests
        if ($_.Exception.Response.StatusCode -eq 429) {
            Write-Warning "Rate limit exceeded (429). Waiting for reset..."

            if ($_.Exception.Response.Headers) {
                Update-RateLimitInfo -Headers $_.Exception.Response.Headers
            }

            $waitSeconds = ([DateTimeOffset]::FromUnixTimeSeconds($script:RateLimitReset) - [DateTimeOffset]::UtcNow).TotalSeconds + 1
            if ($waitSeconds -gt 0) {
                Start-Sleep -Seconds $waitSeconds
            }

            # Retry the request
            return Invoke-FastBoundApi -Method $Method -Endpoint $Endpoint -Body $Body -QueryParams $QueryParams
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
    if ($script:RateLimitRemaining -lt 5) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $waitSeconds = $script:RateLimitReset - $now + 1

        if ($waitSeconds -gt 0) {
            Write-Host "Rate limit approaching ($script:RateLimitRemaining remaining). Waiting $waitSeconds seconds for reset..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitSeconds
            $script:RateLimitRemaining = $script:RateLimitLimit
        }
    }
}

function Get-AccountOwnerFFL {
    Write-Host "Fetching account owner information..." -ForegroundColor Cyan

    $response = Invoke-FastBoundApi -Method GET -Endpoint "/api/Account"

    if ($response.owner -and $response.owner.fflNumber) {
        $ownerFFL = Get-NormalizedFFL -FFLNumber $response.owner.fflNumber
        Write-Host "Account owner FFL: $($response.owner.fflNumber) ($($response.owner.licenseName))" -ForegroundColor Green
        return $ownerFFL
    }

    Write-Host "No account owner FFL found" -ForegroundColor Yellow
    return $null
}

function Get-AllContacts {
    Write-Host "Downloading all contacts from FastBound..." -ForegroundColor Cyan

    $allContacts = @()
    $take = 100
    $skip = 0

    do {
        Write-Host "`rDownloading contacts... $($allContacts.Count) retrieved" -NoNewline -ForegroundColor Gray

        $response = Invoke-FastBoundApi -Method GET -Endpoint "/api/Contacts" -QueryParams @{
            take = $take
            skip = $skip
        }

        if ($response.contacts) {
            $contacts = $response.contacts
        }
        elseif ($response -is [Array]) {
            $contacts = $response
        }
        else {
            $contacts = @($response)
        }

        if ($contacts -and $contacts.Count -gt 0) {
            $allContacts += $contacts
            $skip += 1  # skip is number of PAGES to skip, not items
        }
        else {
            break
        }

    } while ($contacts -and $contacts.Count -ge $take)

    Write-Host ""  # Complete the inline status
    Write-Host "Downloaded $($allContacts.Count) contacts" -ForegroundColor Green

    return $allContacts
}

function Get-NormalizedFFL {
    param([string]$FFLNumber)

    if ([string]::IsNullOrWhiteSpace($FFLNumber)) {
        return $null
    }

    # Remove hyphens and normalize
    return ($FFLNumber -replace '-', '').Trim().ToUpper()
}

function Get-RDSFromFFL {
    param([string]$FFLNumber)

    $normalized = Get-NormalizedFFL -FFLNumber $FFLNumber

    if (-not $normalized -or $normalized.Length -ne 15) {
        return $null
    }

    # RDS = Region (1 digit) + District (2 digits) + Sequence (5 digits)
    # Position 0: Region
    # Positions 1-2: District
    # Positions 10-14: Sequence
    $region = $normalized.Substring(0, 1)
    $district = $normalized.Substring(1, 2)
    $sequence = $normalized.Substring(10, 5)

    return "$region$district$sequence"
}

function Get-ExpirationCodeFromFFL {
    param([string]$FFLNumber)

    $normalized = Get-NormalizedFFL -FFLNumber $FFLNumber

    if (-not $normalized -or $normalized.Length -ne 15) {
        return $null
    }

    # Positions 8-9 (0-indexed) contain the expiration code
    return $normalized.Substring(8, 2)
}

function Get-MonthFromLetter {
    param([string]$Letter)

    # Month mapping: A-M, skipping I
    # A=1, B=2, C=3, D=4, E=5, F=6, G=7, H=8, J=9, K=10, L=11, M=12
    $mapping = @{
        'A' = 1
        'B' = 2
        'C' = 3
        'D' = 4
        'E' = 5
        'F' = 6
        'G' = 7
        'H' = 8
        'J' = 9   # I is skipped
        'K' = 10
        'L' = 11
        'M' = 12
    }

    $key = [string]$Letter
    if ($mapping.ContainsKey($key)) {
        return $mapping[$key]
    }

    return $null
}

function Test-FFLExpirationValid {
    param(
        [string]$FFLNumber,
        [datetime]$ExpirationDate
    )

    $expirationCode = Get-ExpirationCodeFromFFL -FFLNumber $FFLNumber

    if (-not $expirationCode -or $expirationCode.Length -ne 2) {
        Write-Verbose "  Invalid expiration code from FFL: $FFLNumber"
        return $false
    }

    $yearDigit = $expirationCode[0]
    $monthLetter = $expirationCode[1]

    # Validate year digit is numeric
    if ($yearDigit -notmatch '^\d$') {
        Write-Verbose "  Invalid year digit '$yearDigit' in FFL: $FFLNumber"
        return $false
    }

    # Get expected month
    $expectedMonth = Get-MonthFromLetter -Letter $monthLetter

    if (-not $expectedMonth) {
        Write-Verbose "  Invalid month letter '$monthLetter' in FFL: $FFLNumber"
        return $false
    }

    # Check if expiration date matches
    $actualYearDigit = $ExpirationDate.Year % 10
    $actualMonth = $ExpirationDate.Month

    $yearMatches = [string]$yearDigit -eq [string]$actualYearDigit
    $monthMatches = $expectedMonth -eq $actualMonth

    if (-not $yearMatches) {
        Write-Verbose "  Year mismatch: FFL code '$yearDigit' vs actual '$actualYearDigit' for FFL: $FFLNumber"
    }
    if (-not $monthMatches) {
        Write-Verbose "  Month mismatch: FFL code '$monthLetter' (month $expectedMonth) vs actual month $actualMonth for FFL: $FFLNumber"
    }

    return ($yearMatches -and $monthMatches)
}

function Merge-Contacts {
    param(
        [string]$WinningContactId,
        [string]$LosingContactId
    )

    $body = @{
        winningContactId = $WinningContactId
        losingContactId = $LosingContactId
    }

    $result = Invoke-FastBoundApi -Method POST -Endpoint "/api/Contacts/Merge" -Body $body
    return $result
}

#endregion


#region Main Script

Write-Host "`n=== FastBound FFL Contact Merge ===" -ForegroundColor Cyan
Write-Host "Server: $Server"
Write-Host "Account: $Account"
Write-Host "Owner: $OwnerEmail"
if ($WhatIfPreference) {
    Write-Host "Mode: WhatIf (dry run)" -ForegroundColor Yellow
}
Write-Host ""

# Get account owner FFL (to skip merges where owner would be the winning contact, since it can't be updated via API)
try {
    $script:AccountOwnerFFL = Get-AccountOwnerFFL
}
catch {
    Write-Warning "Could not fetch account owner: $_"
    $script:AccountOwnerFFL = $null
}

# Download all contacts
try {
    $contacts = @(Get-AllContacts)
    $script:Stats.TotalContacts = $contacts.Count
}
catch {
    Write-Error "Failed to download contacts: $_"
    exit 1
}

# Filter to FFL contacts only
Write-Host "`nFiltering to FFL contacts..." -ForegroundColor Cyan
$fflContacts = @($contacts | Where-Object { $_.fflNumber })
$script:Stats.FFLContacts = $fflContacts.Count
Write-Host "Found $($fflContacts.Count) contacts with FFL numbers" -ForegroundColor Green

if ($fflContacts.Count -eq 0) {
    Write-Host "`nNo FFL contacts found. Nothing to merge." -ForegroundColor Yellow
    exit 0
}

# Group contacts by RDS
Write-Host "`nGrouping contacts by RDS..." -ForegroundColor Cyan
$rdsGroups = @{}

foreach ($contact in $fflContacts) {
    $rds = Get-RDSFromFFL -FFLNumber $contact.fflNumber

    if (-not $rds) {
        Write-Verbose "Skipping contact $($contact.id) - invalid FFL format: $($contact.fflNumber)"
        continue
    }

    if (-not $rdsGroups.ContainsKey($rds)) {
        $rdsGroups[$rds] = @()
    }

    $rdsGroups[$rds] += $contact
}

$script:Stats.RDSGroups = $rdsGroups.Count
Write-Host "Found $($rdsGroups.Count) unique RDS groups" -ForegroundColor Green

# Process each RDS group
Write-Host "`nProcessing RDS groups..." -ForegroundColor Cyan
$groupsWithMultiple = @($rdsGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
$script:Stats.GroupsWithMultiple = $groupsWithMultiple.Count

Write-Host "Groups with multiple FFLs: $($groupsWithMultiple.Count)" -ForegroundColor Yellow

# Initialize progress tracking
$script:Progress.StartTime = Get-Date
$script:Progress.TotalGroups = $groupsWithMultiple.Count
$script:Progress.ProcessedGroups = 0
$groupIndex = 0

foreach ($group in $groupsWithMultiple) {
    $groupIndex++
    $rds = $group.Key
    $groupContacts = $group.Value

    # Update status bar
    Update-StatusBar -Phase "groups" -Current $groupIndex -Total $groupsWithMultiple.Count

    Write-Host "`n--- RDS Group: $rds ($($groupContacts.Count) contacts) ---" -ForegroundColor Cyan

    # Validate each FFL's expiration and filter out invalid ones
    $validContacts = @()
    $invalidContacts = @()

    foreach ($contact in $groupContacts) {
        $expiration = $null

        # Parse expiration date
        if ($contact.fflExpires) {
            try {
                $expiration = [DateTime]::Parse($contact.fflExpires)
            }
            catch {
                Write-Verbose "  Could not parse expiration date for contact $($contact.id): $($contact.fflExpires)"
            }
        }

        if (-not $expiration) {
            Write-Host "  INVALID (no expiration): $($contact.fflNumber) - $($contact.licenseName)" -ForegroundColor Red
            $invalidContacts += $contact
            $script:Stats.InvalidFFLContacts++
            continue
        }

        # Validate expiration matches FFL code
        $isValid = Test-FFLExpirationValid -FFLNumber $contact.fflNumber -ExpirationDate $expiration

        if ($isValid) {
            Write-Host "  VALID: $($contact.fflNumber) expires $($expiration.ToString('yyyy-MM-dd')) - $($contact.licenseName)" -ForegroundColor Green
            $validContacts += [PSCustomObject]@{
                Contact = $contact
                Expiration = $expiration
            }
            $script:Stats.ValidFFLContacts++
        }
        else {
            $expirationCode = Get-ExpirationCodeFromFFL -FFLNumber $contact.fflNumber
            Write-Host "  INVALID (expiration mismatch): $($contact.fflNumber) code=$expirationCode actual=$($expiration.ToString('yyyy-MM')) - $($contact.licenseName)" -ForegroundColor Red
            $invalidContacts += $contact
            $script:Stats.InvalidFFLContacts++
        }
    }

    # Need at least 2 valid contacts to merge
    if ($validContacts.Count -lt 2) {
        Write-Host "  Skipping group - fewer than 2 valid contacts" -ForegroundColor Yellow
        continue
    }

    # Sort by expiration date (oldest first)
    $sortedContacts = $validContacts | Sort-Object { $_.Expiration }

    Write-Host "`n  Merge chain (oldest to newest):" -ForegroundColor White

    # The newest (last) contact will be the final winner
    $winner = $sortedContacts[-1]

    # Merge from oldest to newest
    # oldest → next oldest → ... → newest (winner)
    for ($i = 0; $i -lt $sortedContacts.Count - 1; $i++) {
        $loser = $sortedContacts[$i]

        $logEntry = [PSCustomObject]@{
            RDS = $rds
            WinnerFFLNumber = $winner.Contact.fflNumber
            WinnerExpiration = $winner.Expiration.ToString('yyyy-MM-dd')
            WinnerContactId = $winner.Contact.id
            WinnerLicenseName = $winner.Contact.licenseName
            LoserFFLNumber = $loser.Contact.fflNumber
            LoserExpiration = $loser.Expiration.ToString('yyyy-MM-dd')
            LoserContactId = $loser.Contact.id
            LoserLicenseName = $loser.Contact.licenseName
            Status = "Planned"
            Error = ""
        }

        Write-Host "    [$($i+1)] Merge $($loser.Contact.fflNumber) ($($loser.Expiration.ToString('yyyy-MM-dd'))) → $($winner.Contact.fflNumber) ($($winner.Expiration.ToString('yyyy-MM-dd')))" -ForegroundColor Gray

        $script:Stats.MergesPlanned++

        # Check if winner is the account owner (can't update account owner contact via API)
        $winnerNormalizedFFL = Get-NormalizedFFL -FFLNumber $winner.Contact.fflNumber
        if ($script:AccountOwnerFFL -and $winnerNormalizedFFL -eq $script:AccountOwnerFFL) {
            $logEntry.Status = "Skipped"
            $logEntry.Error = "Account Owner Contact"
            $script:Stats.MergesSkipped++
            Write-Host "        Skipped (Account Owner Contact)" -ForegroundColor Yellow
        }
        elseif (-not $WhatIfPreference) {
            try {
                Write-Host "        Executing merge..." -ForegroundColor DarkGray
                $result = Merge-Contacts -WinningContactId $winner.Contact.id -LosingContactId $loser.Contact.id
                $logEntry.Status = "Success"
                $script:Stats.MergesCompleted++
                Write-Host "        Merge completed successfully" -ForegroundColor Green
            }
            catch {
                $logEntry.Status = "Failed"
                $logEntry.Error = $_.Exception.Message
                $script:Stats.MergesFailed++
                Write-Host "        Merge FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            $logEntry.Status = "WhatIf"
        }

        $script:MergeLog += $logEntry
    }
}

# Complete status bar
Complete-StatusBar

Write-Host "`n=== Merge Summary ===" -ForegroundColor Cyan
Write-Host "Total Contacts: $($script:Stats.TotalContacts)"
Write-Host "FFL Contacts: $($script:Stats.FFLContacts)"
Write-Host "Valid FFL Contacts: $($script:Stats.ValidFFLContacts)" -ForegroundColor Green
Write-Host "Invalid FFL Contacts: $($script:Stats.InvalidFFLContacts)" -ForegroundColor $(if ($script:Stats.InvalidFFLContacts -gt 0) { "Yellow" } else { "Green" })
Write-Host "RDS Groups: $($script:Stats.RDSGroups)"
Write-Host "Groups with Multiple FFLs: $($script:Stats.GroupsWithMultiple)"
Write-Host "Merges Planned: $($script:Stats.MergesPlanned)"

if (-not $WhatIfPreference) {
    Write-Host "Merges Completed: $($script:Stats.MergesCompleted)" -ForegroundColor Green
    Write-Host "Merges Skipped: $($script:Stats.MergesSkipped)" -ForegroundColor $(if ($script:Stats.MergesSkipped -gt 0) { "Yellow" } else { "Green" })
    Write-Host "Merges Failed: $($script:Stats.MergesFailed)" -ForegroundColor $(if ($script:Stats.MergesFailed -gt 0) { "Red" } else { "Green" })
}

# Export merge log
if ($OutputFile -or $script:MergeLog.Count -gt 0) {
    $exportFile = if ($OutputFile) { $OutputFile } else { "$Account-merge-log.csv" }

    try {
        $script:MergeLog | Export-Csv -Path $exportFile -NoTypeInformation -Encoding UTF8
        Write-Host "`nMerge log exported to: $exportFile" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to export merge log: $_"
    }
}

Write-Host "`nMerge operation complete!" -ForegroundColor Cyan

#endregion
