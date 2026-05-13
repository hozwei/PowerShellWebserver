#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /users/<id> — REST routing via the F9 placeholder.

.DESCRIPTION
    Pairs with `webroot/users/[id].ps1` AND `webroot/users/admin.ps1`.
    Same client URL (`/users/<id>`) but the response differs:

        /users/admin   -> served by users/admin.ps1 (exact-filename wins)
        /users/<other> -> served by users/[id].ps1   (placeholder fallback)

    Requires `PathPlaceholders = $true` in the active config.psd1.
    Without it, every non-literal URL returns 404.

.PARAMETER Id
    User id to fetch. Pass 'admin' to hit the specific handler.

.PARAMETER Detail
    Forwarded to the script as a query parameter.

.EXAMPLE
    .\Get-User.ps1 -Id 42 -Detail
    .\Get-User.ps1 -Id admin
#>
param(
    [Parameter(Mandatory)][string] $Id,
    [switch] $Detail
)

. $PSScriptRoot/_Common.ps1

$query = @{}
if ($Detail) { $query.Detail = 'true' }

$envelope = Invoke-Posh -Path ("/users/$Id") -Query $query -SkipHttpErrorCheck

if ($envelope.exitCode -ne 0) {
    Write-Host "Endpoint returned exitCode=$($envelope.exitCode)" -ForegroundColor Red
    $envelope | Write-Envelope
    return
}

$user = $envelope.output | ConvertFrom-Json -Depth 10
Write-Host '--- user record ---'
$user | ConvertTo-Json -Depth 5
