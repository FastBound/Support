# Reference implementation — not intended for production use without review and adaptation.
# Source: https://github.com/FastBound/Support/tree/main/samples/transfers/python
#
# Requires: Python 3.9+
# Dependencies: requests (pip install requests)

import hashlib
import json
import requests
from datetime import datetime, timezone
from base64 import b64encode

# --- Reusable client ---


class FastBoundTransferClient:
    """Sends firearm transfer payloads to the FastBound Transfers API."""

    def __init__(self, username, password, api_url="https://cloud.fastbound.com/api/transfers"):
        self.api_url = api_url
        self.auth_header = "Basic " + b64encode(f"{username}:{password}".encode()).decode()

    def send_transfer(self, payload):
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.auth_header,
        }
        response = requests.post(self.api_url, headers=headers, data=json.dumps(payload, separators=(",", ":")))
        return {"status_code": response.status_code, "body": response.text}


# --- Domain types ---


class FastBoundTransferPayload:
    """Builds a transfer payload with automatic idempotency key generation."""

    @staticmethod
    def create(transferor, transferee, items, transferee_emails=None, tracking_number=None,
               po_number=None, invoice_number=None, acquire_type="Purchase", note=None):
        idempotency_key = FastBoundTransferPayload._build_idempotency_key(
            transferor, transferee, tracking_number, po_number, invoice_number, items
        )
        return {
            "$schema": "https://schemas.fastbound.org/transfers-push-v1.json",
            "idempotency_key": idempotency_key,
            "transferor": transferor,
            "transferee": transferee,
            "transferee_emails": transferee_emails or [],
            "tracking_number": tracking_number,
            "po_number": po_number,
            "invoice_number": invoice_number,
            "acquire_type": acquire_type,
            "note": note,
            "items": items,
        }

    @staticmethod
    def _build_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items):
        parts = [
            datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            transferor,
            transferee,
            tracking_number or "",
            po_number or "",
            invoice_number or "",
            *[item["serial"] for item in items],
        ]
        return hashlib.sha256("\n".join(parts).encode()).hexdigest()


# --- Demo usage ---

USERNAME = "YOUR_USERNAME"
PASSWORD = "YOUR_PASSWORD"

transferor = "1-23-456-78-9A-12345"
transferee = "1-23-456-78-9B-54321"

items = [
    {
        "manufacturer": "Glock",
        "importer": "Glock, Inc.",
        "country": "Austria",
        "model": "17",
        "caliber": "9X19",
        "type": "Pistol",
        "serial": "ABC123456",
        "sku": "GLK-G17",
        "mpn": "PA1750203",
        "upc": "764503022616",
        "barrelLength": 4.48,
        "overallLength": 8.03,
        "cost": 500.00,
        "price": 650.00,
        "condition": "New",
        "note": "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush",
    },
    {
        "manufacturer": "Smith & Wesson",
        "importer": None,
        "country": None,
        "model": "M&P 9 Shield",
        "caliber": "9MM",
        "type": "Pistol",
        "serial": "XYZ987654",
        "sku": "S&W-SHIELD",
        "mpn": "10035",
        "upc": "022188864151",
        "barrelLength": 3.1,
        "overallLength": 6.1,
        "cost": 450.00,
        "price": 600.00,
        "condition": "New",
        "note": "No thumb safety, factory case, 7rd flush and 8rd extended mags",
    },
]

client = FastBoundTransferClient(USERNAME, PASSWORD)
payload = FastBoundTransferPayload.create(
    transferor=transferor,
    transferee=transferee,
    items=items,
    transferee_emails=["transferee@example.com"],
    tracking_number="1Z999AA10123456784",
    po_number="PO123456",
    invoice_number="INV98765",
    acquire_type="Purchase",
    note="2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
)

result = client.send_transfer(payload)
print(f"HTTP Code: {result['status_code']}")
print(f"Response: {result['body']}")
