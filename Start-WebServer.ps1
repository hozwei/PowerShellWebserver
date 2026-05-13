#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell HTTP/HTTPS web server — executes local .ps1 scripts via HTTP requests.

.DESCRIPTION
    Listens on port 80 (HTTP) by default and optionally on port 443 (HTTPS).
    URL paths are mapped directly to .\webroot\.
    Query parameters are passed as named arguments to the script.
    Every request is logged to .\logs\YYYY-MM-DD.log.

    Requires PowerShell 7 (pwsh.exe).
    Must be run as Administrator.

    HTTPS prerequisite: a netsh sslcert binding must have been configured via
    Register-ScheduledTask.ps1. The server checks this at startup and exits with
    exit 1 if the binding is missing.

.PARAMETER HttpsEnabled
    Enable HTTPS. Requires a netsh sslcert binding for HttpsPort.

.PARAMETER HttpPort
    HTTP port. Default: 80. Value 0 = HTTP disabled (only useful with -HttpsEnabled).

.PARAMETER HttpsPort
    HTTPS port. Default: 443. Only evaluated when -HttpsEnabled is set.

.EXAMPLE
    # HTTP only (default)
    .\Start-WebServer.ps1

    # HTTP on port 8080
    .\Start-WebServer.ps1 -HttpPort 8080

    # HTTPS on 443, HTTP on 80 still active
    .\Start-WebServer.ps1 -HttpsEnabled -HttpPort 80 -HttpsPort 443

    # HTTPS only (HTTP disabled)
    .\Start-WebServer.ps1 -HttpsEnabled -HttpPort 0 -HttpsPort 443

    http://localhost/script1.ps1
    http://localhost/subdir/script2.ps1?Name=Max&Value=42
    http://localhost/                    <- lists all available scripts
    http://localhost/health              <- server status, uptime, request counter (open)
    http://localhost/metrics             <- uptime, requestsTotal, rateLimitedTotal (auth required)
#>

param(
    [switch] $HttpsEnabled,
    [ValidateRange(0, 65535)]
    [int]    $HttpPort  = 80,
    [ValidateRange(1, 65535)]
    [int]    $HttpsPort = 443
)

# ---------------------------------------------------------------------------
# Base path — hardcoded for reliable operation across all execution contexts.
# Defined before all checks so every early-exit path shares the same value.
# Adjust if the deployment directory differs.
# ---------------------------------------------------------------------------
$baseDir = 'C:\posh'

# ---------------------------------------------------------------------------
# PowerShell 7 — mandatory check
# Must run before $cfg and logging setup.
# $PSVersionTable.PSEdition is 'Core' in PS 7, 'Desktop' in PS 5.x
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Core') {
    $logDir  = Join-Path $baseDir 'logs'
    $logFile = Join-Path $logDir 'startup.log'
    $line    = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | PowerShell 7 required. Running version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    try {
        if (-not (Test-Path $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($logFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    exit 1
}

# ---------------------------------------------------------------------------
# Do NOT set ErrorActionPreference to Stop — the process runs indefinitely.
# Errors are handled per request, never globally.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# API key check — must run before $cfg so $apiKey is set when the hashtable
# is constructed. POSH_API_KEY must be set as a system environment variable
# (via Register-ScheduledTask.ps1 or manually:
# [Environment]::SetEnvironmentVariable('POSH_API_KEY','...','Machine'))
# No key = no start — unprotected operation is not permitted.
# ---------------------------------------------------------------------------
$apiKey = $env:POSH_API_KEY
if ([string]::IsNullOrEmpty($apiKey)) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | ERROR: Environment variable POSH_API_KEY is not set. Server will not start."
    try {
        if (-not (Test-Path $baseDir)) { $null = New-Item -ItemType Directory -Path $baseDir -Force }
        $startupLog = Join-Path $baseDir 'logs\startup.log'
        [System.IO.File]::AppendAllText($startupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output 'Solution: set POSH_API_KEY as a system environment variable and restart the server.'
    Write-Output "  [Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key', 'Machine')"
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration
# The prefix is no longer stored in $cfg — it is built dynamically from
# HttpPort/HttpsPort and added directly to the listener.
# HttpPort = 0 signals: HTTP disabled (only useful with HttpsEnabled).
# ---------------------------------------------------------------------------
$cfg = @{
    HttpsEnabled        = $HttpsEnabled.IsPresent                    # HTTPS active?
    HttpPort            = $HttpPort                                  # HTTP port (0 = disabled)
    HttpsPort           = $HttpsPort                                 # HTTPS port (only relevant when HttpsEnabled)
    WebRoot             = Join-Path $baseDir 'webroot'
    LogDir              = Join-Path $baseDir 'logs'
    PwshExe             = (Get-Process -Id $PID).MainModule.FileName # pwsh.exe of the running process — no hardcoded path
    ApiKey              = $apiKey                                    # from $env:POSH_API_KEY — already checked for empty string
    ScriptTimeoutSec         = 300    # 5 minutes — scripts running longer are terminated (HTTP 504)
    MaxConcurrent            = 10     # maximum parallel requests — excess requests receive HTTP 503
    LogRetentionDays         = 180    # log files older than N days are deleted at startup (0 = disabled)
    PostJsonDir              = Join-Path $baseDir 'postjson' # directory where POST body JSON files are stored
    PostJsonRetentionDays    = 30     # POST JSON files older than N days are deleted at startup (0 = disabled)
    MaxRequestBodyBytes      = 20MB   # maximum POST body size in bytes — larger requests: HTTP 413
    RateLimitRequests        = 100    # maximum requests per IP per window — excess requests: HTTP 429 (0 = disabled)
    RateLimitWindowSec       = 600    # fixed window size in seconds (10 minutes)
    RateLimitPenaltySec      = 1800   # penalty duration after first 429 in seconds (30 minutes)
    RateLimitMode            = 'reject' # 'reject' = immediate HTTP 429 | 'queue' = wait up to RateLimitQueueTimeoutSec
    RateLimitQueueTimeoutSec = 10     # 'queue' mode only: seconds to wait before returning HTTP 429
    RateLimitExemptPaths     = @('/health', '/metrics') # paths excluded from rate limiting — always an array
    MinRequestIntervalSec    = 1      # minimum seconds between dispatched requests, globally — 0 = disabled. /health and /metrics are always exempt.
    AllowedIPs               = @()    # IP allowlist — empty = all IPs allowed; non-empty = only listed IPs pass (except /health)
    BlockedIPs               = @()    # IP blocklist — always rejected before AllowedIPs check (except /health); empty = no blocks
    GzipEnabled              = $true  # GZIP response compression — only applied when client sent Accept-Encoding: gzip AND body >= GzipMinBytes AND Content-Type matches GzipMimeTypes
    GzipMinBytes             = 1024   # responses smaller than this byte count are never compressed (compression overhead exceeds savings)
    GzipMimeTypes            = @(     # response Content-Types eligible for compression — checked via StartsWith, so 'application/json' covers 'application/json; charset=utf-8'
        'application/json',
        'application/xml',
        'application/javascript',
        'text/html',
        'text/plain',
        'text/css',
        'text/javascript',
        'text/xml'
    )
    LogIntegrityHash         = $false # write <logfile>.md5 next to every completed log file at startup (legacy PoSH Server parity); current day's file is left alone
    LogSchedule              = 'Daily' # 'Daily' = YYYY-MM-DD.log | 'Hourly' = YYYY-MM-DDTHH.log
    LogFormat                = 'Native' # 'Native' = current pipe-delimited format | 'IIS-W3C' = W3C Extended Log File Format with #Fields header
    StaticServingEnabled     = $false # serve non-.ps1 files (HTML, CSS, JS, images, …) from StaticRoot — opt-in for backward compatibility
    StaticRoot               = ''     # static file root; empty string = use WebRoot (so static files live alongside .ps1 endpoints by default)
    DefaultDocuments         = @('index.html', 'index.htm')  # served when StaticServing handles a directory request (e.g. GET /docs/); PR-9 (DirectoryBrowsing) takes over when none of these exist
    StaticCacheHeaders       = $true  # emit ETag + Last-Modified on static responses and honor If-None-Match / If-Modified-Since with HTTP 304
    BlockedMimeTypes         = @()    # MIME-type blacklist for static responses — matched via StartsWith; entries trigger HTTP 403 (legacy PoSH content filter)
    MimeTypeMap              = @{
        # Extension keys are lowercased, with leading dot. Comparison is case-insensitive.
        # Text-ish types include charset=utf-8 so browsers render UTF-8 correctly without sniffing.
        '.html' = 'text/html; charset=utf-8'
        '.htm'  = 'text/html; charset=utf-8'
        '.xhtml'= 'application/xhtml+xml; charset=utf-8'
        '.css'  = 'text/css; charset=utf-8'
        '.js'   = 'text/javascript; charset=utf-8'
        '.mjs'  = 'text/javascript; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'
        '.xml'  = 'application/xml; charset=utf-8'
        '.txt'  = 'text/plain; charset=utf-8'
        '.md'   = 'text/markdown; charset=utf-8'
        '.csv'  = 'text/csv; charset=utf-8'
        '.rss'  = 'application/rss+xml'
        '.atom' = 'application/atom+xml'
        '.svg'  = 'image/svg+xml'
        '.svgz' = 'image/svg+xml'
        '.png'  = 'image/png'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif'  = 'image/gif'
        '.ico'  = 'image/x-icon'
        '.webp' = 'image/webp'
        '.bmp'  = 'image/bmp'
        '.tiff' = 'image/tiff'
        '.tif'  = 'image/tiff'
        '.pdf'  = 'application/pdf'
        '.zip'  = 'application/zip'
        '.rar'  = 'application/vnd.rar'
        '.7z'   = 'application/x-7z-compressed'
        '.gz'   = 'application/gzip'
        '.tar'  = 'application/x-tar'
        '.mp3'  = 'audio/mpeg'
        '.ogg'  = 'audio/ogg'
        '.oga'  = 'audio/ogg'
        '.wav'  = 'audio/wav'
        '.mp4'  = 'video/mp4'
        '.m4v'  = 'video/mp4'
        '.ogv'  = 'video/ogg'
        '.webm' = 'video/webm'
        '.mpeg' = 'video/mpeg'
        '.mpg'  = 'video/mpeg'
        '.flv'  = 'video/x-flv'
        '.swf'  = 'application/x-shockwave-flash'
        '.wmv'  = 'video/x-ms-wmv'
        '.woff' = 'font/woff'
        '.woff2'= 'font/woff2'
        '.eot'  = 'application/vnd.ms-fontobject'
        '.otf'  = 'font/otf'
        '.ttf'  = 'font/ttf'
        '.wasm' = 'application/wasm'
        '.map'  = 'application/json; charset=utf-8'
    }
}

# StaticRoot fallback — empty string means: reuse WebRoot. Resolved here rather than at
# request time so the static handler can compare full paths without per-request work.
if ([string]::IsNullOrEmpty($cfg.StaticRoot)) { $cfg.StaticRoot = $cfg.WebRoot }

# Runtime measurement from server start — used for health check uptime.
$startTime = [System.Diagnostics.Stopwatch]::StartNew()

# Counts completed script requests (exit-code-independent).
# [ref] + Interlocked::Increment guarantees thread safety without a mutex.
$script:requestsTotal = [ref] 0L

# Counts requests rejected by rate limiting (HTTP 429).
# Kept separate from requestsTotal — used by the future /metrics endpoint.
$script:rateLimitedTotal = [ref] 0L

# Per-IP rate limit state — ConcurrentDictionary for lock-free access from RunspacePool Runspaces.
# Key: client IP string. Value: PSCustomObject { Count [ref]; WindowStart [datetime]; PenaltyUntil [datetime] }.
$script:rateLimitTable = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# Mutex serializes concurrent write access to the log file.
# Global\ makes the mutex unique across process boundaries.
$script:logMutex = [System.Threading.Mutex]::new($false, 'Global\PoshWebserverLog')

# ---------------------------------------------------------------------------
# Logging
# Writes to the log file AND to stdout (visible in Scheduled Task event log).
# No Write-Host with -ForegroundColor — throws IOException in non-interactive contexts.
# $script:cfg instead of $cfg — function also runs in RunspacePool instances.
#
# Format-aware:
#   Native   — pipe-delimited line as before, file = YYYY-MM-DD.log (or YYYY-MM-DDTHH.log when Hourly).
#   IIS-W3C  — W3C Extended Log File Format, file name identical, first write to a new file
#              emits #Software / #Version / #Date / #Fields header lines.
#
# Optional W3C extras ($HttpStatus / $Method / $UriStem / $UriQuery / $UserAgent) are only
# consulted in IIS-W3C mode. When omitted, they are derived from $Request as a best-effort
# fallback so existing callers do not need to change. $Status (text) is mapped onto sc-status
# heuristically as a last resort.
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string] $ClientIP   = '-',
        [string] $Request    = '-',
        [string] $Status     = '-',
        [string] $ExitCode   = '-',
        [string] $RequestId  = '-',
        # W3C-only extras — ignored in Native format.
        [int]    $HttpStatus = 0,
        [string] $Method     = '',
        [string] $UriStem    = '',
        [string] $UriQuery   = '',
        [string] $UserAgent  = '-'
    )

    $now      = Get-Date
    $schedule = if ($script:cfg.LogSchedule -eq 'Hourly') { 'Hourly' } else { 'Daily' }
    $format   = if ($script:cfg.LogFormat   -eq 'IIS-W3C') { 'IIS-W3C' } else { 'Native' }

    $fileStem = if ($schedule -eq 'Hourly') { $now.ToString('yyyy-MM-ddTHH') } else { $now.ToString('yyyy-MM-dd') }
    $logFile  = Join-Path $script:cfg.LogDir ($fileStem + '.log')

    if ($format -eq 'IIS-W3C') {
        # Derive missing W3C fields from the Native-style $Request "GET /path?query" as a fallback.
        if ($Method -eq '' -or $UriStem -eq '') {
            $parts = $Request -split ' ', 2
            if ($Method -eq '' -and $parts.Count -ge 1) { $Method = $parts[0] }
            if ($parts.Count -ge 2) {
                $uri = $parts[1]
                $qIx = $uri.IndexOf('?')
                if ($qIx -ge 0) {
                    if ($UriStem  -eq '') { $UriStem  = $uri.Substring(0, $qIx) }
                    if ($UriQuery -eq '') { $UriQuery = $uri.Substring($qIx + 1) }
                } elseif ($UriStem -eq '') {
                    $UriStem = $uri
                }
            }
        }
        if ($HttpStatus -le 0) {
            # Map textual $Status onto sc-status when caller did not pass an explicit HTTP code.
            $HttpStatus = switch -Regex ($Status) {
                '^OK$|^INDEX$|^HEALTH$|^METRICS$' { 200; break }
                '^METHOD NOT ALLOWED$'            { 405; break }
                '^UNAUTHORIZED$'                  { 401; break }
                '^FORBIDDEN$|^IP BLOCKED$|^IP NOT ALLOWED$' { 403; break }
                '^NOT FOUND$'                     { 404; break }
                '^RATE LIMITED$'                  { 429; break }
                '^TIMEOUT$'                       { 504; break }
                '^BAD REQUEST$|^HTTP \d+$'        { 400; break }
                '^ERROR$|^REQUEST-ERROR'          { 500; break }
                default                           { 0 }
            }
        }
        if ([string]::IsNullOrEmpty($UriStem))  { $UriStem  = '-' }
        if ([string]::IsNullOrEmpty($UriQuery)) { $UriQuery = '-' }
        if ([string]::IsNullOrEmpty($Method))   { $Method   = '-' }
        if ([string]::IsNullOrEmpty($UserAgent)){ $UserAgent = '-' }
        # W3C requires UA without spaces — collapse whitespace to '+'.
        $UserAgent = ($UserAgent -replace '\s+', '+')

        $line = '{0} {1} {2} {3} {4} {5} {6} {7} {8}' -f `
            $now.ToString('yyyy-MM-dd'),
            $now.ToString('HH:mm:ss'),
            $ClientIP,
            $Method,
            $UriStem,
            $UriQuery,
            $HttpStatus,
            $UserAgent,
            $RequestId
    } else {
        $line = '{0} | {1} | {2} | EXIT:{3} | {4} | {5}' -f `
            $now.ToString('yyyy-MM-dd HH:mm:ss'),
            $ClientIP.PadRight(15),
            $Request.PadRight(60),
            $ExitCode.PadRight(4),
            $Status.PadRight(13),
            $RequestId
    }

    # Mutex prevents corrupted lines from parallel writes across RunspacePool Runspaces.
    # WaitOne(500): wait at most 500ms — on failure continue silently, never kill the process.
    # Track $acquired: ReleaseMutex() must only be called when WaitOne() succeeded —
    # otherwise ApplicationException because the calling thread does not hold the mutex.
    $acquired = $false
    try {
        $acquired = $script:logMutex.WaitOne(500)
        if ($format -eq 'IIS-W3C' -and -not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
            # Emit W3C header block once per file — the #Fields line is what tools like
            # logparser require to interpret subsequent records.
            $header = @(
                '#Software: posh-webserver'
                '#Version: 1.0'
                ('#Date: {0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'))
                '#Fields: date time c-ip cs-method cs-uri-stem cs-uri-query sc-status cs(User-Agent) x-request-id'
            ) -join [System.Environment]::NewLine
            Add-Content -LiteralPath $logFile -Value $header -Encoding UTF8
        }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { } finally {
        try { if ($acquired) { $script:logMutex.ReleaseMutex() } } catch { }
    }

    # Also to stdout — appears in Scheduled Task history output.
    Write-Output $line
}

# Startup events (before the listener) are written to a separate startup.log.
function Write-StartupLog {
    param([string] $Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp | STARTUP | $Message"

    # LogDir is already ensured in the startup flow — no Test-Path needed.
    try {
        Add-Content -LiteralPath (Join-Path $script:cfg.LogDir 'startup.log') -Value $line -Encoding UTF8
    } catch { }

    Write-Output $line
}

# ---------------------------------------------------------------------------
# Log rotation
# Deletes .log files in LogDir that are older than RetentionDays days.
# Runs once at startup — never during operation.
# RetentionDays = 0: rotation disabled (explicit opt-out).
# Returns the number of deleted files — logging is the caller's responsibility.
# ---------------------------------------------------------------------------
function Remove-OldLogs {
    param(
        [string] $LogDir,
        [int]    $RetentionDays
    )

    if ($RetentionDays -le 0) { return 0 }

    $cutoff  = (Get-Date).AddDays(-$RetentionDays)
    $deleted = 0

    Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
                # Companion MD5 file (if LogIntegrityHash was enabled previously) is removed too —
                # leaving orphan .md5 files would clutter the directory and confuse audit consumers.
                $md5 = $_.FullName + '.md5'
                if (Test-Path -LiteralPath $md5 -PathType Leaf) {
                    try { Remove-Item -LiteralPath $md5 -Force } catch { }
                }
            } catch { }
        }

    return $deleted
}

# ---------------------------------------------------------------------------
# Save-LogIntegrityHashes
# Writes an MD5 hash file next to every completed log file in LogDir.
# A log file is "completed" when its file stem differs from the current
# YYYY-MM-DD (Daily) or YYYY-MM-DDTHH (Hourly) stem — the currently-active
# file is left untouched so its hash never goes out of sync with a partial
# write.
# Runs once at startup — never during operation. Caller controls invocation
# via $cfg.LogIntegrityHash. Idempotent: an existing .md5 file is not rewritten.
# Returns the number of hash files newly created.
# ---------------------------------------------------------------------------
function Save-LogIntegrityHashes {
    # MD5 is intentional: this is a basic at-rest integrity tag for log audit, NOT a security
    # primitive. The format matches `md5sum` for tool compatibility, and that is what the
    # legacy PoSH Server emitted — replacing MD5 with SHA256 here would break audit consumers
    # without strengthening anything (a log-rewriter on the same box can also rewrite the .md5).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '',
        Justification = 'MD5 chosen for md5sum-compatible at-rest log integrity tagging, not for cryptographic use')]
    param(
        [string] $LogDir,
        [string] $Schedule = 'Daily'   # 'Daily' or 'Hourly' — controls which file stem counts as "current"
    )

    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return 0 }

    $currentStem = if ($Schedule -eq 'Hourly') { (Get-Date).ToString('yyyy-MM-ddTHH') } else { (Get-Date).ToString('yyyy-MM-dd') }
    $created     = 0

    Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -ne $currentStem -and $_.BaseName -ne 'startup' -and $_.BaseName -ne 'jobs' } |
        ForEach-Object {
            $hashFile = $_.FullName + '.md5'
            if (Test-Path -LiteralPath $hashFile -PathType Leaf) { return }
            try {
                # Get-FileHash is the canonical way; .NET MD5 wrapper avoids spawning Format-* pipelines.
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash.ToLowerInvariant()
                # Format mirrors `md5sum` so the file is consumable by standard audit tools.
                $line = '{0}  {1}' -f $hash, $_.Name
                [System.IO.File]::WriteAllText($hashFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
                $created++
            } catch { }
        }

    return $created
}

# ---------------------------------------------------------------------------
# POST JSON file cleanup
# Deletes .json files in PostJsonDir that are older than RetentionDays days.
# Runs once at startup — never during operation.
# RetentionDays = 0: cleanup disabled (explicit opt-out).
# Returns the number of deleted files — logging is the caller's responsibility.
# ---------------------------------------------------------------------------
function Remove-OldPostJsonFiles {
    param(
        [string] $PostJsonDir,
        [int]    $RetentionDays
    )

    if ($RetentionDays -le 0) { return 0 }

    $cutoff  = (Get-Date).AddDays(-$RetentionDays)
    $deleted = 0

    Get-ChildItem -Path $PostJsonDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
            } catch { }
        }

    return $deleted
}

# ---------------------------------------------------------------------------
# Rate-limit table cleanup
# Removes stale entries from the per-IP ConcurrentDictionary — IPs whose
# penalty has expired AND whose rate-limit window has elapsed hold no useful
# state and would grow the table indefinitely over long uptimes.
# Called once at startup before the listener opens — no concurrent access.
# Returns the number of removed entries — logging is the caller's responsibility.
# ---------------------------------------------------------------------------
function Remove-StaleRateLimitEntries {
    param(
        [System.Collections.Concurrent.ConcurrentDictionary[string,object]] $Table,
        [int] $WindowSec,
        [int] $PenaltySec
    )

    if ($Table.Count -eq 0) { return 0 }

    $now     = [datetime]::UtcNow
    $removed = 0

    # @($Table.Keys) snapshots the key list — defensive against keys added by other
    # threads. At startup there are no other threads, but the pattern is correct.
    foreach ($key in @($Table.Keys)) {
        $entry = $null
        if (-not $Table.TryGetValue($key, [ref]$entry)) { continue }

        # Ticks arithmetic — avoids [datetime] operator/method dispatch issues in
        # runspace contexts (not relevant here at startup, but consistent with the
        # rest of the codebase).
        $penaltyExpired = $entry.PenaltyUntil.Ticks  -le $now.Ticks
        $windowExpired  = (($now.Ticks - $entry.WindowStart.Ticks) / [timespan]::TicksPerSecond) -ge $WindowSec

        if ($penaltyExpired -and $windowExpired) {
            $out = $null
            if ($Table.TryRemove($key, [ref]$out)) { $removed++ }
        }
    }

    return $removed
}

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-StartupLog 'ERROR: Not running as Administrator. Port binding requires admin privileges.'
    Write-Output ''
    Write-Output 'ERROR: This script must be run as Administrator.'
    Write-Output 'Solution: open pwsh.exe as Administrator and run again.'
    exit 1
}

# ---------------------------------------------------------------------------
# HTTPS validation
# Check whether a netsh sslcert binding exists for the configured HTTPS port
# before starting the listener. Missing binding: hard exit with exit 1.
# Silent fallback to HTTP would be dangerous — unencrypted communication
# would occur without notice.
# ---------------------------------------------------------------------------
if ($cfg.HttpsEnabled) {
    $netshOut = netsh http show sslcert "ipport=0.0.0.0:$($cfg.HttpsPort)" 2>&1
    if ($LASTEXITCODE -ne 0 -or ($netshOut -join '') -notmatch 'IP:Port') {
        Write-StartupLog "ERROR: No netsh sslcert binding found for port $($cfg.HttpsPort)."
        Write-StartupLog 'Solution: run Register-ScheduledTask.ps1 again and configure HTTPS.'
        Write-Output ''
        Write-Output "ERROR: HTTPS configured but no certificate binding found for port $($cfg.HttpsPort)."
        Write-Output "Check: netsh http show sslcert ipport=0.0.0.0:$($cfg.HttpsPort)"
        Write-Output 'Solution: run Register-ScheduledTask.ps1 again.'
        exit 1
    }
    Write-StartupLog "HTTPS validation OK: netsh sslcert binding found for port $($cfg.HttpsPort)."
}

# ---------------------------------------------------------------------------
# Log startup information
# ---------------------------------------------------------------------------
$httpsInfo = if ($cfg.HttpsEnabled) { "  HTTPS=:$($cfg.HttpsPort)" } else { '' }
$httpInfo  = if ($cfg.HttpPort -gt 0) { "  HTTP=:$($cfg.HttpPort)" } else { '  HTTP=disabled' }
Write-StartupLog "Web server starting. BaseDir=$baseDir  WebRoot=$($cfg.WebRoot)  LogDir=$($cfg.LogDir)  PS=$($PSVersionTable.PSVersion)$httpInfo$httpsInfo"

# ---------------------------------------------------------------------------
# Ensure directories exist
# ---------------------------------------------------------------------------
foreach ($dir in @($cfg.WebRoot, $cfg.LogDir, $cfg.PostJsonDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Write-StartupLog "Directory created: $dir"
    }
}

# ---------------------------------------------------------------------------
# Log rotation at startup
# ---------------------------------------------------------------------------
$deletedLogs = Remove-OldLogs -LogDir $cfg.LogDir -RetentionDays $cfg.LogRetentionDays
if ($deletedLogs -gt 0) {
    Write-StartupLog "Log rotation: $deletedLogs file(s) older than $($cfg.LogRetentionDays) days deleted."
}

# ---------------------------------------------------------------------------
# Log integrity hashes at startup (opt-in, $cfg.LogIntegrityHash).
# Writes <logfile>.md5 next to every completed log file — the file currently
# being written to is intentionally skipped so the hash never goes stale.
# ---------------------------------------------------------------------------
if ($cfg.LogIntegrityHash) {
    $hashesCreated = Save-LogIntegrityHashes -LogDir $cfg.LogDir -Schedule $cfg.LogSchedule
    if ($hashesCreated -gt 0) {
        Write-StartupLog "Log integrity: $hashesCreated MD5 hash file(s) created."
    }
}

# ---------------------------------------------------------------------------
# POST JSON file cleanup at startup
# Deletes .json files in PostJsonDir older than PostJsonRetentionDays days.
# Files are intentionally kept after processing for audit/debugging purposes.
# ---------------------------------------------------------------------------
$deletedPostJson = Remove-OldPostJsonFiles -PostJsonDir $cfg.PostJsonDir -RetentionDays $cfg.PostJsonRetentionDays
if ($deletedPostJson -gt 0) {
    Write-StartupLog "POST JSON cleanup: $deletedPostJson file(s) older than $($cfg.PostJsonRetentionDays) days deleted."
}

# ---------------------------------------------------------------------------
# Rate-limit table cleanup at startup
# The table starts empty on every fresh process start — this is a no-op on
# first start. On restart after a crash or update the table retains no state
# (in-memory only), so this is also always a no-op in practice. The call is
# kept for correctness and future-proofing (e.g. if persistence is ever added).
# ---------------------------------------------------------------------------
if ($cfg.RateLimitRequests -gt 0) {
    $cleanedEntries = Remove-StaleRateLimitEntries `
        -Table      $script:rateLimitTable `
        -WindowSec  $cfg.RateLimitWindowSec `
        -PenaltySec $cfg.RateLimitPenaltySec
    Write-StartupLog "Rate-limit table cleanup: $cleanedEntries stale entries removed."
}

# ---------------------------------------------------------------------------
# Configure HTTP listener
# Prefixes are built dynamically from HttpPort/HttpsPort.
# HttpPort = 0: no HTTP prefix — HTTPS only.
# Both protocols can be active simultaneously — HttpListener supports
# mixed http/https prefixes without restrictions.
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()

$activePrefixes = [System.Collections.Generic.List[string]]::new()
if ($cfg.HttpsEnabled) {
    $null = $activePrefixes.Add("https://+:$($cfg.HttpsPort)/")
}
if ($cfg.HttpPort -gt 0) {
    $null = $activePrefixes.Add("http://+:$($cfg.HttpPort)/")
}
foreach ($prefix in $activePrefixes) {
    $listener.Prefixes.Add($prefix)
}

try {
    $listener.Start()
} catch {
    Write-StartupLog "ERROR: HttpListener could not be started: $_"
    $portHint = if ($cfg.HttpPort -gt 0) { $cfg.HttpPort } else { $cfg.HttpsPort }
    Write-Output "ERROR: Port $portHint may already be in use."
    Write-Output "Check: netstat -ano | findstr :$portHint"
    exit 1
}

foreach ($prefix in $activePrefixes) {
    Write-StartupLog "Web server listening on $prefix"
}

Write-Output ''
Write-Output 'PowerShell web server started'
foreach ($prefix in $activePrefixes) {
    Write-Output "Prefix  : $prefix"
}
Write-Output "WebRoot : $($cfg.WebRoot)"
Write-Output "LogDir  : $($cfg.LogDir)"
Write-Output ''

# ---------------------------------------------------------------------------
# Concurrency infrastructure
# Semaphore: limits active requests to MaxConcurrent — protects against bursts.
# ---------------------------------------------------------------------------
$semaphore = [System.Threading.SemaphoreSlim]::new($cfg.MaxConcurrent, $cfg.MaxConcurrent)

# ---------------------------------------------------------------------------
# Helper functions for request processing
# ---------------------------------------------------------------------------

function New-JsonResponse {
    param(
        [int]    $ExitCode,
        [string] $Output,
        [string] $Err
    )
    [ordered]@{
        exitCode = $ExitCode
        output   = $Output
        error    = $Err
    } | ConvertTo-Json -Compress -Depth 2
}

function Send-Response {
    param(
        [System.Net.HttpListenerResponse] $Response,
        [int]    $StatusCode,
        [string] $Body,
        [string] $RequestId      = '',
        [string] $ContentType    = 'application/json; charset=utf-8',
        [AllowNull()]
        [string] $AcceptEncoding = $null
    )
    try {
        # Default $AcceptEncoding to the per-request value the handler stashes in $script:
        # scope before calling. Keeps the 13 existing call sites unchanged while still
        # giving Send-Response access to the client's Accept-Encoding header.
        if ($null -eq $AcceptEncoding) {
            try { $AcceptEncoding = $script:acceptEncoding } catch { $AcceptEncoding = '' }
            if ($null -eq $AcceptEncoding) { $AcceptEncoding = '' }
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)

        # GZIP compression — opt-in via $cfg.GzipEnabled, gated on three conditions:
        #   1. Client advertised gzip via Accept-Encoding.
        #   2. Body is large enough that compression actually saves bytes (GzipMinBytes).
        #   3. Content-Type matches one of the configured prefixes — only text-ish payloads
        #      benefit; pre-compressed binary types (PNG, JPEG, ZIP) would only inflate.
        # The comparison uses StartsWith so 'application/json' covers 'application/json; charset=utf-8'.
        if ($script:cfg.GzipEnabled -and
            $AcceptEncoding -and
            $AcceptEncoding.IndexOf('gzip', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $bytes.Length -ge $script:cfg.GzipMinBytes) {

            $mimeOk = $false
            foreach ($mime in $script:cfg.GzipMimeTypes) {
                if ($ContentType.StartsWith($mime, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mimeOk = $true
                    break
                }
            }
            if ($mimeOk) {
                $ms = $null
                $gz = $null
                try {
                    $ms = [System.IO.MemoryStream]::new()
                    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                    $gz.Write($bytes, 0, $bytes.Length)
                    $gz.Dispose(); $gz = $null
                    $bytes = $ms.ToArray()
                    $Response.AddHeader('Content-Encoding', 'gzip')
                } finally {
                    if ($null -ne $gz) { try { $gz.Dispose() } catch { } }
                    if ($null -ne $ms) { try { $ms.Dispose() } catch { } }
                }
            }
        }

        $Response.StatusCode      = $StatusCode
        $Response.ContentType     = $ContentType
        $Response.ContentLength64 = $bytes.Length
        # X-Request-Id header allows clients to correlate requests to log entries.
        if ($RequestId -ne '') { $Response.AddHeader('X-Request-Id', $RequestId) }
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        # Connection may have been closed by the client before the response was sent.
        # Log for diagnostics but do not propagate — a broken pipe must never kill the process.
        Write-Log -ClientIP '-' -Request '-' -Status "SEND-ERROR: $_" -ExitCode '-'
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Get-QueryParams {
    param([System.Collections.Specialized.NameValueCollection] $QueryString)
    $params = @{}
    foreach ($key in $QueryString.AllKeys) {
        if ($null -ne $key -and $key -ne '') {
            $params[$key] = $QueryString[$key]
        }
    }
    return $params
}

function Get-BodyParams {
    # Reads and validates the POST body.
    # Returns PSCustomObject { Error [int]; RawJson [string] }.
    #   Error = 0   → valid; RawJson contains the raw UTF-8 body string.
    #   Error = 415 → wrong Content-Type (must be application/json).
    #   Error = 413 → body exceeds MaxRequestBodyBytes.
    #   Error = 400 → body is not valid JSON.
    #
    # No flat-structure validation — nested objects and arrays are fully supported.
    # The raw JSON is written to a file by Save-PostJson; the script receives the
    # file path via -JsonFilePath and reads/parses the JSON itself.
    param([System.Net.HttpListenerRequest] $Request)

    # Check Content-Type — must be application/json.
    # StartsWith allows variants like "application/json; charset=utf-8".
    $ct = $Request.ContentType
    if (-not $ct -or -not $ct.StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Error = 415; RawJson = $null }
    }

    # Check body size before reading — ContentLength64 is -1 when no Content-Length header is set.
    # Only reject when size is known AND too large — unknown size is checked after reading.
    if ($Request.ContentLength64 -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; RawJson = $null }
    }

    # Read body — leaveOpen=$true keeps InputStream alive (owned by HttpListenerRequest).
    # The StreamReader wrapper itself is disposed explicitly after reading.
    $reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8, $true, -1, $true)
    try {
        $rawBody = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }

    # Check size again in case Content-Length was missing.
    if ($rawBody.Length -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; RawJson = $null }
    }

    # Empty body — treat as empty JSON object so the script receives an empty file.
    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return [PSCustomObject]@{ Error = 0; RawJson = '{}' }
    }

    # Validate JSON syntax — reject syntactically invalid payloads early.
    # Nested objects and arrays are intentionally allowed.
    try {
        $null = $rawBody | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Error = 400; RawJson = $null }
    }

    return [PSCustomObject]@{ Error = 0; RawJson = $rawBody }
}

# ---------------------------------------------------------------------------
# Save-PostJson
# Writes the raw POST body to a uniquely named .json file in PostJsonDir.
# File name format: YYYYMMDD_HHmmss_<requestId>.json
#   — date+time prefix: chronologically sortable
#   — requestId suffix: unique, correlatable to log entry and X-Request-Id header
# File is UTF-8, no BOM.
# Returns the absolute file path — passed to the webroot script as -JsonFilePath.
# Files are intentionally kept after processing for audit/debugging.
# Cleanup is handled by Remove-OldPostJsonFiles at startup (PostJsonRetentionDays).
# ---------------------------------------------------------------------------
function Save-PostJson {
    param(
        [string] $RawJson,
        [string] $RequestId
    )

    $fileName = '{0}_{1}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $RequestId
    $filePath = Join-Path $script:cfg.PostJsonDir $fileName
    [System.IO.File]::WriteAllText($filePath, $RawJson, [System.Text.Encoding]::UTF8)
    return $filePath
}

# ---------------------------------------------------------------------------
# Get-MimeType
# Returns the configured MIME-type for a file extension, or 'application/octet-stream'
# when no entry matches. Comparison is case-insensitive — keys in $cfg.MimeTypeMap
# are always lowercase with a leading dot ('.png', '.json').
# ---------------------------------------------------------------------------
function Get-MimeType {
    param([string] $Extension)
    if ([string]::IsNullOrEmpty($Extension)) { return 'application/octet-stream' }
    $key = $Extension.ToLowerInvariant()
    if (-not $key.StartsWith('.')) { $key = '.' + $key }
    if ($script:cfg.MimeTypeMap.ContainsKey($key)) { return $script:cfg.MimeTypeMap[$key] }
    return 'application/octet-stream'
}

# ---------------------------------------------------------------------------
# Send-StaticFile
# Serves a file from disk with full RFC-7232 conditional-request support
# (If-None-Match / If-Modified-Since) and RFC-7233 byte-range support.
#
# Returns PSCustomObject { StatusCode [int]; Reason [string]; Length [long] }.
# Reason is used only for log output — Send-StaticFile writes headers and body
# itself and never throws on a closed client connection.
#
# Caller responsibilities:
#   - resolve $FilePath under StaticRoot with path-traversal protection
#   - log the result (via Write-Log) — Send-StaticFile does not log
#   - skip this path for .ps1 endpoints — those go through Invoke-Script
# ---------------------------------------------------------------------------
function Send-StaticFile {
    param(
        [System.Net.HttpListenerRequest]  $Request,
        [System.Net.HttpListenerResponse] $Response,
        [string]                          $FilePath,
        [string]                          $RequestId
    )

    $fi = [System.IO.FileInfo]::new($FilePath)
    if (-not $fi.Exists) {
        return [PSCustomObject]@{ StatusCode = 404; Reason = 'NOT FOUND'; Length = 0 }
    }

    $mime = Get-MimeType -Extension $fi.Extension

    # MIME blacklist — legacy PoSH content filter parity. Matching uses StartsWith
    # so 'video/' blocks all video subtypes without listing each.
    foreach ($blocked in $script:cfg.BlockedMimeTypes) {
        if ($mime.StartsWith($blocked, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{ StatusCode = 403; Reason = 'MIME BLOCKED'; Length = 0 }
        }
    }

    # Cache validators — ETag is "<length>-<utcTicks>" so it changes on either
    # content size OR last-write-time change. Quotes are part of the literal
    # ETag value per RFC 7232.
    $lastModifiedUtc = $fi.LastWriteTimeUtc
    $etag            = '"{0}-{1:X}"' -f $fi.Length, $lastModifiedUtc.Ticks

    if ($script:cfg.StaticCacheHeaders) {
        $ifNoneMatch = $Request.Headers['If-None-Match']
        if ($ifNoneMatch -and $ifNoneMatch -eq $etag) {
            $Response.StatusCode = 304
            $Response.AddHeader('ETag',          $etag)
            $Response.AddHeader('Last-Modified', $lastModifiedUtc.ToString('R'))
            if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }
            try { $Response.OutputStream.Close() } catch { }
            return [PSCustomObject]@{ StatusCode = 304; Reason = 'NOT MODIFIED'; Length = 0 }
        }
        $ifModifiedSince = $Request.Headers['If-Modified-Since']
        if ($ifModifiedSince) {
            try {
                $imsDate = [datetime]::Parse($ifModifiedSince).ToUniversalTime()
                # Trim sub-second precision — HTTP-date format does not carry milliseconds.
                $lastModTrimmed = [datetime]::new($lastModifiedUtc.Year, $lastModifiedUtc.Month, $lastModifiedUtc.Day, $lastModifiedUtc.Hour, $lastModifiedUtc.Minute, $lastModifiedUtc.Second, [System.DateTimeKind]::Utc)
                if ($lastModTrimmed.Ticks -le $imsDate.Ticks) {
                    $Response.StatusCode = 304
                    $Response.AddHeader('ETag',          $etag)
                    $Response.AddHeader('Last-Modified', $lastModifiedUtc.ToString('R'))
                    if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }
                    try { $Response.OutputStream.Close() } catch { }
                    return [PSCustomObject]@{ StatusCode = 304; Reason = 'NOT MODIFIED'; Length = 0 }
                }
            } catch { }
        }
    }

    # Range request — single-range only (multipart/byteranges intentionally not implemented).
    $rangeStart = 0L
    $rangeEnd   = $fi.Length - 1L
    $isRange    = $false
    $rawRange   = $Request.Headers['Range']
    if ($rawRange -and $rawRange.StartsWith('bytes=', [System.StringComparison]::OrdinalIgnoreCase)) {
        $spec = $rawRange.Substring(6).Trim()
        # Multi-range like 'bytes=0-100,200-300' — fall back to full content instead of
        # complicating the response with multipart/byteranges. Conformant per RFC 7233.
        if (-not $spec.Contains(',')) {
            $parts = $spec.Split('-', 2)
            if ($parts.Length -eq 2) {
                try {
                    if ($parts[0] -ne '') { $rangeStart = [long]$parts[0] }
                    if ($parts[1] -ne '') { $rangeEnd   = [long]$parts[1] }
                    elseif ($parts[0] -eq '') {
                        # Suffix range 'bytes=-N' — last N bytes.
                        $suffix = [long]$parts[1]
                        $rangeStart = [long][math]::Max(0L, $fi.Length - $suffix)
                        $rangeEnd   = $fi.Length - 1L
                    }
                    if ($rangeStart -lt 0 -or $rangeEnd -ge $fi.Length -or $rangeStart -gt $rangeEnd) {
                        $Response.StatusCode = 416
                        $Response.AddHeader('Content-Range', ('bytes */{0}' -f $fi.Length))
                        if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }
                        try { $Response.OutputStream.Close() } catch { }
                        return [PSCustomObject]@{ StatusCode = 416; Reason = 'RANGE INVALID'; Length = 0 }
                    }
                    $isRange = $true
                } catch { $isRange = $false }
            }
        }
    }

    $contentLength = $rangeEnd - $rangeStart + 1L

    # GZIP compression for static text content — only when no Range was requested.
    # Range + Content-Encoding is a thorny combination (clients differ on whether ranges
    # apply to compressed or original bytes); skipping compression for ranges sidesteps
    # the issue and matches the behavior of most production servers.
    $compressBody = $null
    $useGzip      = $false
    if (-not $isRange -and $script:cfg.GzipEnabled -and $contentLength -ge $script:cfg.GzipMinBytes) {
        $accept = $Request.Headers['Accept-Encoding']
        if ($accept -and $accept.IndexOf('gzip', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            foreach ($prefix in $script:cfg.GzipMimeTypes) {
                if ($mime.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Load + compress in-memory. Acceptable for text content where bodies are
                    # typically small (HTML/CSS/JS); GzipMinBytes still gates against tiny payloads.
                    $useGzip      = $true
                    $allBytes     = [System.IO.File]::ReadAllBytes($FilePath)
                    $ms           = [System.IO.MemoryStream]::new()
                    $gz           = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                    try {
                        $gz.Write($allBytes, 0, $allBytes.Length)
                    } finally {
                        $gz.Dispose()
                    }
                    $compressBody = $ms.ToArray()
                    $ms.Dispose()
                    break
                }
            }
        }
    }

    # Common headers
    $Response.StatusCode    = if ($isRange) { 206 } else { 200 }
    $Response.ContentType   = $mime
    $Response.AddHeader('Accept-Ranges', 'bytes')
    if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }
    if ($script:cfg.StaticCacheHeaders) {
        $Response.AddHeader('ETag',          $etag)
        $Response.AddHeader('Last-Modified', $lastModifiedUtc.ToString('R'))
    }
    if ($isRange) {
        $Response.AddHeader('Content-Range', ('bytes {0}-{1}/{2}' -f $rangeStart, $rangeEnd, $fi.Length))
    }
    if ($useGzip -and $null -ne $compressBody) {
        $Response.AddHeader('Content-Encoding', 'gzip')
        $Response.AddHeader('Vary',             'Accept-Encoding')
        $Response.ContentLength64 = $compressBody.Length
    } else {
        $Response.ContentLength64 = $contentLength
    }

    # Body stream — gzip path uses the in-memory buffer; otherwise stream from disk
    # with a 64 KB buffer to avoid loading large media files entirely into memory.
    if ($useGzip -and $null -ne $compressBody) {
        try { $Response.OutputStream.Write($compressBody, 0, $compressBody.Length) } catch { }
    } else {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            if ($rangeStart -gt 0) { $null = $fs.Seek($rangeStart, [System.IO.SeekOrigin]::Begin) }
            $buffer    = [byte[]]::new(65536)
            $remaining = $contentLength
            while ($remaining -gt 0L) {
                $toRead = [int][math]::Min([long]$buffer.Length, $remaining)
                $read   = $fs.Read($buffer, 0, $toRead)
                if ($read -le 0) { break }
                $Response.OutputStream.Write($buffer, 0, $read)
                $remaining -= $read
            }
        } catch {
            # Client disconnected mid-stream — common for media seeking; never fatal.
        } finally {
            if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
        }
    }
    try { $Response.OutputStream.Close() } catch { }

    $reason = if ($isRange) { 'OK PARTIAL' } else { 'OK STATIC' }
    return [PSCustomObject]@{ StatusCode = $Response.StatusCode; Reason = $reason; Length = $contentLength }
}

function Invoke-Script {
    param(
        [string]    $ScriptPath,
        [hashtable] $Params,
        [int]       $TimeoutSec,
        [string]    $JsonFilePath = ''  # when set: passed as -JsonFilePath to the script (POST requests)
    )

    # pwsh.exe as a separate process — the only reliable method to:
    # 1. Read $proc.ExitCode correctly (exit 0 / exit 1 from webroot scripts)
    # 2. Enforce timeout via WaitForExit(ms) + Kill()
    # 3. Avoid running scripts directly in the Runspace where exit 1 is invisible
    # ReadToEndAsync BEFORE WaitForExit — no ScriptBlock delegate, no runspace needed, no deadlock.

    # Build parameters as separate entries in ArgumentList — no manual quoting needed.
    # ArgumentList (Collection) instead of Arguments (String): Windows escapes each entry correctly;
    # special characters like " or spaces in query parameter values cannot corrupt the argument list.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $script:cfg.PwshExe
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    foreach ($arg in @('-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        $null = $psi.ArgumentList.Add($arg)
    }
    # GET: pass query string key/value pairs as named arguments.
    foreach ($key in $Params.Keys) {
        $null = $psi.ArgumentList.Add("-$key")
        $null = $psi.ArgumentList.Add($Params[$key])
    }
    # POST: pass the JSON file path as -JsonFilePath — the script reads and parses it.
    # No -Key Value pairs for POST: single file path is unambiguous and avoids
    # ArgumentList length limits and quoting edge cases for large/complex payloads.
    if ($JsonFilePath -ne '') {
        $null = $psi.ArgumentList.Add('-JsonFilePath')
        $null = $psi.ArgumentList.Add($JsonFilePath)
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    # Read streams asynchronously BEFORE WaitForExit — prevents deadlock when stdout/stderr buffer fills up.
    # GetAwaiter().GetResult() blocks synchronously until the stream is closed — pure .NET, no ScriptBlock.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $finished) {
        # Timeout — kill the process.
        try { $proc.Kill() } catch { }
        $proc.Dispose()
        return [PSCustomObject]@{
            ExitCode = -1
            Output   = ''
            Error    = "Timeout: script was terminated after $TimeoutSec seconds."
            TimedOut = $true
        }
    }

    # Second WaitForExit() ensures all buffered stream data is flushed before
    # reading the stream tasks. Under load, many pwsh.exe processes start
    # simultaneously and contend on Windows-internal process-creation locks —
    # startup can take 3-10s instead of the normal ~0.4s. A 10s timeout gives
    # enough headroom without risking an infinite block.
    $null = $proc.WaitForExit(10000)
    $exitCode = $proc.ExitCode

    # Read stdout/stderr with a hard timeout — never block forever.
    # Task.WaitAll(..., ms) returns false if the timeout expires before all
    # tasks complete — in that case we return whatever was captured so far.
    # GetAwaiter().GetResult() on an incomplete task would block indefinitely,
    # so we only call it when IsCompleted is true.
    $null = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)
    $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
    $stderr = if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' }
    $proc.Dispose()

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $stdout.TrimEnd()
        Error    = $stderr.TrimEnd()
        TimedOut = $false
    }
}

function Get-ScriptIndex {
    # @() forces array serialisation even on an empty result — prevents $null instead of [].
    $list = if (Test-Path -LiteralPath $script:cfg.WebRoot -PathType Container) {
        Get-ChildItem -Path $script:cfg.WebRoot -Recurse -Filter '*.ps1' | ForEach-Object {
            '/' + $_.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
        }
    } else {
        @()
    }
    return @($list) | ConvertTo-Json -Compress -Depth 3
}

# ---------------------------------------------------------------------------
# Rate limiting — Fixed Window per client IP with penalty on violation.
#
# Returns PSCustomObject { Allowed [bool]; RetryAfterSec [int] }.
#
# Algorithm:
#   Each IP entry holds three fields:
#     Count       — atomic request counter for the current window ([ref] long)
#     WindowStart — UTC start of the current Fixed Window ([datetime])
#     PenaltyUntil — UTC time until which the IP is fully blocked ([datetime])
#
#   Per request:
#     1. PenaltyUntil set and not yet expired? → reject immediately, Retry-After = remaining penalty
#     2. Window expired (UtcNow >= WindowStart + RateLimitWindowSec)? → reset Count and WindowStart
#     3. Increment Count atomically via Interlocked::Increment
#     4. Count > RateLimitRequests? → set PenaltyUntil = UtcNow + RateLimitPenaltySec → reject
#     5. Otherwise → allow
#
#   Penalty starts on the FIRST rejected request and runs for RateLimitPenaltySec seconds
#   regardless of when in the window the limit was hit. Every subsequent request during
#   the penalty period receives a fresh Retry-After based on the remaining penalty time.
#
# Called from $requestHandler after the method check, before the auth check.
# Reading $script:cfg and $script:rateLimitTable relies on the script: scope
# injected in the RunspacePool Runspace — same pattern as Write-Log and Get-ScriptIndex.
# ---------------------------------------------------------------------------
function Test-RateLimit {
    param(
        [string] $ClientIP,
        [string] $Path
    )

    # Rate limiting disabled — 0 means no limit.
    if ($script:cfg.RateLimitRequests -le 0) {
        return [PSCustomObject]@{ Allowed = $true; RetryAfterSec = 0 }
    }

    # Exempt paths bypass rate limiting entirely.
    if ($script:cfg.RateLimitExemptPaths -contains $Path) {
        return [PSCustomObject]@{ Allowed = $true; RetryAfterSec = 0 }
    }

    # Retrieve or create entry for this IP.
    # GetOrAdd requires a direct value — a ScriptBlock is stored as-is, not invoked.
    # Two threads may create $newEntry simultaneously, but GetOrAdd guarantees only one
    # is stored; both callers receive the same winner object.
    $newEntry = [PSCustomObject]@{
        Count        = [ref] 0L
        WindowStart  = [datetime]::UtcNow
        PenaltyUntil = [datetime]::MinValue   # MinValue = no active penalty
    }
    $entry = $script:rateLimitTable.GetOrAdd($ClientIP, $newEntry)

    # --- Step 1: active penalty check ---
    # Read PenaltyUntil once to avoid a race between the comparison and the calculation.
    # Use Ticks arithmetic instead of operator (-) or .Subtract() — both fail to resolve
    # in ThreadJob runspace contexts on PS 7.x due to Value-Type method dispatch issues.
    # Ticks are a plain [long] — no operator or method lookup required.
    $penaltyUntil = $entry.PenaltyUntil
    $nowTicks     = [datetime]::UtcNow.Ticks
    if ($penaltyUntil.Ticks -gt $nowTicks) {
        $remainingSec  = [math]::Max(1, [math]::Ceiling(($penaltyUntil.Ticks - $nowTicks) / [timespan]::TicksPerSecond))
        return [PSCustomObject]@{ Allowed = $false; RetryAfterSec = [int]$remainingSec }
    }

    # --- Step 2: window reset if expired ---
    # Ticks arithmetic for the same reason as above.
    # Value types ([datetime]) on 64-bit .NET are read/written atomically for aligned fields —
    # safe on all supported PS7 platforms (x64 Windows).
    $elapsedSec = ($nowTicks - $entry.WindowStart.Ticks) / [timespan]::TicksPerSecond
    if ($elapsedSec -ge $script:cfg.RateLimitWindowSec) {
        $entry.WindowStart = [datetime]::UtcNow
        $null = [System.Threading.Interlocked]::Exchange($entry.Count, 0L)
    }

    # --- Step 3: increment atomically ---
    $count = [System.Threading.Interlocked]::Increment($entry.Count)

    # --- Step 4: limit exceeded → start penalty ---
    if ($count -gt $script:cfg.RateLimitRequests) {
        # Only set PenaltyUntil if it is not already active (avoids continuously pushing
        # the deadline forward when multiple threads hit the limit simultaneously).
        if ($entry.PenaltyUntil.Ticks -le $nowTicks) {
            $entry.PenaltyUntil = [datetime]::UtcNow.AddSeconds($script:cfg.RateLimitPenaltySec)
        }
        $remainingSec  = [math]::Max(1, [math]::Ceiling(($entry.PenaltyUntil.Ticks - [datetime]::UtcNow.Ticks) / [timespan]::TicksPerSecond))
        return [PSCustomObject]@{ Allowed = $false; RetryAfterSec = [int]$remainingSec }
    }

    # --- Step 5: allowed ---
    return [PSCustomObject]@{ Allowed = $true; RetryAfterSec = 0 }
}

# ---------------------------------------------------------------------------
# $shared: serialisable values passed to every runspace via -ArgumentList.
# Functions are exported as ScriptBlocks and injected via ${function:Name}.
#
# Live .NET objects (SemaphoreSlim, Mutex, Stopwatch, ConcurrentDictionary,
# [ref] counters) are NOT included here — they are injected directly into
# each runspace via InitialSessionState.Variables before the runspace opens.
# ---------------------------------------------------------------------------
$shared = @{
    Cfg              = $cfg
    FnWriteLog       = ${function:Write-Log}
    FnSendResp       = ${function:Send-Response}
    FnNewJson        = ${function:New-JsonResponse}
    FnGetParams      = ${function:Get-QueryParams}
    FnGetBodyParams  = ${function:Get-BodyParams}
    FnSavePostJson   = ${function:Save-PostJson}
    FnInvScript      = ${function:Invoke-Script}
    FnGetIndex       = ${function:Get-ScriptIndex}
    FnRateLimit      = ${function:Test-RateLimit}
    FnGetMime        = ${function:Get-MimeType}
    FnSendStatic     = ${function:Send-StaticFile}
}

# ---------------------------------------------------------------------------
# $requestHandler: complete request processing logic as a ScriptBlock.
# Executed per request in its own Runspace (via RunspacePool + PowerShell::Create).
# Live objects ($semaphore, $script:logMutex, etc.) are available directly —
# they were injected into the runspace via InitialSessionState.Variables.
# ---------------------------------------------------------------------------
$requestHandler = {
    param(
        [System.Net.HttpListenerContext] $context,
        [hashtable]                      $shared
    )

    # Inject functions and configuration from $shared into the local scope.
    # $script: scope makes them visible in all injected functions (Write-Log,
    # Get-ScriptIndex, Test-RateLimit).
    ${function:Write-Log}        = $shared.FnWriteLog
    ${function:Send-Response}    = $shared.FnSendResp
    ${function:New-JsonResponse} = $shared.FnNewJson
    ${function:Get-QueryParams}  = $shared.FnGetParams
    ${function:Get-BodyParams}   = $shared.FnGetBodyParams
    ${function:Save-PostJson}    = $shared.FnSavePostJson
    ${function:Invoke-Script}    = $shared.FnInvScript
    ${function:Get-ScriptIndex}  = $shared.FnGetIndex
    ${function:Test-RateLimit}   = $shared.FnRateLimit
    ${function:Get-MimeType}     = $shared.FnGetMime
    ${function:Send-StaticFile}  = $shared.FnSendStatic
    $script:cfg              = $shared.Cfg

    # Live .NET objects were injected via InitialSessionState.Variables — plain names.
    # Map them to $script: scope so injected functions (Write-Log, Test-RateLimit, etc.)
    # can access them via $script:logMutex / $script:rateLimitTable etc.
    $script:logMutex         = $logMutex
    $script:rateLimitTable   = $rateLimitTable
    $script:rateLimitedTotal = $rateLimitedTotal
    # $semaphore, $startTime, $requestsTotal are used directly (no $script: needed)

    try {
        $req  = $context.Request
        $resp = $context.Response

        # Stash Accept-Encoding in $script: scope so Send-Response can pick it up without
        # every call site having to forward an extra parameter — the value is per-request
        # and per-runspace, so $script:-scope is safe here.
        $script:acceptEncoding = $req.Headers['Accept-Encoding']
        if ($null -eq $script:acceptEncoding) { $script:acceptEncoding = '' }

        $clientIP    = $req.RemoteEndPoint.Address.ToString()
        $urlPath     = $req.Url.AbsolutePath
        $requestLine = '{0} {1}' -f $req.HttpMethod, $req.Url.PathAndQuery

        # Unique 8-character hex ID per request — correlates log entries to X-Request-Id response header.
        # Substring(0,8) of a GUID gives 32^8 combinations — sufficient for automation-scale traffic.
        $requestId = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # --------------------------------------------------------------
        # Only GET and POST are allowed — all other methods are rejected.
        # --------------------------------------------------------------
        if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'POST') {
            $body = New-JsonResponse -ExitCode 405 -Output '' -Err "Method not allowed: $($req.HttpMethod). Only GET and POST are supported."
            $resp.AddHeader('Allow', 'GET, POST')
            Send-Response -Response $resp -StatusCode 405 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # Rate limiting — Fixed Window per client IP.
        # Checked before auth so brute-force attempts on the API key are
        # also throttled. /health and other exempt paths are skipped inside
        # Test-RateLimit via RateLimitExemptPaths.
        # In 'queue' mode the thread sleeps in a loop until the window clears
        # or RateLimitQueueTimeoutSec elapses — the semaphore slot is held
        # during the entire wait, so the effective queue depth equals
        # MaxConcurrent. New arrivals beyond that receive HTTP 503 as usual.
        # --------------------------------------------------------------
        if ($script:cfg.RateLimitRequests -gt 0) {
            $rl = Test-RateLimit -ClientIP $clientIP -Path $urlPath

            if (-not $rl.Allowed -and $script:cfg.RateLimitMode -eq 'queue') {
                # Queue mode: poll until the window resets or timeout expires.
                # Use Ticks arithmetic — [datetime] comparison operators (op_LessThan) and
                # .AddSeconds() fail in RunspacePool Runspace contexts on PS 7.x.
                $queueDeadlineTicks = [datetime]::UtcNow.Ticks + ($script:cfg.RateLimitQueueTimeoutSec * [timespan]::TicksPerSecond)
                while (-not $rl.Allowed -and [datetime]::UtcNow.Ticks -lt $queueDeadlineTicks) {
                    Start-Sleep -Milliseconds 200
                    $rl = Test-RateLimit -ClientIP $clientIP -Path $urlPath
                }
            }

            if (-not $rl.Allowed) {
                $body = New-JsonResponse -ExitCode 429 -Output '' -Err 'Too many requests. Please slow down.'
                $resp.AddHeader('Retry-After', [string]$rl.RetryAfterSec)
                Send-Response -Response $resp -StatusCode 429 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'RATE LIMITED' -ExitCode '-' -RequestId $requestId
                $null = [System.Threading.Interlocked]::Increment($script:rateLimitedTotal)
                return
            }
        }

        # --------------------------------------------------------------
        # API key authentication
        # /health and /metrics are intentionally open — monitoring and metrics
        # endpoints must be reachable without credentials.
        # All other routes require the X-Api-Key header.
        # Same response for missing and incorrect key — no hint which case applies.
        # --------------------------------------------------------------
        if ($urlPath -ne '/health' -and $urlPath -ne '/metrics') {
            $providedKey = $req.Headers['X-Api-Key']
            if ($providedKey -ne $script:cfg.ApiKey) {
                $body = New-JsonResponse -ExitCode 401 -Output '' -Err 'Unauthorized.'
                Send-Response -Response $resp -StatusCode 401 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'UNAUTHORIZED' -ExitCode '-' -RequestId $requestId
                return
            }
        }

        # --------------------------------------------------------------
        # GET / -> script index
        # --------------------------------------------------------------
        if ($urlPath -eq '/') {
            $json = Get-ScriptIndex
            Send-Response -Response $resp -StatusCode 200 -Body $json -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'INDEX' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # GET /health -> health check (no webroot script)
        # Uptime as a human-readable string, requestsTotal counts script requests only.
        # --------------------------------------------------------------
        if ($urlPath -eq '/health') {
            $uptimeSec = [long] $startTime.Elapsed.TotalSeconds
            $h         = [int]($uptimeSec / 3600)
            $m         = [int](($uptimeSec % 3600) / 60)
            $s         = $uptimeSec % 60
            $uptimeStr = '{0}h {1}m {2}s' -f $h, $m, $s
            $total     = [System.Threading.Interlocked]::Read($requestsTotal)
            $body      = [ordered]@{
                status        = 'ok'
                uptime        = $uptimeStr
                requestsTotal = $total
            } | ConvertTo-Json -Compress
            Send-Response -Response $resp -StatusCode 200 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'HEALTH' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # GET /metrics -> server metrics (auth required)
        # rateLimitedTotal counts per-IP rate-limit rejections (HTTP 429 from
        # the Runspace) — global-throttle 429s (MinRequestIntervalSec, main
        # thread) are intentionally excluded, consistent with the no-logging
        # decision for burst-traffic main-thread rejections.
        # --------------------------------------------------------------
        if ($urlPath -eq '/metrics') {
            $uptimeSec   = [long] $startTime.Elapsed.TotalSeconds
            $h           = [int]($uptimeSec / 3600)
            $m           = [int](($uptimeSec % 3600) / 60)
            $s           = $uptimeSec % 60
            $uptimeStr   = '{0}h {1}m {2}s' -f $h, $m, $s
            $total       = [System.Threading.Interlocked]::Read($requestsTotal)
            $rateLimited = [System.Threading.Interlocked]::Read($script:rateLimitedTotal)
            $body        = [ordered]@{
                uptime           = $uptimeStr
                requestsTotal    = $total
                rateLimitedTotal = $rateLimited
            } | ConvertTo-Json -Compress
            Send-Response -Response $resp -StatusCode 200 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METRICS' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # Non-.ps1 path → static file branch (opt-in via StaticServingEnabled).
        # POST requests to non-.ps1 paths are always rejected — static content is
        # GET-only by design and POST would otherwise silently no-op.
        # When StaticServingEnabled is off, fall back to the legacy HTTP 400.
        # --------------------------------------------------------------
        if (-not $urlPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {

            if (-not $script:cfg.StaticServingEnabled) {
                $body = New-JsonResponse -ExitCode 400 -Output '' -Err "Only .ps1 files are allowed. Requested: $urlPath"
                Send-Response -Response $resp -StatusCode 400 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'BAD REQUEST' -ExitCode '-' -RequestId $requestId
                return
            }

            if ($req.HttpMethod -ne 'GET') {
                $body = New-JsonResponse -ExitCode 405 -Output '' -Err 'Static resources may only be requested with GET.'
                $resp.AddHeader('Allow', 'GET')
                Send-Response -Response $resp -StatusCode 405 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-' -RequestId $requestId
                return
            }

            # Path-traversal protection — identical pattern to the .ps1 branch below
            # but rooted at StaticRoot (which defaults to WebRoot).
            $staticRel  = $urlPath.TrimStart('/').Replace('/', '\')
            $staticFull = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.StaticRoot $staticRel))
            $rootFull   = [System.IO.Path]::GetFullPath($script:cfg.StaticRoot)
            $isInsideRoot = $staticFull -eq $rootFull -or
                            $staticFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $isInsideRoot) {
                $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Access denied.'
                Send-Response -Response $resp -StatusCode 403 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-' -RequestId $requestId
                return
            }

            # Directory request: try configured default documents (index.html, …) in order.
            # If none exist, fall through to a 404 — PR-9 (DirectoryBrowsing) will plug a
            # directory listing in here later when that feature is implemented.
            $isDir = Test-Path -LiteralPath $staticFull -PathType Container
            if ($isDir -or $urlPath.EndsWith('/')) {
                $resolvedDefault = $null
                foreach ($candidate in $script:cfg.DefaultDocuments) {
                    $probe = Join-Path $staticFull $candidate
                    if (Test-Path -LiteralPath $probe -PathType Leaf) { $resolvedDefault = $probe; break }
                }
                if ($null -eq $resolvedDefault) {
                    $body = New-JsonResponse -ExitCode 404 -Output '' -Err "No default document for: $urlPath"
                    Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                    Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                    return
                }
                $staticFull = $resolvedDefault
            } elseif (-not (Test-Path -LiteralPath $staticFull -PathType Leaf)) {
                $body = New-JsonResponse -ExitCode 404 -Output '' -Err "File not found: $urlPath"
                Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                return
            }

            $sr = Send-StaticFile -Request $req -Response $resp -FilePath $staticFull -RequestId $requestId
            $null = [System.Threading.Interlocked]::Increment($requestsTotal)
            Write-Log -ClientIP $clientIP -Request $requestLine -Status $sr.Reason -ExitCode "$($sr.StatusCode)" -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # Path traversal protection
        # Ensure the resolved path is inside WebRoot.
        # --------------------------------------------------------------
        $relativePath = $urlPath.TrimStart('/').Replace('/', '\')
        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.WebRoot $relativePath))
        $webrootFull  = [System.IO.Path]::GetFullPath($script:cfg.WebRoot)

        if (-not $resolvedPath.StartsWith($webrootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Access denied.'
            Send-Response -Response $resp -StatusCode 403 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # Script file must exist
        # --------------------------------------------------------------
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $body = New-JsonResponse -ExitCode 404 -Output '' -Err "Script not found: $urlPath"
            Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # Assemble parameters and execute the script.
        # GET:  query string parameters are passed as named -Key Value arguments.
        # POST: the JSON body is written to a file in PostJsonDir; the script
        #       receives the absolute file path via -JsonFilePath and reads/
        #       parses the JSON itself. No -Key Value pairs for POST — query
        #       string parameters at POST are rejected (HTTP 400) to enforce a
        #       single, unambiguous input channel.
        # Invoke-Script blocks until the script finishes or the timeout
        # (ScriptTimeoutSec) elapses — the client waits accordingly.
        # --------------------------------------------------------------
        if ($req.HttpMethod -eq 'POST') {
            # Reject query string parameters on POST — all input must be in the JSON body.
            $queryKeys = @($req.QueryString.AllKeys | Where-Object { $null -ne $_ -and $_ -ne '' })
            if ($queryKeys.Count -gt 0) {
                $body = New-JsonResponse -ExitCode 400 -Output '' -Err 'Query string parameters are not allowed on POST requests. Pass all input in the JSON body.'
                Send-Response -Response $resp -StatusCode 400 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'BAD REQUEST' -ExitCode '-' -RequestId $requestId
                return
            }

            $bodyResult = Get-BodyParams -Request $req
            if ($bodyResult.Error -ne 0) {
                $errMsg = switch ($bodyResult.Error) {
                    413     { 'Request body too large. Maximum size: {0} MB.' -f [math]::Round($script:cfg.MaxRequestBodyBytes / 1MB) }
                    415     { 'Content-Type must be application/json.' }
                    400     { 'Invalid JSON body.' }
                    default { 'Request error.' }
                }
                $body = New-JsonResponse -ExitCode $bodyResult.Error -Output '' -Err $errMsg
                Send-Response -Response $resp -StatusCode $bodyResult.Error -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status "HTTP $($bodyResult.Error)" -ExitCode '-' -RequestId $requestId
                return
            }

            # Write body to file — script receives path via -JsonFilePath.
            $jsonFilePath = Save-PostJson -RawJson $bodyResult.RawJson -RequestId $requestId
            $result = Invoke-Script -ScriptPath $resolvedPath -Params @{} -TimeoutSec $script:cfg.ScriptTimeoutSec -JsonFilePath $jsonFilePath
        } else {
            # GET: pass query string key/value pairs as named arguments.
            $scriptParams = Get-QueryParams -QueryString $req.QueryString
            $result = Invoke-Script -ScriptPath $resolvedPath -Params $scriptParams -TimeoutSec $script:cfg.ScriptTimeoutSec
        }

        # Script request completed — increment counter atomically (thread-safe).
        $null = [System.Threading.Interlocked]::Increment($requestsTotal)

        $httpStatus = if     ($result.TimedOut)       { 504 }
                      elseif ($result.ExitCode -eq 0) { 200 }
                      else                            { 500 }
        $body       = New-JsonResponse -ExitCode $result.ExitCode -Output $result.Output -Err $result.Error

        Send-Response -Response $resp -StatusCode $httpStatus -Body $body -RequestId $requestId

        $statusText = if     ($result.TimedOut)       { 'TIMEOUT' }
                      elseif ($result.ExitCode -eq 0) { 'OK' }
                      else                            { 'ERROR' }
        Write-Log -ClientIP $clientIP -Request $requestLine -Status $statusText -ExitCode "$($result.ExitCode)" -RequestId $requestId

    } catch {
        # Error in request processing — log and continue.
        # The process is NOT terminated.
        Write-Log -ClientIP '-' -Request '-' -Status "REQUEST-ERROR: $_" -ExitCode '1'
        try {
            $body = New-JsonResponse -ExitCode 500 -Output '' -Err "Internal error: $_"
            Send-Response -Response $context.Response -StatusCode 500 -Body $body
        } catch { }
    } finally {
        # Always release the semaphore slot — even on error or timeout.
        try { $null = $semaphore.Release() } catch { }
    }
}

# ---------------------------------------------------------------------------
# RunspacePool — replaces Start-ThreadJob entirely.
#
# Why not Start-ThreadJob:
#   Start-ThreadJob relies on Microsoft.PowerShell.ThreadJob's JobSourceAdapter.
#   Under sustained load in PS 7.6 the adapter becomes unregistered after a
#   varying number of calls — Start-ThreadJob then throws "not recognized" and
#   the server crashes. Root causes identified:
#     1. -ArgumentList serialises all arguments; .NET sync objects
#        (SemaphoreSlim, Mutex, ConcurrentDictionary, [ref]) become dead
#        Deserialized.* snapshots — semaphore.Release() silently fails.
#     2. $using: on ScriptBlock-variables (not literal ScriptBlocks) is
#        unreliable in PS 7.6 — variables resolve to $null.
#     3. The JobSourceAdapter itself degrades under repeated rapid invocations.
#
# RunspacePool + [PowerShell]::Create() + BeginInvoke() is the correct
# .NET-native solution:
#   - No JobSourceAdapter, no module dependency, no serialisation.
#   - Live objects injected directly via InitialSessionState.Variables —
#     every runspace gets the real reference, not a snapshot.
#   - BeginInvoke() is non-blocking; the main thread returns to GetContext()
#     immediately.
#   - Concurrency is bounded by the RunspacePool max size (= MaxConcurrent).
#     The SemaphoreSlim is still used for the 503 fast-path before BeginInvoke.
# ---------------------------------------------------------------------------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

# Inject live .NET objects as session variables — direct reference, no serialisation.
# Plain variable names only — no scope qualifiers in SessionStateVariableEntry names.
# The requestHandler maps them to $script: scope explicitly after startup.
foreach ($entry in @(
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('semaphore',        $semaphore,                  $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('startTime',        $startTime,                  $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('requestsTotal',    $script:requestsTotal,       $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('logMutex',         $script:logMutex,            $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('rateLimitTable',   $script:rateLimitTable,      $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('rateLimitedTotal', $script:rateLimitedTotal,    $null)
)) { $iss.Variables.Add($entry) }

# RunspacePool max = MaxConcurrent * 2.
# The SemaphoreSlim limits real parallelism to MaxConcurrent — the pool needs
# extra headroom because RunspacePool slots are only released when EndInvoke()+
# Dispose() is called in the main loop (next iteration). Between semaphore.Release()
# in the handler's finally and Dispose() in the main loop, the slot is still counted
# as occupied by the pool. Without extra headroom BeginInvoke() blocks the main
# thread when the pool is full — GetContext() is never called — the server hangs.
$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, ($cfg.MaxConcurrent * 2), $iss, $Host)
$runspacePool.Open()

# ---------------------------------------------------------------------------
# Main loop
# GetContext() blocks synchronously until a request arrives.
# A PowerShell instance is started per request via the RunspacePool —
# the main thread returns immediately to accept the next request.
# Shutdown: $listener.Stop() throws an exception in GetContext() — the
# IsListening check exits the loop cleanly.
# ---------------------------------------------------------------------------
try {
    Write-Output 'Web server running. Waiting for requests...'

    # Tracks active [PowerShell] instances so EndInvoke()+Dispose() can be called
    # once completed — prevents RunspacePool slot leaks.
    $psInstances = [System.Collections.Generic.List[object]]::new()

    # Tracks the Stopwatch timestamp of the last dispatched request.
    # Used for global throttling (MinRequestIntervalSec).
    # Initialized to 0 — first request is always allowed.
    $lastDispatchTick = 0L

    while ($listener.IsListening) {
        # Blocks until a request arrives or the listener is stopped.
        try {
            $context = $listener.GetContext()
        } catch {
            # Listener was stopped (shutdown) — exit the loop.
            if (-not $listener.IsListening) { break }
            continue
        }

        # Dispose completed [PowerShell] instances — releases RunspacePool slots.
        # Iterate backwards so RemoveAt() does not shift unvisited indices.
        for ($i = $psInstances.Count - 1; $i -ge 0; $i--) {
            $item = $psInstances[$i]
            if ($item.Handle.IsCompleted) {
                try { $item.Ps.EndInvoke($item.Handle) } catch { }
                try { $item.Ps.Dispose()               } catch { }
                $psInstances.RemoveAt($i)
            }
        }

        # ---------------------------------------------------------------------------
        # IP filter — checked in the main thread before the global throttle.
        # /health is always exempt so monitoring tools are never blocked.
        # BlockedIPs is checked first — an IP on both lists is always blocked.
        # AllowedIPs empty = all IPs pass; non-empty = only listed IPs pass.
        # Direct [System.IO.File]::AppendAllText for logging — Write-Log lives in
        # the Runspace scope and is not available in the main thread.
        # ---------------------------------------------------------------------------
        $reqUrlPath = $context.Request.Url.AbsolutePath
        if ($reqUrlPath -ne '/health' -and
            ($cfg.BlockedIPs.Count -gt 0 -or $cfg.AllowedIPs.Count -gt 0)) {

            $reqClientIP = $context.Request.RemoteEndPoint.Address.ToString()
            $ipDenied    = $false
            $ipStatus    = ''

            if ($cfg.BlockedIPs -contains $reqClientIP) {
                $ipDenied = $true
                $ipStatus = 'IP BLOCKED'
            } elseif ($cfg.AllowedIPs.Count -gt 0 -and $cfg.AllowedIPs -notcontains $reqClientIP) {
                $ipDenied = $true
                $ipStatus = 'IP NOT ALLOWED'
            }

            if ($ipDenied) {
                $ipReqId   = [Guid]::NewGuid().ToString('N').Substring(0, 8)
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
                    '{"exitCode":403,"output":"","error":"Access denied."}'
                )
                $resp403 = $context.Response
                $resp403.StatusCode      = 403
                $resp403.ContentType     = 'application/json; charset=utf-8'
                $resp403.ContentLength64 = $bodyBytes.Length
                $resp403.AddHeader('X-Request-Id', $ipReqId)
                try { $resp403.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
                try { $resp403.OutputStream.Close()                                  } catch { }
                $ipLogLine = '{0} | {1} | {2} | EXIT:{3} | {4} | {5}' -f `
                    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                    $reqClientIP.PadRight(15),
                    ('{0} {1}' -f $context.Request.HttpMethod, $context.Request.Url.PathAndQuery).PadRight(60),
                    '-   ',
                    $ipStatus.PadRight(13),
                    $ipReqId
                $ipLogFile = Join-Path $cfg.LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
                try {
                    if (-not (Test-Path -LiteralPath $cfg.LogDir -PathType Container)) {
                        $null = New-Item -ItemType Directory -Path $cfg.LogDir -Force
                    }
                    [System.IO.File]::AppendAllText($ipLogFile, $ipLogLine + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
                } catch { }
                Write-Output $ipLogLine
                continue
            }
        }

        # Global throttle — enforce MinRequestIntervalSec between dispatched requests.
        # Checked in the main thread before any runspace is started — RunspacePool stays cold.
        # /health and /metrics are always exempt so monitoring endpoints are never blocked.
        # Stopwatch::GetTimestamp() / Frequency gives elapsed seconds as a plain long division —
        # no [datetime] operators, no .NET method dispatch issues.
        # $lastDispatchTick is only updated when the request is allowed through —
        # a 429 response must not reset the clock (a burst would otherwise push the deadline
        # forward indefinitely and block all subsequent legitimate requests).
        if ($cfg.MinRequestIntervalSec -gt 0 -and
            $reqUrlPath -ne '/health' -and
            $reqUrlPath -ne '/metrics') {

            $nowTick    = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $elapsedSec = ($nowTick - $lastDispatchTick) / [System.Diagnostics.Stopwatch]::Frequency
            if ($elapsedSec -lt $cfg.MinRequestIntervalSec) {
                $retryAfter     = [math]::Ceiling($cfg.MinRequestIntervalSec - $elapsedSec)
                $throttleReqId  = [Guid]::NewGuid().ToString('N').Substring(0, 8)
                $bodyBytes      = [System.Text.Encoding]::UTF8.GetBytes(
                    '{"exitCode":429,"output":"","error":"Request rate too high. Maximum 1 request per second."}'
                )
                $resp429 = $context.Response
                $resp429.StatusCode      = 429
                $resp429.ContentType     = 'application/json; charset=utf-8'
                $resp429.ContentLength64 = $bodyBytes.Length
                $resp429.AddHeader('Retry-After', [string]$retryAfter)
                $resp429.AddHeader('X-Request-Id', $throttleReqId)
                try { $resp429.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
                try { $resp429.OutputStream.Close()                                  } catch { }
                continue
            }
            $lastDispatchTick = $nowTick
        }

        # Semaphore: check immediately without waiting (timeout 0ms).
        # Under overload, return 503 immediately — no runspace needed.
        if (-not $semaphore.Wait(0)) {
            $overloadReqId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
                '{"exitCode":503,"output":"","error":"Server busy. Please try again later."}'
            )
            $resp503 = $context.Response
            $resp503.StatusCode      = 503
            $resp503.ContentType     = 'application/json; charset=utf-8'
            $resp503.ContentLength64 = $bodyBytes.Length
            $resp503.AddHeader('X-Request-Id', $overloadReqId)
            try { $resp503.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
            try { $resp503.OutputStream.Close()                                  } catch { }
            continue
        }

        # Dispatch request to RunspacePool — non-blocking.
        # Semaphore is released inside $requestHandler's finally block.
        $ps     = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        $null   = $ps.AddScript($requestHandler).AddArgument($context).AddArgument($shared)
        $handle = $ps.BeginInvoke()
        $psInstances.Add([PSCustomObject]@{ Ps = $ps; Handle = $handle })
    }

} finally {
    # Always executed — regardless of normal exit, Ctrl+C, or crash.
    # Order is critical:
    #   1. Stop listener — interrupts running GetContext() immediately
    #   2. Wait 5s — gives running runspaces time to finish cleanly
    #   3. Release remaining resources
    # Every call is individually wrapped in try/catch — a degraded runspace
    # state during forced shutdown (e.g. taskkill, session end) must never
    # prevent the remaining cleanup steps from running.
    try { Write-StartupLog 'Shutdown initiated — waiting for in-flight requests (max. 5s)...' } catch { }
    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    try { Start-Sleep -Seconds 5                          } catch { }
    try { $listener.Close()                               } catch { }
    # Dispose any remaining tracked [PowerShell] instances.
    try {
        if ($null -ne $psInstances) {
            foreach ($item in $psInstances) {
                try { $item.Ps.EndInvoke($item.Handle) } catch { }
                try { $item.Ps.Dispose()               } catch { }
            }
        }
    } catch { }
    try { $runspacePool.Close()                           } catch { }
    try { $runspacePool.Dispose()                         } catch { }
    try { $semaphore.Dispose()                            } catch { }
    try { $script:logMutex.Dispose()                      } catch { }
    try { Write-StartupLog 'Web server stopped.'          } catch { }
    try { Write-Output 'Web server stopped.'              } catch { }
}
