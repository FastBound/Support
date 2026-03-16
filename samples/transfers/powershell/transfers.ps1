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
        [string]$Note = $null
    )

    $SerialNumbers = $Items | ForEach-Object { $_.serial }
    $IdempotencyParts = @(
        (Get-Date -Format "yyyy-MM-dd"),
        $Transferor, $Transferee,
        ($TrackingNumber ?? ""), ($PoNumber ?? ""), ($InvoiceNumber ?? "")
    ) + @($SerialNumbers)

    $IdempotencyData = $IdempotencyParts -join "`n"
    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($IdempotencyData))
    $IdempotencyKey = ($HashBytes | ForEach-Object { $_.ToString("x2") }) -join ""

    return [ordered]@{
        '$schema'         = "https://schemas.fastbound.org/transfers-push-v1.json"
        idempotency_key   = $IdempotencyKey
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
    -Note "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery"

$Result = Send-FastBoundTransfer -Client $Client -Payload $Payload
Write-Host "HTTP Code: $($Result.StatusCode)"
Write-Host "Response: $($Result.Body)"
