# FastBound Transfer API Sample - PowerShell
#
# Run: pwsh transfers.ps1

# Authentication credentials
$Username = "YOUR_USERNAME"
$Password = "YOUR_PASSWORD"

# API endpoint
$Url = "https://cloud.fastbound.com/api/transfers"

# Set shipment date (use actual shipment date when available)
$ShipmentDate = (Get-Date -Format "yyyy-MM-dd")

# Other required fields
$Transferor = "1-54-810-07-7B-25807"   # Replace with actual FFL number
$Transferee = "9-68-067-07-5K-99999"   # Replace with actual FFL number
$TrackingNumber = "1Z999AA10123456784"  # Optional
$PoNumber = "PO123456"                  # Optional
$InvoiceNumber = "INV98765"             # Optional

# Define items
$Items = @(
    @{
        manufacturer  = "Glock"
        importer      = $null
        country       = "Austria"
        model         = "G17"
        caliber       = "9mm"
        type          = "Pistol"
        serial        = "ABC123456"
        sku           = "GLK-G17"
        mpn           = "G17MPN"
        upc           = "123456789012"
        barrelLength  = 4.48
        overallLength = 8.03
        cost          = 500.00
        price         = 650.00
        condition     = "New"
        note          = "Brand new firearm"
    },
    @{
        manufacturer  = "Smith & Wesson"
        importer      = $null
        country       = "USA"
        model         = "M&P Shield"
        caliber       = "9mm"
        type          = "Pistol"
        serial        = "XYZ987654"
        sku           = "S&W-SHIELD"
        mpn           = "SHIELDMPN"
        upc           = "987654321098"
        barrelLength  = 3.1
        overallLength = 6.1
        cost          = 450.00
        price         = 600.00
        condition     = "New"
        note          = "Compact pistol"
    }
)

# Extract serial numbers
$SerialNumbers = $Items | ForEach-Object { $_.serial }

# Generate idempotency key based on shipment details
$IdempotencyParts = @(
    $ShipmentDate, $Transferor, $Transferee,
    $TrackingNumber, $PoNumber, $InvoiceNumber
) + $SerialNumbers

$IdempotencyData = $IdempotencyParts -join "`n"
$Sha256 = [System.Security.Cryptography.SHA256]::Create()
$HashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($IdempotencyData))
$IdempotencyKey = ($HashBytes | ForEach-Object { $_.ToString("x2") }) -join ""

# Construct the payload
$Payload = [ordered]@{
    '$schema'         = "https://schemas.fastbound.org/transfers-push-v1.json"
    idempotency_key   = $IdempotencyKey
    transferor        = $Transferor
    transferee        = $Transferee
    transferee_emails = @(
        "transferee@example.com",
        "transferee@example.net",
        "transferee@example.org"
    )
    tracking_number   = $TrackingNumber
    po_number         = $PoNumber
    invoice_number    = $InvoiceNumber
    acquire_type      = "Purchase"
    note              = "This is a test transfer."
    items             = $Items
}

$JsonData = $Payload | ConvertTo-Json -Depth 10

# Create Basic Authentication header
$AuthBytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
$AuthHeader = [System.Convert]::ToBase64String($AuthBytes)

$Headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Basic $AuthHeader"
}

# Send POST request
try {
    $Response = Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers -Body $JsonData -UseBasicParsing
    Write-Host "HTTP Code: $($Response.StatusCode)"
    Write-Host "Response: $($Response.Content)"
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    $ErrorBody = $_.ErrorDetails.Message
    Write-Host "HTTP Code: $StatusCode"
    Write-Host "Response: $ErrorBody"
}
