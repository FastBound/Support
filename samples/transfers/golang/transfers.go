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
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
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
	payload := NewFastBoundTransferPayload(
		transferor, transferee, items,
		[]string{"transferee@example.com"},
		"1Z999AA10123456784", "PO123456", "INV98765", "Purchase",
		"2-unit dealer stock order, shipped UPS Ground insured, signature required on delivery",
	)

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

func NewFastBoundTransferPayload(
	transferor, transferee string, items []FastBoundTransferItem,
	transfereeEmails []string, trackingNumber, poNumber, invoiceNumber, acquireType, note string,
) *FastBoundTransferPayload {
	return &FastBoundTransferPayload{
		Schema:           "https://schemas.fastbound.org/transfers-push-v1.json",
		IdempotencyKey:   buildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber, items),
		Transferor:       transferor,
		Transferee:       transferee,
		TransfereeEmails: transfereeEmails,
		TrackingNumber:   trackingNumber,
		PoNumber:         poNumber,
		InvoiceNumber:    invoiceNumber,
		AcquireType:      acquireType,
		Note:             note,
		Items:            items,
	}
}

func buildIdempotencyKey(transferor, transferee, trackingNumber, poNumber, invoiceNumber string, items []FastBoundTransferItem) string {
	parts := []string{
		time.Now().UTC().Format("2006-01-02"),
		transferor, transferee,
		trackingNumber, poNumber, invoiceNumber,
	}
	for _, item := range items {
		parts = append(parts, item.Serial)
	}
	hash := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return fmt.Sprintf("%x", hash)
}
