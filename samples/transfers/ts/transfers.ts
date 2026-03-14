// FastBound Transfer API Sample - TypeScript (Deno / Node 22+)
//
// Run with Deno:  deno run --allow-net transfers.ts
// Run with Node:  npx tsx transfers.ts

import { createHash } from "node:crypto";

// Authentication credentials
const USERNAME = "YOUR_USERNAME";
const PASSWORD = "YOUR_PASSWORD";

// API endpoint
const URL = "https://cloud.fastbound.com/api/transfers";

interface Item {
  manufacturer: string;
  importer: string | null;
  country: string;
  model: string;
  caliber: string;
  type: string;
  serial: string;
  sku: string;
  mpn: string;
  upc: string;
  barrelLength: number;
  overallLength: number;
  cost: number;
  price: number;
  condition: string;
  note: string;
}

interface TransferPayload {
  $schema: string;
  idempotency_key: string;
  transferor: string;
  transferee: string;
  transferee_emails: string[];
  tracking_number: string;
  po_number: string;
  invoice_number: string;
  acquire_type: string;
  note: string;
  items: Item[];
}

// Set shipment date (use actual shipment date when available)
const shipmentDate = new Date().toISOString().split("T")[0]; // YYYY-MM-DD format

// Other required fields
const transferor = "1-23-456-78-9A-12345"; // Replace with actual FFL number
const transferee = "1-23-456-78-9B-54321"; // Replace with actual FFL number
const trackingNumber = "1Z999AA10123456784"; // Optional
const poNumber = "PO123456"; // Optional
const invoiceNumber = "INV98765"; // Optional

// Define items
const items: Item[] = [
  {
    manufacturer: "Glock",
    importer: null,
    country: "Austria",
    model: "G17",
    caliber: "9mm",
    type: "Pistol",
    serial: "ABC123456",
    sku: "GLK-G17",
    mpn: "G17MPN",
    upc: "123456789012",
    barrelLength: 4.48,
    overallLength: 8.03,
    cost: 500.0,
    price: 650.0,
    condition: "New",
    note: "Brand new firearm",
  },
  {
    manufacturer: "Smith & Wesson",
    importer: null,
    country: "USA",
    model: "M&P Shield",
    caliber: "9mm",
    type: "Pistol",
    serial: "XYZ987654",
    sku: "S&W-SHIELD",
    mpn: "SHIELDMPN",
    upc: "987654321098",
    barrelLength: 3.1,
    overallLength: 6.1,
    cost: 450.0,
    price: 600.0,
    condition: "New",
    note: "Compact pistol",
  },
];

// Generate idempotency key based on shipment details
const serialNumbers = items.map((item) => item.serial);
const idempotencyData = [
  shipmentDate,
  transferor,
  transferee,
  trackingNumber,
  poNumber,
  invoiceNumber,
  ...serialNumbers,
].join("\n");

const idempotencyKey = createHash("sha256")
  .update(idempotencyData)
  .digest("hex");

// Construct the payload
const payload: TransferPayload = {
  $schema: "https://schemas.fastbound.org/transfers-push-v1.json",
  idempotency_key: idempotencyKey,
  transferor,
  transferee,
  transferee_emails: [
    "transferee@example.com",
    "transferee@example.net",
    "transferee@example.org",
  ],
  tracking_number: trackingNumber,
  po_number: poNumber,
  invoice_number: invoiceNumber,
  acquire_type: "Purchase",
  note: "This is a test transfer.",
  items,
};

// Create Basic Authentication header
const auth = btoa(`${USERNAME}:${PASSWORD}`);

// Send POST request and print response
async function main() {
  const response = await fetch(URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Basic ${auth}`,
    },
    body: JSON.stringify(payload),
  });

  const responseBody = await response.text();

  console.log(`HTTP Code: ${response.status}`);
  console.log(`Response: ${responseBody}`);

  if (!response.ok) {
    process.exit(1);
  }
}

main();
