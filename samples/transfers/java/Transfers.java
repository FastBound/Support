import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class Transfers {

    // Authentication credentials
    static final String USERNAME = "YOUR_USERNAME";
    static final String PASSWORD = "YOUR_PASSWORD";

    // API endpoint
    static final String URL = "https://cloud.fastbound.com/api/transfers";

    public static void main(String[] args) throws IOException, NoSuchAlgorithmException {
        // Set shipment date (use actual shipment date when available)
        String shipmentDate = LocalDate.now().toString(); // YYYY-MM-DD format

        // Other required fields
        String transferor = "1-54-810-07-7B-25807";   // Replace with actual FFL number
        String transferee = "9-68-067-07-5K-99999";   // Replace with actual FFL number
        String trackingNumber = "1Z999AA10123456784";  // Optional
        String poNumber = "PO123456";                  // Optional
        String invoiceNumber = "INV98765";             // Optional

        // Define items
        Map<String, Object> item1 = new LinkedHashMap<>();
        item1.put("manufacturer", "Glock");
        item1.put("importer", null);
        item1.put("country", "Austria");
        item1.put("model", "G17");
        item1.put("caliber", "9mm");
        item1.put("type", "Pistol");
        item1.put("serial", "ABC123456");
        item1.put("sku", "GLK-G17");
        item1.put("mpn", "G17MPN");
        item1.put("upc", "123456789012");
        item1.put("barrelLength", 4.48);
        item1.put("overallLength", 8.03);
        item1.put("cost", 500.00);
        item1.put("price", 650.00);
        item1.put("condition", "New");
        item1.put("note", "Brand new firearm");

        Map<String, Object> item2 = new LinkedHashMap<>();
        item2.put("manufacturer", "Smith & Wesson");
        item2.put("importer", null);
        item2.put("country", "USA");
        item2.put("model", "M&P Shield");
        item2.put("caliber", "9mm");
        item2.put("type", "Pistol");
        item2.put("serial", "XYZ987654");
        item2.put("sku", "S&W-SHIELD");
        item2.put("mpn", "SHIELDMPN");
        item2.put("upc", "987654321098");
        item2.put("barrelLength", 3.1);
        item2.put("overallLength", 6.1);
        item2.put("cost", 450.00);
        item2.put("price", 600.00);
        item2.put("condition", "New");
        item2.put("note", "Compact pistol");

        List<Map<String, Object>> items = new ArrayList<>();
        items.add(item1);
        items.add(item2);

        // Extract serial numbers for idempotency key
        List<String> serialNumbers = new ArrayList<>();
        for (Map<String, Object> item : items) {
            serialNumbers.add((String) item.get("serial"));
        }

        // Generate idempotency key based on shipment details
        List<String> idempotencyParts = new ArrayList<>();
        idempotencyParts.add(shipmentDate);
        idempotencyParts.add(transferor);
        idempotencyParts.add(transferee);
        idempotencyParts.add(trackingNumber);
        idempotencyParts.add(poNumber);
        idempotencyParts.add(invoiceNumber);
        idempotencyParts.addAll(serialNumbers);

        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(
            String.join("\n", idempotencyParts).getBytes(StandardCharsets.UTF_8)
        );
        StringBuilder idempotencyKey = new StringBuilder();
        for (byte b : hash) {
            idempotencyKey.append(String.format("%02x", b));
        }

        // Construct the payload
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("$schema", "https://schemas.fastbound.org/transfers-push-v1.json");
        payload.put("idempotency_key", idempotencyKey.toString());
        payload.put("transferor", transferor);
        payload.put("transferee", transferee);
        payload.put("transferee_emails", List.of(
            "transferee@example.com",
            "transferee@example.net",
            "transferee@example.org"
        ));
        payload.put("tracking_number", trackingNumber);
        payload.put("po_number", poNumber);
        payload.put("invoice_number", invoiceNumber);
        payload.put("acquire_type", "Purchase");
        payload.put("note", "This is a test transfer.");
        payload.put("items", items);

        String jsonData = toJson(payload);

        // Create Basic Authentication header
        String auth = Base64.getEncoder().encodeToString(
            (USERNAME + ":" + PASSWORD).getBytes(StandardCharsets.UTF_8)
        );

        // Send POST request
        HttpURLConnection conn = (HttpURLConnection) URI.create(URL).toURL().openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setRequestProperty("Authorization", "Basic " + auth);
        conn.setDoOutput(true);

        try (OutputStream os = conn.getOutputStream()) {
            os.write(jsonData.getBytes(StandardCharsets.UTF_8));
        }

        // Print response
        int statusCode = conn.getResponseCode();
        java.io.InputStream responseStream = statusCode >= 400
            ? conn.getErrorStream()
            : conn.getInputStream();
        String responseBody = responseStream != null
            ? new String(responseStream.readAllBytes(), StandardCharsets.UTF_8)
            : "(no response body)";

        System.out.println("HTTP Code: " + statusCode);
        System.out.println("Response: " + responseBody);
    }

    // Minimal JSON serializer using only the standard library
    @SuppressWarnings("unchecked")
    static String toJson(Object value) {
        if (value == null) {
            return "null";
        } else if (value instanceof String s) {
            return "\"" + s.replace("\\", "\\\\")
                          .replace("\"", "\\\"")
                          .replace("\n", "\\n")
                          .replace("\r", "\\r")
                          .replace("\t", "\\t") + "\"";
        } else if (value instanceof Number) {
            String str = value.toString();
            // Remove trailing ".0" for whole numbers
            if (str.endsWith(".0")) {
                str = str.substring(0, str.length() - 2);
            }
            return str;
        } else if (value instanceof Boolean) {
            return value.toString();
        } else if (value instanceof List<?> list) {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(toJson(list.get(i)));
            }
            sb.append("]");
            return sb.toString();
        } else if (value instanceof Map<?, ?> map) {
            StringBuilder sb = new StringBuilder("{");
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) sb.append(",");
                first = false;
                sb.append(toJson(entry.getKey().toString()));
                sb.append(":");
                sb.append(toJson(entry.getValue()));
            }
            sb.append("}");
            return sb.toString();
        }
        return "\"" + value + "\"";
    }
}
