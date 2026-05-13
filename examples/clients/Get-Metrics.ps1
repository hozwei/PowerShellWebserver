#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /metrics + /metrics-prom — both built-in formats side by side.

.DESCRIPTION
    /metrics returns a JSON envelope with uptime + counters; suitable
    for ad-hoc inspection from PowerShell.
    /metrics-prom returns Prometheus text-format (Content-Type
    `text/plain; version=0.0.4`); pointable at Prometheus, Grafana,
    VictoriaMetrics, etc.

    Both routes are auth-exempt and exempt from rate limiting.

.EXAMPLE
    .\Get-Metrics.ps1
#>

. $PSScriptRoot/_Common.ps1

$base = Get-PoshBaseUrl

Write-Host '--- /metrics (JSON) ---'
$json = Invoke-RestMethod -Uri "$base/metrics" -SkipHttpErrorCheck
$json | ConvertTo-Json -Depth 5

Write-Host ''
Write-Host '--- /metrics-prom (Prometheus text) ---'
$resp = Invoke-WebRequest -Uri "$base/metrics-prom" -SkipHttpErrorCheck
Write-Host ('Content-Type: {0}' -f $resp.Headers['Content-Type'])
Write-Host ''
Write-Host $resp.Content
