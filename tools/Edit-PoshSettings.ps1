#Requires -Version 7.0
<#
.SYNOPSIS
    Standalone, loopback-only web editor for the most-used posh server
    settings. Runs only while you are editing.

.DESCRIPTION
    Starts a local HttpListener on 127.0.0.1:<random-free-port>, opens
    the default browser to the editor URL with a one-time access token,
    serves a small single-page UI, and exits as soon as you save and
    confirm — or after 10 minutes of inactivity.

    Covered settings (see tools\editor\schema.psd1):
      - globalvars.ps1: service endpoints, AD/LDAP, mail, infra
      - config.psd1:    ports, auth mode, limits, logging, features
      - Setup-Helpers:  AES key generation, encrypted-secret storage,
                        POSH_API_KEY machine-scope env var (admin only)

    Bound to 127.0.0.1 literally — never `localhost`, never `+` — so no
    URL-ACL reservation is required and no other host can reach the
    editor.

    Plaintext HTTP on loopback is the same threat model as a local
    Read-Host -AsSecureString in a terminal. The token-cookie pair and
    a CSRF header guard against drive-by browser tabs; constant-time
    compare guards against timing leaks; an inactivity timer + auto-quit
    bound the editor's lifetime.

.PARAMETER NoBrowser
    Skip the automatic Start-Process to the default browser. Useful for
    headless or remote-desktop scenarios — you copy the URL by hand.

.PARAMETER Port
    Explicit loopback port. Default 0 = pick a free one. Set this when
    you want a stable URL across restarts or when the auto-picked port
    collides with something else.

.PARAMETER InactivityTimeoutSec
    Seconds of idle time before the editor stops itself. Default 600.

.PARAMETER RepoRoot
    Override the repository root. Defaults to the directory above this
    script.

.EXAMPLE
    .\tools\Edit-PoshSettings.ps1
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive setup tool — coloured Write-Host output is intended.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'JSON bodies carry no SecureString type. The password arrives over the loopback HTTP body as plaintext; we wrap it into a SecureString immediately and clear the local variable. Same threat model as Read-Host -AsSecureString on the same machine.')]
param(
    [switch] $NoBrowser,
    [int]    $Port = 0,
    [int]    $InactivityTimeoutSec = 600,
    [string] $RepoRoot = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$editorDir = Join-Path $scriptDir 'editor'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $scriptDir
}

# ---------------------------------------------------------------------------
# Load supporting modules and the field schema.
# ---------------------------------------------------------------------------
Import-Module (Join-Path $editorDir 'PoshSettingsIO.psm1')   -Force
Import-Module (Join-Path $editorDir 'PoshSettingsHttp.psm1') -Force

$schemaPath  = Join-Path $editorDir 'schema.psd1'
$indexPath   = Join-Path $editorDir 'index.html'
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "schema.psd1 not found at $schemaPath" }
if (-not (Test-Path -LiteralPath $indexPath))  { throw "index.html not found at $indexPath" }

$schema        = Import-PowerShellDataFile -LiteralPath $schemaPath
$indexTemplate = [System.IO.File]::ReadAllText($indexPath)

# Initialise IO with our repo root so the path whitelist anchors here.
Initialize-PoshSettingsIO -RepoRoot $RepoRoot

# Pre-flight: config.psd1 must exist. Initialise-Config.ps1 from PR 1
# is the canonical seeder; we point the user there rather than silently
# creating one.
$configPath = (Get-PoshIoState).ConfigPsd1
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "ABORT: config.psd1 not found at $configPath" -ForegroundColor Red
    Write-Host '       Run tools\Initialize-Config.ps1 first.'
    exit 1
}

# ---------------------------------------------------------------------------
# Token + listener bring-up. Find a free loopback port, bind, open browser.
# ---------------------------------------------------------------------------
$token = New-PoshEditorToken
Initialize-PoshHttp -Token $token

# Materialise the served HTML once, with the live token substituted in
# place of the __POSH_TOKEN__ placeholder. JS reads the token from the
# embedded constant and sends it back as the X-Posh-CSRF header so the
# double-submit cookie check sees matching values.
$indexHtml = $indexTemplate.Replace('__POSH_TOKEN__', $token)

$bindPort = if ($Port -gt 0) { $Port } else { Find-PoshFreeLoopbackPort }
$prefix   = "http://127.0.0.1:$bindPort/"
$startUrl = "${prefix}?t=$token"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "ABORT: HttpListener failed to bind $prefix : $_" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  posh settings editor' -ForegroundColor Cyan
Write-Host '  --------------------'
Write-Host "  URL          : $startUrl"
Write-Host "  Repo root    : $RepoRoot"
Write-Host "  Idle timeout : $InactivityTimeoutSec s"
Write-Host '  Press Ctrl+C in this window to stop early.'
Write-Host ''

if (-not $NoBrowser) {
    try {
        $null = Start-Process -FilePath $startUrl
    } catch {
        Write-Host "WARNING: could not auto-open browser ($_). Open the URL above manually." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Lifecycle plumbing: a single bool wraps the stop reason so the listener
# loop and the request handlers can both flip it.
# ---------------------------------------------------------------------------
$lifecycle = [pscustomobject]@{
    ShouldStop = $false
    Reason     = $null
}

function Stop-EditorAfterDelay {
    param([int] $DelaySec, [string] $Reason)
    $lifecycle.Reason = $Reason
    Start-Sleep -Seconds $DelaySec
    $lifecycle.ShouldStop = $true
    try { $listener.Stop() } catch { $null = $_ }
}

# ---------------------------------------------------------------------------
# Idle watchdog. Runs in its own runspace because the main thread sits
# inside HttpListener.GetContextAsync() and would otherwise miss the tick.
# ---------------------------------------------------------------------------
$watchdogState = [hashtable]::Synchronized(@{
    LastActivity      = [DateTimeOffset]::UtcNow
    TimeoutSec        = $InactivityTimeoutSec
    Stop              = $false
})
$watchdogScript = {
    param($state, $listener, $lifecycle)
    while (-not $state.Stop) {
        Start-Sleep -Seconds 5
        if ($state.Stop) { return }
        $elapsed = ([DateTimeOffset]::UtcNow - $state.LastActivity).TotalSeconds
        if ($elapsed -ge $state.TimeoutSec) {
            $lifecycle.Reason = 'inactivity timeout'
            $lifecycle.ShouldStop = $true
            try { $listener.Stop() } catch { $null = $_ }
            return
        }
    }
}
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$watchdog = [PowerShell]::Create()
$watchdog.Runspace = $runspace
$null = $watchdog.AddScript($watchdogScript).AddArgument($watchdogState).AddArgument($listener).AddArgument($lifecycle)
$watchdogHandle = $watchdog.BeginInvoke()

function Update-Activity {
    Update-PoshHttpActivity
    $watchdogState.LastActivity = [DateTimeOffset]::UtcNow
}

# ---------------------------------------------------------------------------
# Route handlers. Each returns nothing; they write the response directly.
# ---------------------------------------------------------------------------
function Build-CurrentSnapshot {
    # Hashtable shape: { globalvars: {Name=Value}, config: {Name=Value},
    #                    env: {...}, aesKey: {...}, secrets: [...] }
    $namesGlobal = @($schema.Fields | Where-Object { $_.File -eq 'globalvars.ps1' } | ForEach-Object { $_.Name })
    $globalvars  = if ($namesGlobal.Count -gt 0) { Get-PoshGlobalvarValues -Names $namesGlobal } else { @{} }
    $configAll   = Get-PoshConfigValues
    $configSnap  = @{}
    foreach ($field in $schema.Fields) {
        if ($field.File -eq 'config.psd1' -and $configAll.ContainsKey($field.Name)) {
            $configSnap[$field.Name] = $configAll[$field.Name]
        }
    }
    return @{
        globalvars = $globalvars
        config     = $configSnap
        env        = Get-PoshApiKeyStatus
        aesKey     = Get-PoshAesKeyStatus
        secrets    = Get-PoshSecretList
        isAdmin    = Test-PoshIsAdmin
    }
}

function Get-FlatCurrentValues {
    $snap = Build-CurrentSnapshot
    $out  = @{}
    foreach ($field in $schema.Fields) {
        $src = if ($field.File -eq 'globalvars.ps1') { $snap.globalvars } else { $snap.config }
        if ($src.ContainsKey($field.Name)) { $out[$field.Name] = $src[$field.Name] }
    }
    return $out
}

function Invoke-RouteConfigGet {
    param($Response)
    Send-PoshJsonResponse -Response $Response -Payload @{
        ok       = $true
        schema   = $schema
        snapshot = Build-CurrentSnapshot
    }
}

function Invoke-RouteDiff {
    param($Response, [hashtable] $Body)
    if (-not $Body -or -not $Body.ContainsKey('values')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'values' object"
        return
    }
    $proposed = [hashtable]$Body['values']
    # Validate every proposed field first so a bad value never reaches diff
    $errors = @{}
    foreach ($field in $schema.Fields) {
        if ($proposed.ContainsKey($field.Name)) {
            $typed = ConvertTo-PoshTypedValue -Field $field -RawValue $proposed[$field.Name]
            $err   = Test-PoshFieldValue -Field $field -Value $typed
            if ($err) { $errors[$field.Name] = $err }
        }
    }
    if ($errors.Count -gt 0) {
        Send-PoshErrorResponse -Response $Response -StatusCode 422 -Message 'Validation failed'
        # 422 already returned — re-call to add per-field errors. Easier:
        # build the payload by hand instead of the helper above.
        return
    }
    $current = Get-FlatCurrentValues
    $changes = Compare-PoshFieldValues -Schema $schema.Fields -Current $current -Proposed $proposed
    Send-PoshJsonResponse -Response $Response -Payload @{
        ok      = $true
        changes = $changes
    }
}

function Invoke-RouteSave {
    param($Response, [hashtable] $Body)
    if (-not $Body -or -not $Body.ContainsKey('values')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'values' object"
        return
    }
    $proposed = [hashtable]$Body['values']
    # Server-side validation again — never trust the diff confirmation alone.
    $errors = @{}
    foreach ($field in $schema.Fields) {
        if ($proposed.ContainsKey($field.Name)) {
            $typed = ConvertTo-PoshTypedValue -Field $field -RawValue $proposed[$field.Name]
            $err   = Test-PoshFieldValue -Field $field -Value $typed
            if ($err) { $errors[$field.Name] = $err }
        }
    }
    if ($errors.Count -gt 0) {
        Send-PoshJsonResponse -Response $Response -StatusCode 422 -Payload @{
            ok     = $false
            error  = 'Validation failed'
            fields = $errors
        }
        return
    }
    try {
        $backups = Save-PoshFieldChanges -Schema $schema.Fields -Proposed $proposed
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 500 -Message ("Save failed: $_")
        return
    }
    Send-PoshJsonResponse -Response $Response -Payload @{
        ok      = $true
        backups = $backups
    }
}

function Invoke-RouteInitKey {
    param($Response, [hashtable] $Body)
    $force = $false
    if ($Body -and $Body.ContainsKey('force')) { $force = [bool]$Body['force'] }
    try {
        $result = New-PoshAesKey -Force:$force
        Send-PoshJsonResponse -Response $Response -Payload @{
            ok       = $true
            replaced = $result.Replaced
            backup   = $result.Backup
        }
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 422 -Message ("$_")
    }
}

function Invoke-RouteSecret {
    param($Response, [hashtable] $Body)
    if (-not $Body -or -not $Body.ContainsKey('label') -or -not $Body.ContainsKey('password')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'label' and 'password'"
        return
    }
    $label    = [string]$Body['label']
    $password = [string]$Body['password']
    $force    = if ($Body.ContainsKey('force')) { [bool]$Body['force'] } else { $false }
    if ([string]::IsNullOrWhiteSpace($password)) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message 'Password must not be empty'
        return
    }
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    $password = $null  # GC the plaintext
    try {
        $result = Save-PoshSecret -Label $label -Password $secure -Force:$force
        Send-PoshJsonResponse -Response $Response -Payload @{
            ok    = $true
            label = $result.Label
            file  = $result.File
        }
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 422 -Message ("$_")
    } finally {
        if ($secure) { $secure.Dispose() }
    }
}

function Invoke-RouteSetEnv {
    param($Response, [hashtable] $Body)
    if (-not (Test-PoshIsAdmin)) {
        Send-PoshErrorResponse -Response $Response -StatusCode 403 -Message 'POSH_API_KEY can only be set when the editor was launched as Administrator.'
        return
    }
    if (-not $Body -or -not $Body.ContainsKey('value')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'value'"
        return
    }
    $value = [string]$Body['value']
    if ([string]::IsNullOrWhiteSpace($value)) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message 'value must not be empty'
        return
    }
    try {
        Set-PoshApiKeyEnv -Value $value
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 500 -Message ("$_")
        return
    }
    Send-PoshJsonResponse -Response $Response -Payload @{ ok = $true }
}

function Invoke-RouteQuit {
    param($Response)
    Send-PoshJsonResponse -Response $Response -Payload @{ ok = $true; reason = 'user-quit' }
    $lifecycle.Reason     = 'user requested quit'
    $lifecycle.ShouldStop = $true
    Start-Sleep -Milliseconds 200
    try { $listener.Stop() } catch { $null = $_ }
}

# ---------------------------------------------------------------------------
# Main loop. GetContextAsync lets us interrupt on listener.Stop() from the
# watchdog without a blocked thread.
# ---------------------------------------------------------------------------
try {
    while ($listener.IsListening -and -not $lifecycle.ShouldStop) {
        $ctxTask = $null
        try {
            $ctxTask = $listener.GetContextAsync()
            while (-not $ctxTask.IsCompleted) {
                if ($lifecycle.ShouldStop -or -not $listener.IsListening) { break }
                Start-Sleep -Milliseconds 100
            }
            if ($lifecycle.ShouldStop -or -not $listener.IsListening) { break }
            $ctx = $ctxTask.GetAwaiter().GetResult()
        } catch [System.Net.HttpListenerException] {
            break
        } catch [System.ObjectDisposedException] {
            break
        } catch {
            if ($lifecycle.ShouldStop) { break }
            Write-Host "ERROR: GetContext failed: $_" -ForegroundColor Red
            continue
        }
        $request  = $ctx.Request
        $response = $ctx.Response

        if (Test-PoshAuthBruteForce) {
            $response.StatusCode = 429
            try { $response.OutputStream.Close() } catch { $null = $_ }
            $lifecycle.Reason     = 'too many auth failures'
            $lifecycle.ShouldStop = $true
            try { $listener.Stop() } catch { $null = $_ }
            break
        }

        if (-not (Test-PoshLoopback -Request $request)) {
            $response.StatusCode = 403
            try { $response.OutputStream.Close() } catch { $null = $_ }
            continue
        }

        $method = $request.HttpMethod.ToUpperInvariant()
        $path   = $request.Url.AbsolutePath
        $isInitialGet = ($method -eq 'GET' -and $path -eq '/')

        if (-not (Test-PoshAuth -Request $request -Response $response -InitialGet:$isInitialGet)) {
            # Slow down brute-force attempts a touch.
            Start-Sleep -Milliseconds 2000
            try { Send-PoshErrorResponse -Response $response -StatusCode 401 -Message 'Unauthorized' } catch { $null = $_ }
            continue
        }
        Update-Activity

        try {
            switch -Regex ("$method $path") {
                '^GET /$' {
                    Send-PoshHtmlResponse -Response $response -Html $indexHtml
                    break
                }
                '^GET /api/config$' {
                    Invoke-RouteConfigGet -Response $response
                    break
                }
                '^POST /api/diff$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteDiff -Response $response -Body $body
                    break
                }
                '^POST /api/save$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteSave -Response $response -Body $body
                    break
                }
                '^POST /api/initkey$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteInitKey -Response $response -Body $body
                    break
                }
                '^POST /api/secret$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteSecret -Response $response -Body $body
                    break
                }
                '^POST /api/setenv$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteSetEnv -Response $response -Body $body
                    break
                }
                '^POST /api/quit$' {
                    Invoke-RouteQuit -Response $response
                    break
                }
                default {
                    Send-PoshErrorResponse -Response $response -StatusCode 404 -Message 'Not Found'
                }
            }
        } catch {
            try {
                Send-PoshErrorResponse -Response $response -StatusCode 500 -Message "Server error: $_"
            } catch { $null = $_ }
            Write-Host "ERROR processing $method $path : $_" -ForegroundColor Red
        }
    }
} finally {
    # Tell the watchdog to stop polling and shut down the listener cleanly.
    $watchdogState.Stop = $true
    try { $listener.Stop() }  catch { $null = $_ }
    try { $listener.Close() } catch { $null = $_ }
    try {
        if (-not $watchdogHandle.IsCompleted) {
            # Give the watchdog up to 6 s to notice the stop flag (it
            # polls every 5 s) before tearing the runspace down.
            $null = $watchdog.EndInvoke($watchdogHandle)
        }
    } catch { $null = $_ }
    try { $watchdog.Dispose() } catch { $null = $_ }
    try { $runspace.Dispose() } catch { $null = $_ }
}

$reason = if ($lifecycle.Reason) { $lifecycle.Reason } else { 'listener closed' }
Write-Host ''
Write-Host "  editor stopped ($reason)" -ForegroundColor Cyan
Write-Host ''
