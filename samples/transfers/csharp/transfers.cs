using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

class Program
{
    private const string Username = "YOUR_USERNAME";
    private const string Password = "YOUR_PASSWORD";
    private const string ApiUrl = "https://cloud.fastbound.com/api/transfers";

    static async Task Main()
    {
        string shipmentDate = DateTime.UtcNow.ToString("yyyy-MM-dd");
        string transferor = "1-23-456-78-9A-12345";
        string transferee = "1-23-456-78-9B-54321";
        string trackingNumber = "1Z999AA10123456784";
        string poNumber = "PO123456";
        string invoiceNumber = "INV98765";

        var items = new List<Item>
        {
            new Item("Glock", null, "Austria", "G17", "9mm", "Pistol", "ABC123456", "GLK-G17", "G17MPN", "123456789012", 4.48, 8.03, 500.00, 650.00, "New", "Brand new firearm"),
            new Item("Smith & Wesson", null, "USA", "M&P Shield", "9mm", "Pistol", "XYZ987654", "S&W-SHIELD", "SHIELDMPN", "987654321098", 3.1, 6.1, 450.00, 600.00, "New", "Compact pistol")
        };

        var serialNumbers = items.ConvertAll(item => item.Serial);
        string idempotencyKey = GenerateIdempotencyKey(shipmentDate, transferor, transferee, trackingNumber, poNumber, invoiceNumber, serialNumbers);

        var payload = new Payload
        {
            Idempotency_Key = idempotencyKey,
            Transferor = transferor,
            Transferee = transferee,
            Transferee_Emails = new[] { "transferee@example.com", "transferee@example.net", "transferee@example.org" },
            Tracking_Number = trackingNumber,
            Po_Number = poNumber,
            Invoice_Number = invoiceNumber,
            Acquire_Type = "Purchase",
            Note = "This is a test transfer.",
            Items = items
        };

        string jsonPayload = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        await SendPostRequest(jsonPayload);
    }

    private static string GenerateIdempotencyKey(string shipmentDate, string transferor, string transferee, string trackingNumber, string poNumber, string invoiceNumber, List<string> serialNumbers)
    {
        string data = string.Join("\n", shipmentDate, transferor, transferee, trackingNumber, poNumber, invoiceNumber, string.Join("\n", serialNumbers));
        using SHA256 sha256 = SHA256.Create();
        byte[] hash = sha256.ComputeHash(Encoding.UTF8.GetBytes(data));
        return BitConverter.ToString(hash).Replace("-", "").ToLower();
    }

    private static async Task SendPostRequest(string jsonPayload)
    {
        using HttpClient client = new HttpClient();
        string authString = Convert.ToBase64String(Encoding.ASCII.GetBytes($"{Username}:{Password}"));
        client.DefaultRequestHeaders.Add("Authorization", $"Basic {authString}");

        HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Post, ApiUrl)
        {
            Content = new StringContent(jsonPayload, Encoding.UTF8, "application/json")
        };

        HttpResponseMessage response = await client.SendAsync(request);
        string responseBody = await response.Content.ReadAsStringAsync();

        Console.WriteLine($"HTTP Code: {response.StatusCode}");
        Console.WriteLine("Response: " + responseBody);
    }
}

public record Payload
{
    [JsonPropertyName("$schema")]
    public string Schema { get; set; } = "https://schemas.fastbound.org/transfers-push-v1.json";
    public required string Idempotency_Key { get; set; }
    public required string Transferor { get; set; }
    public required string Transferee { get; set; }
    public required string[] Transferee_Emails { get; set; }
    public string? Tracking_Number { get; set; }
    public string? Po_Number { get; set; }
    public string? Invoice_Number { get; set; }
    public required string Acquire_Type { get; set; }
    public string? Note { get; set; }
    public required List<Item> Items { get; set; }
}

public record Item
{
    public string Manufacturer { get; }
    public string? Importer { get; }
    public string? Country { get; }
    public string Model { get; }
    public string Caliber { get; }
    public string Type { get; }
    public string Serial { get; }
    public string? Sku { get; }
    public string? Mpn { get; }
    public string? Upc { get; }
    public double? BarrelLength { get; }
    public double? OverallLength { get; }
    public double? Cost { get; }
    public double? Price { get; }
    public string? Condition { get; }
    public string? Note { get; }

    public Item(string manufacturer, string? importer, string country, string model, string caliber, string type, string serial, string sku, string mpn, string upc, double? barrelLength, double? overallLength, double? cost, double? price, string condition, string note)
    {
        Manufacturer = manufacturer;
        Importer = importer;
        Country = country;
        Model = model;
        Caliber = caliber;
        Type = type;
        Serial = serial;
        Sku = sku;
        Mpn = mpn;
        Upc = upc;
        BarrelLength = barrelLength;
        OverallLength = overallLength;
        Cost = cost;
        Price = price;
        Condition = condition;
        Note = note;
    }
}
