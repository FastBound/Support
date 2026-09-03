# Copyright © FastBound Inc. All rights reserved.
#
# Reference implementation — not intended for production use without review and adaptation.
# Source: https://github.com/FastBound/Support/tree/main/samples/transfers/ruby
#
# Requires: Ruby 3.0+
# Dependencies: none — uses only stdlib (json, net/http, digest, base64)

require "json"
require "net/http"
require "uri"
require "digest"
require "base64"

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
                  po_number: nil, invoice_number: nil, acquire_type: "Purchase", note: nil,
                  idempotency_key: nil)
    key = if idempotency_key.nil?
            derive_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items)
          else
            validate_idempotency_key(idempotency_key)
          end
    {
      "$schema" => "https://schemas.fastbound.org/transfers-push-v1.json",
      "idempotency_key" => key,
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

  def self.validate_idempotency_key(key)
    raise ArgumentError, "idempotency_key must not be blank." if key.strip.empty?

    # The API caps the field at 255 characters; catching it here beats a 400 on a
    # request that has already been accepted once under a truncated key.
    if key.length > 255
      raise ArgumentError, "idempotency_key must be at most 255 characters (got #{key.length})."
    end

    key
  end
  private_class_method :validate_idempotency_key

  # Fallback for callers with no transaction id of their own to reuse.
  #
  # Reads no clock. A retry after a timeout is the case this key exists for, and a key
  # containing today's date changes at midnight — mid-afternoon in US time zones —
  # handing the retry a fresh key and creating the duplicate it was meant to stop.
  # Serials are sorted because item order carries no meaning, so a retry that
  # re-serializes from an unordered source must not read as a second shipment.
  def self.derive_idempotency_key(transferor, transferee, tracking_number, po_number, invoice_number, items)
    if to_s_or_empty(tracking_number).empty? && to_s_or_empty(po_number).empty? &&
       to_s_or_empty(invoice_number).empty?
      raise ArgumentError,
            "Cannot derive an idempotency key from the FFL numbers and serials alone: two " \
            "separate orders of the same firearms between the same parties would collide and " \
            "the second would be dropped as a duplicate. Pass idempotency_key, or supply a " \
            "tracking, PO or invoice number."
    end

    # Ordinal (byte) sort, not locale-aware, so that every language port of this sample
    # agrees on the key for the same transfer.
    serials = items.map { |i| i[:serial] }.sort
    data = canonicalize([
      transferor, transferee,
      to_s_or_empty(tracking_number), to_s_or_empty(po_number), to_s_or_empty(invoice_number),
      *serials,
    ])
    "sha256:#{Digest::SHA256.hexdigest(data)}"
  end
  private_class_method :derive_idempotency_key

  def self.to_s_or_empty(value)
    value.nil? ? "" : value.to_s
  end
  private_class_method :to_s_or_empty

  # Length-prefixes each part so no field can impersonate another.
  #
  # Concatenating with a plain separator is ambiguous when a field may contain that
  # separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
  # items and invoice_number "INV-1" with serial "ABC123" produce the same joined
  # string, so two different transfers collide on one key. Prefixing with the UTF-8
  # byte count — bytes, not characters, so ports to other languages agree — makes the
  # encoding unambiguous.
  def self.canonicalize(parts)
    parts.map { |part| "#{part.bytesize}:#{part}" }.join
  end
  private_class_method :canonicalize
end

# Only runs when this file is executed directly, so the builders above can be required
# from your own code without firing a live request.
if __FILE__ == $PROGRAM_NAME
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
    note: "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
    # Prefer your own transaction id, so a retry — even days later, from another process
    # — resolves to the same key. Bump the revision suffix when you mean to send a
    # genuinely new transfer for the same order. Omit idempotency_key entirely and one is
    # derived from the shipment's identifying fields instead.
    idempotency_key: "po-123456:rev1"
  )

  result = client.send_transfer(payload)
  puts "HTTP Code: #{result[:status_code]}"
  puts "Response: #{result[:body]}"
end
