#Requires -Version 7.0
<#
.SYNOPSIS
    Client: exercises every Mode of /errors.ps1 and reports the resulting HTTP code.

.DESCRIPTION
    Pairs with `webroot/errors.ps1`. Useful to verify how exit codes,
    Write-Error, and terminating exceptions map to HTTP status codes
    after a server upgrade.

.PARAMETER IncludeTimeout
    Off by default — set this switch to also probe Mode=timeout. The
    server takes `ScriptTimeoutSec` (default 300s) to return a 504 in
    that case, so the test waits 5+ minutes when you include it.

.EXAMPLE
    .\Test-Errors.ps1
    .\Test-Errors.ps1 -IncludeTimeout
#>
param([switch] $IncludeTimeout)

. $PSScriptRoot/_Common.ps1

$cases = @(
    @{ Mode = 'ok';      Expected = @(200) }
    @{ Mode = 'warn';    Expected = @(200) }
    @{ Mode = 'fail';    Expected = @(500) }
    @{ Mode = 'throw';   Expected = @(500) }
    @{ Mode = 'unknown'; Expected = @(500) }
)
if ($IncludeTimeout) {
    $cases += @{ Mode = 'timeout'; Expected = @(504) }
}

$uri      = '{0}/errors.ps1' -f (Get-PoshBaseUrl)
$headers  = @{ 'X-Api-Key' = Get-PoshApiKey }
$failures = 0

foreach ($c in $cases) {
    $callUri = '{0}?Mode={1}' -f $uri, [uri]::EscapeDataString($c.Mode)
    try {
        $r = Invoke-WebRequest -Uri $callUri -Headers $headers -SkipHttpErrorCheck
        $status = [int]$r.StatusCode
    } catch {
        $status = 0
    }
    $ok = $c.Expected -contains $status
    $verdict = if ($ok) { 'OK ' } else { 'FAIL' }
    $color   = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('[{0}] Mode={1,-8} HTTP {2,3}  (expected {3})' -f $verdict, $c.Mode, $status, ($c.Expected -join ',')) -ForegroundColor $color
    if (-not $ok) { $failures++ }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'All cases matched expectation.' -ForegroundColor Green
} else {
    Write-Host ("{0} case(s) did not match — see lines above." -f $failures) -ForegroundColor Red
}
