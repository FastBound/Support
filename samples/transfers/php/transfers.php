<?php
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/php
//
// Requires: PHP 8.1+
// Dependencies: ext-curl, ext-json (both included in standard PHP)

// --- Demo usage ---

$username = 'YOUR_USERNAME';
$password = 'YOUR_PASSWORD';

$transferor = '1-23-456-78-9A-12345';
$transferee = '1-23-456-78-9B-54321';

$items = [
    [
        'manufacturer' => 'Glock',
        'importer' => 'Glock, Inc.',
        'country' => 'Austria',
        'model' => '17',
        'caliber' => '9X19',
        'type' => 'Pistol',
        'serial' => 'ABC123456',
        'sku' => 'GLK-G17',
        'mpn' => 'PA1750203',
        'upc' => '764503022616',
        'barrelLength' => 4.48,
        'overallLength' => 8.03,
        'cost' => 500.00,
        'price' => 650.00,
        'condition' => 'New',
        'note' => 'Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush',
    ],
    [
        'manufacturer' => 'Smith & Wesson',
        'importer' => null,
        'country' => null,
        'model' => 'M&P 9 Shield',
        'caliber' => '9MM',
        'type' => 'Pistol',
        'serial' => 'XYZ987654',
        'sku' => 'S&W-SHIELD',
        'mpn' => '10035',
        'upc' => '022188864151',
        'barrelLength' => 3.1,
        'overallLength' => 6.1,
        'cost' => 450.00,
        'price' => 600.00,
        'condition' => 'New',
        'note' => 'No thumb safety, factory case, 7rd flush and 8rd extended mags',
    ],
];

$client = new FastBoundTransferClient($username, $password);
$payload = FastBoundTransferPayload::create(
    transferor: $transferor,
    transferee: $transferee,
    items: $items,
    transfereeEmails: ['transferee@example.com'],
    trackingNumber: '1Z999AA10123456784',
    poNumber: 'PO123456',
    invoiceNumber: 'INV98765',
    acquireType: 'Purchase',
    note: '2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery',
);

$result = $client->sendTransfer($payload);
echo "HTTP Code: " . $result['status_code'] . "\n";
echo "Response: " . $result['body'] . "\n";

// --- Reusable client ---

class FastBoundTransferClient
{
    private string $apiUrl;
    private string $authHeader;

    public function __construct(string $username, string $password, string $apiUrl = 'https://cloud.fastbound.com/api/transfers')
    {
        $this->apiUrl = $apiUrl;
        $this->authHeader = 'Basic ' . base64_encode("$username:$password");
    }

    public function sendTransfer(array $payload): array
    {
        $ch = curl_init($this->apiUrl);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            'Content-Type: application/json',
            'Authorization: ' . $this->authHeader,
        ]);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($payload, JSON_UNESCAPED_SLASHES));

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);

        if ($error) {
            return ['status_code' => 0, 'body' => "cURL Error: $error"];
        }
        return ['status_code' => $httpCode, 'body' => $response];
    }
}

// --- Domain types ---

class FastBoundTransferPayload
{
    public static function create(
        string $transferor,
        string $transferee,
        array $items,
        array $transfereeEmails = [],
        ?string $trackingNumber = null,
        ?string $poNumber = null,
        ?string $invoiceNumber = null,
        string $acquireType = 'Purchase',
        ?string $note = null,
    ): array {
        $idempotencyKey = self::buildIdempotencyKey($transferor, $transferee, $trackingNumber, $poNumber, $invoiceNumber, $items);
        return [
            '$schema' => 'https://schemas.fastbound.org/transfers-push-v1.json',
            'idempotency_key' => $idempotencyKey,
            'transferor' => $transferor,
            'transferee' => $transferee,
            'transferee_emails' => $transfereeEmails,
            'tracking_number' => $trackingNumber,
            'po_number' => $poNumber,
            'invoice_number' => $invoiceNumber,
            'acquire_type' => $acquireType,
            'note' => $note,
            'items' => $items,
        ];
    }

    private static function buildIdempotencyKey(
        string $transferor, string $transferee,
        ?string $trackingNumber, ?string $poNumber, ?string $invoiceNumber,
        array $items,
    ): string {
        $parts = [
            gmdate('Y-m-d'),
            $transferor, $transferee,
            $trackingNumber ?? '', $poNumber ?? '', $invoiceNumber ?? '',
            ...array_column($items, 'serial'),
        ];
        return hash('sha256', implode("\n", $parts));
    }
}
