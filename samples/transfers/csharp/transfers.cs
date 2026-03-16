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
    note: "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery"
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

    [JsonPropertyName("Idempotency_Key")]
    public required string IdempotencyKey { get; init; }

    [JsonPropertyName("Transferor")]
    public required string Transferor { get; init; }

    [JsonPropertyName("Transferee")]
    public required string Transferee { get; init; }

    [JsonPropertyName("Transferee_Emails")]
    public required string[] TransfereeEmails { get; init; }

    [JsonPropertyName("Tracking_Number")]
    public string? TrackingNumber { get; init; }

    [JsonPropertyName("Po_Number")]
    public string? PoNumber { get; init; }

    [JsonPropertyName("Invoice_Number")]
    public string? InvoiceNumber { get; init; }

    [JsonPropertyName("Acquire_Type")]
    public required string AcquireType { get; init; }

    [JsonPropertyName("Note")]
    public string? Note { get; init; }

    [JsonPropertyName("Items")]
    public required List<FastBoundTransferItem> Items { get; init; }

    /// <summary>
    /// Preferred entry point. Handles idempotency key generation so callers don't have to.
    /// </summary>
    public static FastBoundTransferPayload Create(
        string transferor, string transferee, List<FastBoundTransferItem> items,
        string[]? transfereeEmails = null, string? trackingNumber = null,
        string? poNumber = null, string? invoiceNumber = null,
        string acquireType = "Purchase", string? note = null) => new()
    {
        IdempotencyKey = BuildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items),
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

    /// <summary>
    /// Deterministic SHA-256 hash of the transfer's identifying fields.
    /// Same inputs on the same date always produce the same key, preventing duplicate submissions.
    /// </summary>
    private static string BuildIdempotencyKey(
        string transferor, string transferee,
        string? trackingNumber, string? poNumber, string? invoiceNumber,
        List<FastBoundTransferItem> items)
    {
        string data = string.Join("\n",
            DateTime.UtcNow.ToString("yyyy-MM-dd"),
            transferor, transferee,
            trackingNumber, poNumber, invoiceNumber,
            string.Join("\n", items.Select(i => i.Serial)));

        using SHA256 sha = SHA256.Create();
        return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(data)))
            .Replace("-", "").ToLower();
    }
}

/// <summary>
/// Represents a single firearm in a transfer.
/// Null Importer and Country indicate domestic manufacture.
/// </summary>
public record FastBoundTransferItem(
    string Manufacturer, string? Importer, string? Country,
    string Model, string Caliber, string Type, string Serial,
    string? Sku, string? Mpn, string? Upc,
    double? BarrelLength, double? OverallLength,
    decimal? Cost, decimal? Price,
    string? Condition, string? Note
);

// --- Source-generated JSON serialization (supports native AOT and .NET 10 single-file execution) ---

[JsonSerializable(typeof(FastBoundTransferPayload))]
internal partial class TransferJsonContext : JsonSerializerContext;
