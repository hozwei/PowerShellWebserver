#Requires -Version 7.0
<#
.SYNOPSIS
    Client: round-trips a session cookie across two GET /session.ps1 calls.

.DESCRIPTION
    Pairs with `webroot/session.ps1`. First call seeds the cookie via
    -SessionVariable; second call reuses the cookie via -WebSession.
    Output proves the server saw the same session id on both calls
    (only when `SessionEnabled = $true` is active in config.psd1).

.EXAMPLE
    .\Test-Session.ps1
#>

. $PSScriptRoot/_Common.ps1

# A fresh WebRequestSession captures the cookie the server sets on the first
# response. Passing the same instance to the second call replays the cookie,
# so the server sees the same POSH-Session-Id on both calls when
# SessionEnabled is on.
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$first   = Invoke-Posh -Path '/session.ps1' -Session $session
$second  = Invoke-Posh -Path '/session.ps1' -Session $session

$firstParsed  = $first.output  | ConvertFrom-Json -Depth 5
$secondParsed = $second.output | ConvertFrom-Json -Depth 5

Write-Host '--- First call ---'
$firstParsed | ConvertTo-Json -Depth 5

Write-Host ''
Write-Host '--- Second call (same session) ---'
$secondParsed | ConvertTo-Json -Depth 5

Write-Host ''
if ($firstParsed.sessionEnabled -and $firstParsed.sessionId -eq $secondParsed.sessionId) {
    Write-Host 'OK: cookie round-trip works — same session id observed on both calls.' -ForegroundColor Green
} elseif (-not $firstParsed.sessionEnabled) {
    Write-Host 'SessionEnabled is $false in config.psd1 — flip it on to use cookies.' -ForegroundColor Yellow
} else {
    Write-Host ('Mismatch: first={0}  second={1}' -f $firstParsed.sessionId, $secondParsed.sessionId) -ForegroundColor Red
}
