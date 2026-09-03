# Copyright © FastBound Inc. All rights reserved.
#
# Reference implementation — not intended for production use without review and adaptation.
# Source: https://github.com/FastBound/Support/tree/main/samples/transfers/powershell
#
# Requires: PowerShell 7+
# Dependencies: none

# --- Reusable client ---

function New-FastBoundTransferClient {
    param(
        [string]$Username,
        [string]$Password,
        [string]$ApiUrl = "https://cloud.fastbound.com/api/transfers"
    )
    $AuthBytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
    $AuthHeader = [System.Convert]::ToBase64String($AuthBytes)
    return @{
        ApiUrl     = $ApiUrl
        AuthHeader = "Basic $AuthHeader"
    }
}

function Send-FastBoundTransfer {
    param(
        [hashtable]$Client,
        [hashtable]$Payload
    )
    $JsonData = $Payload | ConvertTo-Json -Depth 10
    $Headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = $Client.AuthHeader
    }
    try {
        $Response = Invoke-WebRequest -Uri $Client.ApiUrl -Method Post -Headers $Headers -Body $JsonData -UseBasicParsing
        return @{ StatusCode = $Response.StatusCode; Body = $Response.Content }
    } catch {
        $StatusCode = $_.Exception.Response.StatusCode.value__
        $ErrorBody = $_.ErrorDetails.Message
        return @{ StatusCode = $StatusCode; Body = $ErrorBody }
    }
}

# --- Domain types ---

function Test-FastBoundIdempotencyKey {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "IdempotencyKey must not be blank."
    }
    # The API caps the field at 255 characters; catching it here beats a 400 on a request
    # that has already been accepted once under a truncated key.
    if ($Key.Length -gt 255) {
        throw "IdempotencyKey must be at most 255 characters (got $($Key.Length))."
    }

    return $Key
}

# Length-prefixes each part so no field can impersonate another.
#
# Concatenating with a plain separator is ambiguous when a field may contain that
# separator and the tail is variable-length: invoice_number "INV-1`nABC123" with no items
# and invoice_number "INV-1" with serial "ABC123" produce the same joined string, so two
# different transfers collide on one key. Prefixing with the UTF-8 byte count — bytes, not
# characters, so ports to other languages agree — makes the encoding unambiguous.
function ConvertTo-FastBoundCanonicalString {
    param([string[]]$Parts)

    $Builder = [System.Text.StringBuilder]::new()
    foreach ($Part in $Parts) {
        $ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($Part)
        [void]$Builder.Append($ByteCount).Append(':').Append($Part)
    }

    return $Builder.ToString()
}

# Fallback for callers with no transaction id of their own to reuse.
#
# Reads no clock. A retry after a timeout is the case this key exists for, and a key
# containing today's date changes at midnight — mid-afternoon in US time zones — handing
# the retry a fresh key and creating the duplicate it was meant to stop. Serials are
# sorted because item order carries no meaning, so a retry that re-serializes from an
# unordered source must not read as a second shipment.
function Get-FastBoundDerivedIdempotencyKey {
    param(
        [string]$Transferor,
        [string]$Transferee,
        [string]$TrackingNumber,
        [string]$PoNumber,
        [string]$InvoiceNumber,
        [array]$Items
    )

    if ([string]::IsNullOrEmpty($TrackingNumber) -and [string]::IsNullOrEmpty($PoNumber) `
            -and [string]::IsNullOrEmpty($InvoiceNumber)) {
        throw ("Cannot derive an idempotency key from the FFL numbers and serials alone: two " +
            "separate orders of the same firearms between the same parties would collide and " +
            "the second would be dropped as a duplicate. Pass IdempotencyKey, or supply a " +
            "tracking, PO or invoice number.")
    }

    $Serials = [System.Collections.Generic.List[string]]::new()
    foreach ($Item in $Items) {
        $Serials.Add([string]$Item.serial)
    }
    # Ordinal sort rather than Sort-Object, which is culture-aware, so that every language
    # port of this sample agrees on the key for the same transfer.
    $Serials.Sort([System.StringComparer]::Ordinal)

    $Parts = @($Transferor, $Transferee, $TrackingNumber, $PoNumber, $InvoiceNumber) + $Serials
    $Data = ConvertTo-FastBoundCanonicalString -Parts $Parts

    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $HashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    } finally {
        $Sha256.Dispose()
    }

    return "sha256:" + (($HashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function New-FastBoundTransferPayload {
    param(
        [string]$Transferor,
        [string]$Transferee,
        [array]$Items,
        [string[]]$TransfereeEmails = @(),
        [string]$TrackingNumber = $null,
        [string]$PoNumber = $null,
        [string]$InvoiceNumber = $null,
        [string]$AcquireType = "Purchase",
        [string]$Note = $null,
        # Pass your own transaction id — the preferred form; leave it unset and one is
        # derived from the shipment's identifying fields instead.
        [string]$IdempotencyKey = $null
    )

    $Key = if ([string]::IsNullOrEmpty($IdempotencyKey)) {
        Get-FastBoundDerivedIdempotencyKey `
            -Transferor $Transferor -Transferee $Transferee `
            -TrackingNumber $TrackingNumber -PoNumber $PoNumber `
            -InvoiceNumber $InvoiceNumber -Items $Items
    } else {
        Test-FastBoundIdempotencyKey -Key $IdempotencyKey
    }

    return [ordered]@{
        '$schema'         = "https://schemas.fastbound.org/transfers-push-v1.json"
        idempotency_key   = $Key
        transferor        = $Transferor
        transferee        = $Transferee
        transferee_emails = $TransfereeEmails
        tracking_number   = $TrackingNumber
        po_number         = $PoNumber
        invoice_number    = $InvoiceNumber
        acquire_type      = $AcquireType
        note              = $Note
        items             = $Items
    }
}

# Only runs when this file is executed rather than dot-sourced, so the functions above
# can be loaded into your own script without firing a live request.
if ($MyInvocation.InvocationName -ne '.') {
    # --- Demo usage ---

    $Username = "YOUR_USERNAME"
    $Password = "YOUR_PASSWORD"

    $Transferor = "1-23-456-78-9A-12345"
    $Transferee = "1-23-456-78-9B-54321"

    $Items = @(
        @{
            manufacturer  = "Glock"
            importer      = "Glock, Inc."
            country       = "Austria"
            model         = "17"
            caliber       = "9X19"
            type          = "Pistol"
            serial        = "ABC123456"
            sku           = "GLK-G17"
            mpn           = "PA1750203"
            upc           = "764503022616"
            barrelLength  = 4.48
            overallLength = 8.03
            cost          = 500.00
            price         = 650.00
            condition     = "New"
            note          = "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush"
        },
        @{
            manufacturer  = "Smith & Wesson"
            importer      = $null
            country       = $null
            model         = "M&P 9 Shield"
            caliber       = "9MM"
            type          = "Pistol"
            serial        = "XYZ987654"
            sku           = "S&W-SHIELD"
            mpn           = "10035"
            upc           = "022188864151"
            barrelLength  = 3.1
            overallLength = 6.1
            cost          = 450.00
            price         = 600.00
            condition     = "New"
            note          = "No thumb safety, factory case, 7rd flush and 8rd extended mags"
        }
    )

    $Client = New-FastBoundTransferClient -Username $Username -Password $Password
    $Payload = New-FastBoundTransferPayload `
        -Transferor $Transferor `
        -Transferee $Transferee `
        -Items $Items `
        -TransfereeEmails @("transferee@example.com") `
        -TrackingNumber "1Z999AA10123456784" `
        -PoNumber "PO123456" `
        -InvoiceNumber "INV98765" `
        -AcquireType "Purchase" `
        -Note "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery" `
        -IdempotencyKey "po-123456:rev1"

    $Result = Send-FastBoundTransfer -Client $Client -Payload $Payload
    Write-Host "HTTP Code: $($Result.StatusCode)"
    Write-Host "Response: $($Result.Body)"
}
