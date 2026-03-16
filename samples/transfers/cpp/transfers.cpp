// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/cpp
//
// Requires: C++17
// Dependencies: libcurl, OpenSSL
//
// Build:
//   Linux/macOS: g++ -std=c++17 -o transfers transfers.cpp -lcurl -lssl -lcrypto
//   Windows (vcpkg): cl /std:c++17 transfers.cpp /link libcurl.lib libssl.lib libcrypto.lib

#include <ctime>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include <curl/curl.h>
#include <openssl/evp.h>

// --- Domain types ---

struct FastBoundTransferItem {
    std::string manufacturer;
    std::optional<std::string> importer;
    std::optional<std::string> country;
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

    std::string to_json() const;
};

struct FastBoundTransferResult {
    long status_code;
    std::string body;
};

// --- Reusable client ---

class FastBoundTransferClient {
public:
    FastBoundTransferClient(const std::string &username, const std::string &password,
                            const std::string &api_url = "https://cloud.fastbound.com/api/transfers")
        : api_url_(api_url), auth_header_("Basic " + base64_encode(username + ":" + password)) {}

    FastBoundTransferResult send_transfer(const std::string &json_payload) const;

private:
    std::string api_url_;
    std::string auth_header_;

    static std::string base64_encode(const std::string &input);
    static size_t write_callback(char *ptr, size_t size, size_t nmemb, std::string *data);
};

// --- Helper functions ---

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

static std::string json_str(const std::string &key, const std::string &val) {
    return "\"" + key + "\":\"" + json_escape(val) + "\"";
}

static std::string json_num(const std::string &key, double val) {
    std::ostringstream ss;
    ss << "\"" << key << "\":" << val;
    return ss.str();
}

static std::string json_opt(const std::string &key, const std::optional<std::string> &val) {
    if (val.has_value())
        return "\"" + key + "\":\"" + json_escape(val.value()) + "\"";
    return "\"" + key + "\":null";
}

static std::string build_idempotency_key(
    const std::string &transferor, const std::string &transferee,
    const std::string &tracking_number, const std::string &po_number,
    const std::string &invoice_number, const std::vector<FastBoundTransferItem> &items) {

    std::time_t now = std::time(nullptr);
    char date_buf[11];
    std::strftime(date_buf, sizeof(date_buf), "%Y-%m-%d", std::gmtime(&now));

    std::ostringstream data;
    data << date_buf << "\n"
         << transferor << "\n" << transferee << "\n"
         << tracking_number << "\n" << po_number << "\n" << invoice_number;
    for (const auto &item : items)
        data << "\n" << item.serial;

    return sha256_hex(data.str());
}

static std::string build_payload_json(
    const std::string &idempotency_key,
    const std::string &transferor, const std::string &transferee,
    const std::vector<std::string> &transferee_emails,
    const std::string &tracking_number, const std::string &po_number,
    const std::string &invoice_number, const std::string &acquire_type,
    const std::string &note, const std::vector<FastBoundTransferItem> &items) {

    std::string emails_json;
    for (size_t i = 0; i < transferee_emails.size(); i++) {
        if (i > 0) emails_json += ",";
        emails_json += "\"" + json_escape(transferee_emails[i]) + "\"";
    }

    std::string items_json;
    for (size_t i = 0; i < items.size(); i++) {
        if (i > 0) items_json += ",";
        items_json += items[i].to_json();
    }

    return "{"
        "\"$schema\":\"https://schemas.fastbound.org/transfers-push-v1.json\","
        "\"idempotency_key\":\"" + idempotency_key + "\","
        "\"transferor\":\"" + json_escape(transferor) + "\","
        "\"transferee\":\"" + json_escape(transferee) + "\","
        "\"transferee_emails\":[" + emails_json + "],"
        "\"tracking_number\":\"" + json_escape(tracking_number) + "\","
        "\"po_number\":\"" + json_escape(po_number) + "\","
        "\"invoice_number\":\"" + json_escape(invoice_number) + "\","
        "\"acquire_type\":\"" + json_escape(acquire_type) + "\","
        "\"note\":\"" + json_escape(note) + "\","
        "\"items\":[" + items_json + "]"
        "}";
}

// --- FastBoundTransferItem implementation ---

std::string FastBoundTransferItem::to_json() const {
    std::ostringstream ss;
    ss << "{";
    ss << json_str("manufacturer", manufacturer) << ",";
    ss << json_opt("importer", importer) << ",";
    ss << json_opt("country", country) << ",";
    ss << json_str("model", model) << ",";
    ss << json_str("caliber", caliber) << ",";
    ss << json_str("type", type) << ",";
    ss << json_str("serial", serial) << ",";
    ss << json_str("sku", sku) << ",";
    ss << json_str("mpn", mpn) << ",";
    ss << json_str("upc", upc) << ",";
    ss << json_num("barrelLength", barrel_length) << ",";
    ss << json_num("overallLength", overall_length) << ",";
    ss << json_num("cost", cost) << ",";
    ss << json_num("price", price) << ",";
    ss << json_str("condition", condition) << ",";
    ss << json_str("note", note);
    ss << "}";
    return ss.str();
}

// --- FastBoundTransferClient implementation ---

std::string FastBoundTransferClient::base64_encode(const std::string &input) {
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

size_t FastBoundTransferClient::write_callback(char *ptr, size_t size, size_t nmemb, std::string *data) {
    data->append(ptr, size * nmemb);
    return size * nmemb;
}

FastBoundTransferResult FastBoundTransferClient::send_transfer(const std::string &json_payload) const {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    CURL *curl = curl_easy_init();
    if (!curl) {
        curl_global_cleanup();
        return {0, "Failed to initialize curl"};
    }

    std::string response_body;
    long http_code = 0;

    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, ("Authorization: " + auth_header_).c_str());

    curl_easy_setopt(curl, CURLOPT_URL, api_url_.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_payload.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_body);

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        response_body = std::string("Request failed: ") + curl_easy_strerror(res);
    } else {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    curl_global_cleanup();

    return {http_code, response_body};
}

// --- Demo usage ---

int main() {
    std::vector<FastBoundTransferItem> items = {
        {
            "Glock", "Glock, Inc.", "Austria", "17", "9X19", "Pistol",
            "ABC123456", "GLK-G17", "PA1750203", "764503022616",
            4.48, 8.03, 500.00, 650.00, "New",
            "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush"
        },
        {
            "Smith & Wesson", std::nullopt, std::nullopt, "M&P 9 Shield", "9MM", "Pistol",
            "XYZ987654", "S&W-SHIELD", "10035", "022188864151",
            3.1, 6.1, 450.00, 600.00, "New",
            "No thumb safety, factory case, 7rd flush and 8rd extended mags"
        }
    };

    std::string transferor = "1-23-456-78-9A-12345";
    std::string transferee = "1-23-456-78-9B-54321";
    std::string tracking_number = "1Z999AA10123456784";
    std::string po_number = "PO123456";
    std::string invoice_number = "INV98765";

    std::string idempotency_key = build_idempotency_key(
        transferor, transferee, tracking_number, po_number, invoice_number, items);

    std::string payload = build_payload_json(
        idempotency_key, transferor, transferee,
        {"transferee@example.com"},
        tracking_number, po_number, invoice_number, "Purchase",
        "2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
        items);

    FastBoundTransferClient client("YOUR_USERNAME", "YOUR_PASSWORD");
    auto result = client.send_transfer(payload);

    std::cout << "HTTP Code: " << result.status_code << std::endl;
    std::cout << "Response: " << result.body << std::endl;

    return (result.status_code >= 200 && result.status_code < 300) ? 0 : 1;
}
