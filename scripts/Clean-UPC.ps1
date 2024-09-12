param(
    [Parameter(Mandatory=$true)]
    [string]$incsv,

    [Parameter(Mandatory=$true)]
    [string]$outcsv,

    [string]$upc = "UPC"
)

$csvData = Import-Csv -Path $incsv
$updatedRows = @()

foreach ($row in $csvData) {
    $upcValue = $row.$upc

    if ($upcValue -match "^\d{11,18}$") {
        $row.$upc = $upcValue
    } else {
        $row.$upc = ""
    }

    $updatedRows += $row
}

$updatedRows | Export-Csv -Path $outcsv -NoTypeInformation

Write-Output "Updated CSV has been saved to $outcsv"