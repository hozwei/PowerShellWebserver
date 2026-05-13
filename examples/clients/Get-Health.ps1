#Requires -Version 7.0
<#
.SYNOPSIS
    Client: GET /health — built-in liveness endpoint (no auth).

.DESCRIPTION
    /health is one of the open endpoints — no `X-Api-Key` required and
    always exempt from rate limiting and the global throttle. Suitable
    for load-balancer probes.

.EXAMPLE
    .\Get-Health.ps1
#>

. $PSScriptRoot/_Common.ps1

$uri = '{0}/health' -f (Get-PoshBaseUrl)
# Intentionally NO X-Api-Key header — /health is open by design.
$response = Invoke-RestMethod -Uri $uri -SkipHttpErrorCheck
$response | ConvertTo-Json -Depth 5
