import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.time.LocalDate
import java.util.Base64

// Authentication credentials
const val USERNAME = "YOUR_USERNAME"
const val PASSWORD = "YOUR_PASSWORD"

// API endpoint
const val API_URL = "https://cloud.fastbound.com/api/transfers"

data class Item(
    val manufacturer: String,
    val importer: String?,
    val country: String,
    val model: String,
    val caliber: String,
    val type: String,
    val serial: String,
    val sku: String,
    val mpn: String,
    val upc: String,
    val barrelLength: Double,
    val overallLength: Double,
    val cost: Double,
    val price: Double,
    val condition: String,
    val note: String,
)

data class TransferPayload(
    val schema: String,
    val idempotencyKey: String,
    val transferor: String,
    val transferee: String,
    val transfereeEmails: List<String>,
    val trackingNumber: String,
    val poNumber: String,
    val invoiceNumber: String,
    val acquireType: String,
    val note: String,
    val items: List<Item>,
)

fun toJson(value: Any?): String = when (value) {
    null -> "null"
    is String -> "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""
    is Number -> {
        val str = value.toString()
        if (str.endsWith(".0")) str.dropLast(2) else str
    }
    is Boolean -> value.toString()
    is List<*> -> value.joinToString(",", "[", "]") { toJson(it) }
    is Map<*, *> -> value.entries.joinToString(",", "{", "}") { (k, v) ->
        "${toJson(k.toString())}:${toJson(v)}"
    }
    else -> "\"$value\""
}

fun Item.toMap(): Map<String, Any?> = linkedMapOf(
    "manufacturer" to manufacturer,
    "importer" to importer,
    "country" to country,
    "model" to model,
    "caliber" to caliber,
    "type" to type,
    "serial" to serial,
    "sku" to sku,
    "mpn" to mpn,
    "upc" to upc,
    "barrelLength" to barrelLength,
    "overallLength" to overallLength,
    "cost" to cost,
    "price" to price,
    "condition" to condition,
    "note" to note,
)

fun TransferPayload.toMap(): Map<String, Any?> = linkedMapOf(
    "\$schema" to schema,
    "idempotency_key" to idempotencyKey,
    "transferor" to transferor,
    "transferee" to transferee,
    "transferee_emails" to transfereeEmails,
    "tracking_number" to trackingNumber,
    "po_number" to poNumber,
    "invoice_number" to invoiceNumber,
    "acquire_type" to acquireType,
    "note" to note,
    "items" to items.map { it.toMap() },
)

fun main() {
    // Set shipment date (use actual shipment date when available)
    val shipmentDate = LocalDate.now().toString() // YYYY-MM-DD format

    // Other required fields
    val transferor = "1-54-810-07-7B-25807"   // Replace with actual FFL number
    val transferee = "9-68-067-07-5K-99999"   // Replace with actual FFL number
    val trackingNumber = "1Z999AA10123456784"  // Optional
    val poNumber = "PO123456"                  // Optional
    val invoiceNumber = "INV98765"             // Optional

    // Define items
    val items = listOf(
        Item(
            manufacturer = "Glock",
            importer = null,
            country = "Austria",
            model = "G17",
            caliber = "9mm",
            type = "Pistol",
            serial = "ABC123456",
            sku = "GLK-G17",
            mpn = "G17MPN",
            upc = "123456789012",
            barrelLength = 4.48,
            overallLength = 8.03,
            cost = 500.00,
            price = 650.00,
            condition = "New",
            note = "Brand new firearm",
        ),
        Item(
            manufacturer = "Smith & Wesson",
            importer = null,
            country = "USA",
            model = "M&P Shield",
            caliber = "9mm",
            type = "Pistol",
            serial = "XYZ987654",
            sku = "S&W-SHIELD",
            mpn = "SHIELDMPN",
            upc = "987654321098",
            barrelLength = 3.1,
            overallLength = 6.1,
            cost = 450.00,
            price = 600.00,
            condition = "New",
            note = "Compact pistol",
        ),
    )

    // Generate idempotency key based on shipment details
    val idempotencyData = listOf(
        shipmentDate, transferor, transferee,
        trackingNumber, poNumber, invoiceNumber,
        *items.map { it.serial }.toTypedArray(),
    ).joinToString("\n")

    val idempotencyKey = MessageDigest.getInstance("SHA-256")
        .digest(idempotencyData.toByteArray())
        .joinToString("") { "%02x".format(it) }

    // Construct the payload
    val payload = TransferPayload(
        schema = "https://schemas.fastbound.org/transfers-push-v1.json",
        idempotencyKey = idempotencyKey,
        transferor = transferor,
        transferee = transferee,
        transfereeEmails = listOf(
            "transferee@example.com",
            "transferee@example.net",
            "transferee@example.org",
        ),
        trackingNumber = trackingNumber,
        poNumber = poNumber,
        invoiceNumber = invoiceNumber,
        acquireType = "Purchase",
        note = "This is a test transfer.",
        items = items,
    )

    val jsonData = toJson(payload.toMap())

    // Create Basic Authentication header
    val auth = Base64.getEncoder().encodeToString("$USERNAME:$PASSWORD".toByteArray())

    // Send POST request
    val conn = URI(API_URL).toURL().openConnection() as HttpURLConnection
    conn.requestMethod = "POST"
    conn.setRequestProperty("Content-Type", "application/json")
    conn.setRequestProperty("Authorization", "Basic $auth")
    conn.doOutput = true

    conn.outputStream.use { it.write(jsonData.toByteArray()) }

    // Print response
    val statusCode = conn.responseCode
    val responseStream = if (statusCode >= 400) conn.errorStream else conn.inputStream
    val responseBody = responseStream?.readAllBytes()?.toString(Charsets.UTF_8) ?: "(no response body)"

    println("HTTP Code: $statusCode")
    println("Response: $responseBody")
}
