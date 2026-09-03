<?php
// Copyright © FastBound Inc. All rights reserved.
//
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/php
//
// Requires: PHP 8.1+
// Dependencies: ext-curl, ext-json (both included in standard PHP)

// Only runs when this file is the entry script, so the builders below can be
// include()d from your own code without firing a live request.
if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
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
        // Prefer your own transaction id, so a retry — even days later, from another
        // process — resolves to the same key. Bump the revision suffix when you mean to
        // send a genuinely new transfer for the same order. Omit idempotencyKey entirely
        // and one is derived from the shipment's identifying fields instead.
        idempotencyKey: 'po-123456:rev1',
    );

    $result = $client->sendTransfer($payload);
    echo "HTTP Code: " . $result['status_code'] . "\n";
    echo "Response: " . $result['body'] . "\n";
}

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
        ?string $idempotencyKey = null,
    ): array {
        $key = $idempotencyKey === null
            ? self::deriveIdempotencyKey($transferor, $transferee, $trackingNumber, $poNumber, $invoiceNumber, $items)
            : self::validateIdempotencyKey($idempotencyKey);
        return [
            '$schema' => 'https://schemas.fastbound.org/transfers-push-v1.json',
            'idempotency_key' => $key,
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

    private static function validateIdempotencyKey(string $key): string
    {
        if (trim($key) === '') {
            throw new InvalidArgumentException('idempotencyKey must not be blank.');
        }
        // The API caps the field at 255 characters; catching it here beats a 400 on a
        // request that has already been accepted once under a truncated key.
        if (mb_strlen($key) > 255) {
            throw new InvalidArgumentException(
                sprintf('idempotencyKey must be at most 255 characters (got %d).', mb_strlen($key)),
            );
        }
        return $key;
    }

    /**
     * Fallback for callers with no transaction id of their own to reuse.
     *
     * Reads no clock. A retry after a timeout is the case this key exists for, and a
     * key containing today's date changes at midnight — mid-afternoon in US time zones
     * — handing the retry a fresh key and creating the duplicate it was meant to stop.
     * Serials are sorted because item order carries no meaning, so a retry that
     * re-serializes from an unordered source must not read as a second shipment.
     */
    private static function deriveIdempotencyKey(
        string $transferor, string $transferee,
        ?string $trackingNumber, ?string $poNumber, ?string $invoiceNumber,
        array $items,
    ): string {
        if (($trackingNumber ?? '') === '' && ($poNumber ?? '') === '' && ($invoiceNumber ?? '') === '') {
            throw new InvalidArgumentException(
                'Cannot derive an idempotency key from the FFL numbers and serials alone: two '
                . 'separate orders of the same firearms between the same parties would collide and '
                . 'the second would be dropped as a duplicate. Pass idempotencyKey, or supply a '
                . 'tracking, PO or invoice number.',
            );
        }
        $serials = array_column($items, 'serial');
        // Ordinal (byte) sort, not locale-aware, so that every language port of this
        // sample agrees on the key for the same transfer.
        sort($serials, SORT_STRING);
        $data = self::canonicalize([
            $transferor, $transferee,
            $trackingNumber ?? '', $poNumber ?? '', $invoiceNumber ?? '',
            ...$serials,
        ]);
        return 'sha256:' . hash('sha256', $data);
    }

    /**
     * Length-prefixes each part so no field can impersonate another.
     *
     * Concatenating with a plain separator is ambiguous when a field may contain that
     * separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
     * items and invoice_number "INV-1" with serial "ABC123" produce the same joined
     * string, so two different transfers collide on one key. Prefixing with the UTF-8
     * byte count — bytes, not characters, so ports to other languages agree — makes the
     * encoding unambiguous.
     */
    private static function canonicalize(array $parts): string
    {
        $encoded = array_map(static fn (string $part): string => strlen($part) . ':' . $part, $parts);
        return implode('', $encoded);
    }
}
