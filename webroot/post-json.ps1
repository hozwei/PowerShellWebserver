#Requires -Version 7.0
<#
.SYNOPSIS
    POST endpoint demonstrating the -JsonFilePath contract.

.DESCRIPTION
    The server writes every POST body verbatim to
    `<PostJsonDir>\YYYYMMDD_HHmmss_<requestId>.json` and passes the
    absolute path via the `-JsonFilePath` parameter. Scripts read and
    parse that file themselves, which means nested objects, arrays, and
    large payloads all work — there is no flattening into
    command-line arguments.

    This script echoes the body back as a structured response: it
    shows scalar access, nested-object traversal, and array iteration.

.PARAMETER JsonFilePath
    Absolute path to the JSON file written by the server. Injected
    automatically by `Start-WebServer.ps1` — do NOT set manually.

.EXAMPLE
    $body = @{
        firstName  = 'Anna'
        lastName   = 'Mueller'
        department = @{ name = 'IT'; costCenter = '4200' }
        roles      = @('admin', 'reader')
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method POST -Uri 'http://localhost/post-json.ps1' `
        -ContentType 'application/json' `
        -Headers @{ 'X-Api-Key' = 'your-key' } `
        -Body $body
#>
param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
    Write-Error 'JsonFilePath missing. Call this endpoint via HTTP POST.'
    exit 1
}
if (-not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error "JSON file not found: $JsonFilePath"
    exit 1
}

$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 10

# Defensive accessors — every field is optional so the example also serves
# as a template for real endpoints that need to handle partial payloads.
$firstName = if ($data.PSObject.Properties['firstName']) { $data.firstName } else { '<missing>' }
$lastName  = if ($data.PSObject.Properties['lastName'])  { $data.lastName  } else { '<missing>' }

$deptName       = '<missing>'
$deptCostCenter = '<missing>'
if ($data.PSObject.Properties['department']) {
    $deptName       = $data.department.name
    $deptCostCenter = $data.department.costCenter
}

$roles = if ($data.PSObject.Properties['roles']) { @($data.roles) } else { @() }

$echo = [ordered]@{
    receivedAt   = (Get-Date).ToString('o')
    bodyPath     = $JsonFilePath
    bodyBytes    = (Get-Item -LiteralPath $JsonFilePath).Length
    parsed = [ordered]@{
        fullName    = "$firstName $lastName".Trim()
        department  = [ordered]@{ name = $deptName; costCenter = $deptCostCenter }
        roleCount   = $roles.Count
        roles       = $roles
    }
}

$echo | ConvertTo-Json -Depth 5
exit 0
