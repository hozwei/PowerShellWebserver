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
      - globalvars.ps1: AD, LDAP base DNs, SMTP relay, AdminMail, posh FQDN, defaults
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

# Pre-flight: globalvars.ps1 + config.psd1 must exist and parse cleanly.
# Failing at startup is friendlier than failing on the first /api/config
# request with an opaque JS toast. Initialize-Config.ps1 from PR 1
# is the canonical seeder for config.psd1; globalvars.ps1 is shipped in
# the repo.
$ioState = Get-PoshIoState
if (-not (Test-Path -LiteralPath $ioState.Globalvars -PathType Leaf)) {
    Write-Host "ABORT: globalvars.ps1 not found at $($ioState.Globalvars)" -ForegroundColor Red
    Write-Host '       The editor needs the file to read AD/LDAP/mail variables.'
    exit 1
}
if (-not (Test-Path -LiteralPath $ioState.ConfigPsd1 -PathType Leaf)) {
    Write-Host "ABORT: config.psd1 not found at $($ioState.ConfigPsd1)" -ForegroundColor Red
    Write-Host '       Run tools\Initialize-Config.ps1 first.'
    exit 1
}
try {
    $null = Get-PoshGlobalvarDefinitions
} catch {
    Write-Host "ABORT: globalvars.ps1 has parse errors:" -ForegroundColor Red
    Write-Host "       $_"
    Write-Host '       Fix the file by hand before launching the editor.'
    exit 1
}
try {
    $null = Get-PoshConfigValues
} catch {
    Write-Host "ABORT: config.psd1 is unreadable:" -ForegroundColor Red
    Write-Host "       $_"
    Write-Host '       Regenerate via tools\Initialize-Config.ps1 -Force.'
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
# Build the EFFECTIVE schema by scanning globalvars.ps1 for the variables
# actually present and joining them with the static schema metadata.
# globalvars.ps1 is the single source of truth for "which variables exist"
# — deleting a $Var line drops the field on the next reload, adding one
# makes it appear. Schema metadata (help, validator, min/max, choices) is
# layered on for matched names. Unmatched names render in the same
# 'globalvars.ps1' tab with the AST-inferred type and no validator.
function Build-EffectiveSchema {
    $defs       = Get-PoshGlobalvarDefinitions
    $configAll  = Get-PoshConfigValues
    $configKeys = @($configAll.Keys)

    $fields = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($def in $defs) {
        $match = @($schema.Fields | Where-Object { $_.File -eq 'globalvars.ps1' -and $_.Name -eq $def.Name } | Select-Object -First 1)
        # Skip non-literal vars that aren't in the schema. These are server
        # internals (computed paths like $PoshBaseDir = Join-Path ...,
        # interpolated strings, $env:... refs). They are not "settings" —
        # showing them in the globalvars tab only confuses operators.
        # Non-literal vars that ARE in the schema (e.g. DefaultTargetHost
        # = $env:COMPUTERNAME) stay visible as read-only so the user can
        # see the live value.
        if (-not $def.IsLiteral -and $match.Count -eq 0) { continue }
        $field = @{
            Name      = $def.Name
            File      = 'globalvars.ps1'
            Type      = $def.Type
            IsLiteral = $def.IsLiteral
            RawText   = $def.RawText
        }
        if ($match.Count -gt 0) {
            $m = $match[0]
            $field.Label = $m.Label
            $field.Group = $m.Group
            $field.Help  = $m.Help
            # Trust the schema's declared type when it disagrees with the AST
            # only for literals (e.g. schema says int + Min/Max, AST agrees).
            if ($def.IsLiteral) { $field.Type = $m.Type }
            foreach ($k in 'Validator','Min','Max','Choices') {
                if ($m.ContainsKey($k)) { $field[$k] = $m[$k] }
            }
        } else {
            # User-added var (literal, no schema entry) — same globalvars tab,
            # no special metadata. Operators work with variables, so the
            # label IS the variable name.
            $field.Label = '$' + $def.Name
            $field.Group = 'globalvars'
            $field.Help  = 'Manually added in globalvars.ps1 (no schema validation).'
        }
        $null = $fields.Add($field)
    }

    foreach ($sf in @($schema.Fields | Where-Object { $_.File -eq 'config.psd1' })) {
        if ($configKeys -contains $sf.Name) {
            $copy = @{}
            foreach ($k in $sf.Keys) { $copy[$k] = $sf[$k] }
            $copy.IsLiteral = $true
            $null = $fields.Add($copy)
        }
    }

    # Only keep groups that actually have fields (plus 'setup', which is the
    # helper tab and always present). Order follows the static $schema.Groups.
    $usedIds = @($fields | ForEach-Object { $_.Group } | Sort-Object -Unique)
    $usedIds += 'setup'
    $groups = @($schema.Groups | Where-Object { $_.Id -in $usedIds })

    return @{ Groups = $groups; Fields = @($fields) }
}

function Build-CurrentSnapshot {
    param([hashtable] $EffectiveSchema = (Build-EffectiveSchema))
    $namesGlobal = @($EffectiveSchema.Fields | Where-Object { $_.File -eq 'globalvars.ps1' } | ForEach-Object { $_.Name })
    $globalvars  = if ($namesGlobal.Count -gt 0) { Get-PoshGlobalvarValues -Names $namesGlobal } else { @{} }
    $configAll   = Get-PoshConfigValues
    $configSnap  = @{}
    foreach ($field in $EffectiveSchema.Fields) {
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
    param([hashtable] $EffectiveSchema)
    $snap = Build-CurrentSnapshot -EffectiveSchema $EffectiveSchema
    $out  = @{}
    foreach ($field in $EffectiveSchema.Fields) {
        $src = if ($field.File -eq 'globalvars.ps1') { $snap.globalvars } else { $snap.config }
        if ($src.ContainsKey($field.Name)) { $out[$field.Name] = $src[$field.Name] }
    }
    return $out
}

function Invoke-RouteConfigGet {
    param($Response)
    $eff  = Build-EffectiveSchema
    $snap = Build-CurrentSnapshot -EffectiveSchema $eff
    Send-PoshJsonResponse -Response $Response -Payload @{
        ok       = $true
        schema   = $eff
        snapshot = $snap
    }
}

function Invoke-RouteDiff {
    param($Response, [hashtable] $Body)
    if (-not $Body -or -not $Body.ContainsKey('values')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'values' object"
        return
    }
    $proposed  = [hashtable]$Body['values']
    $eff       = Build-EffectiveSchema
    # Only fields the effective schema currently exposes are valid targets.
    $errors    = @{}
    foreach ($field in $eff.Fields) {
        if ($proposed.ContainsKey($field.Name)) {
            if ($field.ContainsKey('IsLiteral') -and -not $field.IsLiteral) {
                $errors[$field.Name] = 'Value is computed (e.g. Join-Path); not editable in the editor.'
                continue
            }
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
    $current = Get-FlatCurrentValues -EffectiveSchema $eff
    $changes = Compare-PoshFieldValues -Schema $eff.Fields -Current $current -Proposed $proposed
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
    $eff      = Build-EffectiveSchema
    # Server-side validation against the dynamic schema. Defense in depth —
    # never trust the diff confirmation alone, and never touch a variable
    # the file doesn't currently define (the UI would have shown it as
    # missing).
    $errors = @{}
    foreach ($field in $eff.Fields) {
        if ($proposed.ContainsKey($field.Name)) {
            if ($field.ContainsKey('IsLiteral') -and -not $field.IsLiteral) {
                $errors[$field.Name] = 'Value is computed; not editable in the editor.'
                continue
            }
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
        $backups = Save-PoshFieldChanges -Schema $eff.Fields -Proposed $proposed
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 500 -Message ("Save failed: $_")
        return
    }
    Send-PoshJsonResponse -Response $Response -Payload @{
        ok      = $true
        backups = $backups
    }
}

function Invoke-RouteGlobalvarAdd {
    param($Response, [hashtable] $Body)
    if (-not $Body) { Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message 'Body required'; return }
    foreach ($k in 'name','value','type') {
        if (-not $Body.ContainsKey($k)) {
            Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message ("Body must include '$k'")
            return
        }
    }
    $name = [string]$Body['name']
    $type = [string]$Body['type']
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message 'Name may only contain letters, digits and _, and cannot start with a digit.'
        return
    }
    if ($type -notin @('string','int','string-array','bool')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Type must be one of: string, int, string-array, bool"
        return
    }
    $rawValue = $Body['value']
    $tempField = @{ Name = $name; File = 'globalvars.ps1'; Type = $type }
    $typed = ConvertTo-PoshTypedValue -Field $tempField -RawValue $rawValue
    $err   = Test-PoshFieldValue -Field $tempField -Value $typed
    if ($err) {
        Send-PoshJsonResponse -Response $Response -StatusCode 422 -Payload @{ ok = $false; error = $err; fields = @{ ($name) = $err } }
        return
    }
    try {
        # Add-PoshGlobalvar backs up internally AFTER validation. Pre-
        # validating + pre-backing-up here would leave orphan .bak files
        # for refused calls (duplicate name, computed RHS, etc).
        $result = Add-PoshGlobalvar -Name $name -Value $typed -Type $type
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 422 -Message ("$_")
        return
    }
    Send-PoshJsonResponse -Response $Response -Payload @{ ok = $true; name = $result.Name; backup = $result.Backup }
}

function Invoke-RouteGlobalvarRemove {
    param($Response, [hashtable] $Body)
    if (-not $Body -or -not $Body.ContainsKey('name')) {
        Send-PoshErrorResponse -Response $Response -StatusCode 400 -Message "Body must include 'name'"
        return
    }
    $name = [string]$Body['name']
    try {
        # Remove-PoshGlobalvar backs up internally AFTER validation.
        $result = Remove-PoshGlobalvar -Name $name
    } catch {
        Send-PoshErrorResponse -Response $Response -StatusCode 422 -Message ("$_")
        return
    }
    Send-PoshJsonResponse -Response $Response -Payload @{ ok = $true; name = $result.Name; backup = $result.Backup }
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
                '^POST /api/globalvar/add$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteGlobalvarAdd -Response $response -Body $body
                    break
                }
                '^POST /api/globalvar/remove$' {
                    $body = Read-PoshJsonBody -Request $request
                    Invoke-RouteGlobalvarRemove -Response $response -Body $body
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
            # Translate well-known error types to the right HTTP code.
            # IOException from Read-PoshJsonBody = body over 256 KB cap.
            # ArgumentException / InvalidOperationException on body cast
            # (e.g. caller sent a JSON array where a hashtable was expected)
            # is a client error, not a server error.
            $code = 500
            $exc  = $_.Exception
            if ($exc -is [System.IO.IOException])              { $code = 413 }
            elseif ($exc -is [System.ArgumentException] -or
                    $exc -is [System.InvalidOperationException] -or
                    $exc -is [System.Management.Automation.PSInvalidCastException]) {
                $code = 400
            }
            try {
                Send-PoshErrorResponse -Response $response -StatusCode $code -Message ("$exc")
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
