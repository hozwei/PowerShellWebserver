#Requires -Version 7.0
<#
.SYNOPSIS
    Example script demonstrating JSON file passthrough for POST requests.

.DESCRIPTION
    The server writes the POST body to a .json file in C:\posh\postjson\ and passes
    the absolute file path via -JsonFilePath. This script reads and parses that file,
    then accesses individual fields — including nested objects and arrays.

    This is the recommended pattern for all POST-based webroot scripts.
    The JSON file remains on disk after execution for audit and debugging purposes.

.PARAMETER JsonFilePath
    Absolute path to the JSON file written by the server. Passed automatically
    by Start-WebServer.ps1 — do not set this manually.

.EXAMPLE
    # Call via curl (requires X-Api-Key header):
    curl -X POST http://localhost/post-example.ps1 `
         -H "Content-Type: application/json" `
         -H "X-Api-Key: your-api-key" `
         -d '{"firstName":"Anna","lastName":"Müller","department":{"name":"IT","costCenter":"4200"},"roles":["admin","user"]}'

    # Call via Invoke-RestMethod:
    $body = @{
        firstName  = 'Anna'
        lastName   = 'Müller'
        department = @{ name = 'IT'; costCenter = '4200' }
        roles      = @('admin', 'user')
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method POST -Uri 'http://localhost/post-example.ps1' `
        -ContentType 'application/json' `
        -Headers @{ 'X-Api-Key' = 'your-api-key' } `
        -Body $body
#>

param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Validate: server must have provided a valid file path.
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
    Write-Error 'JsonFilePath parameter is missing. This script must be called via POST.'
    exit 1
}

if (-not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error "JSON file not found: $JsonFilePath"
    exit 1
}

# ------------------------------------------------------------------
# Read and parse the JSON file.
# ConvertFrom-Json with -Depth 10 supports deeply nested structures.
# ------------------------------------------------------------------
$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 10

# ------------------------------------------------------------------
# Access top-level scalar fields.
# ------------------------------------------------------------------
$firstName = $data.firstName
$lastName  = $data.lastName

# ------------------------------------------------------------------
# Access a nested object.
# ------------------------------------------------------------------
$deptName       = $data.department.name
$deptCostCenter = $data.department.costCenter

# ------------------------------------------------------------------
# Access an array — iterate or index directly.
# ------------------------------------------------------------------
$roles     = $data.roles
$roleCount = if ($roles) { @($roles).Count } else { 0 }
$roleList  = if ($roles) { ($roles -join ', ') } else { '(none)' }

# ------------------------------------------------------------------
# Output — ends up in the "output" field of the JSON response.
# ------------------------------------------------------------------
Write-Output "Name:        $firstName $lastName"
Write-Output "Department:  $deptName (Cost Center: $deptCostCenter)"
Write-Output "Roles ($roleCount): $roleList"
Write-Output "JSON file:   $JsonFilePath"
