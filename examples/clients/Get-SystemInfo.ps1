#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /subdir/system-info.ps1 — subdir endpoint with multiple params.

.DESCRIPTION
    Pairs with `webroot/subdir/system-info.ps1`. The endpoint returns a
    JSON envelope whose `output` field contains another JSON string
    (the actual system info). This client parses that nested JSON for
    a friendly summary.

.PARAMETER ComputerName
    Target host name (default: local computer).

.PARAMETER Detail
    Include CPU + disk listing.

.EXAMPLE
    .\Get-SystemInfo.ps1 -Detail
#>
param(
    [string] $ComputerName = $env:COMPUTERNAME,
    [switch] $Detail
)

. $PSScriptRoot/_Common.ps1

$query = @{ ComputerName = $ComputerName; Detail = if ($Detail) { 'true' } else { 'false' } }
$envelope = Invoke-Posh -Path '/subdir/system-info.ps1' -Query $query

if ($envelope.exitCode -ne 0) {
    $envelope | Write-Envelope
    return
}

# `output` is a JSON string when the script wrote ConvertTo-Json to stdout.
$info = $envelope.output | ConvertFrom-Json -Depth 10

Write-Host ('Host       : {0}' -f $info.hostname)
Write-Host ('OS         : {0} (v{1})' -f $info.os, $info.osVersion)
Write-Host ('PowerShell : {0}' -f $info.psVersion)
Write-Host ('Uptime     : {0} hours' -f $info.uptimeHours)
Write-Host ('RAM        : {0} GB used / {1} GB total ({2}% free)' -f $info.ramUsedGB, $info.ramTotalGB, $info.ramFreePct)

if ($Detail) {
    Write-Host ''
    Write-Host ('CPU        : {0}' -f $info.cpuModel)
    Write-Host ('CPU load   : {0}%' -f $info.cpuLoadPct)
    Write-Host ''
    Write-Host 'Disks:'
    foreach ($d in $info.disks) {
        Write-Host ('  {0}  {1} GB free / {2} GB total ({3}% free)' -f $d.drive, $d.freeGB, $d.totalGB, $d.freePct)
    }
}
