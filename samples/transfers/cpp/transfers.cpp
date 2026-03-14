// FastBound Transfer API Sample - C++
//
// Dependencies: libcurl, OpenSSL
//
// Build:
//   Linux/macOS: g++ -std=c++17 -o transfers transfers.cpp -lcurl -lssl -lcrypto
//   Windows (vcpkg): cl /std:c++17 transfers.cpp /link libcurl.lib libssl.lib libcrypto.lib

#include <ctime>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <curl/curl.h>
#include <openssl/evp.h>

// Authentication credentials
const std::string USERNAME = "YOUR_USERNAME";
const std::string PASSWORD = "YOUR_PASSWORD";

// API endpoint
const std::string URL = "https://cloud.fastbound.com/api/transfers";

static std::string base64_encode(const std::string &input) {
    static const char table[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    int val = 0, bits = -6;
    for (unsigned char c : input) {
        val = (val << 8) + c;
        bits += 8;
        while (bits >= 0) {
            out.push_back(table[(val >> bits) & 0x3F]);
            bits -= 6;
        }
    }
    if (bits > -6)
        out.push_back(table[((val << 8) >> (bits + 8)) & 0x3F]);
    while (out.size() % 4)
        out.push_back('=');
    return out;
}

static std::string sha256_hex(const std::string &input) {
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr);
    EVP_DigestUpdate(ctx, input.data(), input.size());
    EVP_DigestFinal_ex(ctx, hash, &len);
    EVP_MD_CTX_free(ctx);

    std::ostringstream ss;
    for (unsigned int i = 0; i < len; i++)
        ss << std::hex << std::setfill('0') << std::setw(2) << (int)hash[i];
    return ss.str();
}

static std::string json_escape(const std::string &s) {
    std::string out;
    for (char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n";  break;
        default:   out += c;
        }
    }
    return out;
}

struct Item {
    std::string manufacturer;
    std::string importer;
    std::string country;
    std::string model;
    std::string caliber;
    std::string type;
    std::string serial;
    std::string sku;
    std::string mpn;
    std::string upc;
    double barrel_length;
    double overall_length;
    double cost;
    double price;
    std::string condition;
    std::string note;

    std::string to_json() const {
        auto str = [](const std::string &key, const std::string &val) {
            return "\"" + key + "\":\"" + json_escape(val) + "\"";
        };
        auto num = [](const std::string &key, double val) {
            std::ostringstream ss;
            ss << "\"" << key << "\":" << val;
            return ss.str();
        };

        std::ostringstream ss;
        ss << "{";
        ss << str("manufacturer", manufacturer) << ",";
        ss << "\"importer\":" << (importer.empty() ? "null" : "\"" + json_escape(importer) + "\"") << ",";
        ss << str("country", country) << ",";
        ss << str("model", model) << ",";
        ss << str("caliber", caliber) << ",";
        ss << str("type", type) << ",";
        ss << str("serial", serial) << ",";
        ss << str("sku", sku) << ",";
        ss << str("mpn", mpn) << ",";
        ss << str("upc", upc) << ",";
        ss << num("barrelLength", barrel_length) << ",";
        ss << num("overallLength", overall_length) << ",";
        ss << num("cost", cost) << ",";
        ss << num("price", price) << ",";
        ss << str("condition", condition) << ",";
        ss << str("note", note);
        ss << "}";
        return ss.str();
    }
};

static size_t write_callback(char *ptr, size_t size, size_t nmemb, std::string *data) {
    data->append(ptr, size * nmemb);
    return size * nmemb;
}

int main() {
    // Set shipment date (use actual shipment date when available)
    std::time_t now = std::time(nullptr);
    char date_buf[11];
    std::strftime(date_buf, sizeof(date_buf), "%Y-%m-%d", std::gmtime(&now));
    std::string shipment_date(date_buf);

    // Define items
    std::vector<Item> items = {
        {
            "Glock", "", "Austria", "G17", "9mm", "Pistol",
            "ABC123456", "GLK-G17", "G17MPN", "123456789012",
            4.48, 8.03, 500.00, 650.00, "New", "Brand new firearm"
        },
        {
            "Smith & Wesson", "", "USA", "M&P Shield", "9mm", "Pistol",
            "XYZ987654", "S&W-SHIELD", "SHIELDMPN", "987654321098",
            3.1, 6.1, 450.00, 600.00, "New", "Compact pistol"
        }
    };

    // Other required fields
    std::string transferor      = "1-23-456-78-9A-12345";   // Replace with actual FFL number
    std::string transferee      = "1-23-456-78-9B-54321";   // Replace with actual FFL number
    std::string tracking_number = "1Z999AA10123456784";      // Optional
    std::string po_number       = "PO123456";                // Optional
    std::string invoice_number  = "INV98765";                // Optional

    // Generate idempotency key based on shipment details
    std::ostringstream id_data;
    id_data << shipment_date << "\n"
            << transferor << "\n"
            << transferee << "\n"
            << tracking_number << "\n"
            << po_number << "\n"
            << invoice_number;
    for (const auto &item : items)
        id_data << "\n" << item.serial;

    std::string idempotency_key = sha256_hex(id_data.str());

    // Build items JSON array
    std::string items_json;
    for (size_t i = 0; i < items.size(); i++) {
        if (i > 0) items_json += ",";
        items_json += items[i].to_json();
    }

    // Construct JSON payload
    std::string payload =
        "{"
        "\"$schema\":\"https://schemas.fastbound.org/transfers-push-v1.json\","
        "\"idempotency_key\":\"" + idempotency_key + "\","
        "\"transferor\":\"" + transferor + "\","
        "\"transferee\":\"" + transferee + "\","
        "\"transferee_emails\":[\"transferee@example.com\",\"transferee@example.net\",\"transferee@example.org\"],"
        "\"tracking_number\":\"" + tracking_number + "\","
        "\"po_number\":\"" + po_number + "\","
        "\"invoice_number\":\"" + invoice_number + "\","
        "\"acquire_type\":\"Purchase\","
        "\"note\":\"This is a test transfer.\","
        "\"items\":[" + items_json + "]"
        "}";

    // Create Basic Authentication header
    std::string auth = base64_encode(USERNAME + ":" + PASSWORD);

    // Send POST request
    curl_global_init(CURL_GLOBAL_DEFAULT);
    CURL *curl = curl_easy_init();
    if (!curl) {
        std::cerr << "Failed to initialize curl" << std::endl;
        return 1;
    }

    std::string response_body;
    long http_code = 0;

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, ("Authorization: Basic " + auth).c_str());

    curl_easy_setopt(curl, CURLOPT_URL, URL.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_body);

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        std::cerr << "Request failed: " << curl_easy_strerror(res) << std::endl;
    } else {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
        std::cout << "HTTP Code: " << http_code << std::endl;
        std::cout << "Response: " << response_body << std::endl;
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    curl_global_cleanup();

    return (res == CURLE_OK) ? 0 : 1;
}
