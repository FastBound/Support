// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/java
//
// Requires: Java 17+
// Dependencies: none — uses only java.net, java.security, java.nio, java.util, java.time, java.io

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

// --- Demo usage ---

public class Transfers {

    static final String USERNAME = "YOUR_USERNAME";
    static final String PASSWORD = "YOUR_PASSWORD";

    public static void main(String[] args) throws IOException, NoSuchAlgorithmException {
        String transferor = "1-23-456-78-9A-12345";
        String transferee = "1-23-456-78-9B-54321";

        List<Map<String, Object>> items = new ArrayList<>();
        items.add(FastBoundTransferItem.create(
            "Glock", "Glock, Inc.", "Austria", "17", "9X19", "Pistol",
            "ABC123456", "GLK-G17", "PA1750203", "764503022616",
            4.48, 8.03, 500.00, 650.00, "New",
            "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush"));
        items.add(FastBoundTransferItem.create(
            "Smith & Wesson", null, null, "M&P 9 Shield", "9MM", "Pistol",
            "XYZ987654", "S&W-SHIELD", "10035", "022188864151",
            3.1, 6.1, 450.00, 600.00, "New",
            "No thumb safety, factory case, 7rd flush and 8rd extended mags"));

        var client = new FastBoundTransferClient(USERNAME, PASSWORD);
        Map<String, Object> payload = FastBoundTransferPayload.create(
            transferor, transferee, items,
            List.of("transferee@example.com"),
            "1Z999AA10123456784", "PO123456", "INV98765", "Purchase",
            "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery");

        int[] result = client.sendTransfer(payload);
        // result[0] is status code, response body is printed inside sendTransfer
    }
}

// --- Reusable client ---

class FastBoundTransferClient {
    private final String apiUrl;
    private final String authHeader;

    FastBoundTransferClient(String username, String password) {
        this(username, password, "https://cloud.fastbound.com/api/transfers");
    }

    FastBoundTransferClient(String username, String password, String apiUrl) {
        this.apiUrl = apiUrl;
        this.authHeader = "Basic " + Base64.getEncoder().encodeToString(
            (username + ":" + password).getBytes(StandardCharsets.UTF_8));
    }

    int[] sendTransfer(Map<String, Object> payload) throws IOException {
        String jsonData = JsonWriter.toJson(payload);
        HttpURLConnection conn = (HttpURLConnection) URI.create(apiUrl).toURL().openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setRequestProperty("Authorization", authHeader);
        conn.setDoOutput(true);

        try (OutputStream os = conn.getOutputStream()) {
            os.write(jsonData.getBytes(StandardCharsets.UTF_8));
        }

        int statusCode = conn.getResponseCode();
        java.io.InputStream responseStream = statusCode >= 400
            ? conn.getErrorStream()
            : conn.getInputStream();
        String responseBody = responseStream != null
            ? new String(responseStream.readAllBytes(), StandardCharsets.UTF_8)
            : "(no response body)";

        System.out.println("HTTP Code: " + statusCode);
        System.out.println("Response: " + responseBody);
        return new int[]{ statusCode };
    }
}

// --- Domain types ---

class FastBoundTransferItem {
    static Map<String, Object> create(
            String manufacturer, String importer, String country,
            String model, String caliber, String type, String serial,
            String sku, String mpn, String upc,
            Double barrelLength, Double overallLength,
            Double cost, Double price,
            String condition, String note) {
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("manufacturer", manufacturer);
        item.put("importer", importer);
        item.put("country", country);
        item.put("model", model);
        item.put("caliber", caliber);
        item.put("type", type);
        item.put("serial", serial);
        item.put("sku", sku);
        item.put("mpn", mpn);
        item.put("upc", upc);
        item.put("barrelLength", barrelLength);
        item.put("overallLength", overallLength);
        item.put("cost", cost);
        item.put("price", price);
        item.put("condition", condition);
        item.put("note", note);
        return item;
    }
}

class FastBoundTransferPayload {
    static Map<String, Object> create(
            String transferor, String transferee, List<Map<String, Object>> items,
            List<String> transfereeEmails, String trackingNumber, String poNumber,
            String invoiceNumber, String acquireType, String note) throws NoSuchAlgorithmException {
        String idempotencyKey = buildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items);
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("$schema", "https://schemas.fastbound.org/transfers-push-v1.json");
        payload.put("idempotency_key", idempotencyKey);
        payload.put("transferor", transferor);
        payload.put("transferee", transferee);
        payload.put("transferee_emails", transfereeEmails);
        payload.put("tracking_number", trackingNumber);
        payload.put("po_number", poNumber);
        payload.put("invoice_number", invoiceNumber);
        payload.put("acquire_type", acquireType);
        payload.put("note", note);
        payload.put("items", items);
        return payload;
    }

    private static String buildIdempotencyKey(
            String transferor, String transferee,
            String trackingNumber, String poNumber, String invoiceNumber,
            List<Map<String, Object>> items) throws NoSuchAlgorithmException {
        List<String> parts = new ArrayList<>();
        parts.add(LocalDate.now().toString());
        parts.add(transferor);
        parts.add(transferee);
        parts.add(trackingNumber != null ? trackingNumber : "");
        parts.add(poNumber != null ? poNumber : "");
        parts.add(invoiceNumber != null ? invoiceNumber : "");
        for (Map<String, Object> item : items) {
            parts.add((String) item.get("serial"));
        }

        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(String.join("\n", parts).getBytes(StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder();
        for (byte b : hash) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
}

class JsonWriter {
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
