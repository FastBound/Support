const https = require('https');
const crypto = require('crypto');

// Authentication credentials
const USERNAME = 'YOUR_USERNAME';
const PASSWORD = 'YOUR_PASSWORD';
const API_URL = 'https://cloud.fastbound.com/api/transfers';

// Get today's date (YYYY-MM-DD format)
const shipmentDate = new Date().toISOString().split('T')[0];

// Define transfer details
const transferor = '1-23-456-78-9A-12345'; // Replace with actual FFL number
const transferee = '1-23-456-78-9B-54321'; // Replace with actual FFL number
const trackingNumber = '1Z999AA10123456784'; // Optional
const poNumber = 'PO123456'; // Optional
const invoiceNumber = 'INV98765'; // Optional

// Define items
const items = [
    createItem('Glock', null, 'Austria', 'G17', '9mm', 'Pistol', 'ABC123456', 'GLK-G17', 'G17MPN', '123456789012', 4.48, 8.03, 500.00, 650.00, 'New', 'Brand new firearm'),
    createItem('Smith & Wesson', null, 'USA', 'M&P Shield', '9mm', 'Pistol', 'XYZ987654', 'S&W-SHIELD', 'SHIELDMPN', '987654321098', 3.1, 6.1, 450.00, 600.00, 'New', 'Compact pistol')
];

// Extract serial numbers
const serialNumbers = items.map(item => item.serial);

// Generate idempotency key
const idempotencyKey = generateIdempotencyKey(shipmentDate, transferor, transferee, trackingNumber, poNumber, invoiceNumber, serialNumbers);

// Construct payload
const payload = {
    "$schema": "https://schemas.fastbound.org/transfers-push-v1.json",
    "idempotency_key": idempotencyKey,
    "transferor": transferor,
    "transferee": transferee,
    "transferee_emails": ["transferee@example.com", "transferee@example.net", "transferee@example.org"],
    "tracking_number": trackingNumber,
    "po_number": poNumber,
    "invoice_number": invoiceNumber,
    "acquire_type": "Purchase",
    "note": "This is a test transfer.",
    "items": items
};

// Convert payload to JSON
const jsonPayload = JSON.stringify(payload, null, 2);

// Send POST request
sendPostRequest(jsonPayload);

// Create an item object
function createItem(manufacturer, importer, country, model, caliber, type, serial, sku, mpn, upc, barrelLength, overallLength, cost, price, condition, note) {
    return {
        manufacturer,
        importer,
        country,
        model,
        caliber,
        type,
        serial,
        sku,
        mpn,
        upc,
        barrelLength,
        overallLength,
        cost,
        price,
        condition,
        note
    };
}

// Generate idempotency key
function generateIdempotencyKey(shipmentDate, transferor, transferee, trackingNumber, poNumber, invoiceNumber, serialNumbers) {
    const data = [
        shipmentDate,
        transferor,
        transferee,
        trackingNumber,
        poNumber,
        invoiceNumber,
        ...serialNumbers
    ].join('\n');

    return crypto.createHash('sha256').update(data).digest('hex');
}

// Send POST request
function sendPostRequest(jsonPayload) {
    const authString = Buffer.from(`${USERNAME}:${PASSWORD}`).toString('base64');
    const url = new URL(API_URL);

    const options = {
        method: 'POST',
        hostname: url.hostname,
        path: url.pathname,
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Basic ${authString}`
        }
    };

    const req = https.request(options, res => {
        let responseBody = '';
        res.on('data', chunk => responseBody += chunk);
        res.on('end', () => {
            console.log(`HTTP Code: ${res.statusCode}`);
            console.log('Response:', responseBody);
        });
    });

    req.on('error', error => {
        console.error('Error:', error);
    });

    req.write(jsonPayload);
    req.end();
}
