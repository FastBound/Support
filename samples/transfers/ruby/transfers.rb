# Reference implementation — not intended for production use without review and adaptation.
# Source: https://github.com/FastBound/Support/tree/main/samples/transfers/ruby
#
# Requires: Ruby 3.0+
# Dependencies: none — uses only stdlib (json, net/http, digest, base64, time)

require "json"
require "net/http"
require "uri"
require "digest"
require "base64"
require "time"

# --- Reusable client ---

class FastBoundTransferClient
  def initialize(username, password, api_url = "https://cloud.fastbound.com/api/transfers")
    @api_url = api_url
    @auth_header = "Basic " + Base64.strict_encode64("#{username}:#{password}")
  end

  def send_transfer(payload)
    uri = URI.parse(@api_url)
    request = Net::HTTP::Post.new(uri)
    request.content_type = "application/json"
    request["Authorization"] = @auth_header
    request.body = JSON.generate(payload)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    response = http.request(request)

    { status_code: response.code.to_i, body: response.body }
  end
end

# --- Domain types ---

class FastBoundTransferPayload
  def self.create(transferor:, transferee:, items:, transferee_emails: [], tracking_number: nil,
                  po_number: nil, invoice_number: nil, acquire_type: "Purchase", note: nil)
    idempotency_key = build_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items)
    {
      "$schema" => "https://schemas.fastbound.org/transfers-push-v1.json",
      "idempotency_key" => idempotency_key,
      "transferor" => transferor,
      "transferee" => transferee,
      "transferee_emails" => transferee_emails,
      "tracking_number" => tracking_number,
      "po_number" => po_number,
      "invoice_number" => invoice_number,
      "acquire_type" => acquire_type,
      "note" => note,
      "items" => items,
    }
  end

  def self.build_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items)
    parts = [
      Time.now.utc.strftime("%Y-%m-%d"),
      transferor, transferee,
      tracking_number.to_s, po_number.to_s, invoice_number.to_s,
      *items.map { |i| i[:serial] },
    ]
    Digest::SHA256.hexdigest(parts.join("\n"))
  end
  private_class_method :build_idempotency_key
end

# --- Demo usage ---

USERNAME = "YOUR_USERNAME"
PASSWORD = "YOUR_PASSWORD"

transferor = "1-23-456-78-9A-12345"
transferee = "1-23-456-78-9B-54321"

items = [
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
    cost: 500.00,
    price: 650.00,
    condition: "New",
    note: "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush",
  },
  {
    manufacturer: "Smith & Wesson",
    importer: nil,
    country: nil,
    model: "M&P 9 Shield",
    caliber: "9MM",
    type: "Pistol",
    serial: "XYZ987654",
    sku: "S&W-SHIELD",
    mpn: "10035",
    upc: "022188864151",
    barrelLength: 3.1,
    overallLength: 6.1,
    cost: 450.00,
    price: 600.00,
    condition: "New",
    note: "No thumb safety, factory case, 7rd flush and 8rd extended mags",
  },
]

client = FastBoundTransferClient.new(USERNAME, PASSWORD)
payload = FastBoundTransferPayload.create(
  transferor: transferor,
  transferee: transferee,
  items: items,
  transferee_emails: ["transferee@example.com"],
  tracking_number: "1Z999AA10123456784",
  po_number: "PO123456",
  invoice_number: "INV98765",
  acquire_type: "Purchase",
  note: "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery"
)

result = client.send_transfer(payload)
puts "HTTP Code: #{result[:status_code]}"
puts "Response: #{result[:body]}"
