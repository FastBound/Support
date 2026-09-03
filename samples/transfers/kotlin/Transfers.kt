// Copyright © FastBound Inc. All rights reserved.
//
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/kotlin
//
// Requires: Kotlin 1.9+ / JDK 17+
// Dependencies: none — uses only java.net, java.security, java.util

import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Base64

// --- Demo usage ---

const val USERNAME = "YOUR_USERNAME"
const val PASSWORD = "YOUR_PASSWORD"

fun main() {
    val transferor = "1-23-456-78-9A-12345"
    val transferee = "1-23-456-78-9B-54321"

    val items = listOf(
        FastBoundTransferItem(
            manufacturer = "Glock",
            importer = "Glock, Inc.",
            country = "Austria",
            model = "17",
            caliber = "9X19",
            type = "Pistol",
            serial = "ABC123456",
            sku = "GLK-G17",
            mpn = "PA1750203",
            upc = "764503022616",
            barrelLength = 4.48,
            overallLength = 8.03,
            cost = 500.00,
            price = 650.00,
            condition = "New",
            note = "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush",
        ),
        FastBoundTransferItem(
            manufacturer = "Smith & Wesson",
            importer = null,
            country = null,
            model = "M&P 9 Shield",
            caliber = "9MM",
            type = "Pistol",
            serial = "XYZ987654",
            sku = "S&W-SHIELD",
            mpn = "10035",
            upc = "022188864151",
            barrelLength = 3.1,
            overallLength = 6.1,
            cost = 450.00,
            price = 600.00,
            condition = "New",
            note = "No thumb safety, factory case, 7rd flush and 8rd extended mags",
        ),
    )

    val client = FastBoundTransferClient(USERNAME, PASSWORD)
    val payload = FastBoundTransferPayload.create(
        transferor = transferor,
        transferee = transferee,
        items = items,
        transfereeEmails = listOf("transferee@example.com"),
        trackingNumber = "1Z999AA10123456784",
        poNumber = "PO123456",
        invoiceNumber = "INV98765",
        acquireType = "Purchase",
        note = "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
        // Prefer your own transaction id, so a retry — even days later, from another
        // process — resolves to the same key. Bump the revision suffix when you mean to
        // send a genuinely new transfer for the same order. Omit idempotencyKey entirely
        // and one is derived from the shipment's identifying fields instead.
        idempotencyKey = "po-123456:rev1",
    )

    val result = client.sendTransfer(payload)
    println("HTTP Code: ${result.statusCode}")
    println("Response: ${result.body}")
}

// --- Reusable client ---

class FastBoundTransferClient(
    username: String,
    password: String,
    private val apiUrl: String = "https://cloud.fastbound.com/api/transfers",
) {
    private val authHeader = "Basic " + Base64.getEncoder().encodeToString("$username:$password".toByteArray())

    data class Result(val statusCode: Int, val body: String)

    fun sendTransfer(payload: Map<String, Any?>): Result {
        val jsonData = toJson(payload)
        val conn = URI(apiUrl).toURL().openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty("Authorization", authHeader)
        conn.doOutput = true

        conn.outputStream.use { it.write(jsonData.toByteArray()) }

        val statusCode = conn.responseCode
        val responseStream = if (statusCode >= 400) conn.errorStream else conn.inputStream
        val responseBody = responseStream?.readAllBytes()?.toString(Charsets.UTF_8) ?: "(no response body)"

        return Result(statusCode, responseBody)
    }
}

// --- Domain types ---

data class FastBoundTransferItem(
    val manufacturer: String,
    val importer: String?,
    val country: String?,
    val model: String,
    val caliber: String,
    val type: String,
    val serial: String,
    val sku: String?,
    val mpn: String?,
    val upc: String?,
    val barrelLength: Double?,
    val overallLength: Double?,
    val cost: Double?,
    val price: Double?,
    val condition: String?,
    val note: String?,
)

object FastBoundTransferPayload {
    fun create(
        transferor: String,
        transferee: String,
        items: List<FastBoundTransferItem>,
        transfereeEmails: List<String> = emptyList(),
        trackingNumber: String? = null,
        poNumber: String? = null,
        invoiceNumber: String? = null,
        acquireType: String = "Purchase",
        note: String? = null,
        idempotencyKey: String? = null,
    ): Map<String, Any?> {
        val key = if (idempotencyKey == null) {
            deriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items)
        } else {
            validateIdempotencyKey(idempotencyKey)
        }
        return linkedMapOf(
            "\$schema" to "https://schemas.fastbound.org/transfers-push-v1.json",
            "idempotency_key" to key,
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
    }

    private fun validateIdempotencyKey(key: String): String {
        require(key.isNotBlank()) { "idempotencyKey must not be blank." }
        // The API caps the field at 255 characters; catching it here beats a 400 on a
        // request that has already been accepted once under a truncated key.
        require(key.length <= 255) {
            "idempotencyKey must be at most 255 characters (got ${key.length})."
        }
        return key
    }

    /**
     * Fallback for callers with no transaction id of their own to reuse.
     *
     * Reads no clock. A retry after a timeout is the case this key exists for, and a key
     * containing today's date changes at midnight — mid-afternoon in US time zones —
     * handing the retry a fresh key and creating the duplicate it was meant to stop.
     * Serials are sorted because item order carries no meaning, so a retry that
     * re-serializes from an unordered source must not read as a second shipment.
     */
    private fun deriveIdempotencyKey(
        transferor: String, transferee: String,
        trackingNumber: String?, poNumber: String?, invoiceNumber: String?,
        items: List<FastBoundTransferItem>,
    ): String {
        require(!trackingNumber.isNullOrEmpty() || !poNumber.isNullOrEmpty() || !invoiceNumber.isNullOrEmpty()) {
            "Cannot derive an idempotency key from the FFL numbers and serials alone: two " +
                "separate orders of the same firearms between the same parties would collide and " +
                "the second would be dropped as a duplicate. Pass idempotencyKey, or supply a " +
                "tracking, PO or invoice number."
        }

        // Natural (ordinal) sort, not locale-aware, so that every language port of this
        // sample agrees on the key for the same transfer.
        val serials = items.map { it.serial }.sorted()
        val data = canonicalize(
            listOf(
                transferor, transferee,
                trackingNumber ?: "", poNumber ?: "", invoiceNumber ?: "",
            ) + serials,
        )

        val digest = MessageDigest.getInstance("SHA-256")
            .digest(data.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "sha256:$digest"
    }

    /**
     * Length-prefixes each part so no field can impersonate another.
     *
     * Concatenating with a plain separator is ambiguous when a field may contain that
     * separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
     * items and invoice_number "INV-1" with serial "ABC123" produce the same joined
     * string, so two different transfers collide on one key. Prefixing with the UTF-8
     * byte count — bytes, not characters, so ports to other languages agree — makes the
     * encoding unambiguous.
     */
    private fun canonicalize(parts: List<String>): String =
        parts.joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }
}

private fun FastBoundTransferItem.toMap(): Map<String, Any?> = linkedMapOf(
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

private fun toJson(value: Any?): String = when (value) {
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
