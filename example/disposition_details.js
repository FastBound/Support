const express = require('express');
const mysql = require('mysql2/promise'); // Using mysql2 for promise-based queries
const app = express();

// Middleware to parse JSON bodies
app.use(express.json());

const delaySeconds = 5;

// Function to respond slowly
async function respondSlowly(startTime, message, res) {
    const executionTime = (Date.now() - startTime) / 1000;
    const delay = Math.max(0, delaySeconds - executionTime);

    await new Promise(resolve => setTimeout(resolve, delay * 1000)); // Delay in seconds

    res.json({
        success: false,
        message: message
    });
}

// MySQL database connection configuration
const dbConfig = {
    host: 'localhost',
    user: 'username',
    password: 'password',
    database: 'your_database'
};

// POST route to handle requests
app.post('/your-endpoint', async (req, res) => {
    const startTime = Date.now();

    const identifier = req.body.identifier ? req.body.identifier.trim() : null;
    const verifier = req.body.verifier ? req.body.verifier.trim() : null;

    if (!identifier || !verifier) {
        return respondSlowly(startTime, "No matching packing list found.", res);
    }

    try {
        // Establish a connection to the database
        const connection = await mysql.createConnection(dbConfig);

        // Fetch the packing list record
        const [records] = await connection.execute(
            'SELECT * FROM `PACKING_LIST` WHERE `id` = ? AND `customer` = ? LIMIT 1',
            [identifier, verifier]
        );

        const record = records[0];

        if (!record) {
            return respondSlowly(startTime, "No matching packing list found.", res);
        }

        // Fetch the firearms
        const [items] = await connection.execute(
            'SELECT * FROM `PACKING_LIST_ITEMS` WHERE `packing_list_id` = ? AND `type` = ?',
            [record.id, 'firearm']
        );

        const responseItems = items.map(item => ({
            manufacturer: item.manufacturer,
            importer: item.importer,
            country: item.country,
            model: item.model,
            caliber: item.caliber,
            type: item.type,
            serial: item.serial,
            mpn: item.mpn,
            upc: item.upc,
            barrelLength: parseFloat(item.barrelLength),
            overallLength: parseFloat(item.overallLength),
            sku: item.sku,
            cost: parseFloat(item.cost),
            price: parseFloat(item.price),
            condition: item.condition,
            note: item.note
        }));

        // Create the response object
        const response = {
            fastbound_transfer_version: 2015,
            success: true,
            transferor: record.transferor,
            tracking_number: record.tracking_number,
            po_number: record.po_number,
            invoice_number: record.invoice_number,
            acquire_type: record.acquire_type,
            note: record.note,
            items: responseItems
        };

        // Return the JSON response
        res.json(response);
    } catch (error) {
        console.error(error);
        res.status(500).json({
            success: false,
            message: "An error occurred while processing the request."
        });
    }
});

// Handle invalid request methods
app.use((req, res) => {
    res.status(405).json({
        success: false,
        message: "Invalid request method. Please use POST."
    });
});

// Start the server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`Server is running on port ${PORT}`);
});
