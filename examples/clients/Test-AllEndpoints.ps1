#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end smoke test against every example endpoint in webroot/.

.DESCRIPTION
    Walks through every demo endpoint in the right order and reports a
    pass/fail per call. Useful as a sanity check after deploying a new
    version of `Start-WebServer.ps1` or after changing `config.psd1`.

    Set the env vars `POSH_BASE_URL` and `POSH_API_KEY` (or edit
    `_Common.ps1`) before running. The test assumes:
        * /hello.ps1, /post-json.ps1, /post-form.ps1, /errors.ps1 are reachable
        * PathPlaceholders = $true is active (skips the F9 case otherwise)

.EXAMPLE
    $env:POSH_API_KEY = 'your-key'
    .\Test-AllEndpoints.ps1
#>

. $PSScriptRoot/_Common.ps1

$base    = Get-PoshBaseUrl
$apiKey  = Get-PoshApiKey
$headers = @{ 'X-Api-Key' = $apiKey }
$pass    = 0
$fail    = 0

function Assert-Case {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][scriptblock] $Test
    )
    # Per-case stopwatch makes slow endpoints stand out in the output
    # without requiring a separate run. >500ms is gently flagged in yellow
    # so the eye catches outliers without colouring every line.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ok = & $Test
        $sw.Stop()
        $ms     = [int]$sw.ElapsedMilliseconds
        $msTag  = if ($ms -ge 500) { '!{0,5}ms' -f $ms } else { ' {0,5}ms' -f $ms }
        $msColor = if ($ms -ge 500) { 'Yellow' } else { 'DarkGray' }
        if ($ok) {
            Write-Host ('[OK ] ' + $msTag + ' ') -ForegroundColor Green -NoNewline
            Write-Host $Label -ForegroundColor $msColor
            $script:pass++
        } else {
            Write-Host ('[FAIL] ' + $msTag + ' ') -ForegroundColor Red -NoNewline
            Write-Host $Label -ForegroundColor $msColor
            $script:fail++
        }
    } catch {
        $sw.Stop()
        $ms = [int]$sw.ElapsedMilliseconds
        Write-Host ('[FAIL] {0,6}ms {1}: {2}' -f $ms, $Label, $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}

# Built-in routes (no auth).
Assert-Case '/health'        { (Invoke-RestMethod "$base/health").status -eq 'ok' }
Assert-Case '/metrics-prom'  { (Invoke-WebRequest  "$base/metrics-prom").Content -match 'posh_uptime_seconds' }
Assert-Case '/openapi.json'  { (Invoke-RestMethod  "$base/openapi.json").openapi -like '3.*' }

# Script endpoints (auth required).
Assert-Case '/hello.ps1' {
    $r = Invoke-RestMethod "$base/hello.ps1?Name=Smoke" -Headers $headers
    $r.exitCode -eq 0 -and $r.output -eq 'Hello, Smoke!'
}
Assert-Case '/subdir/system-info.ps1' {
    $r = Invoke-RestMethod "$base/subdir/system-info.ps1" -Headers $headers
    $r.exitCode -eq 0 -and ($r.output | ConvertFrom-Json).hostname
}
Assert-Case '/post-json.ps1' {
    $body = @{ firstName = 'Smoke'; lastName = 'Test'; roles = @('reader') } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod "$base/post-json.ps1" -Method POST -Headers $headers -ContentType 'application/json' -Body $body
    $r.exitCode -eq 0 -and ($r.output | ConvertFrom-Json).parsed.fullName -eq 'Smoke Test'
}
Assert-Case '/post-form.ps1' {
    $r = Invoke-RestMethod "$base/post-form.ps1" -Method POST -Headers $headers `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body 'firstName=Smoke&lastName=Test&tags[]=a&tags[]=b'
    $r.exitCode -eq 0 -and ($r.output | ConvertFrom-Json).keys -contains 'firstName'
}
Assert-Case '/users/admin (exact filename wins over placeholder)' {
    $r = Invoke-RestMethod "$base/users/admin" -Headers $headers -SkipHttpErrorCheck
    if ($r.PSObject.Properties['exitCode'] -and $r.exitCode -ne 0) { return $false }
    $info = $r.output | ConvertFrom-Json
    $info.id -eq 'admin' -and $info.role -eq 'admin'
}
Assert-Case '/users/42 (placeholder route)' {
    $r = Invoke-RestMethod "$base/users/42" -Headers $headers -SkipHttpErrorCheck
    if ($r.PSObject.Properties['exitCode'] -and $r.exitCode -ne 0) { return $false }
    ($r.output | ConvertFrom-Json).id -eq '42'
}
Assert-Case '/api-status.psxml (.psxml extension)' {
    $resp = Invoke-WebRequest "$base/api-status.psxml" -Headers $headers
    $resp.Headers['Content-Type'] -like 'text/xml*' -and ([xml]$resp.Content).Result.Code -eq '1'
}
Assert-Case '/errors.ps1?Mode=ok => 200' {
    $r = Invoke-WebRequest "$base/errors.ps1?Mode=ok" -Headers $headers -SkipHttpErrorCheck
    [int]$r.StatusCode -eq 200
}
Assert-Case '/errors.ps1?Mode=fail => 500' {
    $r = Invoke-WebRequest "$base/errors.ps1?Mode=fail" -Headers $headers -SkipHttpErrorCheck
    [int]$r.StatusCode -eq 500
}
Assert-Case '/session.ps1 cookie round-trip' {
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $a = Invoke-RestMethod "$base/session.ps1" -Headers $headers -WebSession $session
    $b = Invoke-RestMethod "$base/session.ps1" -Headers $headers -WebSession $session
    $sa = ($a.output | ConvertFrom-Json).sessionId
    $sb = ($b.output | ConvertFrom-Json).sessionId
    -not [string]::IsNullOrEmpty($sa) -and $sa -eq $sb
}

Write-Host ''
$total = $pass + $fail
$color = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("Summary: {0} pass / {1} fail / {2} total" -f $pass, $fail, $total) -ForegroundColor $color
exit ([int]($fail -gt 0))
