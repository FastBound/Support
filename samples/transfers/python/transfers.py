# Copyright © FastBound Inc. All rights reserved.
#
# Reference implementation — not intended for production use without review and adaptation.
# Source: https://github.com/FastBound/Support/tree/main/samples/transfers/python
#
# Requires: Python 3.9+
# Dependencies: requests (pip install requests)

import hashlib
import json
import requests
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
               po_number=None, invoice_number=None, acquire_type="Purchase", note=None,
               idempotency_key=None):
        key = (
            FastBoundTransferPayload._derive_idempotency_key(
                transferor, transferee, tracking_number, po_number, invoice_number, items
            )
            if idempotency_key is None
            else FastBoundTransferPayload._validate_idempotency_key(idempotency_key)
        )
        return {
            "$schema": "https://schemas.fastbound.org/transfers-push-v1.json",
            "idempotency_key": key,
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
    def _validate_idempotency_key(key):
        if not key.strip():
            raise ValueError("idempotency_key must not be blank.")
        # The API caps the field at 255 characters; catching it here beats a 400 on a
        # request that has already been accepted once under a truncated key.
        if len(key) > 255:
            raise ValueError(f"idempotency_key must be at most 255 characters (got {len(key)}).")
        return key

    @staticmethod
    def _derive_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items):
        """Fallback for callers with no transaction id of their own to reuse.

        Reads no clock. A retry after a timeout is the case this key exists for, and a
        key containing today's date changes at midnight — mid-afternoon in US time zones
        — handing the retry a fresh key and creating the duplicate it was meant to stop.
        Serials are sorted because item order carries no meaning, so a retry that
        re-serializes from an unordered source must not read as a second shipment.
        """
        if not tracking_number and not po_number and not invoice_number:
            raise ValueError(
                "Cannot derive an idempotency key from the FFL numbers and serials alone: two "
                "separate orders of the same firearms between the same parties would collide and "
                "the second would be dropped as a duplicate. Pass idempotency_key, or supply a "
                "tracking, PO or invoice number."
            )
        serials = sorted(item["serial"] for item in items)
        data = _canonicalize([
            transferor,
            transferee,
            tracking_number or "",
            po_number or "",
            invoice_number or "",
            *serials,
        ])
        return "sha256:" + hashlib.sha256(data.encode()).hexdigest()


def _canonicalize(parts):
    """Length-prefixes each part so no field can impersonate another.

    Concatenating with a plain separator is ambiguous when a field may contain that
    separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
    items and invoice_number "INV-1" with serial "ABC123" produce the same joined
    string, so two different transfers collide on one key. Prefixing with the UTF-8
    byte count — bytes, not characters, so ports to other languages agree — makes the
    encoding unambiguous.
    """
    return "".join(f"{len(part.encode())}:{part}" for part in parts)


if __name__ == "__main__":
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
        # Prefer your own transaction id, so a retry — even days later, from another
        # process — resolves to the same key. Bump the revision suffix when you mean to
        # send a genuinely new transfer for the same order. Omit idempotency_key entirely
        # and one is derived from the shipment's identifying fields instead.
        idempotency_key="po-123456:rev1",
    )

    result = client.send_transfer(payload)
    print(f"HTTP Code: {result['status_code']}")
    print(f"Response: {result['body']}")
