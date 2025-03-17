package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

const (
	USERNAME = "YOUR_USERNAME"
	PASSWORD = "YOUR_PASSWORD"
	API_URL  = "https://cloud.fastbound.com/api/transfers"
)

type Item struct {
	Manufacturer  string  `json:"manufacturer"`
	Importer      *string `json:"importer"`
	Country       string  `json:"country"`
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

type TransferPayload struct {
	Schema           string   `json:"$schema"`
	IdempotencyKey   string   `json:"idempotency_key"`
	Transferor       string   `json:"transferor"`
	Transferee       string   `json:"transferee"`
	TransfereeEmails []string `json:"transferee_emails"`
	TrackingNumber   string   `json:"tracking_number"`
	PoNumber         string   `json:"po_number"`
	InvoiceNumber    string   `json:"invoice_number"`
	AcquireType      string   `json:"acquire_type"`
	Note             string   `json:"note"`
	Items            []Item   `json:"items"`
}

func generateIdempotencyKey(data []string) string {
	hash := sha256.Sum256([]byte(strings.Join(data, "\n")))
	return fmt.Sprintf("%x", hash)
}

func sendPostRequest(jsonPayload []byte) {
	authString := base64.StdEncoding.EncodeToString([]byte(USERNAME + ":" + PASSWORD))

	req, err := http.NewRequest("POST", API_URL, bytes.NewBuffer(jsonPayload))
	if err != nil {
		fmt.Println("Error creating request:", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Basic "+authString)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("Error sending request:", err)
		return
	}
	defer resp.Body.Close()

	body, _ := ioutil.ReadAll(resp.Body)
	fmt.Printf("HTTP Code: %d\n", resp.StatusCode)
	fmt.Println("Response:", string(body))
}

func main() {
	shipmentDate := time.Now().Format("2006-01-02")

	transferor := "1-23-456-78-9A-12345"
	transferee := "1-23-456-78-9B-54321"
	trackingNumber := "1Z999AA10123456784"
	poNumber := "PO123456"
	invoiceNumber := "INV98765"

	items := []Item{
		{"Glock", nil, "Austria", "G17", "9mm", "Pistol", "ABC123456", "GLK-G17", "G17MPN", "123456789012", 4.48, 8.03, 500.00, 650.00, "New", "Brand new firearm"},
		{"Smith & Wesson", nil, "USA", "M&P Shield", "9mm", "Pistol", "XYZ987654", "S&W-SHIELD", "SHIELDMPN", "987654321098", 3.1, 6.1, 450.00, 600.00, "New", "Compact pistol"},
	}

	serialNumbers := []string{}
	for _, item := range items {
		serialNumbers = append(serialNumbers, item.Serial)
	}

	idempotencyKey := generateIdempotencyKey(append([]string{shipmentDate, transferor, transferee, trackingNumber, poNumber, invoiceNumber}, serialNumbers...))

	payload := TransferPayload{
		Schema:           "https://schemas.fastbound.org/transfers-push-v1.json",
		IdempotencyKey:   idempotencyKey,
		Transferor:       transferor,
		Transferee:       transferee,
		TransfereeEmails: []string{"transferee@example.com", "transferee@example.net", "transferee@example.org"},
		TrackingNumber:   trackingNumber,
		PoNumber:         poNumber,
		InvoiceNumber:    invoiceNumber,
		AcquireType:      "Purchase",
		Note:             "This is a test transfer.",
		Items:            items,
	}

	jsonPayload, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		fmt.Println("Error marshalling JSON:", err)
		return
	}

	sendPostRequest(jsonPayload)
}
