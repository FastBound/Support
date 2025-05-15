use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use chrono::Utc;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::error::Error;

const USERNAME: &str = "YOUR_USERNAME";
const PASSWORD: &str = "YOUR_PASSWORD";
const API_URL: &str = "https://cloud.fastbound.com/api/transfers";

#[derive(Debug, Serialize, Deserialize)]
struct Item {
    manufacturer: String,
    importer: Option<String>,
    country: String,
    model: String,
    caliber: String,
    #[serde(rename = "type")]
    item_type: String,
    serial: String,
    sku: String,
    mpn: String,
    upc: String,
    barrel_length: f64,
    overall_length: f64,
    cost: f64,
    price: f64,
    condition: String,
    note: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct TransferPayload {
    #[serde(rename = "$schema")]
    schema: String,
    idempotency_key: String,
    transferor: String,
    transferee: String,
    transferee_emails: Vec<String>,
    tracking_number: String,
    po_number: String,
    invoice_number: String,
    acquire_type: String,
    note: String,
    items: Vec<Item>,
}

fn generate_idempotency_key(
    shipment_date: &str,
    transferor: &str,
    transferee: &str,
    tracking_number: &str,
    po_number: &str,
    invoice_number: &str,
    serial_numbers: &[String],
) -> String {
    let data = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}",
        shipment_date,
        transferor,
        transferee,
        tracking_number,
        po_number,
        invoice_number,
        serial_numbers.join("\n")
    );

    let mut hasher = Sha256::new();
    hasher.update(data.as_bytes());
    format!("{:x}", hasher.finalize())
}

async fn send_post_request(json_payload: &str) -> Result<(), Box<dyn Error>> {
    let auth_string = BASE64.encode(format!("{}:{}", USERNAME, PASSWORD));
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Basic {}", auth_string))?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

    let client = reqwest::Client::new();
    let response = client
        .post(API_URL)
        .headers(headers)
        .body(json_payload.to_string())
        .send()
        .await?;

    println!("HTTP Code: {}", response.status());
    println!("Response: {}", response.text().await?);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let shipment_date = Utc::now().format("%Y-%m-%d").to_string();
    let transferor = "1-23-456-78-9A-12345";
    let transferee = "1-23-456-78-9B-54321";
    let tracking_number = "1Z999AA10123456784";
    let po_number = "PO123456";
    let invoice_number = "INV98765";

    let items = vec![
        Item {
            manufacturer: "Glock".to_string(),
            importer: None,
            country: "Austria".to_string(),
            model: "G17".to_string(),
            caliber: "9mm".to_string(),
            item_type: "Pistol".to_string(),
            serial: "ABC123456".to_string(),
            sku: "GLK-G17".to_string(),
            mpn: "G17MPN".to_string(),
            upc: "123456789012".to_string(),
            barrel_length: 4.48,
            overall_length: 8.03,
            cost: 500.00,
            price: 650.00,
            condition: "New".to_string(),
            note: "Brand new firearm".to_string(),
        },
        Item {
            manufacturer: "Smith & Wesson".to_string(),
            importer: None,
            country: "USA".to_string(),
            model: "M&P Shield".to_string(),
            caliber: "9mm".to_string(),
            item_type: "Pistol".to_string(),
            serial: "XYZ987654".to_string(),
            sku: "S&W-SHIELD".to_string(),
            mpn: "SHIELDMPN".to_string(),
            upc: "987654321098".to_string(),
            barrel_length: 3.1,
            overall_length: 6.1,
            cost: 450.00,
            price: 600.00,
            condition: "New".to_string(),
            note: "Compact pistol".to_string(),
        },
    ];

    let serial_numbers: Vec<String> = items.iter().map(|item| item.serial.clone()).collect();
    let idempotency_key = generate_idempotency_key(
        &shipment_date,
        transferor,
        transferee,
        tracking_number,
        po_number,
        invoice_number,
        &serial_numbers,
    );

    let payload = TransferPayload {
        schema: "https://schemas.fastbound.org/transfers-push-v1.json".to_string(),
        idempotency_key,
        transferor: transferor.to_string(),
        transferee: transferee.to_string(),
        transferee_emails: vec![
            "transferee@example.com".to_string(),
            "transferee@example.net".to_string(),
            "transferee@example.org".to_string(),
        ],
        tracking_number: tracking_number.to_string(),
        po_number: po_number.to_string(),
        invoice_number: invoice_number.to_string(),
        acquire_type: "Purchase".to_string(),
        note: "This is a test transfer.".to_string(),
        items,
    };

    let json_payload = serde_json::to_string_pretty(&payload)?;
    send_post_request(&json_payload).await?;

    Ok(())
} 