// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/nodejs
//
// Requires: Node.js 18+
// Dependencies: none — uses built-in https, crypto, and Buffer

const https = require("https");
const crypto = require("crypto");

// --- Reusable client ---

function FastBoundTransferClient(username, password, apiUrl) {
    const url = new URL(apiUrl || "https://cloud.fastbound.com/api/transfers");
    const authHeader = "Basic " + Buffer.from(`${username}:${password}`).toString("base64");

    this.sendTransfer = function (payload) {
        return new Promise((resolve, reject) => {
            const body = JSON.stringify(payload);
            const options = {
                method: "POST",
                hostname: url.hostname,
                path: url.pathname,
                headers: {
                    "Content-Type": "application/json",
                    Authorization: authHeader,
                },
            };

            const req = https.request(options, (res) => {
                let responseBody = "";
                res.on("data", (chunk) => (responseBody += chunk));
                res.on("end", () => resolve({ statusCode: res.statusCode, body: responseBody }));
            });

            req.on("error", reject);
            req.write(body);
            req.end();
        });
    };
}

// --- Domain types ---

const FastBoundTransferPayload = {
    create({ transferor, transferee, items, transfereeEmails = [], trackingNumber = null, poNumber = null, invoiceNumber = null, acquireType = "Purchase", note = null }) {
        const idempotencyKey = this._buildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items);
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
    },

    _buildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items) {
        const data = [
            new Date().toISOString().split("T")[0],
            transferor, transferee,
            trackingNumber || "", poNumber || "", invoiceNumber || "",
            ...items.map((i) => i.serial),
        ].join("\n");
        return crypto.createHash("sha256").update(data).digest("hex");
    },
};

// --- Demo usage ---

const USERNAME = "YOUR_USERNAME";
const PASSWORD = "YOUR_PASSWORD";

const transferor = "1-23-456-78-9A-12345";
const transferee = "1-23-456-78-9B-54321";

const items = [
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

client.sendTransfer(payload).then((result) => {
    console.log(`HTTP Code: ${result.statusCode}`);
    console.log(`Response: ${result.body}`);
});
