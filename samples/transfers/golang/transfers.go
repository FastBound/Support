// Copyright © FastBound Inc. All rights reserved.
//
// Reference implementation — not intended for production use without review and adaptation.
// Source: https://github.com/FastBound/Support/tree/main/samples/transfers/golang
//
// Requires: Go 1.21+
// Dependencies: none — uses only the standard library

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
)

// --- Demo usage ---

const (
	USERNAME = "YOUR_USERNAME"
	PASSWORD = "YOUR_PASSWORD"
)

func main() {
	transferor := "1-23-456-78-9A-12345"
	transferee := "1-23-456-78-9B-54321"

	items := []FastBoundTransferItem{
		{
			Manufacturer:  "Glock",
			Importer:      strPtr("Glock, Inc."),
			Country:       strPtr("Austria"),
			Model:         "17",
			Caliber:       "9X19",
			Type:          "Pistol",
			Serial:        "ABC123456",
			SKU:           "GLK-G17",
			MPN:           "PA1750203",
			UPC:           "764503022616",
			BarrelLength:  4.48,
			OverallLength: 8.03,
			Cost:          500.00,
			Price:         650.00,
			Condition:     "New",
			Note:          "Gen 5, nDLC finish, factory case, 3x17rd mags, loader, brush",
		},
		{
			Manufacturer:  "Smith & Wesson",
			Importer:      nil,
			Country:       nil,
			Model:         "M&P 9 Shield",
			Caliber:       "9MM",
			Type:          "Pistol",
			Serial:        "XYZ987654",
			SKU:           "S&W-SHIELD",
			MPN:           "10035",
			UPC:           "022188864151",
			BarrelLength:  3.1,
			OverallLength: 6.1,
			Cost:          450.00,
			Price:         600.00,
			Condition:     "New",
			Note:          "No thumb safety, factory case, 7rd flush and 8rd extended mags",
		},
	}

	client := NewFastBoundTransferClient(USERNAME, PASSWORD, "")
	// Prefer your own transaction id, so a retry — even days later, from another
	// process — resolves to the same key. Bump the revision suffix when you mean to
	// send a genuinely new transfer for the same order. Pass "" instead and one is
	// derived from the shipment's identifying fields.
	payload, err := NewFastBoundTransferPayload(
		transferor, transferee, items,
		[]string{"transferee@example.com"},
		"1Z999AA10123456784", "PO123456", "INV98765", "Purchase",
		"2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
		"po-123456:rev1",
	)
	if err != nil {
		fmt.Println("Error:", err)
		return
	}

	statusCode, body, err := client.SendTransfer(payload)
	if err != nil {
		fmt.Println("Error:", err)
		return
	}
	fmt.Printf("HTTP Code: %d\n", statusCode)
	fmt.Println("Response:", body)
}

func strPtr(s string) *string { return &s }

// --- Reusable client ---

type FastBoundTransferClient struct {
	apiURL     string
	authHeader string
}

func NewFastBoundTransferClient(username, password, apiURL string) *FastBoundTransferClient {
	if apiURL == "" {
		apiURL = "https://cloud.fastbound.com/api/transfers"
	}
	auth := base64.StdEncoding.EncodeToString([]byte(username + ":" + password))
	return &FastBoundTransferClient{apiURL: apiURL, authHeader: "Basic " + auth}
}

func (c *FastBoundTransferClient) SendTransfer(payload *FastBoundTransferPayload) (int, string, error) {
	jsonPayload, err := json.Marshal(payload)
	if err != nil {
		return 0, "", fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequest("POST", c.apiURL, bytes.NewBuffer(jsonPayload))
	if err != nil {
		return 0, "", fmt.Errorf("request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", c.authHeader)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("send: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body), nil
}

// --- Domain types ---

type FastBoundTransferItem struct {
	Manufacturer  string  `json:"manufacturer"`
	Importer      *string `json:"importer"`
	Country       *string `json:"country"`
	Model         string  `json:"model"`
	Caliber       string  `json:"caliber"`
	Type          string  `json:"type"`
	Serial        string  `json:"serial"`
	SKU           string  `json:"sku"`
	MPN           string  `json:"mpn"`
	UPC           string  `json:"upc"`
	BarrelLength  float64 `json:"barrelLength"`
	OverallLength float64 `json:"overallLength"`
	Cost          float64 `json:"cost"`
	Price         float64 `json:"price"`
	Condition     string  `json:"condition"`
	Note          string  `json:"note"`
}

type FastBoundTransferPayload struct {
	Schema           string                  `json:"$schema"`
	IdempotencyKey   string                  `json:"idempotency_key"`
	Transferor       string                  `json:"transferor"`
	Transferee       string                  `json:"transferee"`
	TransfereeEmails []string                `json:"transferee_emails"`
	TrackingNumber   string                  `json:"tracking_number"`
	PoNumber         string                  `json:"po_number"`
	InvoiceNumber    string                  `json:"invoice_number"`
	AcquireType      string                  `json:"acquire_type"`
	Note             string                  `json:"note"`
	Items            []FastBoundTransferItem `json:"items"`
}

// NewFastBoundTransferPayload builds a transfer payload. Pass idempotencyKey to reuse
// your own transaction id — the preferred form; pass "" to derive one from the
// shipment's identifying fields instead.
func NewFastBoundTransferPayload(
	transferor, transferee string, items []FastBoundTransferItem,
	transfereeEmails []string, trackingNumber, poNumber, invoiceNumber, acquireType, note string,
	idempotencyKey string,
) (*FastBoundTransferPayload, error) {
	var key string
	var err error
	if idempotencyKey == "" {
		key, err = deriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items)
	} else {
		key, err = validateIdempotencyKey(idempotencyKey)
	}
	if err != nil {
		return nil, err
	}
	return &FastBoundTransferPayload{
		Schema:           "https://schemas.fastbound.org/transfers-push-v1.json",
		IdempotencyKey:   key,
		Transferor:       transferor,
		Transferee:       transferee,
		TransfereeEmails: transfereeEmails,
		TrackingNumber:   trackingNumber,
		PoNumber:         poNumber,
		InvoiceNumber:    invoiceNumber,
		AcquireType:      acquireType,
		Note:             note,
		Items:            items,
	}, nil
}

func validateIdempotencyKey(key string) (string, error) {
	if strings.TrimSpace(key) == "" {
		return "", errors.New("idempotencyKey must not be blank")
	}
	// The API caps the field at 255 characters; catching it here beats a 400 on a
	// request that has already been accepted once under a truncated key.
	if len([]rune(key)) > 255 {
		return "", fmt.Errorf("idempotencyKey must be at most 255 characters (got %d)", len([]rune(key)))
	}
	return key, nil
}

// deriveIdempotencyKey is the fallback for callers with no transaction id of their own
// to reuse.
//
// It reads no clock. A retry after a timeout is the case this key exists for, and a key
// containing today's date changes at midnight — mid-afternoon in US time zones —
// handing the retry a fresh key and creating the duplicate it was meant to stop.
// Serials are sorted because item order carries no meaning, so a retry that
// re-serializes from an unordered source must not read as a second shipment.
func deriveIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber string, items []FastBoundTransferItem) (string, error) {
	if trackingNumber == "" && poNumber == "" && invoiceNumber == "" {
		return "", errors.New(
			"cannot derive an idempotency key from the FFL numbers and serials alone: two " +
				"separate orders of the same firearms between the same parties would collide and " +
				"the second would be dropped as a duplicate; pass idempotencyKey, or supply a " +
				"tracking, PO or invoice number")
	}
	serials := make([]string, 0, len(items))
	for _, item := range items {
		serials = append(serials, item.Serial)
	}
	// Ordinal (byte) sort, not locale-aware, so that every language port of this sample
	// agrees on the key for the same transfer.
	sort.Strings(serials)

	parts := append([]string{transferor, transferee, trackingNumber, poNumber, invoiceNumber}, serials...)
	hash := sha256.Sum256([]byte(canonicalize(parts)))
	return fmt.Sprintf("sha256:%x", hash), nil
}

// canonicalize length-prefixes each part so no field can impersonate another.
//
// Concatenating with a plain separator is ambiguous when a field may contain that
// separator and the tail is variable-length: invoice_number "INV-1\nABC123" with no
// items and invoice_number "INV-1" with serial "ABC123" produce the same joined string,
// so two different transfers collide on one key. Prefixing with the UTF-8 byte count —
// bytes, not characters, so ports to other languages agree — makes the encoding
// unambiguous.
func canonicalize(parts []string) string {
	var b strings.Builder
	for _, part := range parts {
		fmt.Fprintf(&b, "%d:%s", len(part), part)
	}
	return b.String()
}
