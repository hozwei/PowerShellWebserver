#Requires -Version 7.0
<#
.SYNOPSIS
    HTTP plumbing for tools\Edit-PoshSettings.ps1.

.DESCRIPTION
    Loopback-only listener helpers: response writers, JSON body reader,
    cookie + CSRF token validation, brute-force counter. Keeps the
    entry-point script focused on routing.

    Token compare uses CryptographicOperations.FixedTimeEquals so a
    brute-force probe cannot learn anything from response timing.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module state. Token, cookie name, brute-force counter, idle clock —
# everything the route layer needs to enforce auth uniformly.
# ---------------------------------------------------------------------------
$script:httpState = $null

function Initialize-PoshHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Token,
        [string] $CookieName     = 'posh_editor',
        [string] $CsrfHeaderName = 'X-Posh-CSRF',
        [int]    $MaxBodyBytes   = 262144,
        [int]    $MaxAuthFails   = 20
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Token must not be empty' }
    $script:httpState = [pscustomobject]@{
        Token          = $Token
        TokenBytes     = [System.Text.Encoding]::UTF8.GetBytes($Token)
        CookieName     = $CookieName
        CsrfHeaderName = $CsrfHeaderName
        MaxBodyBytes   = $MaxBodyBytes
        MaxAuthFails   = $MaxAuthFails
        AuthFails      = 0
        LastActivity   = [System.DateTimeOffset]::UtcNow
    }
}

function Get-PoshHttpState {
    if ($null -eq $script:httpState) { throw 'PoshHttp is not initialised' }
    return $script:httpState
}

function Update-PoshHttpActivity {
    $s = Get-PoshHttpState
    $s.LastActivity = [System.DateTimeOffset]::UtcNow
}

# ---------------------------------------------------------------------------
# Constant-time string equality. PowerShell -eq short-circuits on first
# mismatch, which leaks length and prefix to an attacker over the wire.
# FixedTimeEquals only returns once both buffers have been fully read.
# ---------------------------------------------------------------------------
function Test-PoshTokenEqual {
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Provided)
    $s = Get-PoshHttpState
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Provided)
    } catch {
        return $false
    }
    if ($bytes.Length -ne $s.TokenBytes.Length) {
        # Run a fixed-length compare against random bytes so the timing
        # of a wrong-length input matches the timing of a right-length
        # input. Avoids using the real token bytes as the dummy because
        # that would let an attacker fingerprint by length.
        $dummy = [byte[]]::new($s.TokenBytes.Length)
        $b2    = [byte[]]::new($s.TokenBytes.Length)
        $null  = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($b2, $dummy)
        return $false
    }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($bytes, $s.TokenBytes)
}

# ---------------------------------------------------------------------------
# Auth check applied to every request. The first GET / consumes ?t=<token>
# and Set-Cookie's it; everything after that must present cookie AND CSRF
# header, double-submit style.
# ---------------------------------------------------------------------------
function Test-PoshAuth {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] $Response,
        [switch] $InitialGet
    )
    $s = Get-PoshHttpState
    if ($InitialGet) {
        # Token may arrive in the query string for the first navigation.
        $queryToken = $Request.QueryString['t']
        if ($queryToken -and (Test-PoshTokenEqual -Provided $queryToken)) {
            # Issue the cookie and let the caller decide whether to redirect.
            $cookie = [System.Net.Cookie]::new($s.CookieName, $s.Token, '/')
            $cookie.HttpOnly = $true
            $cookie.Secure   = $false  # plaintext loopback, no TLS
            $Response.AppendCookie($cookie)
            # SameSite is set via header because System.Net.Cookie's
            # SameSite property is .NET-Framework-only.
            $Response.Headers.Add('Set-Cookie', "$($s.CookieName)=$($s.Token); Path=/; HttpOnly; SameSite=Strict")
            return $true
        }
        # Fall through — maybe the cookie is already set.
    }
    $cookie = $Request.Cookies[$s.CookieName]
    if (-not $cookie -or -not (Test-PoshTokenEqual -Provided $cookie.Value)) {
        $s.AuthFails++
        return $false
    }
    if (-not $InitialGet) {
        $csrf = $Request.Headers[$s.CsrfHeaderName]
        if (-not $csrf -or -not (Test-PoshTokenEqual -Provided $csrf)) {
            $s.AuthFails++
            return $false
        }
    }
    return $true
}

function Test-PoshAuthBruteForce {
    [OutputType([bool])]
    param()
    $s = Get-PoshHttpState
    return ($s.AuthFails -ge $s.MaxAuthFails)
}

# ---------------------------------------------------------------------------
# Belt-and-suspenders check that the remote endpoint actually resolved to
# loopback. Listener was bound to 127.0.0.1, but a route-layer mistake
# (or a future move to 0.0.0.0) should still fail closed here.
# ---------------------------------------------------------------------------
function Test-PoshLoopback {
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Request)
    try {
        $ip = $Request.RemoteEndPoint.Address
        if ($null -eq $ip) { return $false }
        return ($ip.Equals([System.Net.IPAddress]::Loopback) -or
                $ip.Equals([System.Net.IPAddress]::IPv6Loopback))
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# JSON body reader with a hard size cap. Reading InputStream end-to-end
# without a limit would let a hostile loopback caller exhaust memory.
# ---------------------------------------------------------------------------
function Read-PoshJsonBody {
    param([Parameter(Mandatory)] $Request)
    $s = Get-PoshHttpState
    $stream = $Request.InputStream
    $buffer = [System.IO.MemoryStream]::new()
    try {
        $chunk = [byte[]]::new(8192)
        $total = 0
        while ($true) {
            $read = $stream.Read($chunk, 0, $chunk.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $s.MaxBodyBytes) {
                throw [System.IO.IOException]::new('Body exceeds 256 KB limit')
            }
            $buffer.Write($chunk, 0, $read)
        }
        if ($buffer.Length -eq 0) { return $null }
        $bytes = $buffer.ToArray()
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -AsHashtable -Depth 20)
    } finally {
        $buffer.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Standard response writers. Keep Content-Type and length consistent so
# we never depend on HttpListener defaults.
# ---------------------------------------------------------------------------
function Send-PoshJsonResponse {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes HTTP response — no system state changes.')]
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] $Payload,
        [int] $StatusCode = 200
    )
    $json  = $Payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode      = $StatusCode
    $Response.ContentType     = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    # Disallow caching of the API surface — token + state are per-process.
    $Response.Headers.Add('Cache-Control', 'no-store')
    $Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-PoshTextResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes HTTP response — no system state changes.')]
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [string] $Body,
        [int]    $StatusCode  = 200,
        [string] $ContentType = 'text/plain; charset=utf-8'
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode      = $StatusCode
    $Response.ContentType     = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers.Add('Cache-Control', 'no-store')
    $Response.Headers.Add('X-Content-Type-Options', 'nosniff')
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-PoshHtmlResponse {
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [string] $Html,
        [int] $StatusCode = 200
    )
    Send-PoshTextResponse -Response $Response -Body $Html -StatusCode $StatusCode -ContentType 'text/html; charset=utf-8'
}

function Send-PoshErrorResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes HTTP response — no system state changes.')]
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [string] $Message
    )
    Send-PoshJsonResponse -Response $Response -StatusCode $StatusCode -Payload @{
        ok    = $false
        error = $Message
    }
}

# ---------------------------------------------------------------------------
# Generate a URL-safe random token. 16 bytes = 128 bits = comfortably
# more than CSPRNG-equivalent for our threat model.
# ---------------------------------------------------------------------------
function New-PoshEditorToken {
    [OutputType([string])]
    param([int] $ByteLength = 16)
    $bytes = [byte[]]::new($ByteLength)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes)
    return $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# ---------------------------------------------------------------------------
# Pick a free loopback TCP port. Tiny TOCTOU window between Stop and
# HttpListener binding — acceptable on a single-user dev box.
# ---------------------------------------------------------------------------
function Find-PoshFreeLoopbackPort {
    [OutputType([int])]
    param()
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ($listener.LocalEndpoint).Port
        $listener.Stop()
        return [int]$port
    } finally {
        try { $listener.Stop() } catch { $null = $_ }
    }
}

Export-ModuleMember -Function @(
    'Initialize-PoshHttp',
    'Get-PoshHttpState',
    'Update-PoshHttpActivity',
    'Test-PoshTokenEqual',
    'Test-PoshAuth',
    'Test-PoshAuthBruteForce',
    'Test-PoshLoopback',
    'Read-PoshJsonBody',
    'Send-PoshJsonResponse',
    'Send-PoshTextResponse',
    'Send-PoshHtmlResponse',
    'Send-PoshErrorResponse',
    'New-PoshEditorToken',
    'Find-PoshFreeLoopbackPort'
)
