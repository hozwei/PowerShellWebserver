#Requires -Version 7.0
<#
.SYNOPSIS
    Client: POST /post-json.ps1 — JSON body with nested objects + arrays.

.DESCRIPTION
    Pairs with `webroot/post-json.ps1`. Sends a structured JSON body;
    the server writes it to disk and passes the file path via
    -JsonFilePath. The webroot script parses the file and echoes a
    summary back.

.PARAMETER FirstName
    Demo input — first name.

.PARAMETER LastName
    Demo input — last name.

.PARAMETER Roles
    Array of role names to send.

.EXAMPLE
    .\Send-PostJson.ps1 -FirstName Anna -LastName Mueller -Roles admin,reader
#>
param(
    [string]   $FirstName = 'Anna',
    [string]   $LastName  = 'Mueller',
    [string[]] $Roles     = @('admin', 'reader')
)

. $PSScriptRoot/_Common.ps1

$body = @{
    firstName  = $FirstName
    lastName   = $LastName
    department = @{ name = 'IT'; costCenter = '4200' }
    roles      = $Roles
}

$envelope = Invoke-Posh -Path '/post-json.ps1' -Method POST -Body $body
if ($envelope.exitCode -ne 0) {
    $envelope | Write-Envelope
    return
}

$echo = $envelope.output | ConvertFrom-Json -Depth 10
Write-Host ('Received at : {0}' -f $echo.receivedAt)
Write-Host ('Body bytes  : {0}' -f $echo.bodyBytes)
Write-Host ('Full name   : {0}' -f $echo.parsed.fullName)
Write-Host ('Department  : {0} (cc {1})' -f $echo.parsed.department.name, $echo.parsed.department.costCenter)
Write-Host ('Role count  : {0}' -f $echo.parsed.roleCount)
foreach ($r in $echo.parsed.roles) { Write-Host "  - $r" }
