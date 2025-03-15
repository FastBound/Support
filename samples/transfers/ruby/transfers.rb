require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'base64'
require 'time'

# Function to generate idempotency key using SHA-256
def generate_idempotency_key(shipment_date, transferor, transferee, tracking_number, po_number, invoice_number, serial_numbers)
  data = [
    shipment_date, transferor, transferee,
    tracking_number || "", po_number || "", invoice_number || "",
    serial_numbers.join("\n")
  ].join("\n")

  Digest::SHA256.hexdigest(data)
end

# Function to send a POST request
def send_post_request(json_payload, username, password)
  uri = URI.parse("https://cloud.fastbound.com/api/transfers")
  request = Net::HTTP::Post.new(uri)
  request.content_type = "application/json"
  
  # Add Basic Authentication Header
  auth_string = Base64.strict_encode64("#{username}:#{password}")
  request["Authorization"] = "Basic #{auth_string}"
  request.body = json_payload

  # Send request
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  response = http.request(request)

  # Print response
  puts "HTTP Code: #{response.code}"
  puts "Response: #{response.body}"
end

# API Credentials (Replace with actual values)
USERNAME = 'YOUR_USERNAME'
PASSWORD = 'YOUR_PASSWORD'

# Get today's date in YYYY-MM-DD format
shipment_date = Time.now.utc.strftime('%Y-%m-%d')

# Define transfer details
transferor = "1-23-456-78-9A-12345"
transferee = "1-23-456-78-9B-54321"
tracking_number = "1Z999AA10123456784"
po_number = "PO123456"
invoice_number = "INV98765"

# Define items
items = [
  {
    manufacturer: "Glock",
    importer: nil,
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
    cost: 500.00,
    price: 650.00,
    condition: "New",
    note: "Brand new firearm"
  },
  {
    manufacturer: "Smith & Wesson",
    importer: nil,
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
    cost: 450.00,
    price: 600.00,
    condition: "New",
    note: "Compact pistol"
  }
]

# Extract serial numbers from items
serial_numbers = items.map { |item| item[:serial] }

# Generate idempotency key
idempotency_key = generate_idempotency_key(
  shipment_date, transferor, transferee, tracking_number, po_number, invoice_number, serial_numbers
)

# Construct payload
payload = {
  "$schema" => "https://schemas.fastbound.org/transfers-push-v1.json",
  "idempotency_key" => idempotency_key,
  "transferor" => transferor,
  "transferee" => transferee,
  "transferee_emails" => ["transferee@example.com", "transferee@example.net", "transferee@example.org"],
  "tracking_number" => tracking_number,
  "po_number" => po_number,
  "invoice_number" => invoice_number,
  "acquire_type" => "Purchase",
  "note" => "This is a test transfer.",
  "items" => items
}

# Convert payload to JSON
json_payload = JSON.generate(payload)

# Send POST request
send_post_request(json_payload, USERNAME, PASSWORD)
