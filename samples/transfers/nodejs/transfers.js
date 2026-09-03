// Copyright © FastBound Inc. All rights reserved.
//
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
    create({ transferor, transferee, items, transfereeEmails = [], trackingNumber = null, poNumber = null, invoiceNumber = null, acquireType = "Purchase", note = null, idempotencyKey = undefined }) {
        const key = idempotencyKey === undefined
            ? this._deriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items)
            : this._validateIdempotencyKey(idempotencyKey);
        return {
            $schema: "https://schemas.fastbound.org/transfers-push-v1.json",
            idempotency_key: key,
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

    _validateIdempotencyKey(key) {
        if (key.trim().length === 0) {
            throw new Error("idempotencyKey must not be blank.");
        }
        // The API caps the field at 255 characters; catching it here beats a 400 on a
        // request that has already been accepted once under a truncated key.
        if (key.length > 255) {
            throw new Error(`idempotencyKey must be at most 255 characters (got ${key.length}).`);
        }
        return key;
    },

    /**
     * Fallback for callers with no transaction id of their own to reuse.
     *
     * Reads no clock. A retry after a timeout is the case this key exists for, and a
     * key containing today's date changes at midnight — mid-afternoon in US time zones
     * — handing the retry a fresh key and creating the duplicate it was meant to stop.
     * Serials are sorted because item order carries no meaning, so a retry that
     * re-serializes from an unordered source must not read as a second shipment.
     */
    _deriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items) {
        if (!trackingNumber && !poNumber && !invoiceNumber) {
            throw new Error(
                "Cannot derive an idempotency key from the FFL numbers and serials alone: two " +
                "separate orders of the same firearms between the same parties would collide and " +
                "the second would be dropped as a duplicate. Pass idempotencyKey, or supply a " +
                "tracking, PO or invoice number.",
            );
        }
        // Ordinal sort, not locale-aware, so that every language port of this sample
        // agrees on the key for the same transfer.
        const serials = items.map((i) => i.serial).sort();
        const digest = crypto.createHash("sha256")
            .update(canonicalize([
                transferor, transferee,
                trackingNumber || "", poNumber || "", invoiceNumber || "",
                ...serials,
            ]))
            .digest("hex");
        return `sha256:${digest}`;
    },
};

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
function canonicalize(parts) {
    return parts.map((part) => `${Buffer.byteLength(part, "utf8")}:${part}`).join("");
}

module.exports = { FastBoundTransferClient, FastBoundTransferPayload };

// Only runs when this file is executed directly, so the builders above can be
// require()d from your own code without firing a live request.
if (require.main === module) {
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
        // Prefer your own transaction id, so a retry — even days later, from another
        // process — resolves to the same key. Bump the revision suffix when you mean to
        // send a genuinely new transfer for the same order. Omit idempotencyKey entirely
        // and one is derived from the shipment's identifying fields instead.
        idempotencyKey: "po-123456:rev1",
    });

    client.sendTransfer(payload).then((result) => {
        console.log(`HTTP Code: ${result.statusCode}`);
        console.log(`Response: ${result.body}`);
    });
}
