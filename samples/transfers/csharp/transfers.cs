// Copyright © FastBound Inc. All rights reserved.
//
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/csharp
//
// Requires: .NET 8+, C# 12+
// Dependencies: none — System.Text.Json, System.Security.Cryptography, and System.Net.Http are all BCL
// C# 12 features used: primary constructors, collection expressions

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

// --- Demo usage ---

var client = new FastBoundTransferClient("YOUR_USERNAME", "YOUR_PASSWORD");

var items = new List<FastBoundTransferItem>
{
    new("Glock", "Glock, Inc.", "Austria", "17", "9X19", "Pistol", "ABC123456", "GLK-G17", "PA1750203", "764503022616", 4.48, 8.03, 500.00m, 650.00m, "New", "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush"),
    new("Smith & Wesson", null, null, "M&P 9 Shield", "9MM", "Pistol", "XYZ987654", "S&W-SHIELD", "10035", "022188864151", 3.1, 6.1, 450.00m, 600.00m, "New", "No thumb safety, factory case, 7rd flush and 8rd extended mags")
};

var payload = FastBoundTransferPayload.Create(
    transferor: "1-23-456-78-9A-12345",
    transferee: "1-23-456-78-9B-54321",
    items: items,
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
    idempotencyKey: "po-123456:rev1"
);

var result = await client.SendTransferAsync(payload);
Console.WriteLine($"HTTP Code: {result.StatusCode}");
Console.WriteLine($"Response: {result.Body}");

// --- Reusable client ---

/// <summary>
/// Sends firearm transfer payloads to the FastBound Transfers API.
/// Reuse a single instance across calls — HttpClient is not re-created per request.
/// </summary>
public class FastBoundTransferClient(string username, string password, string apiUrl = "https://cloud.fastbound.com/api/transfers")
{
    private readonly HttpClient _http = new();
    private readonly string _authHeader = "Basic " + Convert.ToBase64String(Encoding.ASCII.GetBytes($"{username}:{password}"));

    public async Task<FastBoundTransferResult> SendTransferAsync(FastBoundTransferPayload payload)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, apiUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload, TransferJsonContext.Default.FastBoundTransferPayload), Encoding.UTF8, "application/json")
        };
        request.Headers.Add("Authorization", _authHeader);

        var response = await _http.SendAsync(request);
        return new FastBoundTransferResult((int)response.StatusCode, await response.Content.ReadAsStringAsync());
    }
}

public record FastBoundTransferResult(int StatusCode, string Body)
{
    public bool IsSuccess => StatusCode is >= 200 and < 300;
}

// --- Domain types ---

public record FastBoundTransferPayload
{
    [JsonPropertyName("$schema")]
    public string Schema { get; init; } = "https://schemas.fastbound.org/transfers-push-v1.json";

    [JsonPropertyName("idempotency_key")]
    public required string IdempotencyKey { get; init; }

    [JsonPropertyName("transferor")]
    public required string Transferor { get; init; }

    [JsonPropertyName("transferee")]
    public required string Transferee { get; init; }

    [JsonPropertyName("transferee_emails")]
    public required string[] TransfereeEmails { get; init; }

    [JsonPropertyName("tracking_number")]
    public string? TrackingNumber { get; init; }

    [JsonPropertyName("po_number")]
    public string? PoNumber { get; init; }

    [JsonPropertyName("invoice_number")]
    public string? InvoiceNumber { get; init; }

    [JsonPropertyName("acquire_type")]
    public required string AcquireType { get; init; }

    [JsonPropertyName("note")]
    public string? Note { get; init; }

    [JsonPropertyName("items")]
    public required List<FastBoundTransferItem> Items { get; init; }

    /// <summary>
    /// Preferred entry point. Pass <paramref name="idempotencyKey"/> to reuse your own
    /// transaction id — the preferred form; omit it and one is derived from the
    /// shipment's identifying fields instead.
    /// </summary>
    public static FastBoundTransferPayload Create(
        string transferor, string transferee, List<FastBoundTransferItem> items,
        string[]? transfereeEmails = null, string? trackingNumber = null,
        string? poNumber = null, string? invoiceNumber = null,
        string acquireType = "Purchase", string? note = null,
        string? idempotencyKey = null) => new()
    {
        IdempotencyKey = idempotencyKey is null
            ? DeriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items)
            : ValidateIdempotencyKey(idempotencyKey),
        Transferor = transferor,
        Transferee = transferee,
        TransfereeEmails = transfereeEmails ?? [],
        TrackingNumber = trackingNumber,
        PoNumber = poNumber,
        InvoiceNumber = invoiceNumber,
        AcquireType = acquireType,
        Note = note,
        Items = items
    };

    private static string ValidateIdempotencyKey(string key)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            throw new ArgumentException("idempotencyKey must not be blank.", nameof(key));
        }

        // The API caps the field at 255 characters; catching it here beats a 400 on a
        // request that has already been accepted once under a truncated key.
        if (key.Length > 255)
        {
            throw new ArgumentException(
                $"idempotencyKey must be at most 255 characters (got {key.Length}).", nameof(key));
        }

        return key;
    }

    /// <summary>
    /// Fallback for callers with no transaction id of their own to reuse.
    /// </summary>
    /// <remarks>
    /// Reads no clock. A retry after a timeout is the case this key exists for, and a key
    /// containing today's date changes at midnight — mid-afternoon in US time zones —
    /// handing the retry a fresh key and creating the duplicate it was meant to stop.
    /// Serials are sorted because item order carries no meaning, so a retry that
    /// re-serializes from an unordered source must not read as a second shipment.
    /// </remarks>
    private static string DeriveIdempotencyKey(
        string transferor, string transferee,
        string? trackingNumber, string? poNumber, string? invoiceNumber,
        List<FastBoundTransferItem> items)
    {
        if (string.IsNullOrEmpty(trackingNumber) && string.IsNullOrEmpty(poNumber)
            && string.IsNullOrEmpty(invoiceNumber))
        {
            throw new ArgumentException(
                "Cannot derive an idempotency key from the FFL numbers and serials alone: two "
                + "separate orders of the same firearms between the same parties would collide and "
                + "the second would be dropped as a duplicate. Pass idempotencyKey, or supply a "
                + "tracking, PO or invoice number.");
        }

        // Ordinal sort, not culture-aware, so that every language port of this sample
        // agrees on the key for the same transfer.
        List<string> serials = [.. items.Select(i => i.Serial).Order(StringComparer.Ordinal)];

        string data = Canonicalize([
            transferor, transferee,
            trackingNumber ?? "", poNumber ?? "", invoiceNumber ?? "",
            .. serials
        ]);

        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(data));
        return $"sha256:{Convert.ToHexString(hash).ToLowerInvariant()}";
    }

    /// <summary>
    /// Length-prefixes each part so no field can impersonate another.
    /// </summary>
    /// <remarks>
    /// Concatenating with a plain separator is ambiguous when a field may contain that
    /// separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
    /// items and invoice_number "INV-1" with serial "ABC123" produce the same joined
    /// string, so two different transfers collide on one key. Prefixing with the UTF-8
    /// byte count — bytes, not characters, so ports to other languages agree — makes the
    /// encoding unambiguous.
    /// </remarks>
    private static string Canonicalize(IReadOnlyList<string> parts)
    {
        StringBuilder builder = new();
        foreach (string part in parts)
        {
            builder.Append(Encoding.UTF8.GetByteCount(part)).Append(':').Append(part);
        }

        return builder.ToString();
    }
}

/// <summary>
/// Represents a single firearm in a transfer.
/// Null Importer and Country indicate domestic manufacture.
/// </summary>
public record FastBoundTransferItem(
    [property: JsonPropertyName("manufacturer")] string Manufacturer,
    [property: JsonPropertyName("importer")] string? Importer,
    [property: JsonPropertyName("country")] string? Country,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("caliber")] string Caliber,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("serial")] string Serial,
    [property: JsonPropertyName("sku")] string? Sku,
    [property: JsonPropertyName("mpn")] string? Mpn,
    [property: JsonPropertyName("upc")] string? Upc,
    [property: JsonPropertyName("barrelLength")] double? BarrelLength,
    [property: JsonPropertyName("overallLength")] double? OverallLength,
    [property: JsonPropertyName("cost")] decimal? Cost,
    [property: JsonPropertyName("price")] decimal? Price,
    [property: JsonPropertyName("condition")] string? Condition,
    [property: JsonPropertyName("note")] string? Note
);

// --- Source-generated JSON serialization (supports native AOT and .NET 10 single-file execution) ---

[JsonSerializable(typeof(FastBoundTransferPayload))]
internal partial class TransferJsonContext : JsonSerializerContext;
