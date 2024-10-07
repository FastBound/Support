<?php

// Set the content type to application/json
header('Content-Type: application/json');

// Capture the start time
$startTime = microtime(true);

// Configurable delay in seconds
$delaySeconds = 5;

// Function to respond slowly so someone trying to guess is slowed way down
function respondSlowly($startTime, $message) {
    global $delaySeconds; // Access the global variable

    // Prepare the error response
    $errorResponse = [
        "success" => false,
        "message" => $message
    ];

    // Calculate execution time
    $executionTime = microtime(true) - $startTime;

    // Calculate delay to maintain consistent response time
    $delay = max(0, $delaySeconds - $executionTime);
    usleep($delay * 1000000); // Delay in microseconds

    echo json_encode($errorResponse);
    exit;
}

// Check if the request method is POST
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    
    // Something that the customer has, like a packing list number
    $identifier = isset($_POST['identifier']) ? trim($_POST['identifier']) : null;

    // Something the customer knows, like an account or customer number
    $verifier = isset($_POST['verifier']) ? trim($_POST['verifier']) : null;

    // Check if both variables are provided
    if (empty($identifier) || empty($verifier)) {
        respondSlowly($startTime, "No matching packing list found.");
    }

    // Assuming you have a database connection established here
    $pdo = new PDO('mysql:host=localhost;dbname=your_database', 'username', 'password');
    $stmt = $pdo->prepare("SELECT * FROM `PACKING_LIST` WHERE `id` = :identifier AND `customer` = :verifier LIMIT 1");
    $stmt->execute(['identifier' => $identifier, 'verifier' => $verifier]);
    $record = $stmt->fetch();

    // Check if a record was found
    if (!$record) {
        respondSlowly($startTime, "No matching packing list found.");
    }

    // Now select the firearms
    $itemsStmt = $pdo->prepare("SELECT * FROM `PACKING_LIST_ITEMS` WHERE `packing_list_id` = :packing_list_id AND `type` = 'firearm'");
    $itemsStmt->execute(['packing_list_id' => $record['id']]);
    $items = $itemsStmt->fetchAll(PDO::FETCH_ASSOC);

    // Create the items array for the response
    $responseItems = [];
    foreach ($items as $item) {
        $responseItems[] = [
            "manufacturer" => $item['manufacturer'], // "GLOCK"
            "importer" => $item['importer'], // "GLOCK INC"
            "country" => $item['country'], // "AUSTRIA"
            "model" => $item['model'], // "17"
            "caliber" => $item['caliber'], // "9x19"
            "type" => $item['type'], // "Pistol"
            "serial" => $item['serial'], // "XYP4567" or "QZR2345"
            "mpn" => $item['mpn'], // "PI1750201"
            "upc" => $item['upc'], // "764503175022"
            "barrelLength" => (float)$item['barrelLength'], // 4.48 or null
            "overallLength" => (float)$item['overallLength'], // 8.03 or null
            "sku" => $item['sku'], // null
            "cost" => (float)$item['cost'], // 499.99 or null
            "price" => (float)$item['price'], // 599.99 or null
            "condition" => $item['condition'], // "New"
            "note" => $item['note'] // "XYP4567 has extra magazines" or "QZR2345 is new but open box"
        ];
    }

    // If firearms found, respond with an empty items array
    if (empty($responseItems)) {
        $responseItems = [];
    }

    // If a record is found, create the response array
    $response = [
        "fastbound_transfer_version" => 2015, // Required. Let's FastBound know the format of your response.
        "success" => true, // Set success to true
        "transferor" => $record['transferor'], // "1-22-333-44-5J-66666" -- transferor's FFL number, FastBound will take care of the rest 
        "tracking_number" => $record['tracking_number'], // "1Z999AA10123456789" -- FastBound will create a link to a UPS, FedEx, DHL, or USPS tracking number
        "po_number" => $record['po_number'], // "PO12345" -- customer's purchase order number or null
        "invoice_number" => $record['invoice_number'], // "INV12345" -- customer's invoice number or null
        "acquire_type" => $record['acquire_type'], // "Purchase" -- not an ATF field: Purchase is most common
        "note" => $record['note'], // "This order is for JOHN Q. PUBLIC" -- optional acquisition note regarding all items in this acquisition 
        "items" => $responseItems // Add the dynamically fetched items
    ];

    // Close the database connection
    $pdo = null; // Set PDO object to null to close the connection

    // Return the JSON response immediately for successful requests
    echo json_encode($response);
    exit;
}

// If accessed directly (not a POST request), return an error response immediately
echo json_encode([
    "success" => false,
    "message" => "Invalid request method. Please use POST."
]);
?>
