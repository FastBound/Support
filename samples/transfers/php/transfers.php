<?php

// Authentication credentials
$username = 'YOUR_USERNAME';
$password = 'YOUR_PASSWORD';

// API endpoint
$url = 'https://cloud.fastbound.com/api/transfers';

// Set shipment date (use actual shipment date when available)
$shipmentDate = date('Y-m-d');  // YYYY-MM-DD format

// Define items with serial numbers included in details
$items = [
    [
        'manufacturer' => 'Glock',
        'importer' => null,
        'country' => 'Austria',
        'model' => 'G17',
        'caliber' => '9mm',
        'type' => 'Pistol',
        'serial' => 'ABC123456',
        'sku' => 'GLK-G17',
        'mpn' => 'G17MPN',
        'upc' => '123456789012',
        'barrelLength' => 4.48,
        'overallLength' => 8.03,
        'cost' => 500.00,
        'price' => 650.00,
        'condition' => 'New',
        'note' => 'Brand new firearm'
    ],
    [
        'manufacturer' => 'Smith & Wesson',
        'importer' => null,
        'country' => 'USA',
        'model' => 'M&P Shield',
        'caliber' => '9mm',
        'type' => 'Pistol',
        'serial' => 'XYZ987654',
        'sku' => 'S&W-SHIELD',
        'mpn' => 'SHIELDMPN',
        'upc' => '987654321098',
        'barrelLength' => 3.1,
        'overallLength' => 6.1,
        'cost' => 450.00,
        'price' => 600.00,
        'condition' => 'New',
        'note' => 'Compact pistol'
    ]
];

// Extract serial numbers from items
$serialNumbers = array_column($items, 'serial');

// Other required fields
$transferor = '1-23-456-78-9A-12345';  // Replace with actual FFL number
$transferee = '1-23-456-78-9B-54321';  // Replace with actual FFL number
$trackingNumber = '1Z999AA10123456784';  // Optional
$poNumber = 'PO123456';  // Optional
$invoiceNumber = 'INV98765';  // Optional

// Generate idempotency key based on shipment details
$idempotencyData = [
    $shipmentDate,
    $transferor,
    $transferee,
    $trackingNumber,
    $poNumber,
    $invoiceNumber,
    ...$serialNumbers  // Spread operator to include all serial numbers
];

// Create hash
$idempotencyKey = hash('sha256', implode("\n", $idempotencyData));

// Construct the JSON payload
$data = [
    '$schema' => 'https://schemas.fastbound.org/transfers-push-v1.json',
    'idempotency_key' => $idempotencyKey,
    'transferor' => $transferor,
    'transferee' => $transferee,
    'transferee_emails' => [
        'transferee@example.com',
        'transferee@example.net',
        'transferee@example.org'
    ],
    'tracking_number' => $trackingNumber,
    'po_number' => $poNumber,
    'invoice_number' => $invoiceNumber,
    'acquire_type' => 'Purchase',
    'note' => 'This is a test transfer.',
    'items' => $items
];

// Convert data to JSON
$jsonData = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);

// Initialize cURL session
$ch = curl_init($url);

// Set cURL options
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_HTTPHEADER, [
    'Content-Type: application/json',
    'Authorization: Basic ' . base64_encode("$username:$password")
]);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_POSTFIELDS, $jsonData);

// Execute cURL request
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$error = curl_error($ch);

// Close cURL session
curl_close($ch);

// Check for errors
if ($error) {
    echo "cURL Error: " . $error . "\n";
} else {
    echo "HTTP Code: " . $httpCode . "\n";
    echo "Response: " . $response . "\n";
}

?>
