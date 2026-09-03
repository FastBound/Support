#!/usr/bin/env -S cargo +nightly -Zscript
---
[dependencies]
tokio = { version = "1.0", features = ["full"] }
reqwest = { version = "0.11", features = ["json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
base64 = "0.21"
sha2 = "0.10"
---
// Copyright © FastBound Inc. All rights reserved.
//
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/rs
//
// Requires: Rust 1.77+ (cargo script)
// Dependencies: reqwest, tokio, serde, serde_json, sha2, base64
//
// Run: cargo +nightly -Zscript transfers.rs

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::error::Error;

// --- Demo usage ---

const USERNAME: &str = "YOUR_USERNAME";
const PASSWORD: &str = "YOUR_PASSWORD";

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let transferor = "1-23-456-78-9A-12345";
    let transferee = "1-23-456-78-9B-54321";

    let items = vec![
        FastBoundTransferItem {
            manufacturer: "Glock".into(),
            importer: Some("Glock, Inc.".into()),
            country: Some("Austria".into()),
            model: "17".into(),
            caliber: "9X19".into(),
            item_type: "Pistol".into(),
            serial: "ABC123456".into(),
            sku: "GLK-G17".into(),
            mpn: "PA1750203".into(),
            upc: "764503022616".into(),
            barrel_length: 4.48,
            overall_length: 8.03,
            cost: 500.00,
            price: 650.00,
            condition: "New".into(),
            note: "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush".into(),
        },
        FastBoundTransferItem {
            manufacturer: "Smith & Wesson".into(),
            importer: None,
            country: None,
            model: "M&P 9 Shield".into(),
            caliber: "9MM".into(),
            item_type: "Pistol".into(),
            serial: "XYZ987654".into(),
            sku: "S&W-SHIELD".into(),
            mpn: "10035".into(),
            upc: "022188864151".into(),
            barrel_length: 3.1,
            overall_length: 6.1,
            cost: 450.00,
            price: 600.00,
            condition: "New".into(),
            note: "No thumb safety, factory case, 7rd flush and 8rd extended mags".into(),
        },
    ];

    let client = FastBoundTransferClient::new(USERNAME, PASSWORD, None);
    let payload = FastBoundTransferPayload::create(
        transferor,
        transferee,
        items,
        vec!["transferee@example.com".into()],
        Some("1Z999AA10123456784".into()),
        Some("PO123456".into()),
        Some("INV98765".into()),
        "Purchase",
        Some("2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery".into()),
        // Prefer your own transaction id, so a retry — even days later, from another
        // process — resolves to the same key. Bump the revision suffix when you mean to
        // send a genuinely new transfer for the same order. Pass None instead and one is
        // derived from the shipment's identifying fields.
        Some("po-123456:rev1".into()),
    )?;

    let result = client.send_transfer(&payload).await?;
    println!("HTTP Code: {}", result.status_code);
    println!("Response: {}", result.body);

    Ok(())
}

// --- Reusable client ---

struct FastBoundTransferClient {
    api_url: String,
    auth_header: String,
}

struct FastBoundTransferResult {
    status_code: u16,
    body: String,
}

impl FastBoundTransferClient {
    fn new(username: &str, password: &str, api_url: Option<&str>) -> Self {
        let url = api_url.unwrap_or("https://cloud.fastbound.com/api/transfers");
        let auth = BASE64.encode(format!("{username}:{password}"));
        Self {
            api_url: url.into(),
            auth_header: format!("Basic {auth}"),
        }
    }

    async fn send_transfer(&self, payload: &FastBoundTransferPayload) -> Result<FastBoundTransferResult, Box<dyn Error>> {
        let json_payload = serde_json::to_string(payload)?;

        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, HeaderValue::from_str(&self.auth_header)?);
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));

        let client = reqwest::Client::new();
        let response = client
            .post(&self.api_url)
            .headers(headers)
            .body(json_payload)
            .send()
            .await?;

        let status_code = response.status().as_u16();
        let body = response.text().await?;
        Ok(FastBoundTransferResult { status_code, body })
    }
}

// --- Domain types ---

#[derive(Debug, Serialize, Deserialize)]
struct FastBoundTransferItem {
    manufacturer: String,
    importer: Option<String>,
    country: Option<String>,
    model: String,
    caliber: String,
    #[serde(rename = "type")]
    item_type: String,
    serial: String,
    sku: String,
    mpn: String,
    upc: String,
    #[serde(rename = "barrelLength")]
    barrel_length: f64,
    #[serde(rename = "overallLength")]
    overall_length: f64,
    cost: f64,
    price: f64,
    condition: String,
    note: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct FastBoundTransferPayload {
    #[serde(rename = "$schema")]
    schema: String,
    idempotency_key: String,
    transferor: String,
    transferee: String,
    transferee_emails: Vec<String>,
    tracking_number: Option<String>,
    po_number: Option<String>,
    invoice_number: Option<String>,
    acquire_type: String,
    note: Option<String>,
    items: Vec<FastBoundTransferItem>,
}

impl FastBoundTransferPayload {
    /// Builds a transfer payload. Pass `idempotency_key` to reuse your own transaction id
    /// — the preferred form; pass `None` to derive one from the shipment's identifying
    /// fields instead.
    #[allow(clippy::too_many_arguments)]
    fn create(
        transferor: &str, transferee: &str, items: Vec<FastBoundTransferItem>,
        transferee_emails: Vec<String>,
        tracking_number: Option<String>, po_number: Option<String>,
        invoice_number: Option<String>, acquire_type: &str, note: Option<String>,
        idempotency_key: Option<String>,
    ) -> Result<Self, String> {
        let key = match idempotency_key {
            None => Self::derive_idempotency_key(
                transferor, transferee,
                tracking_number.as_deref(), po_number.as_deref(),
                invoice_number.as_deref(), &items,
            )?,
            Some(key) => Self::validate_idempotency_key(&key)?,
        };
        Ok(Self {
            schema: "https://schemas.fastbound.org/transfers-push-v1.json".into(),
            idempotency_key: key,
            transferor: transferor.into(),
            transferee: transferee.into(),
            transferee_emails,
            tracking_number,
            po_number,
            invoice_number,
            acquire_type: acquire_type.into(),
            note,
            items,
        })
    }

    fn validate_idempotency_key(key: &str) -> Result<String, String> {
        if key.trim().is_empty() {
            return Err("idempotency_key must not be blank.".into());
        }
        // The API caps the field at 255 characters; catching it here beats a 400 on a
        // request that has already been accepted once under a truncated key.
        let length = key.chars().count();
        if length > 255 {
            return Err(format!(
                "idempotency_key must be at most 255 characters (got {length})."
            ));
        }
        Ok(key.to_owned())
    }

    /// Fallback for callers with no transaction id of their own to reuse.
    ///
    /// Reads no clock. A retry after a timeout is the case this key exists for, and a key
    /// containing today's date changes at midnight — mid-afternoon in US time zones —
    /// handing the retry a fresh key and creating the duplicate it was meant to stop.
    /// Serials are sorted because item order carries no meaning, so a retry that
    /// re-serializes from an unordered source must not read as a second shipment.
    fn derive_idempotency_key(
        transferor: &str, transferee: &str,
        tracking_number: Option<&str>, po_number: Option<&str>,
        invoice_number: Option<&str>, items: &[FastBoundTransferItem],
    ) -> Result<String, String> {
        let is_blank = |value: Option<&str>| value.unwrap_or("").is_empty();
        if is_blank(tracking_number) && is_blank(po_number) && is_blank(invoice_number) {
            return Err(
                "Cannot derive an idempotency key from the FFL numbers and serials alone: two \
                 separate orders of the same firearms between the same parties would collide and \
                 the second would be dropped as a duplicate. Pass idempotency_key, or supply a \
                 tracking, PO or invoice number."
                    .into(),
            );
        }

        // Byte-order sort, not locale-aware, so that every language port of this sample
        // agrees on the key for the same transfer.
        let mut serials: Vec<&str> = items.iter().map(|i| i.serial.as_str()).collect();
        serials.sort_unstable();

        let mut parts = vec![
            transferor,
            transferee,
            tracking_number.unwrap_or(""),
            po_number.unwrap_or(""),
            invoice_number.unwrap_or(""),
        ];
        parts.extend(serials);

        let mut hasher = Sha256::new();
        hasher.update(canonicalize(&parts).as_bytes());
        Ok(format!("sha256:{:x}", hasher.finalize()))
    }
}

/// Length-prefixes each part so no field can impersonate another.
///
/// Concatenating with a plain separator is ambiguous when a field may contain that
/// separator and the tail is variable-length: `invoice_number` `"INV-1\nABC123"` with no
/// items and `invoice_number` `"INV-1"` with serial `"ABC123"` produce the same joined
/// string, so two different transfers collide on one key. Prefixing with the UTF-8 byte
/// count — bytes, not characters, so ports to other languages agree — makes the encoding
/// unambiguous.
fn canonicalize(parts: &[&str]) -> String {
    parts
        .iter()
        .map(|part| format!("{}:{}", part.len(), part))
        .collect()
}
