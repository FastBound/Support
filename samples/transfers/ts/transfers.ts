// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/ts
//
// Requires: Deno 1.28+ or Node.js 22+ (with --experimental-strip-types or tsx)
// Dependencies: none — uses built-in fetch, crypto, and btoa

import { createHash } from "node:crypto";

// --- Domain types ---

interface FastBoundTransferItem {
  manufacturer: string;
  importer: string | null;
  country: string | null;
  model: string;
  caliber: string;
  type: string;
  serial: string;
  sku: string | null;
  mpn: string | null;
  upc: string | null;
  barrelLength: number | null;
  overallLength: number | null;
  cost: number | null;
  price: number | null;
  condition: string | null;
  note: string | null;
}

interface FastBoundTransferPayloadData {
  $schema: string;
  idempotency_key: string;
  transferor: string;
  transferee: string;
  transferee_emails: string[];
  tracking_number: string | null;
  po_number: string | null;
  invoice_number: string | null;
  acquire_type: string;
  note: string | null;
  items: FastBoundTransferItem[];
}

class FastBoundTransferPayload {
  static create({
    transferor,
    transferee,
    items,
    transfereeEmails = [],
    trackingNumber = null,
    poNumber = null,
    invoiceNumber = null,
    acquireType = "Purchase",
    note = null,
  }: {
    transferor: string;
    transferee: string;
    items: FastBoundTransferItem[];
    transfereeEmails?: string[];
    trackingNumber?: string | null;
    poNumber?: string | null;
    invoiceNumber?: string | null;
    acquireType?: string;
    note?: string | null;
  }): FastBoundTransferPayloadData {
    const idempotencyKey = FastBoundTransferPayload.buildIdempotencyKey(
      transferor, transferee, trackingNumber, poNumber, invoiceNumber, items,
    );
    return {
      $schema: "https://schemas.fastbound.org/transfers-push-v1.json",
      idempotency_key: idempotencyKey,
      transferor,
      transferee,
      transferee_emails: transfereeEmails,
      tracking_number: trackingNumber,
      po_number: poNumber,
      invoice_number: invoiceNumber,
      acquire_type: acquireType,
      note,
      items,
    };
  }

  private static buildIdempotencyKey(
    transferor: string, transferee: string,
    trackingNumber: string | null | undefined, poNumber: string | null | undefined,
    invoiceNumber: string | null | undefined, items: FastBoundTransferItem[],
  ): string {
    const data = [
      new Date().toISOString().split("T")[0],
      transferor, transferee,
      trackingNumber ?? "", poNumber ?? "", invoiceNumber ?? "",
      ...items.map((i) => i.serial),
    ].join("\n");
    return createHash("sha256").update(data).digest("hex");
  }
}

// --- Reusable client ---

class FastBoundTransferClient {
  private readonly authHeader: string;

  constructor(
    username: string,
    password: string,
    private readonly apiUrl: string = "https://cloud.fastbound.com/api/transfers",
  ) {
    this.authHeader = "Basic " + btoa(`${username}:${password}`);
  }

  async sendTransfer(payload: FastBoundTransferPayloadData): Promise<{ statusCode: number; body: string }> {
    const response = await fetch(this.apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: this.authHeader,
      },
      body: JSON.stringify(payload),
    });
    return { statusCode: response.status, body: await response.text() };
  }
}

// --- Demo usage ---

const USERNAME = "YOUR_USERNAME";
const PASSWORD = "YOUR_PASSWORD";

const transferor = "1-23-456-78-9A-12345";
const transferee = "1-23-456-78-9B-54321";

const items: FastBoundTransferItem[] = [
  {
    manufacturer: "Glock",
    importer: "Glock, Inc.",
    country: "Austria",
    model: "17",
    caliber: "9X19",
    type: "Pistol",
    serial: "ABC123456",
    sku: "GLK-G17",
    mpn: "PA1750203",
    upc: "764503022616",
    barrelLength: 4.48,
    overallLength: 8.03,
    cost: 500.0,
    price: 650.0,
    condition: "New",
    note: "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush",
  },
  {
    manufacturer: "Smith & Wesson",
    importer: null,
    country: null,
    model: "M&P 9 Shield",
    caliber: "9MM",
    type: "Pistol",
    serial: "XYZ987654",
    sku: "S&W-SHIELD",
    mpn: "10035",
    upc: "022188864151",
    barrelLength: 3.1,
    overallLength: 6.1,
    cost: 450.0,
    price: 600.0,
    condition: "New",
    note: "No thumb safety, factory case, 7rd flush and 8rd extended mags",
  },
];

const client = new FastBoundTransferClient(USERNAME, PASSWORD);
const payload = FastBoundTransferPayload.create({
  transferor,
  transferee,
  items,
  transfereeEmails: ["transferee@example.com"],
  trackingNumber: "1Z999AA10123456784",
  poNumber: "PO123456",
  invoiceNumber: "INV98765",
  acquireType: "Purchase",
  note: "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
});

const result = await client.sendTransfer(payload);
console.log(`HTTP Code: ${result.statusCode}`);
console.log(`Response: ${result.body}`);

if (result.statusCode < 200 || result.statusCode >= 300) {
  process.exit(1);
}
