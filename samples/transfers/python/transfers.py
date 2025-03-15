import hashlib
import json
import requests
from datetime import datetime
from base64 import b64encode

# Authentication credentials
USERNAME = "YOUR_USERNAME"
PASSWORD = "YOUR_PASSWORD"

# API endpoint
URL = "https://cloud.fastbound.com/api/transfers"

# Set shipment date (use actual shipment date when available)
shipment_date = datetime.today().strftime("%Y-%m-%d")  # YYYY-MM-DD format

# Define items with serial numbers included in details
items = [
    {
        "manufacturer": "Glock",
        "importer": None,
        "country": "Austria",
        "model": "G17",
        "caliber": "9mm",
        "type": "Pistol",
        "serial": "ABC123456",
        "sku": "GLK-G17",
        "mpn": "G17MPN",
        "upc": "123456789012",
        "barrelLength": 4.48,
        "overallLength": 8.03,
        "cost": 500.00,
        "price": 650.00,
        "condition": "New",
        "note": "Brand new firearm"
    },
    {
        "manufacturer": "Smith & Wesson",
        "importer": None,
        "country": "USA",
        "model": "M&P Shield",
        "caliber": "9mm",
        "type": "Pistol",
        "serial": "XYZ987654",
        "sku": "S&W-SHIELD",
        "mpn": "SHIELDMPN",
        "upc": "987654321098",
        "barrelLength": 3.1,
        "overallLength": 6.1,
        "cost": 450.00,
        "price": 600.00,
        "condition": "New",
        "note": "Compact pistol"
    }
]

# Extract serial numbers from items
serial_numbers = [item["serial"] for item in items]

# Other required fields
transferor = "1-54-810-07-7B-25807"  # Replace with actual FFL number
transferee = "9-68-067-07-5K-99999"  # Replace with actual FFL number
tracking_number = "1Z999AA10123456784"  # Optional
po_number = "PO123456"  # Optional
invoice_number = "INV98765"  # Optional

# Generate idempotency key based on shipment details
idempotency_data = [
    shipment_date,
    transferor,
    transferee,
    tracking_number,
    po_number,
    invoice_number,
    *serial_numbers  # Expands serial numbers into the list
]

# Create hash
idempotency_key = hashlib.sha256("\n".join(idempotency_data).encode()).hexdigest()

# Construct the JSON payload
data = {
    "$schema": "https://schemas.fastbound.org/transfers-push-v1.json",
    "idempotency_key": idempotency_key,
    "transferor": transferor,
    "transferee": transferee,
    "transferee_emails": [
        "transferee@example.com",
        "transferee@example.net",
        "transferee@example.org"
    ],
    "tracking_number": tracking_number,
    "po_number": po_number,
    "invoice_number": invoice_number,
    "acquire_type": "Purchase",
    "note": "This is a test transfer.",
    "items": items
}

# Convert data to JSON
json_data = json.dumps(data, indent=2, separators=(",", ":"))

# Create Basic Authentication header
auth_header = b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()
headers = {
    "Content-Type": "application/json",
    "Authorization": f"Basic {auth_header}"
}

# Send POST request
response = requests.post(URL, headers=headers, data=json_data)

# Print response
print(f"HTTP Code: {response.status_code}")
print("Response:", response.text)
