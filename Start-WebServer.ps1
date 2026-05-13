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

.PARAMETER BaseDir
    Base directory for runtime artefacts (config.psd1, webroot, logs, postjson).
    Default: 'C:\posh'. Override for multi-instance or non-default deployments.

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
    [int]    $HttpsPort = 443,
    # Base directory for runtime artefacts: config.psd1, webroot, logs, postjson.
    # All derived $cfg paths (WebRoot, LogDir, PostJsonDir) default to subfolders
    # of this. Override to support multi-instance deployments (e.g. -BaseDir
    # 'D:\posh-staging') or non-default install locations.
    [string] $BaseDir   = 'C:\posh',
    # Path to the runtime config.psd1. Empty = '<BaseDir>\config.psd1'. The file
    # is mandatory at startup — generate it once via tools\Initialize-PoshConfig.ps1.
    [string] $ConfigFile = '',
    # Internal: dump the inline $cfg defaults (after derived-field fallbacks) as
    # JSON to stdout, then exit 0. Used by tools\Initialize-PoshConfig.ps1 to seed a
    # fresh config.psd1 without running the listener. Skips POSH_API_KEY and
    # external-config checks because the dump only consumes inline defaults.
    [switch] $DumpConfig,
    # Internal: dump the EFFECTIVE $cfg AFTER merging config.psd1 and re-
    # applying any explicit CLI overrides. Useful for debugging and for
    # automated tests of the merge precedence. Still requires config.psd1
    # because the merge depends on it; skips POSH_API_KEY only.
    [switch] $DumpEffectiveConfig
)

# ---------------------------------------------------------------------------
# Startup phase
# ---------------------------------------------------------------------------
# Order matters — each step builds on the previous and assumes the earlier
# checks have already failed-loudly when their precondition wasn't met:
#
#   1. -BaseDir resolution (now)
#   2. early startup-log path (immediately below)
#   3. PowerShell 7 runtime check       (lines 94-115)
#   4. POSH_API_KEY env-var check       (lines 117-145)
#   5. Basic-Auth env-var read          (lines 147-160)
#   6. $cfg literal materialisation     (lines ~175 onwards)
#   7. -DumpConfig fast-exit            (after $cfg + derived defaults)
#   8. config.psd1 load + merge         (mandatory, hard-exits)
#   9. CLI-explicit param re-apply      (overrides config.psd1)
#  10. Post-merge numeric/path checks
#  11. API-key BC merge                 (env-key into ApiKeys)
#  12. Set-CfgDerivedDefaults (2nd run) (after file merge)
#  13. -DumpEffectiveConfig fast-exit
#  14. Mutex / counter / cache init
#  15. Function definitions (Write-Log etc.)
#  16. Admin check (loopback bypass)
#  17. HTTPS netsh sslcert validation
#  18. Auth-mode credential validation
#  19. PHP-CGI binary validation
#  20. Prefixes shape + duplicate validation
#  21. Cross-field consistency block
#  22. Directory creation + log rotation
#  23. Listener start + main loop
#
# Any change to the order needs to consider: is the precondition for the
# next step still satisfied? Most fail-loudly checks call exit 1 so a
# misordered earlier step would simply not run.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Base path — defaults to 'C:\posh' but is overridable via -BaseDir. Defined
# before all checks so every early-exit path shares the same value. The
# config-merge step below preserves the resolved value in $cfg via the
# derived-default WebRoot/LogDir/PostJsonDir lookups.
# ---------------------------------------------------------------------------
$baseDir = $BaseDir

# Pre-cfg startup-log path. Used by every early-exit path (PS-7 check, API-key
# check, config-load error) that runs before Write-StartupLog is available.
# Same target as Write-StartupLog ($baseDir\logs\startup.log) so operators
# only need to look at one file.
$script:earlyStartupLog = Join-Path $baseDir 'logs\startup.log'

# ---------------------------------------------------------------------------
# PowerShell 7 — mandatory check
# Must run before $cfg and logging setup. Edition='Core' alone is not enough:
# PowerShell 6 also reports Core but lacks features posh relies on (Brotli
# stream, ConvertFrom-Json -AsHashtable, etc.). Pin the floor at major 7.
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | PowerShell 7 required. Running version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    try {
        $logDir = Split-Path -Parent $script:earlyStartupLog
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($script:earlyStartupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
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
if ([string]::IsNullOrWhiteSpace($apiKey) -and -not $DumpConfig -and -not $DumpEffectiveConfig) {
    $apiKeyReason = if ($null -eq $apiKey) {
        'not set'
    } elseif ($apiKey.Length -eq 0) {
        'set but empty'
    } else {
        'set but contains only whitespace'
    }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | ERROR: Environment variable POSH_API_KEY is $apiKeyReason. Server will not start."
    try {
        $logDir = Split-Path -Parent $script:earlyStartupLog
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($script:earlyStartupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output 'Solution: set POSH_API_KEY as a system environment variable and restart the server.'
    Write-Output "  [Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key', 'Machine')"
    exit 1
}

# ---------------------------------------------------------------------------
# Basic-Auth credentials (PR-4) — sourced from machine-scope env vars analogous
# to POSH_API_KEY. Read here BEFORE $cfg so values are available when the
# hashtable is materialised. Empty strings are fine; the startup validator
# below only complains when AuthMode requires Basic but the credentials are
# missing.
# ---------------------------------------------------------------------------
$basicUser = $env:POSH_BASIC_USER
$basicPass = $env:POSH_BASIC_PASS
if ($null -eq $basicUser) { $basicUser = '' }
if ($null -eq $basicPass) { $basicPass = '' }

# ---------------------------------------------------------------------------
# Configuration
# The prefix is no longer stored in $cfg — it is built dynamically from
# HttpPort/HttpsPort and added directly to the listener.
# HttpPort = 0 signals: HTTP disabled (only useful with HttpsEnabled).
#
# PowerShell evaluates this hashtable literal EAGERLY at parse-time of the
# enclosing scope. Every variable used inside the block — $HttpsEnabled,
# $HttpPort, $HttpsPort, $baseDir, $apiKey, $basicUser, $basicPass, plus
# $PID for PwshExe — must therefore be defined BEFORE the block runs.
# Reordering blocks here without minding that contract leaves silently
# empty $cfg fields (no error is raised — $null just lands in the value).
#
# Naming: in the main script scope, $cfg and $script:cfg refer to the same
# variable — PowerShell aliases them. The dual notation in the codebase is
# intentional: functions called from RunspacePool runspaces use $script:cfg
# (the runspace's own script scope, populated by the request handler), so
# function bodies prefer that form. The main thread's startup body uses the
# unprefixed $cfg for brevity. Don't `Remove-Variable -Scope Script cfg` —
# it would clear the alias too.
# ---------------------------------------------------------------------------
$cfg = @{
    HttpsEnabled        = $HttpsEnabled.IsPresent                    # HTTPS active?
    HttpPort            = $HttpPort                                  # HTTP port (0 = disabled)
    HttpsPort           = $HttpsPort                                 # HTTPS port (only relevant when HttpsEnabled)
    WebRoot             = Join-Path $baseDir 'webroot'
    LogDir              = Join-Path $baseDir 'logs'
    PwshExe             = (Get-Process -Id $PID).MainModule.FileName # pwsh.exe of the running process — no hardcoded path
    ApiKey              = $apiKey                                    # legacy single-key from $env:POSH_API_KEY — kept for BC; auto-merged into ApiKeys as 'default' when ApiKeys is empty
    ApiKeys             = [ordered]@{}                               # multi-key map: label → key. Populate via config.psd1: @{ ApiKeys = @{ 'ci' = 'k1'; 'mon' = 'k2' } }
    ScriptTimeoutSec         = 300    # 5 minutes — scripts running longer are terminated (HTTP 504)
    MaxConcurrent            = 10     # maximum parallel requests — excess requests receive HTTP 503
    LogRetentionDays         = 180    # date-stemmed request logs (YYYY-MM-DD.log / YYYY-MM-DDTHH.log) older than N days are deleted at startup; single-file logs (audit/slow/jobs/startup) are exempt — they have separate size-based rotation. 0 = disabled.
    PostJsonDir              = Join-Path $baseDir 'postjson' # directory where POST body JSON files are stored
    PostJsonRetentionDays    = 30     # POST JSON files older than N days are deleted at startup (0 = disabled)
    MaxRequestBodyBytes      = 20MB   # maximum POST body size in bytes — larger requests: HTTP 413
    RateLimitRequests        = 100    # maximum requests per IP per window — excess requests: HTTP 429 (0 = disabled)
    RateLimitWindowSec       = 600    # fixed window size in seconds (10 minutes)
    RateLimitPenaltySec      = 300    # penalty duration after first 429 in seconds (5 minutes)
    RateLimitMode            = 'reject' # 'reject' = immediate HTTP 429 | 'queue' = wait up to RateLimitQueueTimeoutSec
    RateLimitPerIdentity     = $false   # F4: key the rate-limit table by API-key label (when authenticated) instead of client IP. Anonymous/auth-exempt requests still keyed by IP.
    RateLimitQueueTimeoutSec = 10     # 'queue' mode only: seconds to wait before returning HTTP 429
    RateLimitExemptPaths     = @('/health', '/metrics', '/metrics-prom', '/openapi.json') # paths excluded from rate limiting — always an array
    MinRequestIntervalSec    = 1      # minimum seconds between dispatched requests, globally — 0 = disabled. GlobalThrottleExemptPaths bypass this.
    GlobalThrottleExemptPaths = @('/health', '/metrics', '/metrics-prom', '/openapi.json') # paths exempt from MinRequestIntervalSec — defaults to the monitoring/discovery routes
    AuthExemptPaths          = @('/health', '/metrics', '/metrics-prom', '/openapi.json') # paths that skip authentication entirely. Identity is logged as 'anonymous'.
    AllowedIPs               = @()    # IP allowlist — empty = all IPs allowed; non-empty = only listed IPs pass. IpFilterExemptPaths override this per path.
    BlockedIPs               = @()    # IP blocklist — always rejected before AllowedIPs check. IpFilterExemptPaths override this per path.
    IpFilterExemptPaths      = @('/health') # paths that bypass BlockedIPs / AllowedIPs. Default keeps /health reachable from external monitoring.
    GzipEnabled              = $true  # GZIP response compression — only applied when client sent Accept-Encoding: gzip AND body >= GzipMinBytes AND Content-Type matches GzipMimeTypes
    BrotliEnabled            = $true  # Brotli compression — preferred over GZIP when both client supports them. Reuses GzipMinBytes / GzipMaxBytes / GzipMimeTypes for eligibility.
    GzipMinBytes             = 1024   # responses smaller than this byte count are never compressed (compression overhead exceeds savings)
    GzipMaxBytes             = 10MB   # responses larger than this are streamed uncompressed instead of buffered in memory for gzip — guards against OOM on big text payloads
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
    LogMutexTimeoutMs        = 500     # max ms Write-Log / Write-AuditLog / Write-SlowLog wait for the log mutex; on timeout the line is dropped and posh_*_drops_total ticks. Raise (1000-5000) for high-contention deployments where dropping is worse than blocking briefly; lower (50-100) for latency-sensitive workloads
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
    SessionEnabled           = $false # auto-set a 'POSH-Session-Id' HttpOnly cookie when missing; cookie value is passed to webroot scripts via the POSH_COOKIES env var
    SessionCookieName        = 'POSH-Session-Id'
    CorsAllowedOrigins       = @()    # CORS: list of allowed Origin values, or @('*') for any origin; empty = CORS disabled (default)
    CorsAllowedMethods       = 'GET, POST, OPTIONS'
    CorsAllowedHeaders       = 'X-Api-Key, Content-Type, Authorization'
    CorsAllowCredentials     = $false # set Access-Control-Allow-Credentials: true when an Origin is allowed (incompatible with '*' wildcard per CORS spec)
    CorsMaxAgeSec            = 600    # value of the Access-Control-Max-Age header on preflight responses (how long the browser may cache the preflight result)
    AcceptedContentTypes     = @('application/json', 'application/x-www-form-urlencoded') # POST body content types that pass the Get-BodyParams gate
    AuthMode                 = 'ApiKey' # 'ApiKey' (default), 'Basic', or 'Both' — 'Both' accepts either the X-Api-Key header OR a valid Authorization: Basic header
    BasicAuthUser            = $basicUser # from $env:POSH_BASIC_USER — only validated at startup when AuthMode requires Basic
    BasicAuthPass            = $basicPass # from $env:POSH_BASIC_PASS — kept in process memory only, never written to disk
    BasicAuthRealm           = 'posh'  # value of the WWW-Authenticate realm parameter on 401 responses
    ExecutionMode            = 'Subprocess' # 'Subprocess' (default, reliable exit codes + timeout) or 'InProcess' (faster, no isolation, exit codes via exception only)
    InjectContextVars        = $false # in 'InProcess' mode, expose $PoSHQuery / $PoSHPost / $PoSHCookies / $PoSHHeaders to webroot scripts (legacy PoSH compat)
    ScriptExtensionMap       = @{      # supported webroot file extensions and their response Content-Type. Match is case-insensitive.
        '.ps1'   = ''                  # empty = use JSON envelope (existing behaviour) — server wraps stdout/stderr in { exitCode, output, error }
        '.psxml' = 'text/xml; charset=utf-8'           # raw stdout passed through as XML
        '.posh'  = 'text/html; charset=utf-8'          # raw stdout passed through as HTML
        '.psapi' = 'application/xml; charset=utf-8'    # raw stdout passed through as XML — legacy PoSH 'API' endpoint type
    }
    PhpCgiEnabled            = $false  # serve .php files via an external PHP CGI binary (path = PhpCgiPath). Off by default.
    PhpCgiPath               = ''      # absolute path to php-cgi.exe — required when PhpCgiEnabled = $true
    PhpCgiTimeoutSec         = 60      # max seconds a PHP-CGI process may run before it is killed and HTTP 504 is returned
    CustomErrorPages         = $false  # render <ErrorPagesRoot>/<code>.html instead of the JSON envelope for 4xx/5xx — only when client accepts text/html
    ErrorPagesRoot           = ''      # empty = '<WebRoot>\_error' — directory containing 401.html, 403.html, 404.html, etc.
    Prefixes                 = @()     # explicit HttpListener prefixes (e.g. @('http://api.example.com:80/', 'http://localhost:80/')). Empty = build from HttpPort/HttpsPort with '+' wildcard binding (existing behavior).
    BackgroundJobs           = @()     # array of @{ Path = '<absolute>'; IntervalSec = 300 } — each job runs in its own background runspace on the configured interval; output goes to '<LogDir>\jobs.log'
    JobsLogFile              = ''      # absolute path to the jobs log file; empty = '<LogDir>\jobs.log'
    DirectoryBrowsing        = $false  # render an HTML index listing when a static directory has no DefaultDocuments match. Requires StaticServingEnabled.
    DirectoryBrowsingHidden  = @('_error', '.git', '.gitignore') # entries hidden from the directory listing (case-insensitive match on file/folder name)
    AuditLogEnabled          = $false  # F5: write security-relevant events (AUTH_FAIL, IP_BLOCKED, RATE_LIMITED) as NDJSON to AuditLogFile
    AuditLogFile             = ''      # absolute path to audit.log; empty = '<LogDir>\audit.log'
    AuditLogMaxBytes         = 100MB   # at startup, audit.log files larger than this are rotated to audit.log.<yyyyMMdd-HHmmss>; 0 = disabled (unbounded growth)
    SlowLogMaxBytes          = 50MB    # at startup, slow.log files larger than this are rotated; 0 = disabled
    JobsLogMaxBytes          = 50MB    # at startup, jobs.log files larger than this are rotated; 0 = disabled
    SlowRequestThresholdMs   = 0       # F6: requests >= this many ms (after Invoke-Script returns) get an extra line in SlowLogFile. 0 = disabled.
    SlowLogFile              = ''      # absolute path to slow.log; empty = '<LogDir>\slow.log'
    IndexShowMetadata        = $true   # F7: GET / returns enriched objects with synopsis + parameters parsed from each script's AST. Set $false to revert to the flat path list.
    PromMetricsEnabled       = $true   # F8: expose GET /metrics-prom in Prometheus text-format. Same auth-exempt treatment as /metrics.
    PathPlaceholders         = $false  # F9: match webroot/users/[id].ps1 (Next.js-style) against /users/<anything>. Placeholders are injected as named -Key Value args.
    OpenApiEnabled           = $true   # F10: expose GET /openapi.json with an OpenAPI 3.1 spec auto-generated from webroot script metadata.
    OpenApiTitle             = 'posh'  # 'info.title' in the spec
    OpenApiVersion           = '1.0.0' # 'info.version' in the spec
}

# ---------------------------------------------------------------------------
# Derived-field fallbacks — keys whose default is computed from another $cfg
# value rather than being a literal. Extracted into a function so the
# -DumpConfig path can apply the same defaults without duplicating logic.
# ---------------------------------------------------------------------------
function Set-CfgDerivedDefaults {
    param([Parameter(Mandatory)] [hashtable] $Cfg)
    # IsNullOrWhiteSpace (rather than IsNullOrEmpty) so that an operator setting
    # ErrorPagesRoot = '   ' in config.psd1 doesn't sneak whitespace into the
    # derived path that Test-Path / Join-Path would then handle inconsistently.
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.ErrorPagesRoot)) { $Cfg.ErrorPagesRoot = Join-Path $Cfg.WebRoot '_error' }
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.JobsLogFile))    { $Cfg.JobsLogFile    = Join-Path $Cfg.LogDir 'jobs.log' }
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.AuditLogFile))   { $Cfg.AuditLogFile   = Join-Path $Cfg.LogDir 'audit.log' }
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.SlowLogFile))    { $Cfg.SlowLogFile    = Join-Path $Cfg.LogDir 'slow.log' }
    if ([string]::IsNullOrWhiteSpace([string]$Cfg.StaticRoot))     { $Cfg.StaticRoot     = $Cfg.WebRoot }
}

# ---------------------------------------------------------------------------
# Returns a shallow copy of $cfg with secret-bearing fields zeroed out, so
# dump-style outputs are safe to paste into bug reports / chats. The env-
# sourced credentials (ApiKey, BasicAuthUser, BasicAuthPass) are emptied
# unconditionally because they belong in environment variables, never on
# disk. ApiKeys values are replaced with a marker but the labels stay so
# operators can see WHICH keys exist without leaking the secret.
# ---------------------------------------------------------------------------
function Get-RedactedCfgCopy {
    param([Parameter(Mandatory)] [hashtable] $Cfg)
    $copy = @{}
    foreach ($k in $Cfg.Keys) { $copy[$k] = $Cfg[$k] }
    $copy.ApiKey        = ''
    $copy.BasicAuthUser = ''
    $copy.BasicAuthPass = ''
    if ($copy.ApiKeys -and $copy.ApiKeys.Count -gt 0) {
        $redactedKeys = [ordered]@{}
        foreach ($label in $copy.ApiKeys.Keys) { $redactedKeys[$label] = '***REDACTED***' }
        $copy.ApiKeys = $redactedKeys
    }
    return $copy
}

# ---------------------------------------------------------------------------
# -DumpConfig: emit the inline $cfg defaults (after derived-field fallbacks)
# as JSON and exit. tools\Initialize-PoshConfig.ps1 consumes this to seed a
# fresh config.psd1 without ever touching the listener. Secrets are stripped
# so the output is safe even if POSH_API_KEY happens to be set in the env.
# ---------------------------------------------------------------------------
if ($DumpConfig) {
    Set-CfgDerivedDefaults -Cfg $cfg
    Get-RedactedCfgCopy -Cfg $cfg | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# ---------------------------------------------------------------------------
# config.psd1 is mandatory at startup — generate it once via
# tools\Initialize-PoshConfig.ps1. The inline $cfg block above remains the
# upstream schema (and supplies fallbacks for keys missing from the file),
# but every install must own a personalised runtime config so changes are
# visible in `git diff`/the editor and not buried in script defaults.
# ---------------------------------------------------------------------------
$resolvedConfigFile = if (-not [string]::IsNullOrEmpty($ConfigFile)) { $ConfigFile } else { Join-Path $baseDir 'config.psd1' }
# Relative paths resolve against the current working directory, which under
# Scheduled Task is C:\Windows\System32 — not what an operator expects. Pin
# to an absolute path so error messages and downstream Import-PowerShellDataFile
# calls reference the file the operator actually meant.
if (-not [System.IO.Path]::IsPathRooted($resolvedConfigFile)) {
    $resolvedConfigFile = Join-Path (Get-Location).Path $resolvedConfigFile
}
if (-not (Test-Path -LiteralPath $resolvedConfigFile -PathType Leaf)) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | ERROR: config.psd1 not found at '$resolvedConfigFile'. Run tools\Initialize-PoshConfig.ps1 first."
    try {
        $logDir = Split-Path -Parent $script:earlyStartupLog
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($script:earlyStartupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output "ERROR: config.psd1 is required but was not found at: $resolvedConfigFile"
    Write-Output ''
    Write-Output 'Solution: generate it once from the inline defaults via:'
    Write-Output '  .\tools\Initialize-PoshConfig.ps1'
    Write-Output ''
    Write-Output 'Or pass an explicit path:'
    Write-Output "  .\Start-WebServer.ps1 -ConfigFile 'D:\posh\custom.psd1'"
    exit 1
}

# ---------------------------------------------------------------------------
# External configuration file (PSD1) — applied BEFORE derived-field fallbacks
# so values overridden in the file (e.g. WebRoot, LogDir) flow through into
# StaticRoot / ErrorPagesRoot / JobsLogFile defaults correctly.
#
# Import-PowerShellDataFile only parses static data — no script execution,
# safer than dot-sourcing or Invoke-Expression.
#
# A malformed psd1 hard-exits so misconfigurations surface immediately at
# startup instead of producing subtle later failures.
# ---------------------------------------------------------------------------
$external = $null
try {
    $external = Import-PowerShellDataFile -LiteralPath $resolvedConfigFile
} catch {
    # Surface the parser's position info ($_.InvocationInfo.PositionMessage when
    # set — multi-line, contains the offending line and a caret pointer) so
    # operators do not have to dig through the file by hand. Fall back to the
    # bare exception message when no position is available (e.g. file-not-
    # readable rather than parse error).
    $details = if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        $_.InvocationInfo.PositionMessage.Trim()
    } else {
        $_.Exception.Message
    }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | ERROR: External config '$resolvedConfigFile' could not be parsed: $($_.Exception.Message)"
    try {
        $logDir = Split-Path -Parent $script:earlyStartupLog
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($script:earlyStartupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
        if ($details -ne $_.Exception.Message) {
            [System.IO.File]::AppendAllText($script:earlyStartupLog, $details + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
        }
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output "ERROR: External config '$resolvedConfigFile' is not a valid PowerShell data file."
    Write-Output 'Inspect the file and ensure it contains only a single hashtable: @{ Key = Value; ... }'
    if ($details -ne $_.Exception.Message) {
        Write-Output ''
        Write-Output $details
    }
    exit 1
}
if ($null -ne $external) {
    # Snapshot the inline schema BEFORE the merge so typo detection has a
    # ground truth (operators love to type 'WebRroot' instead of 'WebRoot' —
    # without this check the typo would silently land in $cfg with no effect).
    $knownCfgKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $cfg.Keys) { $null = $knownCfgKeys.Add([string]$k) }

    $unknownKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $external.Keys) {
        if (-not $knownCfgKeys.Contains([string]$k)) { $unknownKeys.Add([string]$k) }
        $cfg[$k] = $external[$k]
    }
    # Stash the success line for Write-StartupLog further down (Write-StartupLog
    # is not defined yet at this point; we want this in startup.log, not just Write-Output).
    $script:externalConfigStartupNote = "External config loaded: $resolvedConfigFile ($($external.Count) key(s) overridden)"
    if ($unknownKeys.Count -gt 0) {
        $script:externalConfigUnknownKeysNote = "WARN: config.psd1 contains $($unknownKeys.Count) key(s) not present in the inline schema (likely typos): $($unknownKeys -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# CLI-explicit parameters win over config.psd1. Param defaults (80, 443,
# switch:off) DO NOT override file values — only values the caller put on
# the command line. $PSBoundParameters distinguishes "default" from
# "explicitly passed" without us tracking it ourselves.
#
# Without this re-apply step, `Start-WebServer.ps1 -HttpPort 8080` would
# silently fall back to whatever HttpPort is in config.psd1 because the
# foreach($external.Keys) above runs last. We discovered this the hard
# way: the Scheduled Task action carries -HttpPort 8080 but config.psd1
# still says 80 → server bound to 80.
# ---------------------------------------------------------------------------
if ($PSBoundParameters.ContainsKey('HttpPort'))     { $cfg.HttpPort     = $HttpPort }
if ($PSBoundParameters.ContainsKey('HttpsPort'))    { $cfg.HttpsPort    = $HttpsPort }
if ($PSBoundParameters.ContainsKey('HttpsEnabled')) { $cfg.HttpsEnabled = $HttpsEnabled.IsPresent }

# ---------------------------------------------------------------------------
# Post-merge port-range validation. The param() decorators only cover values
# arriving on the CLI. config.psd1 can set HttpPort to -1 or HttpsPort to 0
# and the merge would happily forward those into HttpListener, which then
# throws a confusing low-level error. Fail here with a clear message.
# ---------------------------------------------------------------------------
if ($cfg.HttpPort -lt 0 -or $cfg.HttpPort -gt 65535) {
    Write-Output "ERROR: HttpPort=$($cfg.HttpPort) out of range (0-65535). Fix config.psd1 or pass -HttpPort."
    exit 1
}
if ($cfg.HttpsPort -lt 1 -or $cfg.HttpsPort -gt 65535) {
    Write-Output "ERROR: HttpsPort=$($cfg.HttpsPort) out of range (1-65535). Fix config.psd1 or pass -HttpsPort."
    exit 1
}

# ---------------------------------------------------------------------------
# Post-merge numeric-range validation for the remaining $cfg numerics that
# config.psd1 could set to absurd values. The CLI-param decorators only
# guard the three port/switch fields handled above. Anything sourced from
# config.psd1 reaches the runtime unchecked, so a stray `-1` would surface
# as an opaque .NET error inside a runspace many requests in.
#
# Pairs: (Key, Minimum, Maximum) — Maximum = $null means unbounded above.
# Each pair must hold post-merge AND post-derived-defaults; placed here
# because Set-CfgDerivedDefaults runs further down and only touches paths.
# ---------------------------------------------------------------------------
$numericBounds = @(
    @{ Key = 'ScriptTimeoutSec';         Min = 1;    Max = 86400 }   # 1 s .. 24 h
    @{ Key = 'MaxConcurrent';            Min = 1;    Max = 10000 }   # >= 1 worker, soft upper to catch typos
    @{ Key = 'MaxRequestBodyBytes';      Min = 1KB;  Max = 1GB }     # 1 KB .. 1 GB
    @{ Key = 'LogRetentionDays';         Min = 0;    Max = 36500 }   # 0 = disabled, 100 years upper
    @{ Key = 'PostJsonRetentionDays';    Min = 0;    Max = 36500 }
    @{ Key = 'RateLimitRequests';        Min = 0;    Max = 1000000 } # 0 = disabled
    @{ Key = 'MinRequestIntervalSec';    Min = 0;    Max = 3600 }    # 0 = disabled, 1 h upper
    @{ Key = 'GzipMinBytes';             Min = 0;    Max = 1GB }
    @{ Key = 'GzipMaxBytes';             Min = 1;    Max = 1GB }
    @{ Key = 'PhpCgiTimeoutSec';         Min = 1;    Max = 86400 }
    @{ Key = 'CorsMaxAgeSec';            Min = 0;    Max = 86400 }
    @{ Key = 'SlowRequestThresholdMs';   Min = 0;    Max = 3600000 } # 0 = disabled, 1 h upper
    @{ Key = 'LogMutexTimeoutMs';        Min = 1;    Max = 60000 }   # 1 ms .. 60 s
    @{ Key = 'AuditLogMaxBytes';         Min = 0;    Max = 10GB }    # 0 = disabled, 10 GB upper
    @{ Key = 'SlowLogMaxBytes';          Min = 0;    Max = 10GB }
    @{ Key = 'JobsLogMaxBytes';          Min = 0;    Max = 10GB }
)
foreach ($b in $numericBounds) {
    $v = $cfg[$b.Key]
    if ($null -eq $v) { continue }            # missing key: derived-defaults pass / earlier check handles it
    $n = $null
    if (-not [long]::TryParse([string]$v, [ref]$n)) {
        Write-Output ("ERROR: {0} = '{1}' is not numeric. Fix config.psd1." -f $b.Key, $v)
        exit 1
    }
    if ($n -lt $b.Min -or $n -gt $b.Max) {
        Write-Output ("ERROR: {0} = {1} out of range ({2}..{3}). Fix config.psd1." -f $b.Key, $n, $b.Min, $b.Max)
        exit 1
    }
}

# ---------------------------------------------------------------------------
# API-Keys merge — the auth path resolves keys exclusively through ApiKeys.
# Two paths into the table:
#   (a) Operator-populated ApiKeys in config.psd1 (multi-key map).
#   (b) Legacy single key from $env:POSH_API_KEY ($cfg.ApiKey).
# Previously, populating (a) silently dropped (b), so anyone calling with the
# env-var key got 401 with no log trace. Both now coexist:
#   - When ApiKeys is empty, the env-var key seeds it under 'default' (BC).
#   - When ApiKeys is populated and the env-var key is not yet a value in the
#     table, it is added under 'env' (or 'env-<rand>' if that label is taken).
# Operator entries always win over BC seeding by label name, but the key
# value is never silently discarded.
# ---------------------------------------------------------------------------
if (-not $cfg.ApiKeys) {
    $cfg.ApiKeys = [ordered]@{}
}
if (-not [string]::IsNullOrEmpty($cfg.ApiKey)) {
    if ($cfg.ApiKeys.Count -eq 0) {
        $cfg.ApiKeys = [ordered]@{ 'default' = $cfg.ApiKey }
    } else {
        $envKeyAlreadyPresent = $false
        foreach ($existing in $cfg.ApiKeys.Values) {
            if ([string]$existing -ceq [string]$cfg.ApiKey) { $envKeyAlreadyPresent = $true; break }
        }
        if (-not $envKeyAlreadyPresent) {
            $envLabel = if ($cfg.ApiKeys.Contains('env')) { 'env-' + [guid]::NewGuid().ToString('N').Substring(0, 6) } else { 'env' }
            $cfg.ApiKeys[$envLabel] = $cfg.ApiKey
            $script:envKeyMergeNote = "Auto-added POSH_API_KEY to ApiKeys as label '$envLabel' (would otherwise be silently ignored)."
        }
    }
}

# Path inputs the derived-defaults pass depends on must be absolute, non-empty
# strings — Join-Path of '' or a relative path would silently fold the
# derived paths (ErrorPagesRoot, JobsLogFile, ...) into the current
# working directory, which under Scheduled Task is C:\Windows\System32.
foreach ($pathKey in @('WebRoot', 'LogDir', 'PostJsonDir')) {
    $v = [string]$cfg[$pathKey]
    if ([string]::IsNullOrWhiteSpace($v)) {
        Write-Output "ERROR: $pathKey is empty after config merge. Fix config.psd1."
        exit 1
    }
    if (-not [System.IO.Path]::IsPathRooted($v)) {
        Write-Output "ERROR: $pathKey = '$v' is not an absolute path. Use a rooted path (e.g. 'C:\posh\webroot') in config.psd1."
        exit 1
    }
}

# Apply derived-field fallbacks AFTER the external psd1 has merged so file
# overrides on WebRoot / LogDir flow into ErrorPagesRoot / JobsLogFile / etc.
Set-CfgDerivedDefaults -Cfg $cfg

# -DumpEffectiveConfig stops here, after config.psd1 + CLI overrides + the
# second derived-defaults pass. The output is what the listener WOULD use,
# minus the secret-bearing fields (see Get-RedactedCfgCopy).
if ($DumpEffectiveConfig) {
    Get-RedactedCfgCopy -Cfg $cfg | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# Runtime measurement from server start — used for health check uptime.
$startTime = [System.Diagnostics.Stopwatch]::StartNew()

# Counts completed script requests (exit-code-independent).
# [ref] + Interlocked::Increment guarantees thread safety without a mutex.
$script:requestsTotal = [ref] 0L

# Counts requests rejected by rate limiting (HTTP 429).
# Kept separate from requestsTotal — exposed as `rateLimitedTotal` in /metrics
# and as `posh_rate_limited_total` in /metrics-prom.
$script:rateLimitedTotal = [ref] 0L

# Rate-limit state — ConcurrentDictionary for lock-free access from RunspacePool Runspaces.
# Key: 'ip:<address>' or 'id:<api-key-label>' depending on RateLimitPerIdentity (F4).
# Value: PSCustomObject { Count [ref]; WindowStart [datetime]; PenaltyUntil [datetime] }.
$script:rateLimitTable = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# F7: per-script metadata cache populated lazily by Get-ScriptMetadata.
# Key: absolute script path. Value: PSCustomObject { Mtime [long]; Metadata [hashtable] }.
# Mtime-keyed invalidation re-parses a file when its LastWriteTimeUtc changes.
$script:metadataCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# F9: placeholder-route cache built by Get-RouteTable on first call. Key 'routes'
# (single-entry use of the dictionary so all runspaces share the same table).
# Invalidated when WebRoot's LastWriteTimeUtc changes — captures add/remove of
# top-level subdirectories. Deeper edits below the top level are intentionally
# NOT detected; restart needed to pick those up.
$script:routeCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# ---------------------------------------------------------------------------
# Logging subsystem at a glance
# ---------------------------------------------------------------------------
# Four writers, three mutexes:
#   Write-Log        -> <LogDir>\YYYY-MM-DD.log (or YYYY-MM-DDTHH)   [logMutex]
#   Write-AuditLog   -> <AuditLogFile>            (NDJSON, security)  [auditMutex]
#   Write-SlowLog    -> <SlowLogFile>             (pipe-delimited)    [logMutex]
#   Write-StartupLog -> <LogDir>\startup.log      (process-wide,      no mutex; called
#                                                  startup phase only)
#                                                  main thread + bg-runspaces share file
#                                                  but startup writes are serialised
#                                                  naturally by single-threaded flow)
#
# Mutex names are Global\PoshWebserverLog-<hash>, Global\PoshWebserverAudit-<hash>,
# and Global\PoshWebserverJobsLog-<hash>. The hash is sha1(LogDir).Substring(0,16)
# so two posh instances pointing at DIFFERENT directories never contend; two
# instances on the SAME directory share the same kernel object and serialise
# correctly. Without the hash, a second posh instance would unnecessarily
# block on a mutex protecting a log file it has no business writing to.
#
# Contention handling: WaitOne(LogMutexTimeoutMs) returns $false under load;
# rather than writing without the mutex (which interleaves bytes across
# runspaces) the writer DROPS the line and increments posh_log_drops_total /
# posh_audit_log_drops_total / posh_slow_log_drops_total — these are exposed
# in /metrics and /metrics-prom so operators can see logging starvation.
# ---------------------------------------------------------------------------

# Mutex serializes concurrent write access to the log file. Global\ makes
# the mutex unique across process boundaries. The mutex name is keyed on a
# hash of the LogDir path so two posh instances pointing at *different*
# directories don't contend with each other — but two instances pointing
# at the *same* LogDir still share the same Windows kernel object and
# correctly serialise.
$logDirKey = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($cfg.LogDir.ToLowerInvariant()))
).Replace('-', '').Substring(0, 16)
$script:logMutex = [System.Threading.Mutex]::new($false, "Global\PoshWebserverLog-$logDirKey")

# F5: separate Mutex for the audit log so AUTH_FAIL bursts cannot block normal
# request-log writes. Keyed the same way for the same multi-instance reason.
$script:auditMutex = [System.Threading.Mutex]::new($false, "Global\PoshWebserverAudit-$logDirKey")

# Drop counters for the three log writers. WaitOne(500) returns $false under
# heavy contention; rather than write without the mutex (which can interleave
# bytes across runspaces) we now skip the write and tick this counter. The
# value is exposed via /metrics so operators can spot logging starvation.
$script:logDropsTotal       = [ref] 0L
$script:auditLogDropsTotal  = [ref] 0L
$script:slowLogDropsTotal   = [ref] 0L

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
        # F3: API-key label / 'basic:<user>' / 'anonymous' / '-'. When unset (default $null),
        # the per-request $script:authIdentity stash is read so call sites need not change.
        [AllowNull()]
        [string] $Identity   = $null,
        # F6: per-request duration in milliseconds (0 when unset / not measured).
        [int]    $ElapsedMs  = 0,
        # W3C-only extras — ignored in Native format.
        [int]    $HttpStatus = 0,
        [string] $Method     = '',
        [string] $UriStem    = '',
        [string] $UriQuery   = '',
        [string] $UserAgent  = '-'
    )

    if ($null -eq $Identity) {
        try { $Identity = $script:authIdentity } catch { $Identity = '-' }
        if ([string]::IsNullOrEmpty($Identity)) { $Identity = '-' }
    }

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
            # "HTTP NNN" call sites (e.g. body-validation errors) parse the number out so
            # the W3C record reflects the actual code instead of folding everything to 400.
            $HttpStatus = switch -Regex ($Status) {
                '^OK$|^INDEX$|^HEALTH$|^METRICS$|^OPENAPI$|^METRICS-PROM$' { 200; break }
                '^METHOD NOT ALLOWED$'            { 405; break }
                '^UNAUTHORIZED$'                  { 401; break }
                '^FORBIDDEN$|^IP BLOCKED$|^IP NOT ALLOWED$' { 403; break }
                '^NOT FOUND$'                     { 404; break }
                '^RATE LIMITED$'                  { 429; break }
                '^TIMEOUT$'                       { 504; break }
                '^BAD REQUEST$'                   { 400; break }
                '^HTTP\s+(\d+)$'                  { [int]$Matches[1]; break }
                '^ERROR$|^REQUEST-ERROR|^SEND-ERROR' { 500; break }
                default                           { 0 }
            }
        }
        if ([string]::IsNullOrEmpty($UriStem))  { $UriStem  = '-' }
        if ([string]::IsNullOrEmpty($UriQuery)) { $UriQuery = '-' }
        if ([string]::IsNullOrEmpty($Method))   { $Method   = '-' }
        if ([string]::IsNullOrEmpty($UserAgent)){ $UserAgent = '-' }
        # W3C requires UA without spaces — collapse whitespace to '+'.
        $UserAgent = ($UserAgent -replace '\s+', '+')

        $timeTaken = if ($ElapsedMs -gt 0) { $ElapsedMs } else { '-' }
        $line = '{0} {1} {2} {3} {4} {5} {6} {7} {8} {9} {10}' -f `
            $now.ToString('yyyy-MM-dd'),
            $now.ToString('HH:mm:ss'),
            $ClientIP,
            $Method,
            $UriStem,
            $UriQuery,
            $HttpStatus,
            $UserAgent,
            $Identity,
            $timeTaken,
            $RequestId
    } else {
        $elapsedCol = if ($ElapsedMs -gt 0) { "${ElapsedMs}ms" } else { '-' }
        $line = '{0} | {1} | {2} | EXIT:{3} | {4} | {5} | {6} | {7}' -f `
            $now.ToString('yyyy-MM-dd HH:mm:ss'),
            $ClientIP.PadRight(15),
            $Request.PadRight(60),
            $ExitCode.PadRight(4),
            $Status.PadRight(13),
            $Identity.PadRight(16),
            $elapsedCol.PadRight(8),
            $RequestId
    }

    # Mutex prevents interleaved bytes from parallel writes across RunspacePool
    # Runspaces. WaitOne(500) returns $false on contention; when that happens
    # we DROP the log line (and tick the drop counter for /metrics) rather
    # than writing without the mutex — the latter mixes partial records across
    # runspaces and corrupts the log file.
    # Track $acquired: ReleaseMutex() must only be called when WaitOne() succeeded —
    # otherwise ApplicationException because the calling thread does not hold the mutex.
    $acquired   = $false
    $waitMs     = if ($script:cfg.LogMutexTimeoutMs -gt 0) { $script:cfg.LogMutexTimeoutMs } else { 500 }
    try {
        $acquired = $script:logMutex.WaitOne($waitMs)
        if ($acquired) {
            if ($format -eq 'IIS-W3C' -and -not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
                # Emit W3C header block once per file — the #Fields line is what tools like
                # logparser require to interpret subsequent records.
                $header = @(
                    '#Software: posh-webserver'
                    '#Version: 1.0'
                    ('#Date: {0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'))
                    '#Fields: date time c-ip cs-method cs-uri-stem cs-uri-query sc-status cs(User-Agent) cs(identity) time-taken x-request-id'
                ) -join [System.Environment]::NewLine
                Add-Content -LiteralPath $logFile -Value $header -Encoding UTF8
            }
            Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
        } else {
            [System.Threading.Interlocked]::Increment($script:logDropsTotal) | Out-Null
        }
    } catch { } finally {
        try { if ($acquired) { $script:logMutex.ReleaseMutex() } } catch { }
    }

    # Also to stdout — appears in Scheduled Task history output. Stdout is its
    # own (process-wide) lock so we emit it even when the file write was dropped.
    Write-Output $line
}

# ---------------------------------------------------------------------------
# Write-AuditLog (F5)
# Appends an NDJSON event to <cfg.AuditLogFile> when AuditLogEnabled = $true.
# One JSON object per line, ISO-8601 timestamp with offset, fixed schema:
#   { ts, event, identity, ip, path, detail }
#
# Only security-relevant events are logged (AUTH_FAIL, IP_BLOCKED, RATE_LIMITED) —
# the regular request log already covers successful auth.
#
# Serialised via a dedicated Mutex so AUTH_FAIL bursts cannot block normal
# request-log writes.
# ---------------------------------------------------------------------------
function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string] $EventName,
        [string] $Identity = '-',
        [string] $ClientIP = '-',
        [string] $Path     = '-',
        [string] $Detail   = ''
    )
    if (-not $script:cfg.AuditLogEnabled) { return }

    # v: schema version. Bumped on any breaking change to the field set;
    # additive fields keep v unchanged. Today (2026-05): v=1, fields ts,
    # event, identity, ip, path, detail. pid is additive — its absence
    # in older lines means "unknown process", not a v=0 record.
    # pid: PID of the posh process that emitted the line. Disambiguates
    # entries when several posh instances share an audit log target.
    $obj = [ordered]@{
        v        = 1
        ts       = (Get-Date).ToString('o')
        pid      = $PID
        event    = $EventName
        identity = $Identity
        ip       = $ClientIP
        path     = $Path
        detail   = $Detail
    }
    $line = $obj | ConvertTo-Json -Compress -Depth 3

    $acquired = $false
    $waitMs   = if ($script:cfg.LogMutexTimeoutMs -gt 0) { $script:cfg.LogMutexTimeoutMs } else { 500 }
    try {
        $acquired = $script:auditMutex.WaitOne($waitMs)
        if ($acquired) {
            Add-Content -LiteralPath $script:cfg.AuditLogFile -Value $line -Encoding UTF8
        } else {
            [System.Threading.Interlocked]::Increment($script:auditLogDropsTotal) | Out-Null
        }
    } catch { } finally {
        try { if ($acquired) { $script:auditMutex.ReleaseMutex() } } catch { }
    }
}

# ---------------------------------------------------------------------------
# Write-SlowLog (F6)
# Appends a pipe-delimited line to <cfg.SlowLogFile> when a request exceeded
# $cfg.SlowRequestThresholdMs. Rare event, so the existing request-log Mutex
# is reused (no dedicated mutex needed). Caller passes the already-measured
# $ElapsedMs so we do not start a second stopwatch here.
# ---------------------------------------------------------------------------
function Write-SlowLog {
    param(
        [int]    $ElapsedMs,
        [string] $ClientIP   = '-',
        [string] $Identity   = '-',
        [string] $Request    = '-',
        [string] $ExitCode   = '-',
        [string] $RequestId  = '-'
    )
    if ($script:cfg.SlowRequestThresholdMs -le 0) { return }
    if ($ElapsedMs -lt $script:cfg.SlowRequestThresholdMs) { return }

    if ([string]::IsNullOrEmpty($Identity)) { $Identity = '-' }
    $line = '{0} | {1}ms | {2} | identity={3} | {4} | EXIT:{5} | {6}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $ElapsedMs,
        $ClientIP,
        $Identity,
        $Request,
        $ExitCode,
        $RequestId

    $acquired = $false
    $waitMs   = if ($script:cfg.LogMutexTimeoutMs -gt 0) { $script:cfg.LogMutexTimeoutMs } else { 500 }
    try {
        $acquired = $script:logMutex.WaitOne($waitMs)
        if ($acquired) {
            Add-Content -LiteralPath $script:cfg.SlowLogFile -Value $line -Encoding UTF8
        } else {
            [System.Threading.Interlocked]::Increment($script:slowLogDropsTotal) | Out-Null
        }
    } catch { } finally {
        try { if ($acquired) { $script:logMutex.ReleaseMutex() } } catch { }
    }
}

# Startup events (before the listener) are written to a separate startup.log.
function Write-StartupLog {
    param(
        [string] $Message,
        # INFO is the default for legacy callers. New code can pass WARN/ERROR
        # explicitly; if the message itself starts with 'ERROR:' or 'WARN:' the
        # severity is auto-promoted so existing call sites get correct tagging
        # without a per-site edit.
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Severity = 'INFO'
    )

    if ($Severity -eq 'INFO') {
        if ($Message -match '^\s*ERROR\b\s*:?\s*(.*)') {
            $Severity = 'ERROR'
            # Strip the legacy "ERROR: " prefix so the rendered line is "STARTUP | ERROR | msg",
            # not the duplicate "STARTUP | ERROR | ERROR: msg" callers would otherwise produce.
            if ($Matches[1]) { $Message = $Matches[1] }
        } elseif ($Message -match '^\s*WARN\b\s*:?\s*(.*)') {
            $Severity = 'WARN'
            if ($Matches[1]) { $Message = $Matches[1] }
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp | STARTUP | $Severity | $Message"

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

    # Continuously-appended single-file logs (audit/slow/jobs/startup) must be
    # exempt from date-based retention — deleting them mid-life would drop
    # audit-trail data the operator expects to keep around. Only date-stemmed
    # request logs (YYYY-MM-DD.log / YYYY-MM-DDTHH.log) are retention targets.
    $stemPattern = '^\d{4}-\d{2}-\d{2}(T\d{2})?$'

    Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $stemPattern -and $_.LastWriteTime -lt $cutoff } |
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

    # Restrict hashing to the date-stemmed request logs only. audit.log /
    # slow.log / startup.log / jobs.log are continuously appended single
    # files; hashing them produces an integrity tag that goes stale on the
    # very next write. Match either YYYY-MM-DD or YYYY-MM-DDTHH stems.
    $stemPattern = '^\d{4}-\d{2}-\d{2}(T\d{2})?$'

    Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $stemPattern -and $_.BaseName -ne $currentStem } |
        ForEach-Object {
            # Capture name/fullname before try{} so the catch block can reference
            # them — inside catch, $_ rebinds to the ErrorRecord.
            $fileName = $_.Name
            $fileFull = $_.FullName
            $hashFile = $fileFull + '.md5'
            if (Test-Path -LiteralPath $hashFile -PathType Leaf) { return }
            try {
                # Get-FileHash is the canonical way; .NET MD5 wrapper avoids spawning Format-* pipelines.
                $hash = (Get-FileHash -LiteralPath $fileFull -Algorithm MD5).Hash.ToLowerInvariant()
                # Format mirrors `md5sum` so the file is consumable by standard audit tools.
                $line = '{0}  {1}' -f $hash, $fileName
                [System.IO.File]::WriteAllText($hashFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
                $created++
            } catch {
                # Surface the failure so the operator can investigate (locked file, perms, ...)
                # instead of wondering why a .md5 was silently missing.
                Write-StartupLog ("WARN: log integrity hash failed for '{0}': {1}" -f $fileName, $_.Exception.Message)
            }
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
        [int] $WindowSec
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
# Admin check (step 16 in the startup-phase ladder near the top of the file).
# HttpListener needs admin privileges to bind '+' / '*' / non-loopback IPs.
# Loopback-only prefixes (127.0.0.1 / [::1] / localhost) work without admin —
# when the operator has narrowed Prefixes to those, skip the check so dev/test
# workflows don't require an elevated shell.
# ---------------------------------------------------------------------------
$loopbackOnly = $false
if ($cfg.Prefixes -is [System.Collections.IList] -and $cfg.Prefixes.Count -gt 0) {
    $loopbackOnly = $true
    # The regex matches the three forms HttpListener recognises for loopback:
    # 'localhost', '127.0.0.1' (IPv4), and '[::1]' (bracketed IPv6 literal).
    # Anything else — wildcards '+'/'*', external IPs, FQDNs — requires admin.
    foreach ($p in $cfg.Prefixes) {
        if ([string]$p -notmatch '^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?/') {
            $loopbackOnly = $false
            break
        }
    }
}
if (-not $loopbackOnly) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-StartupLog 'ERROR: Not running as Administrator. Port binding requires admin privileges.'
        Write-Output ''
        Write-Output 'ERROR: This script must be run as Administrator.'
        Write-Output 'Solution: open pwsh.exe as Administrator and run again.'
        Write-Output '   (or restrict Prefixes to loopback-only to skip this check)'
        exit 1
    }
} else {
    Write-StartupLog "Admin check skipped: all Prefixes bind to loopback only ($($cfg.Prefixes -join ', '))."
}

# ---------------------------------------------------------------------------
# HTTPS validation
# Check whether a netsh sslcert binding exists for the configured HTTPS port
# before starting the listener. Missing binding: hard exit with exit 1.
# Silent fallback to HTTP would be dangerous — unencrypted communication
# would occur without notice.
# ---------------------------------------------------------------------------

# Surface the external-config-loaded message now that Write-StartupLog is available.
if (-not [string]::IsNullOrEmpty($script:externalConfigStartupNote)) {
    Write-StartupLog $script:externalConfigStartupNote
}
if (-not [string]::IsNullOrEmpty($script:externalConfigUnknownKeysNote)) {
    Write-StartupLog $script:externalConfigUnknownKeysNote
}
if (-not [string]::IsNullOrEmpty($script:envKeyMergeNote)) {
    Write-StartupLog $script:envKeyMergeNote
}

if ($cfg.HttpsEnabled) {
    # Try the IPv4 binding form first, then the IPv6 form. The combined view
    # has both bindings, but using the per-IP form keeps the diagnostic
    # message clear about which address the cert is bound to.
    $netshOut = netsh http show sslcert "ipport=0.0.0.0:$($cfg.HttpsPort)" 2>&1
    $bindingOk = ($LASTEXITCODE -eq 0) -and (($netshOut -join '') -match 'IP:Port')
    if (-not $bindingOk) {
        $netshOut6 = netsh http show sslcert "ipport=[::]:$($cfg.HttpsPort)" 2>&1
        if (($LASTEXITCODE -eq 0) -and (($netshOut6 -join '') -match 'IP:Port')) {
            $bindingOk = $true
            $netshOut  = $netshOut6
        }
    }
    $netshLine = ($netshOut | Out-String).Trim()
    if (-not $bindingOk) {
        Write-StartupLog "ERROR: No netsh sslcert binding found for port $($cfg.HttpsPort)."
        Write-StartupLog 'Solution: run Register-ScheduledTask.ps1 again and configure HTTPS.'
        if (-not [string]::IsNullOrWhiteSpace($netshLine)) {
            Write-StartupLog "netsh output (for diagnostics): $netshLine"
        }
        Write-Output ''
        Write-Output "ERROR: HTTPS configured but no certificate binding found for port $($cfg.HttpsPort)."
        Write-Output "Check: netsh http show sslcert ipport=0.0.0.0:$($cfg.HttpsPort)"
        Write-Output 'Solution: run Register-ScheduledTask.ps1 again.'
        if (-not [string]::IsNullOrWhiteSpace($netshLine)) {
            Write-Output ''
            Write-Output '--- netsh output ---'
            Write-Output $netshLine
        }
        exit 1
    }
    Write-StartupLog "HTTPS validation OK: netsh sslcert binding found for port $($cfg.HttpsPort)."
}

# ---------------------------------------------------------------------------
# Auth-mode validation — Basic / Both require POSH_BASIC_USER + POSH_BASIC_PASS.
# Both additionally requires ApiKeys to have at least one entry (without keys,
# 'Both' degrades to plain Basic and the mode label misleads operators).
# ApiKey / Both require ApiKeys non-empty (BC fallback from POSH_API_KEY makes
# this trivially satisfied when the env var is set).
# ---------------------------------------------------------------------------
if ($cfg.AuthMode -ne 'ApiKey') {
    # IsNullOrWhiteSpace, not IsNullOrEmpty — a whitespace-only env var ' ' would
    # otherwise pass this gate and then never match an incoming Basic header,
    # locking everyone out of an "authenticated" server without any error.
    if ([string]::IsNullOrWhiteSpace($cfg.BasicAuthUser) -or [string]::IsNullOrWhiteSpace($cfg.BasicAuthPass)) {
        Write-StartupLog ("ERROR: AuthMode = '{0}' requires POSH_BASIC_USER and POSH_BASIC_PASS environment variables (non-empty, non-whitespace)." -f $cfg.AuthMode)
        Write-Output ''
        Write-Output ("ERROR: AuthMode = '{0}' but Basic-Auth credentials are missing or whitespace-only." -f $cfg.AuthMode)
        Write-Output 'Solution: set both environment variables as Machine-scope and restart the server:'
        Write-Output "  [Environment]::SetEnvironmentVariable('POSH_BASIC_USER', 'username', 'Machine')"
        Write-Output "  [Environment]::SetEnvironmentVariable('POSH_BASIC_PASS', 'password', 'Machine')"
        exit 1
    }
    Write-StartupLog "Auth validation OK: AuthMode = '$($cfg.AuthMode)', Basic credentials present."
}
if ($cfg.AuthMode -in @('ApiKey', 'Both')) {
    if (-not $cfg.ApiKeys -or $cfg.ApiKeys.Count -eq 0) {
        Write-StartupLog ("ERROR: AuthMode = '{0}' requires at least one ApiKeys entry (or POSH_API_KEY env var). None found." -f $cfg.AuthMode)
        Write-Output ''
        Write-Output ("ERROR: AuthMode = '{0}' but ApiKeys is empty and POSH_API_KEY is not set." -f $cfg.AuthMode)
        Write-Output 'Solution: set POSH_API_KEY or populate ApiKeys = @{ ''label'' = ''key''; ... } in config.psd1.'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# PwshExe sanity — defaults to the currently running pwsh.exe (auto-derived
# from $PID), so a normal startup never trips this check. config.psd1 can
# override the value; warn loudly if the override is no longer valid or
# accidentally points at Windows PowerShell (which lacks PS-7 features).
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($cfg.PwshExe)) {
    if (-not (Test-Path -LiteralPath $cfg.PwshExe -PathType Leaf)) {
        Write-StartupLog "ERROR: PwshExe = '$($cfg.PwshExe)' does not exist. Subprocess execution would fail at runtime."
        Write-Output ''
        Write-Output "ERROR: PwshExe = '$($cfg.PwshExe)' does not exist."
        Write-Output 'Solution: remove the override from config.psd1 (the script auto-derives the running pwsh) or fix the path.'
        exit 1
    }
    $pwshLeaf = (Split-Path -Leaf $cfg.PwshExe).ToLowerInvariant()
    if ($pwshLeaf -ne 'pwsh.exe' -and $pwshLeaf -ne 'pwsh') {
        Write-StartupLog "WARN: PwshExe = '$($cfg.PwshExe)' does not look like pwsh ('$pwshLeaf'). Subprocess scripts may behave unexpectedly under Windows PowerShell."
    }
}

# ---------------------------------------------------------------------------
# PHP-CGI validation — when enabled, the binary must exist on disk.
# ---------------------------------------------------------------------------
if ($cfg.PhpCgiEnabled) {
    if ([string]::IsNullOrWhiteSpace($cfg.PhpCgiPath) -or -not (Test-Path -LiteralPath $cfg.PhpCgiPath -PathType Leaf)) {
        Write-StartupLog "ERROR: PhpCgiEnabled = `$true but PhpCgiPath does not point at an existing file: '$($cfg.PhpCgiPath)'."
        Write-Output ''
        Write-Output 'ERROR: PHP-CGI enabled but php-cgi.exe was not found.'
        Write-Output "Set `$cfg.PhpCgiPath in Start-WebServer.ps1 to an absolute path of php-cgi.exe."
        exit 1
    }
    Write-StartupLog "PHP-CGI validation OK: PhpCgiPath = '$($cfg.PhpCgiPath)'."
}

# ---------------------------------------------------------------------------
# Prefixes validation — HttpListener requires each prefix to end with '/'.
# Catch the obvious misconfiguration early with a clear message instead of
# letting Listener.Start() throw an obscure ArgumentException later.
# ---------------------------------------------------------------------------
if ($cfg.Prefixes -and $cfg.Prefixes.Count -gt 0) {
    $seenPrefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $cfg.Prefixes) {
        if ([string]::IsNullOrEmpty($p) -or -not $p.EndsWith('/')) {
            Write-StartupLog "ERROR: Prefix '$p' is missing the trailing '/' required by HttpListener."
            Write-Output ''
            Write-Output "ERROR: \$cfg.Prefixes entry '$p' must end with '/'."
            Write-Output 'Example: @(''http://api.internal.example.com:443/'')'
            exit 1
        }
        if (-not ($p -match '^https?://')) {
            Write-StartupLog "ERROR: Prefix '$p' must use the http:// or https:// scheme."
            Write-Output ''
            Write-Output "ERROR: \$cfg.Prefixes entry '$p' must start with 'http://' or 'https://'."
            exit 1
        }
        # Duplicate prefixes make HttpListener throw an opaque "Prefix has
        # already been added" exception at Start() — catch it here.
        if (-not $seenPrefixes.Add($p)) {
            Write-StartupLog "ERROR: Prefix '$p' is listed more than once in `$cfg.Prefixes."
            Write-Output ''
            Write-Output "ERROR: Duplicate prefix '$p'. HttpListener requires each prefix to appear exactly once."
            exit 1
        }
    }
    Write-StartupLog ("Prefixes validation OK: {0} explicit prefix(es) configured." -f $cfg.Prefixes.Count)
}

# ---------------------------------------------------------------------------
# Static-serving + error-pages soft warnings — non-existent directories are
# not fatal (the runtime falls back gracefully), but operators usually want
# to know that they pointed a feature at a missing path.
# ---------------------------------------------------------------------------
if ($cfg.StaticServingEnabled -and -not (Test-Path -LiteralPath $cfg.StaticRoot -PathType Container)) {
    Write-StartupLog "WARN: StaticServingEnabled = `$true but StaticRoot does not exist: '$($cfg.StaticRoot)'. Static requests will return 404 until the directory is created."
}
if ($cfg.CustomErrorPages -and -not (Test-Path -LiteralPath $cfg.ErrorPagesRoot -PathType Container)) {
    Write-StartupLog "WARN: CustomErrorPages = `$true but ErrorPagesRoot does not exist: '$($cfg.ErrorPagesRoot)'. Error responses fall back to the JSON envelope."
}

# ---------------------------------------------------------------------------
# Cross-field consistency validation. Catches misconfigurations that today
# silently degrade a feature (no error, just doesn't work). Fatal checks
# (exit 1) are reserved for operator mistakes that an admin must know about
# at startup; soft WARNs surface less-critical typos that would otherwise
# produce a working-but-unintended server.
#
# What lives here (in dispatch order):
#   1. Enum allow-lists       — AuthMode, ExecutionMode, RateLimitMode,
#                                LogSchedule, LogFormat
#   2. Sub-feature gates      — DirectoryBrowsing/StaticServing,
#                                SessionEnabled/SessionCookieName,
#                                BasicAuthRealm non-empty,
#                                CORS '*' + AllowCredentials
#   3. Numeric ranges (post-  — RateLimitWindowSec, RateLimitQueueTimeoutSec,
#      merge)                   GzipMinBytes vs GzipMaxBytes
#   4. ApiKeys hygiene        — no empty values
#   5. Exempt path arrays     — leading '/', non-empty
#   6. BlockedIPs/AllowedIPs  — regex/CIDR/IP grammar
#   7. MimeTypeMap /          — keys start with '.', lowercase; values
#      ScriptExtensionMap       look like Content-Types
#   8. Content-Type lists     — GzipMimeTypes, AcceptedContentTypes,
#                                BlockedMimeTypes — entries contain '/'
#
# Validations that depend on path inputs and therefore run BEFORE the
# derived-defaults pass (further up the file): WebRoot / LogDir /
# PostJsonDir rootedness, port-range, post-merge numeric bounds, unknown-
# key typo detection.
#
# Runtime cousins of these checks live in /metrics (posh_log_drops_total,
# posh_rate_limit_table_size, ...). Use that endpoint to watch for
# operational issues the startup-time checks can't catch.
# ---------------------------------------------------------------------------

# Whitelist-style enum validation — invalid values otherwise fall through to
# the default branch of switch/if-elseif chains with no warning. Driven by a
# single table so adding a new enum-style config key is a one-liner.
$enumBounds = @(
    @{ Key = 'AuthMode';      Valid = @('ApiKey', 'Basic', 'Both') }
    @{ Key = 'ExecutionMode'; Valid = @('Subprocess', 'InProcess') }
    @{ Key = 'RateLimitMode'; Valid = @('reject', 'queue') }
    @{ Key = 'LogSchedule';   Valid = @('Daily', 'Hourly') }
    @{ Key = 'LogFormat';     Valid = @('Native', 'IIS-W3C') }
)
foreach ($e in $enumBounds) {
    $current = $cfg[$e.Key]
    if ($e.Valid -notcontains $current) {
        $allowed = $e.Valid -join ', '
        Write-StartupLog ("ERROR: {0} = '{1}' is invalid. Allowed: {2}." -f $e.Key, $current, $allowed)
        Write-Output ''
        Write-Output ("ERROR: {0} = '{1}' — must be one of: {2}." -f $e.Key, $current, $allowed)
        exit 1
    }
}

# DirectoryBrowsing is a sub-feature of StaticServing — without static serving
# the directory-listing renderer is never reached, so the flag is a silent no-op.
if ($cfg.DirectoryBrowsing -and -not $cfg.StaticServingEnabled) {
    Write-StartupLog 'WARN: DirectoryBrowsing = $true has no effect while StaticServingEnabled = $false. Enable StaticServing or set DirectoryBrowsing = $false to silence this warning.'
}

# SessionEnabled with an empty cookie name silently fails: the server would
# emit a Set-Cookie header without a name, which browsers ignore. Catch it.
if ($cfg.SessionEnabled -and [string]::IsNullOrWhiteSpace([string]$cfg.SessionCookieName)) {
    Write-StartupLog 'ERROR: SessionEnabled = $true but SessionCookieName is empty. Sessions would never be issued.'
    Write-Output ''
    Write-Output 'ERROR: SessionEnabled requires a non-empty SessionCookieName.'
    exit 1
}

# BasicAuthRealm is sent verbatim in the WWW-Authenticate header. An empty
# realm produces a malformed header that some clients reject.
if ($cfg.AuthMode -ne 'ApiKey' -and [string]::IsNullOrWhiteSpace([string]$cfg.BasicAuthRealm)) {
    Write-StartupLog ("ERROR: AuthMode = '{0}' requires a non-empty BasicAuthRealm." -f $cfg.AuthMode)
    Write-Output ''
    Write-Output ("ERROR: BasicAuthRealm is empty but AuthMode = '{0}' relies on it." -f $cfg.AuthMode)
    exit 1
}

# CORS spec forbids '*' with credentials — browsers reject the response,
# so the combination breaks every authenticated cross-origin call silently.
if ($cfg.CorsAllowCredentials -and ($cfg.CorsAllowedOrigins -contains '*')) {
    Write-StartupLog 'ERROR: CorsAllowCredentials = $true is incompatible with CorsAllowedOrigins = @(''*''). The CORS spec requires an explicit origin list when credentials are enabled; browsers will reject every cross-origin response.'
    Write-Output ''
    Write-Output "ERROR: CORS misconfiguration — '*' origin cannot be combined with AllowCredentials = `$true."
    Write-Output 'Solution: replace @(''*'') with the concrete origins that need credentialed access.'
    exit 1
}

# Rate-limit numeric ranges — config.psd1 can set absurd values that no
# CLI param decorator would have caught. Order matters: a zero RateLimitRequests
# legitimately disables the limit (documented behaviour), so only the windows
# and the queue timeout need lower bounds.
if ($cfg.RateLimitWindowSec -lt 1) {
    Write-StartupLog "ERROR: RateLimitWindowSec = $($cfg.RateLimitWindowSec) must be >= 1 (or set RateLimitRequests = 0 to disable rate limiting entirely)."
    Write-Output ''
    Write-Output "ERROR: RateLimitWindowSec = $($cfg.RateLimitWindowSec) — must be >= 1 second."
    exit 1
}
if ($cfg.RateLimitMode -eq 'queue' -and $cfg.RateLimitQueueTimeoutSec -lt 1) {
    Write-StartupLog "ERROR: RateLimitMode = 'queue' requires RateLimitQueueTimeoutSec >= 1 (got $($cfg.RateLimitQueueTimeoutSec))."
    Write-Output ''
    Write-Output "ERROR: RateLimitQueueTimeoutSec = $($cfg.RateLimitQueueTimeoutSec) — queue mode needs a positive timeout."
    exit 1
}

# GZIP threshold sanity — inverted bounds disable compression silently.
if ($cfg.GzipEnabled -and $cfg.GzipMinBytes -ge $cfg.GzipMaxBytes) {
    Write-StartupLog "ERROR: GzipMinBytes ($($cfg.GzipMinBytes)) >= GzipMaxBytes ($($cfg.GzipMaxBytes)) — compression would never fire. Adjust the thresholds."
    Write-Output ''
    Write-Output "ERROR: GzipMinBytes ($($cfg.GzipMinBytes)) must be less than GzipMaxBytes ($($cfg.GzipMaxBytes))."
    exit 1
}

# ApiKeys hashtable must not contain empty values — an empty key in the table
# would let an unauthenticated request through if a client sent '' in X-Api-Key.
if ($cfg.ApiKeys -and $cfg.ApiKeys.Count -gt 0) {
    foreach ($label in $cfg.ApiKeys.Keys) {
        if ([string]::IsNullOrEmpty([string]$cfg.ApiKeys[$label])) {
            Write-StartupLog "ERROR: ApiKeys['$label'] is empty — empty keys would weaken authentication. Remove the entry or set a real key."
            Write-Output ''
            Write-Output "ERROR: ApiKeys['$label'] has an empty value. Remove the entry or set a real key."
            exit 1
        }
    }
}

# Exempt-path arrays — all four are matched verbatim (case-insensitive) against
# the request URL's AbsolutePath, which always starts with '/'. Entries missing
# the leading slash silently never match, so a typo like 'health' instead of
# '/health' would quietly expose the route to the very limit it was meant to
# bypass. Warn (not error) because the config still produces a working server
# — just not the one the operator intended.
$exemptPathKeys = @('RateLimitExemptPaths', 'GlobalThrottleExemptPaths', 'AuthExemptPaths', 'IpFilterExemptPaths')
foreach ($key in $exemptPathKeys) {
    $arr = $cfg[$key]
    if (-not $arr -or $arr.Count -eq 0) { continue }
    foreach ($p in $arr) {
        if ([string]::IsNullOrWhiteSpace([string]$p)) {
            Write-StartupLog "WARN: ${key} contains an empty entry — it will never match a request path."
            continue
        }
        if (-not ([string]$p).StartsWith('/')) {
            Write-StartupLog "WARN: ${key} entry '$p' does not start with '/'. Request paths always do — this entry will never match."
        }
    }
}

# BlockedIPs / AllowedIPs — entries are silently skipped by Test-IpMatch when
# they fail to parse, so a typo turns a security boundary into a no-op. Run
# the same pattern grammar (regex / CIDR / exact IP) at startup and warn on
# every entry that wouldn't match anything. Not fatal: the rest of the list
# still works, and the operator may have a half-written config.
$ipListKeys = @('BlockedIPs', 'AllowedIPs')
foreach ($key in $ipListKeys) {
    $arr = $cfg[$key]
    if (-not $arr -or $arr.Count -eq 0) { continue }
    foreach ($pat in $arr) {
        $s = [string]$pat
        if ([string]::IsNullOrWhiteSpace($s)) {
            Write-StartupLog "WARN: ${key} contains an empty entry — it will never match."
            continue
        }
        if ($s -ne $s.Trim()) {
            Write-StartupLog "WARN: ${key} entry '$s' has leading/trailing whitespace — Test-IpMatch will never match it. Trim the entry in config.psd1."
            continue
        }
        if ($s.StartsWith('~')) {
            try { $null = [regex]::new($s.Substring(1)) } catch {
                Write-StartupLog "WARN: ${key} regex entry '$s' is malformed: $($_.Exception.Message)"
            }
            continue
        }
        $slashIx = $s.IndexOf('/')
        if ($slashIx -gt 0) {
            $netPart  = $s.Substring(0, $slashIx)
            $bitsPart = $s.Substring($slashIx + 1)
            $ip = $null; $bits = $null
            $ipOk   = [System.Net.IPAddress]::TryParse($netPart, [ref]$ip)
            $bitsOk = [int]::TryParse($bitsPart, [ref]$bits)
            if (-not $ipOk -or -not $bitsOk) {
                Write-StartupLog "WARN: ${key} CIDR entry '$s' is malformed (expected '<ip>/<bits>')."
                continue
            }
            $maxBits = if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { 128 } else { 32 }
            if ($bits -lt 0 -or $bits -gt $maxBits) {
                Write-StartupLog "WARN: ${key} CIDR entry '$s' has prefix length out of range (allowed: 0..$maxBits)."
            }
            continue
        }
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($s, [ref]$ip)) {
            Write-StartupLog "WARN: ${key} entry '$s' is not a valid IP address, CIDR range, or '~regex'. It will never match."
        }
    }
}

# MimeTypeMap / ScriptExtensionMap — extension lookups in Get-MimeType / the
# scriptextension dispatch use the literal hashtable key. Keys without a
# leading dot, or with mixed case, silently never match because the lookup
# canonicalises the input to '.<lowercase>'.
foreach ($mapKey in @('MimeTypeMap', 'ScriptExtensionMap')) {
    $map = $cfg[$mapKey]
    if ($null -eq $map -or $map.Count -eq 0) { continue }
    foreach ($ext in @($map.Keys)) {
        $extStr = [string]$ext
        if ([string]::IsNullOrWhiteSpace($extStr)) {
            Write-StartupLog "WARN: ${mapKey} contains an empty key — it will never match a file extension."
            continue
        }
        if (-not $extStr.StartsWith('.')) {
            Write-StartupLog "WARN: ${mapKey} key '$extStr' must start with '.' to match. Add the leading dot in config.psd1."
        }
        if ($extStr -cne $extStr.ToLowerInvariant()) {
            Write-StartupLog "WARN: ${mapKey} key '$extStr' is not lowercase. Lookups canonicalise to lowercase before matching."
        }
        # Value sanity: MimeTypeMap values must be non-empty Content-Types. The
        # ScriptExtensionMap permits '' for .ps1 (JSON envelope), but any other
        # value should still resemble a media type ('<type>/<subtype>').
        $valStr = [string]$map[$ext]
        if ($mapKey -eq 'MimeTypeMap') {
            if ([string]::IsNullOrWhiteSpace($valStr) -or -not $valStr.Contains('/')) {
                Write-StartupLog "WARN: MimeTypeMap['$extStr'] = '$valStr' does not look like a Content-Type ('<type>/<subtype>')."
            }
        } else {
            if (-not [string]::IsNullOrEmpty($valStr) -and -not $valStr.Contains('/')) {
                Write-StartupLog "WARN: ScriptExtensionMap['$extStr'] = '$valStr' does not look like a Content-Type. Use '' for the JSON envelope or '<type>/<subtype>' for a raw passthrough."
            }
        }
    }
}

# Content-Type lists — GzipMimeTypes / AcceptedContentTypes / BlockedMimeTypes
# are all matched via StartsWith against the request/response Content-Type.
# Entries without '/' (e.g. 'json' instead of 'application/json') will never
# match anything.
foreach ($listKey in @('GzipMimeTypes', 'AcceptedContentTypes', 'BlockedMimeTypes')) {
    $list = $cfg[$listKey]
    if (-not $list -or $list.Count -eq 0) { continue }
    foreach ($ct in $list) {
        $ctStr = [string]$ct
        if ([string]::IsNullOrWhiteSpace($ctStr)) {
            Write-StartupLog "WARN: ${listKey} contains an empty entry — it will never match a Content-Type."
            continue
        }
        if (-not $ctStr.Contains('/')) {
            Write-StartupLog "WARN: ${listKey} entry '$ctStr' is not a media-type prefix ('<type>/<subtype>'). StartsWith match will never succeed."
        }
    }
}

# ---------------------------------------------------------------------------
# Log startup information. Single-line summary so log scrapers can pin a
# regex on it. Order is stable: BaseDir, WebRoot, LogDir, PS version, listener.
# ---------------------------------------------------------------------------
$httpsInfo = if ($cfg.HttpsEnabled) { "  HTTPS=:$($cfg.HttpsPort)" } else { '' }
$httpInfo  = if ($cfg.HttpPort -gt 0) { "  HTTP=:$($cfg.HttpPort)" } else { '  HTTP=disabled' }
$authInfo  = "  Auth=$($cfg.AuthMode)"
$execInfo  = "  Exec=$($cfg.ExecutionMode)"
Write-StartupLog "Web server starting. BaseDir=$baseDir  WebRoot=$($cfg.WebRoot)  LogDir=$($cfg.LogDir)  PS=$($PSVersionTable.PSVersion)$httpInfo$httpsInfo$authInfo$execInfo"

# ---------------------------------------------------------------------------
# Ensure directories exist. The top-level dirs (WebRoot, LogDir, PostJsonDir)
# are created unconditionally — they are part of the deployment contract.
# Audit/Slow/Jobs log files default to <LogDir>, but operators can redirect
# them anywhere via config.psd1. Make sure each parent exists so the runtime
# Add-Content writes don't silently fail in a runspace where errors are
# already swallowed by try/catch.
# ---------------------------------------------------------------------------
foreach ($dir in @($cfg.WebRoot, $cfg.LogDir, $cfg.PostJsonDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Write-StartupLog "Directory created: $dir"
    }
}
foreach ($logKey in @('JobsLogFile', 'AuditLogFile', 'SlowLogFile')) {
    $logFile = [string]$cfg[$logKey]
    if ([string]::IsNullOrWhiteSpace($logFile)) { continue }
    $parent = Split-Path -Parent $logFile
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        try {
            $null = New-Item -ItemType Directory -Path $parent -Force
            Write-StartupLog "Directory created for ${logKey}: $parent"
        } catch {
            Write-StartupLog "WARN: ${logKey} parent directory '$parent' could not be created: $($_.Exception.Message). Writes to '$logFile' will fail silently at runtime."
        }
    }
}

# ---------------------------------------------------------------------------
# Pre-flight: warn when the drive backing LogDir / WebRoot is nearly full.
# Not fatal — operators may have monitoring on the volume already and a fresh
# install on a small system partition can briefly look low. Threshold: less
# than 100 MB free is suspicious for a log-writing service.
# ---------------------------------------------------------------------------
$drivesChecked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($pathKey in @('LogDir', 'WebRoot', 'PostJsonDir')) {
    $path = [string]$cfg[$pathKey]
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $root = [System.IO.Path]::GetPathRoot($path)
    if ([string]::IsNullOrEmpty($root)) { continue }
    if (-not $drivesChecked.Add($root)) { continue }
    try {
        $drive = [System.IO.DriveInfo]::new($root)
        if ($drive.IsReady -and $drive.AvailableFreeSpace -lt 100MB) {
            $freeMb = [math]::Round($drive.AvailableFreeSpace / 1MB, 2)
            Write-StartupLog "WARN: drive $root has only $freeMb MB free; log/static writes may fail under load."
        }
    } catch {
        # DriveInfo can throw for non-fixed roots (UNC paths etc.). Best-effort only;
        # surface the failure quietly to startup.log so it isn't truly silent.
        $null = $_
        Write-StartupLog "WARN: disk-space pre-flight failed for '$root': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Log rotation at startup
# ---------------------------------------------------------------------------
$deletedLogs = Remove-OldLogs -LogDir $cfg.LogDir -RetentionDays $cfg.LogRetentionDays
if ($deletedLogs -gt 0) {
    Write-StartupLog "Log rotation: $deletedLogs file(s) older than $($cfg.LogRetentionDays) days deleted."
    if ($cfg.AuditLogEnabled) {
        Write-AuditLog -EventName 'LOG_ROTATION' -Detail "deleted=$deletedLogs; retentionDays=$($cfg.LogRetentionDays)"
    }
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
    # Bulk file deletion is security-relevant (could hide forensic evidence).
    # Emit an audit-log entry when enabled so the cleanup is part of the
    # tamper-evident trail. $script:cfg resolves to the top-level $cfg in a
    # script's main scope, so Write-AuditLog's internal $script:cfg.AuditLogFile
    # lookup sees the right value without an explicit mirror.
    if ($cfg.AuditLogEnabled) {
        Write-AuditLog -EventName 'POSTJSON_CLEANUP' -Detail "deleted=$deletedPostJson; retentionDays=$($cfg.PostJsonRetentionDays)"
    }
}

# ---------------------------------------------------------------------------
# Size-based rotation for the secondary log files (audit/slow/jobs). Their
# primary log counterparts already rotate by date (LogSchedule), but these
# are append-only single files with no built-in cap — left alone, an
# attacker who can trigger AUTH_FAIL bursts (audit) or operators with a
# very low SlowRequestThresholdMs (slow) could grow them without bound.
# Rotation only at startup keeps the runtime write path branchless.
# ---------------------------------------------------------------------------
function Invoke-LogSizeRotation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper; rotation is unconditional when the size threshold is met.')]
    [OutputType([bool])]
    param(
        [string] $LogFile,
        [long]   $MaxBytes,
        [string] $LabelForLog
    )
    if ($MaxBytes -le 0 -or [string]::IsNullOrWhiteSpace($LogFile)) { return $false }
    if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) { return $false }
    try {
        $sz = (Get-Item -LiteralPath $LogFile).Length
        if ($sz -ge $MaxBytes) {
            $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
            $rotated = '{0}.{1}' -f $LogFile, $stamp
            Move-Item -LiteralPath $LogFile -Destination $rotated -Force
            Write-StartupLog "$LabelForLog rotated: $sz bytes >= $MaxBytes; archived as $rotated."
            return $true
        }
    } catch {
        Write-StartupLog "WARN: $LabelForLog rotation failed for '$LogFile': $($_.Exception.Message)"
    }
    return $false
}

if ($cfg.AuditLogEnabled) {
    if (Invoke-LogSizeRotation -LogFile $cfg.AuditLogFile -MaxBytes $cfg.AuditLogMaxBytes -LabelForLog 'Audit log') {
        # Write the rotation marker into the NEW (post-rotation) audit log so
        # the trail can be cross-referenced with the .<timestamp> archive.
        Write-AuditLog -EventName 'AUDIT_LOG_ROTATED' -Detail "maxBytes=$($cfg.AuditLogMaxBytes)"
    }
}
if ($cfg.SlowRequestThresholdMs -gt 0) {
    if ((Invoke-LogSizeRotation -LogFile $cfg.SlowLogFile -MaxBytes $cfg.SlowLogMaxBytes -LabelForLog 'Slow log') -and $cfg.AuditLogEnabled) {
        Write-AuditLog -EventName 'SLOW_LOG_ROTATED' -Detail "maxBytes=$($cfg.SlowLogMaxBytes)"
    }
}
if ($cfg.BackgroundJobs -and $cfg.BackgroundJobs.Count -gt 0) {
    if ((Invoke-LogSizeRotation -LogFile $cfg.JobsLogFile -MaxBytes $cfg.JobsLogMaxBytes -LabelForLog 'Jobs log') -and $cfg.AuditLogEnabled) {
        Write-AuditLog -EventName 'JOBS_LOG_ROTATED' -Detail "maxBytes=$($cfg.JobsLogMaxBytes)"
    }
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
        -Table     $script:rateLimitTable `
        -WindowSec $cfg.RateLimitWindowSec
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
if ($cfg.Prefixes -and $cfg.Prefixes.Count -gt 0) {
    # Explicit prefix list — overrides the HttpPort/HttpsPort/`+`-wildcard defaults.
    # Caller is responsible for ending each prefix with '/'.
    foreach ($prefix in $cfg.Prefixes) { $null = $activePrefixes.Add($prefix) }
} else {
    if ($cfg.HttpsEnabled) {
        $null = $activePrefixes.Add("https://+:$($cfg.HttpsPort)/")
    }
    if ($cfg.HttpPort -gt 0) {
        $null = $activePrefixes.Add("http://+:$($cfg.HttpPort)/")
    }
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

        # Custom HTML error page override — when the client accepts text/html and a
        # matching <code>.html file exists under ErrorPagesRoot, replace the JSON body
        # with the HTML file's contents. Keeps clients that prefer JSON (Accept: */* or
        # application/json) on the existing envelope.
        if ($StatusCode -ge 400 -and $script:cfg.CustomErrorPages) {
            $acceptType = $null
            try { $acceptType = $script:acceptType } catch { }
            if ($acceptType -and $acceptType.IndexOf('text/html', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $errPage = Resolve-ErrorPage -StatusCode $StatusCode
                if ($null -ne $errPage) {
                    try {
                        $Body        = [System.IO.File]::ReadAllText($errPage, [System.Text.Encoding]::UTF8)
                        $ContentType = 'text/html; charset=utf-8'
                    } catch { }
                }
            }
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)

        # Negotiate compression: Brotli is preferred when both Brotli + GZIP are enabled
        # on the server AND the client advertised both. Eligibility (size + MIME prefix
        # list) is shared between the two so a request either qualifies for both or
        # neither. The comparison uses StartsWith so 'application/json' covers
        # 'application/json; charset=utf-8'.
        $sizeOk = $bytes.Length -ge $script:cfg.GzipMinBytes -and $bytes.Length -le $script:cfg.GzipMaxBytes
        $mimeOk = $false
        if ($sizeOk -and $AcceptEncoding) {
            foreach ($mime in $script:cfg.GzipMimeTypes) {
                if ($ContentType.StartsWith($mime, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mimeOk = $true
                    break
                }
            }
        }

        if ($mimeOk -and $script:cfg.BrotliEnabled -and
            $AcceptEncoding.IndexOf('br', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            # Brotli path — ~15-25 % smaller than gzip for text payloads.
            $ms = $null
            $br = $null
            try {
                $ms = [System.IO.MemoryStream]::new()
                $br = [System.IO.Compression.BrotliStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                $br.Write($bytes, 0, $bytes.Length)
                $br.Dispose(); $br = $null
                $bytes = $ms.ToArray()
                $Response.AddHeader('Content-Encoding', 'br')
            } finally {
                if ($null -ne $br) { try { $br.Dispose() } catch { } }
                if ($null -ne $ms) { try { $ms.Dispose() } catch { } }
            }
        } elseif ($mimeOk -and $script:cfg.GzipEnabled -and
                  $AcceptEncoding.IndexOf('gzip', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            # GZIP fallback path — broader client support, slightly larger output.
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
    #   Error = 0   → valid; RawJson contains a UTF-8 JSON string ready to write to disk.
    #   Error = 415 → Content-Type not in AcceptedContentTypes ('application/json' or 'application/x-www-form-urlencoded').
    #   Error = 413 → body exceeds MaxRequestBodyBytes.
    #   Error = 400 → body is not valid JSON (JSON path) or could not be parsed (form path).
    #
    # JSON path: raw body forwarded verbatim — nested objects and arrays preserved.
    # Form path: x-www-form-urlencoded body parsed into a flat object (or nested via 'key[]' arrays)
    #            and re-serialised as JSON, so scripts get the same -JsonFilePath contract regardless
    #            of how the client encoded the request.
    param([System.Net.HttpListenerRequest] $Request)

    $ct = $Request.ContentType
    if (-not $ct) {
        return [PSCustomObject]@{ Error = 415; RawJson = $null }
    }

    $isJson = $ct.StartsWith('application/json',                  [System.StringComparison]::OrdinalIgnoreCase)
    $isForm = $ct.StartsWith('application/x-www-form-urlencoded', [System.StringComparison]::OrdinalIgnoreCase)

    # Honor $cfg.AcceptedContentTypes — operators can narrow the gate (e.g. JSON-only) without
    # touching this function. Empty list = accept whatever this function knows how to parse.
    if ($script:cfg.AcceptedContentTypes -and $script:cfg.AcceptedContentTypes.Count -gt 0) {
        $matched = $false
        foreach ($prefix in $script:cfg.AcceptedContentTypes) {
            if ($ct.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $matched = $true; break }
        }
        if (-not $matched) { return [PSCustomObject]@{ Error = 415; RawJson = $null } }
    } elseif (-not ($isJson -or $isForm)) {
        return [PSCustomObject]@{ Error = 415; RawJson = $null }
    }

    # Check body size before reading — ContentLength64 is -1 when no Content-Length header is set.
    if ($Request.ContentLength64 -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; RawJson = $null }
    }

    # Read body — leaveOpen=$true keeps InputStream alive (owned by HttpListenerRequest).
    $reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8, $true, -1, $true)
    try {
        $rawBody = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }

    if ($rawBody.Length -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; RawJson = $null }
    }

    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return [PSCustomObject]@{ Error = 0; RawJson = '{}' }
    }

    if ($isJson) {
        try {
            $null = $rawBody | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [PSCustomObject]@{ Error = 400; RawJson = $null }
        }
        return [PSCustomObject]@{ Error = 0; RawJson = $rawBody }
    }

    # Form-URL-encoded path.
    # 'key=value&key2=value2' → flat object { key: 'value', key2: 'value2' }
    # 'tags[]=a&tags[]=b'     → { tags: ['a', 'b'] }
    # Multiple plain occurrences of the same key (without '[]') collapse into an array as well.
    try {
        $obj = [ordered]@{}
        foreach ($pair in $rawBody.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $eqIx = $pair.IndexOf('=')
            if ($eqIx -lt 0) {
                $rawKey = $pair
                $rawVal = ''
            } else {
                $rawKey = $pair.Substring(0, $eqIx)
                $rawVal = $pair.Substring($eqIx + 1)
            }
            # WebUtility handles '+' as space and standard percent-encoding.
            $key = [System.Net.WebUtility]::UrlDecode($rawKey)
            $val = [System.Net.WebUtility]::UrlDecode($rawVal)
            if ([string]::IsNullOrEmpty($key)) { continue }

            $isArrayKey = $false
            if ($key.EndsWith('[]')) {
                $isArrayKey = $true
                $key = $key.Substring(0, $key.Length - 2)
            }
            if ($obj.Contains($key)) {
                $existing = $obj[$key]
                if ($existing -is [System.Collections.IList]) {
                    $null = $existing.Add($val)
                } else {
                    $list = [System.Collections.Generic.List[string]]::new()
                    $null = $list.Add([string]$existing)
                    $null = $list.Add($val)
                    $obj[$key] = $list
                }
            } elseif ($isArrayKey) {
                $list = [System.Collections.Generic.List[string]]::new()
                $null = $list.Add($val)
                $obj[$key] = $list
            } else {
                $obj[$key] = $val
            }
        }
        $json = $obj | ConvertTo-Json -Compress -Depth 5
        return [PSCustomObject]@{ Error = 0; RawJson = $json }
    } catch {
        return [PSCustomObject]@{ Error = 400; RawJson = $null }
    }
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
# CORS helpers
# Add-CorsHeaders inspects the incoming Origin and, if it matches CorsAllowedOrigins
# (or '*' is in the list), writes Access-Control-Allow-Origin and the Vary header.
# Returns the matched origin string (or '*' for wildcard mode) so the OPTIONS preflight
# handler can attach the full ACL header set; returns $null when the request is not
# eligible for CORS treatment (origin missing or not allowlisted).
#
# 'null'-origin handling: a literal "Origin: null" header is allowed only when '*' is
# in the allowlist — same behavior as most production servers.
# ---------------------------------------------------------------------------
function Add-CorsHeaders {
    param(
        [System.Net.HttpListenerRequest]  $Request,
        [System.Net.HttpListenerResponse] $Response
    )
    if (-not $script:cfg.CorsAllowedOrigins -or $script:cfg.CorsAllowedOrigins.Count -eq 0) { return $null }

    $origin = $Request.Headers['Origin']
    if ([string]::IsNullOrEmpty($origin)) { return $null }

    # Defense against header-injection via the Origin echo: reject any value carrying a
    # control character (CR, LF, NUL, etc.). .NET's HttpListenerResponse.AddHeader
    # would itself throw on CR/LF, but pre-validating means we just deny CORS instead
    # of bubbling an ArgumentException into a 500 from the request handler.
    foreach ($ch in $origin.ToCharArray()) {
        if ([int][char]$ch -lt 0x20 -or [int][char]$ch -eq 0x7F) { return $null }
    }

    $matchedOrigin = $null
    if ($script:cfg.CorsAllowedOrigins -contains '*') {
        # Wildcard: echo back the actual origin when credentials are allowed (spec forbids '*' + credentials);
        # echo '*' otherwise so caches don't fragment by origin.
        if ($script:cfg.CorsAllowCredentials) { $matchedOrigin = $origin } else { $matchedOrigin = '*' }
    } elseif ($script:cfg.CorsAllowedOrigins -contains $origin) {
        $matchedOrigin = $origin
    }
    if ($null -eq $matchedOrigin) { return $null }

    $Response.AddHeader('Access-Control-Allow-Origin', $matchedOrigin)
    $Response.AddHeader('Vary',                        'Origin')
    if ($script:cfg.CorsAllowCredentials -and $matchedOrigin -ne '*') {
        $Response.AddHeader('Access-Control-Allow-Credentials', 'true')
    }
    return $matchedOrigin
}

# ---------------------------------------------------------------------------
# Send-CorsPreflight
# Handles an OPTIONS preflight: writes the CORS response headers (methods,
# headers, max-age) and returns HTTP 204. Skipped (returns $false) when the
# request is not CORS-eligible — caller is responsible for the fallback path.
# ---------------------------------------------------------------------------
function Send-CorsPreflight {
    param(
        [System.Net.HttpListenerRequest]  $Request,
        [System.Net.HttpListenerResponse] $Response,
        [string]                          $RequestId
    )
    $origin = Add-CorsHeaders -Request $Request -Response $Response
    if ($null -eq $origin) { return $false }

    # Echo the requested ACL-Request-Method/-Headers when the operator left the
    # global defaults at allow-all; otherwise stick to the configured static list.
    $Response.AddHeader('Access-Control-Allow-Methods', $script:cfg.CorsAllowedMethods)
    $Response.AddHeader('Access-Control-Allow-Headers', $script:cfg.CorsAllowedHeaders)
    if ($script:cfg.CorsMaxAgeSec -gt 0) {
        $Response.AddHeader('Access-Control-Max-Age',  [string]$script:cfg.CorsMaxAgeSec)
    }
    if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }

    $Response.StatusCode      = 204
    $Response.ContentLength64 = 0
    try { $Response.OutputStream.Close() } catch { }
    return $true
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
                    if ($parts[0] -eq '') {
                        # Suffix range 'bytes=-N' — last N bytes. Empty prefix means
                        # "the last N bytes of the entity". An RFC-7233 suffix length of
                        # 0 is technically a valid request that must return 416 (no bytes
                        # to serve); the rangeStart/rangeEnd checks below catch that.
                        $suffix     = [long]$parts[1]
                        $rangeStart = [long][math]::Max(0L, $fi.Length - $suffix)
                        $rangeEnd   = $fi.Length - 1L
                    } else {
                        # Regular range 'bytes=N-M' or open-ended 'bytes=N-'.
                        $rangeStart = [long]$parts[0]
                        if ($parts[1] -ne '') { $rangeEnd = [long]$parts[1] }
                        # else: rangeEnd already initialised to $fi.Length - 1L (open-ended).
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

    # Compression for static text content — only when no Range was requested.
    # Range + Content-Encoding is a thorny combination (clients differ on whether ranges
    # apply to compressed or original bytes); skipping compression for ranges sidesteps
    # the issue and matches the behavior of most production servers.
    # Brotli is preferred over GZIP when both server-enabled and client-advertised.
    $compressBody     = $null
    $compressEncoding = $null   # 'br', 'gzip', or $null when uncompressed
    if (-not $isRange -and
        $contentLength -ge $script:cfg.GzipMinBytes -and
        $contentLength -le $script:cfg.GzipMaxBytes) {
        $accept = $Request.Headers['Accept-Encoding']
        if ($accept) {
            $mimeMatched = $false
            foreach ($prefix in $script:cfg.GzipMimeTypes) {
                if ($mime.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mimeMatched = $true
                    break
                }
            }
            if ($mimeMatched) {
                $wantsBrotli = $script:cfg.BrotliEnabled -and $accept.IndexOf('br',   [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                $wantsGzip   = $script:cfg.GzipEnabled   -and $accept.IndexOf('gzip', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                if ($wantsBrotli) {
                    $ms = $null
                    $br = $null
                    try {
                        $allBytes     = [System.IO.File]::ReadAllBytes($FilePath)
                        $ms           = [System.IO.MemoryStream]::new()
                        $br           = [System.IO.Compression.BrotliStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                        $br.Write($allBytes, 0, $allBytes.Length)
                        $br.Dispose(); $br = $null
                        $compressBody     = $ms.ToArray()
                        $compressEncoding = 'br'
                    } finally {
                        if ($null -ne $br) { try { $br.Dispose() } catch { } }
                        if ($null -ne $ms) { try { $ms.Dispose() } catch { } }
                    }
                } elseif ($wantsGzip) {
                    $ms = $null
                    $gz = $null
                    try {
                        $allBytes     = [System.IO.File]::ReadAllBytes($FilePath)
                        $ms           = [System.IO.MemoryStream]::new()
                        $gz           = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                        $gz.Write($allBytes, 0, $allBytes.Length)
                        $gz.Dispose(); $gz = $null
                        $compressBody     = $ms.ToArray()
                        $compressEncoding = 'gzip'
                    } finally {
                        if ($null -ne $gz) { try { $gz.Dispose() } catch { } }
                        if ($null -ne $ms) { try { $ms.Dispose() } catch { } }
                    }
                }
            }
        }
    }
    $useCompressed = $null -ne $compressBody

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
    if ($useCompressed) {
        $Response.AddHeader('Content-Encoding', $compressEncoding)
        $Response.AddHeader('Vary',             'Accept-Encoding')
        $Response.ContentLength64 = $compressBody.Length
    } else {
        $Response.ContentLength64 = $contentLength
    }

    # Body stream — compressed path uses the in-memory buffer; otherwise stream from disk
    # with a 64 KB buffer to avoid loading large media files entirely into memory.
    if ($useCompressed) {
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

# ---------------------------------------------------------------------------
# ConvertTo-PoshApiXml
# Builds an XML response envelope compatible with the legacy PoSH Server
# `New-PoSHAPIXML` helper. Webroot .psxml / .psapi endpoints can write the
# returned string straight to stdout and the server will pass it through with
# the appropriate Content-Type.
#
# Available in webroot scripts only when ExecutionMode = 'InProcess' — the
# function is injected into the runspace by Invoke-ScriptInProcess via
# InitialSessionState.Commands. Subprocess-mode scripts that need XML output
# can either embed equivalent logic or use ConvertTo-Xml from the framework.
# ---------------------------------------------------------------------------
function ConvertTo-PoshApiXml {
    param(
        [int]         $Code    = 1,
        [string]      $Message = 'ok',
        [hashtable[]] $Items   = @(),
        [string]      $Root    = 'Result',
        [string]      $ItemTag = 'Item'
    )

    $doc      = [System.Xml.XmlDocument]::new()
    $rootNode = $doc.CreateElement($Root)
    $null     = $doc.AppendChild($rootNode)

    $codeNode          = $doc.CreateElement('Code')
    $codeNode.InnerText = [string]$Code
    $null              = $rootNode.AppendChild($codeNode)

    $msgNode           = $doc.CreateElement('Message')
    $msgNode.InnerText = $Message
    $null              = $rootNode.AppendChild($msgNode)

    $itemsNode = $doc.CreateElement('Items')
    $null      = $rootNode.AppendChild($itemsNode)

    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $itemNode = $doc.CreateElement($ItemTag)
        foreach ($k in $item.Keys) {
            $field          = $doc.CreateElement([string]$k)
            $field.InnerText = [string]$item[$k]
            $null            = $itemNode.AppendChild($field)
        }
        $null = $itemsNode.AppendChild($itemNode)
    }

    $sw  = $null
    $xtw = $null
    try {
        $sw  = [System.IO.StringWriter]::new()
        $xtw = [System.Xml.XmlTextWriter]::new($sw)
        $xtw.Formatting = [System.Xml.Formatting]::Indented
        $doc.WriteTo($xtw)
        $xtw.Flush()
        return $sw.ToString()
    } finally {
        if ($null -ne $xtw) { try { $xtw.Dispose() } catch { } }
        if ($null -ne $sw)  { try { $sw.Dispose()  } catch { } }
    }
}

# ---------------------------------------------------------------------------
# Resolve-ErrorPage
# Returns the absolute path of the HTML error page that matches a given HTTP
# status code, or $null when CustomErrorPages is disabled / the file does not
# exist. The Send-Response helper uses this to override the JSON envelope on
# 4xx/5xx responses when the client advertises text/html via Accept.
# ---------------------------------------------------------------------------
function Resolve-ErrorPage {
    param([int] $StatusCode)
    if (-not $script:cfg.CustomErrorPages -or $StatusCode -lt 400) { return $null }
    $path = Join-Path $script:cfg.ErrorPagesRoot ("{0}.html" -f $StatusCode)
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

# ---------------------------------------------------------------------------
# Test-IsScriptPath
# Returns $true when the URL path ends in one of the configured script
# extensions (.ps1, .psxml, .posh, .psapi by default). Comparison is
# case-insensitive. Used by the routing branch to decide between the static
# branch (PR-2) and the executable branch (PR-5).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Get-RouteTable (F9)
# Builds (and caches) a list of webroot scripts whose filenames contain
# `[name]` placeholders (Next.js-style). Each entry exposes the regex used
# to match incoming URLs and the placeholder names captured by that regex.
#
# Caches under the single key 'routes' in $script:routeCache. Invalidated
# when WebRoot's LastWriteTimeUtc changes — top-level add/remove of
# subdirectories is detected; deeper edits are not (operator restarts to
# refresh).
#
# Sorting heuristic: more literal segments before placeholders, so
# /users/admin.ps1 wins over /users/[id].ps1 when both match.
# ---------------------------------------------------------------------------
function Get-RouteTable {
    if (-not (Test-Path -LiteralPath $script:cfg.WebRoot -PathType Container)) {
        return @()
    }
    $wrMtime = (Get-Item -LiteralPath $script:cfg.WebRoot).LastWriteTimeUtc.Ticks
    $cached  = $null
    if ($script:routeCache.TryGetValue('routes', [ref]$cached) -and $cached.Mtime -eq $wrMtime) {
        return $cached.Table
    }

    $exts = @($script:cfg.ScriptExtensionMap.Keys)
    $entries = @()
    Get-ChildItem -Path $script:cfg.WebRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -notmatch '\[[^\[\]]+\]') { return $false }
            foreach ($e in $exts) {
                if ([string]::Equals($_.Extension, $e, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        } |
        ForEach-Object {
            $rel    = '/' + $_.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
            $relExt = $_.Extension                                                # '.ps1', '.psxml', …
            $relNoExt = $rel.Substring(0, $rel.Length - $relExt.Length)           # path without trailing '.ps1'
            $names    = [System.Collections.Generic.List[string]]::new()

            # Escape literal regex chars first, then turn each escaped \[name] into a named
            # group (?<name>[^/]+) that captures one path segment.
            # IMPORTANT: [regex]::Escape escapes the opening '[' (special inside a char class)
            # but NOT the closing ']' (literal outside a class) — so the replace pattern
            # matches '\[name]', not '\[name\]'. Without this, placeholders never capture
            # and every placeholder route literally matches its filename in the URL.
            $escapedNoExt = [regex]::Escape($relNoExt)
            # Non-greedy '[^/]+?' so '/users/42.ps1' captures id=42 (not '42.ps1') —
            # the optional extension group on the outside consumes the trailing '.ps1'.
            $patternNoExt = [regex]::Replace($escapedNoExt, '\\\[([^\[\]]+)\]', {
                param($m)
                $nm = $m.Groups[1].Value
                $null = $names.Add($nm)
                "(?<$nm>[^/]+?)"
            })

            # The route regex matches the URL path WITH or WITHOUT the trailing script
            # extension — `/users/123` and `/users/123.ps1` both resolve to the same
            # webroot/users/[id].ps1 file. Without the optional extension group, a
            # REST-style request that omits the extension would 404.
            $escapedExt = [regex]::Escape($relExt)
            $entries += [PSCustomObject]@{
                Pattern          = $rel
                Regex            = '^' + $patternNoExt + '(?:' + $escapedExt + ')?$'
                ScriptPath       = $_.FullName
                PlaceholderNames = $names.ToArray()
            }
        }

    # Specificity: literal segments first. Count placeholder occurrences and sort
    # ascending so routes with fewer placeholders are preferred matches.
    $sorted = $entries | Sort-Object @{ Expression = { ([regex]::Matches($_.Pattern, '\[[^\[\]]+\]')).Count } }
    $script:routeCache['routes'] = [PSCustomObject]@{ Mtime = $wrMtime; Table = @($sorted) }
    return @($sorted)
}

# ---------------------------------------------------------------------------
# Resolve-RoutedScript (F9)
# Try a placeholder-route match for $UrlPath. Returns the absolute script path
# and the captured placeholder values as a hashtable, or $null when no route
# matches or the feature is disabled.
# ---------------------------------------------------------------------------
function Resolve-RoutedScript {
    param([string] $UrlPath)
    if (-not $script:cfg.PathPlaceholders) { return $null }
    if ([string]::IsNullOrEmpty($UrlPath)) { return $null }

    # Exact-filename priority: before walking the placeholder route table, see if
    # a real file with one of the registered script extensions exists at the URL
    # path. So a request like '/users/admin' resolves to '/users/admin.ps1' when
    # that file exists — only routing to '/users/[id].ps1' when no exact match
    # is on disk. Without this, the placeholder route would shadow specific
    # filename-based handlers.
    if ($UrlPath -notmatch '/$') {
        $relAbs       = $UrlPath.TrimStart('/').Replace('/', '\')
        $webrootFull  = [System.IO.Path]::GetFullPath($script:cfg.WebRoot)
        foreach ($ext in $script:cfg.ScriptExtensionMap.Keys) {
            $probe = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.WebRoot ($relAbs + $ext)))
            if ($probe.StartsWith($webrootFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $probe -PathType Leaf)) {
                return [PSCustomObject]@{ ScriptPath = $probe; Placeholders = [ordered]@{} }
            }
        }
    }

    foreach ($route in (Get-RouteTable)) {
        if ($UrlPath -match $route.Regex) {
            $placeholders = [ordered]@{}
            foreach ($nm in $route.PlaceholderNames) {
                $placeholders[$nm] = $Matches[$nm]
            }
            return [PSCustomObject]@{ ScriptPath = $route.ScriptPath; Placeholders = $placeholders }
        }
    }
    return $null
}

function Test-IsScriptPath {
    param([string] $Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    foreach ($ext in $script:cfg.ScriptExtensionMap.Keys) {
        if ($Path.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Get-ScriptContentType
# Returns the configured Content-Type for the matched script extension, or
# an empty string when no override applies (caller defaults to the JSON
# envelope). Empty string is also the marker that means "wrap output in
# { exitCode, output, error }".
# ---------------------------------------------------------------------------
function Get-ScriptContentType {
    param([string] $Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    foreach ($ext in $script:cfg.ScriptExtensionMap.Keys) {
        if ($Path.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$script:cfg.ScriptExtensionMap[$ext]
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
# Invoke-ScriptInProcess
# Runs a webroot script inside a fresh runspace rather than spawning pwsh.exe.
#
# Trade-offs vs. Invoke-Script (Subprocess):
#   - Faster: no process-startup cost (~400 ms saved per request under load).
#   - Less isolation: a script crash within the script's own try/catch can
#     leak module state. We mitigate by giving each request its own runspace
#     and disposing it after the call.
#   - Exit codes are best-effort: `exit 1` from the script ends the pipeline
#     with $? = $false, but the numeric code is not always recoverable across
#     PowerShell pipelines. We treat any pipeline error/exception as exit 1
#     and successful completion as exit 0.
#   - Timeout uses Runspace.Stop() which is best-effort — long-running native
#     calls inside the script may not honor it immediately.
#
# Context variables ($PoSHQuery, $PoSHPost, $PoSHCookies, $PoSHHeaders) are
# injected into the runspace's InitialSessionState when $cfg.InjectContextVars
# is $true — legacy PoSH Server compatibility for scripts that read those
# globals directly.
# ---------------------------------------------------------------------------
function Invoke-ScriptInProcess {
    param(
        [string]    $ScriptPath,
        [hashtable] $Params,
        [int]       $TimeoutSec,
        [string]    $JsonFilePath = '',
        [hashtable] $ContextVars  = $null
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

    if ($script:cfg.InjectContextVars -and $null -ne $ContextVars) {
        foreach ($k in $ContextVars.Keys) {
            $entry = [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($k, $ContextVars[$k], $null)
            $iss.Variables.Add($entry)
        }
    }

    # Expose ConvertTo-PoshApiXml in the script's runspace — webroot .psxml / .psapi
    # endpoints can call it directly instead of reimplementing the XML envelope.
    try {
        $apiFn = (Get-Command ConvertTo-PoshApiXml -ErrorAction Stop).ScriptBlock
        $fnEntry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('ConvertTo-PoshApiXml', $apiFn.ToString())
        $iss.Commands.Add($fnEntry)
    } catch { } # if the helper failed to register globally, scripts can still implement their own XML

    $rs = $null
    $ps = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        # Use & '<path>' so the script's param() block binds named parameters from -Args.
        # Wrap in a try/catch so we surface non-terminating errors uniformly via Streams.Error.
        $null = $ps.AddScript({ param($Path) & $Path @args }, $true)
        $null = $ps.AddArgument($ScriptPath)
        foreach ($k in $Params.Keys) {
            $null = $ps.AddArgument("-$k")
            $null = $ps.AddArgument($Params[$k])
        }
        if ($JsonFilePath -ne '') {
            $null = $ps.AddArgument('-JsonFilePath')
            $null = $ps.AddArgument($JsonFilePath)
        }

        $handle = $ps.BeginInvoke()
        $done   = $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)

        if (-not $done) {
            try { $ps.Stop() } catch { }
            return [PSCustomObject]@{
                ExitCode = -1
                Output   = ''
                Error    = "Timeout: script was terminated after $TimeoutSec seconds (InProcess mode)."
                TimedOut = $true
            }
        }

        $outputObjs = $null
        $hadError   = $false
        $errorText  = ''
        try {
            $outputObjs = $ps.EndInvoke($handle)
        } catch {
            $hadError  = $true
            $errorText = $_.ToString()
        }

        if ($ps.Streams.Error.Count -gt 0) {
            $hadError = $true
            $errParts = foreach ($e in $ps.Streams.Error) { $e.ToString() }
            $errorText = ($errParts -join [System.Environment]::NewLine).Trim()
        }
        if ($ps.HadErrors) { $hadError = $true }

        $outText = ''
        if ($null -ne $outputObjs) {
            $strings = foreach ($o in $outputObjs) { [string]$o }
            $outText = ($strings -join [System.Environment]::NewLine).TrimEnd()
        }

        return [PSCustomObject]@{
            ExitCode = if ($hadError) { 1 } else { 0 }
            Output   = $outText
            Error    = $errorText
            TimedOut = $false
        }
    } finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
    }
}

# ---------------------------------------------------------------------------
# Invoke-PhpCgi
# Runs a .php file through an external php-cgi.exe and returns the parsed
# response so the caller can map it to an HttpListenerResponse.
#
# CGI/1.1 contract (simplified):
#   - Server sets GATEWAY_INTERFACE, REQUEST_METHOD, SCRIPT_FILENAME, QUERY_STRING,
#     CONTENT_LENGTH, CONTENT_TYPE, HTTP_* (all request headers prefixed with HTTP_,
#     dashes converted to underscores, uppercased).
#   - POST body is written to php-cgi's stdin.
#   - php-cgi writes response headers (one per line) terminated by an empty line,
#     followed by the response body. We parse the header block, pick out Status,
#     Content-Type, Location, etc., and forward the body verbatim.
#
# Returns PSCustomObject {
#   StatusCode [int]; ContentType [string]; Headers [hashtable]; Body [byte[]]; TimedOut [bool]; Error [string]
# }.
# Caller is responsible for writing headers + body to the HttpListenerResponse.
# ---------------------------------------------------------------------------
function Invoke-PhpCgi {
    param(
        [System.Net.HttpListenerRequest] $Request,
        [string]                         $ScriptPath,
        [int]                            $TimeoutSec
    )

    if ([string]::IsNullOrEmpty($script:cfg.PhpCgiPath) -or -not (Test-Path -LiteralPath $script:cfg.PhpCgiPath -PathType Leaf)) {
        return [PSCustomObject]@{
            StatusCode = 500; ContentType = 'text/plain; charset=utf-8'; Headers = @{}
            Body = [System.Text.Encoding]::UTF8.GetBytes('PHP-CGI is enabled but php-cgi.exe is not configured correctly.')
            TimedOut = $false; Error = 'PhpCgiPath misconfigured'
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $script:cfg.PhpCgiPath
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    # Working directory = directory of the PHP file. Many PHP apps assume relative includes.
    try { $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($ScriptPath) } catch { }

    # CGI/1.1 environment variables.
    $psi.Environment['GATEWAY_INTERFACE'] = 'CGI/1.1'
    $psi.Environment['REDIRECT_STATUS']   = '200'                       # required by PHP since 5.1 — refuses to run as CGI otherwise
    $psi.Environment['SERVER_PROTOCOL']   = 'HTTP/1.1'
    $psi.Environment['SERVER_SOFTWARE']   = 'posh-webserver'
    $psi.Environment['SCRIPT_FILENAME']   = $ScriptPath
    $psi.Environment['SCRIPT_NAME']       = $Request.Url.AbsolutePath
    $psi.Environment['REQUEST_URI']       = $Request.Url.PathAndQuery
    $psi.Environment['REQUEST_METHOD']    = $Request.HttpMethod
    $psi.Environment['QUERY_STRING']      = if ($Request.Url.Query) { $Request.Url.Query.TrimStart('?') } else { '' }
    $psi.Environment['REMOTE_ADDR']       = $Request.RemoteEndPoint.Address.ToString()
    $psi.Environment['REMOTE_PORT']       = [string]$Request.RemoteEndPoint.Port
    $psi.Environment['SERVER_NAME']       = if ($Request.Url.Host) { $Request.Url.Host } else { 'localhost' }
    $psi.Environment['SERVER_PORT']       = [string]$Request.Url.Port

    if ($null -ne $Request.ContentLength64 -and $Request.ContentLength64 -ge 0) {
        $psi.Environment['CONTENT_LENGTH'] = [string]$Request.ContentLength64
    }
    if ($Request.ContentType) {
        $psi.Environment['CONTENT_TYPE'] = $Request.ContentType
    }

    foreach ($h in $Request.Headers.AllKeys) {
        if ([string]::IsNullOrEmpty($h)) { continue }
        $envName = 'HTTP_' + $h.ToUpperInvariant().Replace('-', '_')
        $psi.Environment[$envName] = $Request.Headers[$h]
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        $null = $proc.Start()
    } catch {
        # php-cgi.exe may have been removed/locked since the startup validation, or the
        # OS may simply refuse the spawn. Return a structured 502 so the request handler
        # can log it cleanly instead of catching a raw exception and emitting a generic 500.
        try { $proc.Dispose() } catch { }
        return [PSCustomObject]@{
            StatusCode = 502; ContentType = 'text/plain; charset=utf-8'; Headers = @{}
            Body = [System.Text.Encoding]::UTF8.GetBytes("PHP-CGI process failed to start: $_")
            TimedOut = $false; Error = "PHP-CGI process failed to start: $_"
        }
    }

    # Pipe the request body to php-cgi's stdin — must be raw bytes (not the parsed body).
    try {
        if ($Request.HasEntityBody) {
            $buffer = [byte[]]::new(65536)
            $stdin  = $proc.StandardInput.BaseStream
            while ($true) {
                $read = $Request.InputStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $stdin.Write($buffer, 0, $read)
            }
            $stdin.Flush()
        }
    } catch { } finally {
        try { $proc.StandardInput.Close() } catch { }
    }

    # Read php-cgi output as bytes — we need the raw stdout so we can split the header
    # block (text) from the body (potentially binary, e.g. PHP-generated images).
    # CopyToAsync runs concurrently with the process; the awaited Task completes once
    # the stream reaches EOF, which happens when php-cgi exits.
    $outMs   = [System.IO.MemoryStream]::new()
    $errMs   = [System.IO.MemoryStream]::new()
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($errMs)

    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        # Kill makes the CopyToAsync tasks complete; bounded wait so a stuck pipe cannot
        # block the timeout response forever.
        try { $null = [System.Threading.Tasks.Task]::WaitAll(@($copyOut, $copyErr), 2000) } catch { }
        try { $proc.Dispose() } catch { }
        try { $outMs.Dispose() } catch { }
        try { $errMs.Dispose() } catch { }
        return [PSCustomObject]@{
            StatusCode = 504; ContentType = 'text/plain; charset=utf-8'; Headers = @{}
            Body = [System.Text.Encoding]::UTF8.GetBytes("PHP-CGI timeout after $TimeoutSec seconds.")
            TimedOut = $true; Error = "PHP-CGI timeout after $TimeoutSec seconds"
        }
    }

    $null = $proc.WaitForExit(5000)
    $null = [System.Threading.Tasks.Task]::WaitAll(@($copyOut, $copyErr), 5000)
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    $outBytes = $outMs.ToArray()
    $errBytes = $errMs.ToArray()
    $outMs.Dispose(); $errMs.Dispose()

    # Header / body split. CGI uses '\r\n\r\n' but Unix-style '\n\n' is also seen.
    $sepIx = -1
    $sepLen = 0
    for ($i = 0; $i -lt ($outBytes.Length - 3); $i++) {
        if ($outBytes[$i] -eq 0x0D -and $outBytes[$i + 1] -eq 0x0A -and $outBytes[$i + 2] -eq 0x0D -and $outBytes[$i + 3] -eq 0x0A) {
            $sepIx = $i; $sepLen = 4; break
        }
    }
    if ($sepIx -lt 0) {
        for ($i = 0; $i -lt ($outBytes.Length - 1); $i++) {
            if ($outBytes[$i] -eq 0x0A -and $outBytes[$i + 1] -eq 0x0A) {
                $sepIx = $i; $sepLen = 2; break
            }
        }
    }

    $statusCode  = 200
    $contentType = 'text/html; charset=utf-8'
    $headers     = @{}
    $bodyBytes   = $outBytes

    if ($sepIx -ge 0) {
        $headerText = [System.Text.Encoding]::UTF8.GetString($outBytes, 0, $sepIx)
        $bodyOffset = $sepIx + $sepLen
        $bodyLen    = $outBytes.Length - $bodyOffset
        $bodyBytes  = [byte[]]::new([math]::Max(0, $bodyLen))
        if ($bodyLen -gt 0) { [Array]::Copy($outBytes, $bodyOffset, $bodyBytes, 0, $bodyLen) }

        foreach ($line in $headerText -split "(`r`n|`n)") {
            $line = $line.Trim()
            if ([string]::IsNullOrEmpty($line)) { continue }
            $colon = $line.IndexOf(':')
            if ($colon -lt 1) { continue }
            $name  = $line.Substring(0, $colon).Trim()
            $value = $line.Substring($colon + 1).Trim()

            if ([string]::Equals($name, 'Status', [System.StringComparison]::OrdinalIgnoreCase)) {
                # 'Status: 302 Found' → 302
                $code = ($value -split ' ', 2)[0]
                try { $statusCode = [int]$code } catch { }
            } elseif ([string]::Equals($name, 'Content-Type', [System.StringComparison]::OrdinalIgnoreCase)) {
                $contentType = $value
            } else {
                $headers[$name] = $value
            }
        }
        # PHP 'Location:' without an explicit Status defaults to 302.
        if ($headers.ContainsKey('Location') -and -not ($headerText -match '(?im)^\s*Status\s*:')) {
            $statusCode = 302
        }
    }

    $errText = if ($errBytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($errBytes) } else { '' }

    return [PSCustomObject]@{
        StatusCode  = $statusCode
        ContentType = $contentType
        Headers     = $headers
        Body        = $bodyBytes
        TimedOut    = $false
        Error       = $errText
        ExitCode    = $exitCode
    }
}

# ---------------------------------------------------------------------------
# Send-DirectoryListing
# Renders an HTML directory listing when DirectoryBrowsing is enabled, the
# request resolved to a directory, and none of $cfg.DefaultDocuments existed
# inside it. The HTML is intentionally minimal — name, size, modified date,
# one link per entry. Items whose name appears in $cfg.DirectoryBrowsingHidden
# (case-insensitive) are omitted.
#
# Returns PSCustomObject { StatusCode; Reason; Length }.
# Caller is responsible for path-traversal protection — Send-DirectoryListing
# trusts that $DirPath is already inside StaticRoot.
# ---------------------------------------------------------------------------
function Send-DirectoryListing {
    param(
        [System.Net.HttpListenerResponse] $Response,
        [string]                          $DirPath,
        [string]                          $UrlPath,
        [string]                          $RequestId
    )

    $hidden = @{}
    foreach ($h in $script:cfg.DirectoryBrowsingHidden) {
        if (-not [string]::IsNullOrEmpty($h)) { $hidden[$h.ToLowerInvariant()] = $true }
    }

    # Drop -Force on purpose: items carrying the HIDDEN or SYSTEM attribute
    # (.env, .htaccess, desktop.ini, Thumbs.db, …) stay invisible in the
    # listing. Operators who really want to expose them can rename to
    # plain visibility — DirectoryBrowsing is a casual file-server feature,
    # not a full file manager, so information-disclosure-safe defaults win.
    $entries = Get-ChildItem -LiteralPath $DirPath -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name.ToLowerInvariant()
            -not $hidden.ContainsKey($name)
        } |
        Sort-Object @{ Expression = { -not $_.PSIsContainer } }, Name

    $sb = [System.Text.StringBuilder]::new(8192)
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="en"><head>')
    $null = $sb.AppendLine(('<title>Index of {0}</title>' -f [System.Net.WebUtility]::HtmlEncode($UrlPath)))
    $null = $sb.AppendLine('<meta charset="utf-8">')
    $null = $sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}h1{font-size:1.4em;margin-bottom:.4em}table{border-collapse:collapse;width:100%;max-width:60em}th,td{padding:.4em .8em;text-align:left;border-bottom:1px solid #eee}th{background:#f6f6f6}td.size{text-align:right;font-variant-numeric:tabular-nums;color:#555}a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}</style>')
    $null = $sb.AppendLine('</head><body>')
    $null = $sb.AppendLine(('<h1>Index of {0}</h1>' -f [System.Net.WebUtility]::HtmlEncode($UrlPath)))
    $null = $sb.AppendLine('<table><thead><tr><th>Name</th><th>Size</th><th>Modified</th></tr></thead><tbody>')

    # Parent-directory link unless we are at the static root.
    if ($UrlPath -ne '/' -and $UrlPath -ne '') {
        $null = $sb.AppendLine('<tr><td><a href="../">../</a></td><td class="size">—</td><td>—</td></tr>')
    }

    foreach ($entry in $entries) {
        $isDir   = $entry.PSIsContainer
        $name    = $entry.Name
        $slash   = if ($isDir) { '/' } else { '' }
        $sizeStr = if ($isDir) { '—' } else { '{0:N0}' -f $entry.Length }
        $modStr  = $entry.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $href    = [Uri]::EscapeDataString($name) + $slash
        $disp    = [System.Net.WebUtility]::HtmlEncode($name) + $slash
        $null = $sb.AppendLine(('<tr><td><a href="{0}">{1}</a></td><td class="size">{2}</td><td>{3}</td></tr>' -f $href, $disp, $sizeStr, $modStr))
    }

    $null = $sb.AppendLine('</tbody></table></body></html>')
    $body = $sb.ToString()

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $Response.StatusCode      = 200
    $Response.ContentType     = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    if ($RequestId) { $Response.AddHeader('X-Request-Id', $RequestId) }
    try { $Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
    try { $Response.OutputStream.Close() } catch { }

    return [PSCustomObject]@{ StatusCode = 200; Reason = 'DIR LISTING'; Length = $bytes.Length }
}

function Invoke-Script {
    param(
        [string]    $ScriptPath,
        [hashtable] $Params,
        [int]       $TimeoutSec,
        [string]    $JsonFilePath = '',  # when set: passed as -JsonFilePath to the script (POST requests)
        [hashtable] $EnvVars      = $null # extra environment variables (POSH_COOKIES, POSH_HEADERS_JSON, …) — child process inherits them
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

    # Inject per-request environment variables for the child pwsh.exe. Touching
    # psi.Environment forces .NET to materialise the parent env block, so we only
    # do it when the caller asked for extras — keeps the hot path zero-cost.
    if ($null -ne $EnvVars -and $EnvVars.Count -gt 0) {
        foreach ($k in $EnvVars.Keys) {
            $psi.Environment[$k] = [string]$EnvVars[$k]
        }
    }

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

# ---------------------------------------------------------------------------
# Get-ScriptMetadata (F7)
# AST-parses a webroot script and returns its declared parameters plus the
# comment-based help block (.SYNOPSIS / .DESCRIPTION / .PARAMETER). Cached by
# absolute path; entries invalidated when LastWriteTimeUtc changes so a script
# edit shows up at the next request without restart.
#
# Returns [ordered] @{ synopsis; description; parameters = @[ @{ name; type; default; description } ] }
# or $null on a parse error / missing file.
# ---------------------------------------------------------------------------
function Get-ScriptMetadata {
    param([string] $ScriptPath)

    $fi = [System.IO.FileInfo]::new($ScriptPath)
    if (-not $fi.Exists) { return $null }
    $currentMtime = $fi.LastWriteTimeUtc.Ticks

    $cachedEntry = $null
    if ($script:metadataCache.TryGetValue($ScriptPath, [ref]$cachedEntry) -and $cachedEntry.Mtime -eq $currentMtime) {
        return $cachedEntry.Metadata
    }

    $errors = $null
    $ast    = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errors)
    } catch {
        return $null
    }
    if ($null -eq $ast) { return $null }

    $synopsis    = ''
    $description = ''
    $paramHelp   = @{}
    try {
        $helpComment = $ast.GetHelpContent()
        # PS 7's GetHelpContent returns $null when '#Requires' precedes the help
        # block (which is the de-facto convention in this repo's webroot scripts).
        # Fall back to re-parsing the source with '#Requires' lines stripped so the
        # help block ends up where GetHelpContent expects it.
        if ($null -eq $helpComment) {
            try {
                $raw       = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
                # Strip every leading #Requires line so the help block (or param
                # block) becomes the first real statement. TrimStart removes the
                # blank line(s) the strip leaves behind, which would otherwise
                # confuse GetHelpContent's "directly above param/function" anchor.
                $stripped  = ($raw -replace '(?m)^#Requires[^\r\n]*', '').TrimStart([char[]]@("`r","`n","`t",' '))
                $astRetry  = [System.Management.Automation.Language.Parser]::ParseInput($stripped, [ref]$null, [ref]$null)
                if ($null -ne $astRetry) { $helpComment = $astRetry.GetHelpContent() }
            } catch { }
        }
        if ($null -ne $helpComment) {
            if ($helpComment.Synopsis)    { $synopsis    = $helpComment.Synopsis.Trim() }
            if ($helpComment.Description) { $description = $helpComment.Description.Trim() }
            if ($helpComment.Parameters)  { $paramHelp = $helpComment.Parameters }
        }
    } catch { }

    $parameters = @()
    try {
        $paramBlock = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Select-Object -First 1
        if ($null -ne $paramBlock) {
            foreach ($p in $paramBlock.Parameters) {
                $paramName = $p.Name.VariablePath.UserPath
                $paramType = if ($null -ne $p.StaticType) { $p.StaticType.Name } else { 'object' }
                $paramDefault = if ($null -ne $p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
                $paramDescription = ''
                # Comment-based help keys arrive uppercased in PS 7's GetHelpContent().
                # $paramHelp is a Dictionary[string,string] when GetHelpContent returns
                # — its .Contains takes a KeyValuePair, not a string, so we have to use
                # the IDictionary cast (which exposes the non-generic Contains(object)).
                $upperName = $paramName.ToUpperInvariant()
                if ($paramHelp -is [System.Collections.IDictionary] -and ([System.Collections.IDictionary]$paramHelp).Contains($upperName)) {
                    $paramDescription = ([string]$paramHelp[$upperName]).Trim()
                }
                $parameters += [ordered]@{
                    name        = $paramName
                    type        = $paramType
                    default     = $paramDefault
                    description = $paramDescription
                }
            }
        }
    } catch { }

    $metadata = [ordered]@{
        synopsis    = $synopsis
        description = $description
        parameters  = $parameters
    }
    $script:metadataCache[$ScriptPath] = [PSCustomObject]@{ Mtime = $currentMtime; Metadata = $metadata }
    return $metadata
}

# ---------------------------------------------------------------------------
# Build-OpenApiSpec (F10)
# Walks every webroot script registered in $cfg.ScriptExtensionMap, reuses
# Get-ScriptMetadata (F7), and produces an OpenAPI 3.1 document. Routes with
# placeholders (`webroot/users/[id].ps1`, F9) are rewritten to OpenAPI-style
# path templates (`/users/{id}.ps1`) and the corresponding parameters appear
# with `in: path, required: true`.
#
# Response schema:
#   .ps1  → JSON envelope `{ exitCode, output, error }`
#   .psxml / .posh / .psapi → free-form text response with the script-mapped
#                              Content-Type (no schema; content-type only).
# ---------------------------------------------------------------------------
function Get-OpenApiSchemaForType {
    param([string] $PsTypeName)
    if ([string]::IsNullOrEmpty($PsTypeName)) { return @{ type = 'string' } }
    $t = $PsTypeName.ToLowerInvariant()
    if ($t.EndsWith('[]')) {
        $inner = Get-OpenApiSchemaForType -PsTypeName ($PsTypeName.Substring(0, $PsTypeName.Length - 2))
        return @{ type = 'array'; items = $inner }
    }
    switch -Regex ($t) {
        '^(int|int32|long|int64|byte|short|sbyte|uint16|uint32|uint64)$' { return @{ type = 'integer' } }
        '^(double|float|single|decimal)$'                                { return @{ type = 'number' } }
        '^(bool|boolean|switch|switchparameter)$'                        { return @{ type = 'boolean' } }
        '^(datetime|date)$'                                              { return @{ type = 'string'; format = 'date-time' } }
        '^(guid)$'                                                       { return @{ type = 'string'; format = 'uuid' } }
        default                                                          { return @{ type = 'string' } }
    }
}

function Build-OpenApiSpec {
    $paths = [ordered]@{}

    $envelopeSchema = [ordered]@{
        type       = 'object'
        properties = [ordered]@{
            exitCode = [ordered]@{ type = 'integer' }
            output   = [ordered]@{ type = 'string' }
            error    = [ordered]@{ type = 'string' }
        }
    }

    if (Test-Path -LiteralPath $script:cfg.WebRoot -PathType Container) {
        $exts = @($script:cfg.ScriptExtensionMap.Keys)
        $files = Get-ChildItem -Path $script:cfg.WebRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $itemExt = $_.Extension
            $matched = $false
            foreach ($e in $exts) {
                if ([string]::Equals($itemExt, $e, [System.StringComparison]::OrdinalIgnoreCase)) { $matched = $true; break }
            }
            $matched
        }
        foreach ($file in $files) {
            $rel = '/' + $file.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
            # F9: rewrite [id] → {id} in the OpenAPI path so tools (Swagger UI, Postman)
            # display the placeholders correctly. Track which placeholders need 'in: path'
            # via a parallel extraction since regex replace + side-effect-in-callback
            # is unreliable across scopes in PS scriptblocks.
            $openapiPath = [regex]::Replace($rel, '\[([^\[\]]+)\]', '{$1}')
            $placeholderNames = @([regex]::Matches($rel, '\[([^\[\]]+)\]') | ForEach-Object { $_.Groups[1].Value })

            $meta = $null
            try { $meta = Get-ScriptMetadata -ScriptPath $file.FullName } catch { }

            $parameters = @()
            if ($null -ne $meta -and $meta.parameters) {
                foreach ($p in $meta.parameters) {
                    $isPath = $placeholderNames -contains $p.name
                    $schema = Get-OpenApiSchemaForType -PsTypeName $p.type
                    # [switch] parameters are never required — they always default to $false
                    # in PowerShell regardless of whether the user wrote `= $false`. Treating
                    # them like ordinary parameters would mark every switch as required because
                    # their AST DefaultValue is $null.
                    $isSwitch = $p.type -in @('SwitchParameter', 'Switch')
                    $required = $isPath -or (-not $isSwitch -and $null -eq $p.default)
                    $paramObj = [ordered]@{
                        name        = $p.name
                        'in'        = if ($isPath) { 'path' } else { 'query' }
                        required    = $required
                        description = if ($p.description) { [string]$p.description } else { '' }
                        schema      = $schema
                    }
                    $parameters += $paramObj
                }
            }

            $contentTypeOverride = [string]$script:cfg.ScriptExtensionMap[$file.Extension]
            $responseContent = if ([string]::IsNullOrEmpty($contentTypeOverride)) {
                [ordered]@{ 'application/json' = [ordered]@{ schema = $envelopeSchema } }
            } else {
                $ctKey = ($contentTypeOverride -split ';')[0].Trim()
                [ordered]@{ $ctKey = [ordered]@{ schema = [ordered]@{ type = 'string' } } }
            }

            $operation = [ordered]@{
                summary     = if ($null -ne $meta) { [string]$meta.synopsis } else { '' }
                description = if ($null -ne $meta) { [string]$meta.description } else { '' }
                parameters  = $parameters
                responses   = [ordered]@{
                    '200' = [ordered]@{
                        description = 'Success (script exited with code 0).'
                        content     = $responseContent
                    }
                    '500' = [ordered]@{
                        description = 'Script exited with a non-zero code.'
                        content     = [ordered]@{ 'application/json' = [ordered]@{ schema = $envelopeSchema } }
                    }
                    '504' = [ordered]@{
                        description = 'Script execution exceeded ScriptTimeoutSec.'
                    }
                }
            }
            $methods = if ($file.Extension -eq '.ps1') { @('get', 'post') } else { @('get') }
            $pathItem = [ordered]@{}
            foreach ($m in $methods) { $pathItem[$m] = $operation }
            $paths[$openapiPath] = $pathItem
        }
    }

    $spec = [ordered]@{
        openapi = '3.1.0'
        info    = [ordered]@{
            title   = [string]$script:cfg.OpenApiTitle
            version = [string]$script:cfg.OpenApiVersion
        }
        paths   = $paths
    }
    return $spec | ConvertTo-Json -Compress -Depth 12
}

# ---------------------------------------------------------------------------
# Format-PromMetrics (F8)
# Builds a Prometheus text-format body from the live counters/gauges. Same
# numbers /metrics already exposes — just expressed in the format Prometheus
# (and Grafana, VictoriaMetrics, etc.) scrape natively.
#
# Cheap to call; runs in the request thread on demand. No background scrape.
# ---------------------------------------------------------------------------
function Format-PromMetrics {
    $uptimeSec   = [int][math]::Floor($startTime.Elapsed.TotalSeconds)
    $total       = [System.Threading.Interlocked]::Read($requestsTotal)
    $rateLimited = [System.Threading.Interlocked]::Read($script:rateLimitedTotal)
    # SemaphoreSlim.CurrentCount = remaining slots; in-flight = MaxConcurrent - remaining.
    $inFlight    = $script:cfg.MaxConcurrent - $semaphore.CurrentCount
    if ($inFlight -lt 0) { $inFlight = 0 }
    $tableSize   = $script:rateLimitTable.Count
    $cacheSize   = $script:metadataCache.Count
    $logDrops    = [System.Threading.Interlocked]::Read($script:logDropsTotal)
    $auditDrops  = [System.Threading.Interlocked]::Read($script:auditLogDropsTotal)
    $slowDrops   = [System.Threading.Interlocked]::Read($script:slowLogDropsTotal)

    $sb = [System.Text.StringBuilder]::new(1024)
    $null = $sb.AppendLine('# HELP posh_uptime_seconds Server uptime since process start.')
    $null = $sb.AppendLine('# TYPE posh_uptime_seconds gauge')
    $null = $sb.AppendLine("posh_uptime_seconds $uptimeSec")
    $null = $sb.AppendLine('# HELP posh_requests_total Number of completed script requests.')
    $null = $sb.AppendLine('# TYPE posh_requests_total counter')
    $null = $sb.AppendLine("posh_requests_total $total")
    $null = $sb.AppendLine('# HELP posh_rate_limited_total Per-identity/IP rate-limit rejections from Test-RateLimit.')
    $null = $sb.AppendLine('# TYPE posh_rate_limited_total counter')
    $null = $sb.AppendLine("posh_rate_limited_total $rateLimited")
    $null = $sb.AppendLine('# HELP posh_in_flight_requests Currently occupied request slots.')
    $null = $sb.AppendLine('# TYPE posh_in_flight_requests gauge')
    $null = $sb.AppendLine("posh_in_flight_requests $inFlight")
    $null = $sb.AppendLine('# HELP posh_rate_limit_table_size Per-key/IP rate-limit table entries.')
    $null = $sb.AppendLine('# TYPE posh_rate_limit_table_size gauge')
    $null = $sb.AppendLine("posh_rate_limit_table_size $tableSize")
    $null = $sb.AppendLine('# HELP posh_script_metadata_cache_size Cached AST metadata entries.')
    $null = $sb.AppendLine('# TYPE posh_script_metadata_cache_size gauge')
    $null = $sb.AppendLine("posh_script_metadata_cache_size $cacheSize")
    $null = $sb.AppendLine('# HELP posh_log_drops_total Log lines skipped because the request-log mutex was contended for >500ms.')
    $null = $sb.AppendLine('# TYPE posh_log_drops_total counter')
    $null = $sb.AppendLine("posh_log_drops_total $logDrops")
    $null = $sb.AppendLine('# HELP posh_audit_log_drops_total Audit-log lines skipped because the audit mutex was contended for >500ms.')
    $null = $sb.AppendLine('# TYPE posh_audit_log_drops_total counter')
    $null = $sb.AppendLine("posh_audit_log_drops_total $auditDrops")
    $null = $sb.AppendLine('# HELP posh_slow_log_drops_total Slow-log lines skipped because the request-log mutex was contended for >500ms.')
    $null = $sb.AppendLine('# TYPE posh_slow_log_drops_total counter')
    $null = $sb.AppendLine("posh_slow_log_drops_total $slowDrops")
    return $sb.ToString()
}

function Get-ScriptIndex {
    # @() forces array serialisation even on an empty result — prevents $null instead of [].
    # Indexes every extension registered in ScriptExtensionMap (.ps1, .psxml, .posh, .psapi
    # by default), not just .ps1, so non-default aliases are discoverable too.
    # F7: when IndexShowMetadata = $true, each entry is enriched with the parsed
    # synopsis + parameters. When $false, the legacy flat string list is returned.
    $exts = @($script:cfg.ScriptExtensionMap.Keys)
    if (-not (Test-Path -LiteralPath $script:cfg.WebRoot -PathType Container)) {
        return @() | ConvertTo-Json -Compress -Depth 5
    }
    $files = Get-ChildItem -Path $script:cfg.WebRoot -Recurse -File | Where-Object {
        $itemExt = $_.Extension
        $matched = $false
        foreach ($e in $exts) {
            if ([string]::Equals($itemExt, $e, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true; break
            }
        }
        $matched
    }
    if (-not $script:cfg.IndexShowMetadata) {
        $list = @($files | ForEach-Object {
            '/' + $_.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
        })
        return @($list) | ConvertTo-Json -Compress -Depth 3
    }
    $entries = @()
    foreach ($file in $files) {
        $urlPath = '/' + $file.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
        $meta = $null
        try { $meta = Get-ScriptMetadata -ScriptPath $file.FullName } catch { }
        $methods = if ($file.Extension -eq '.ps1') { @('GET', 'POST') } else { @('GET') }
        $entry = [ordered]@{
            path    = $urlPath
            methods = $methods
        }
        if ($null -ne $meta) {
            $entry.synopsis    = $meta.synopsis
            $entry.description = $meta.description
            $entry.parameters  = $meta.parameters
        }
        $entries += $entry
    }
    return @($entries) | ConvertTo-Json -Compress -Depth 5
}

# ---------------------------------------------------------------------------
# Resolve-ApiKeyIdentity
# Looks up an X-Api-Key value against $cfg.ApiKeys and returns the matching
# label, or $null when the key does not match any configured entry.
# Comparison is ordinal (case-sensitive byte-exact) — matches the Loop-3 fix
# for the legacy single-key path.
#
# Returned label flows into $script:authIdentity and from there into the
# request log, audit log, per-key rate-limit, and Prometheus metrics.
# ---------------------------------------------------------------------------
function Resolve-ApiKeyIdentity {
    param([string] $ProvidedKey)
    if ([string]::IsNullOrEmpty($ProvidedKey)) { return $null }
    if (-not $script:cfg.ApiKeys -or $script:cfg.ApiKeys.Count -eq 0) { return $null }
    foreach ($entry in $script:cfg.ApiKeys.GetEnumerator()) {
        if ([string]::Equals($entry.Value, $ProvidedKey, [System.StringComparison]::Ordinal)) {
            return $entry.Key
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Test-IpMatch
# Returns $true when $Ip matches any entry in $Patterns. Each pattern can be:
#   - Exact match:  '192.168.1.10' (case-insensitive comparison).
#   - CIDR range:   '192.168.1.0/24' — matches when the first /N bits of $Ip equal
#                   the network bytes. IPv4 and IPv6 both supported; mismatched families
#                   never match (so an IPv4 entry never matches an IPv6 client).
#   - Regex:        '~^10\.' — entries that start with '~' run the rest as a regex
#                   over the literal IP string. Useful for legacy PoSH whitelist parity.
# Empty / null pattern list returns $false.
# ---------------------------------------------------------------------------
function Test-IpMatch {
    param(
        [string]   $Ip,
        [string[]] $Patterns
    )
    if ($null -eq $Patterns -or $Patterns.Count -eq 0) { return $false }

    $ipAddr  = $null
    $ipBytes = $null
    try {
        $ipAddr  = [System.Net.IPAddress]::Parse($Ip)
        $ipBytes = $ipAddr.GetAddressBytes()
    } catch { $ipAddr = $null }

    foreach ($p in $Patterns) {
        if ([string]::IsNullOrEmpty($p)) { continue }

        if ($p.StartsWith('~')) {
            $regex = $p.Substring(1)
            try { if ($Ip -match $regex) { return $true } } catch { } # malformed regex → skip
            continue
        }

        $slashIx = $p.IndexOf('/')
        if ($slashIx -gt 0 -and $null -ne $ipBytes) {
            try {
                $netIp    = [System.Net.IPAddress]::Parse($p.Substring(0, $slashIx))
                $bits     = [int]$p.Substring($slashIx + 1)
                $netBytes = $netIp.GetAddressBytes()
                if ($netBytes.Length -ne $ipBytes.Length) { continue }
                $remaining = $bits
                $matched   = $true
                for ($i = 0; $i -lt $netBytes.Length; $i++) {
                    if ($remaining -le 0) { break }
                    if ($remaining -ge 8) {
                        if ($netBytes[$i] -ne $ipBytes[$i]) { $matched = $false; break }
                        $remaining -= 8
                    } else {
                        $mask = (0xFF -shl (8 - $remaining)) -band 0xFF
                        if ((($netBytes[$i] -band $mask) -bxor ($ipBytes[$i] -band $mask)) -ne 0) {
                            $matched = $false
                        }
                        $remaining = 0
                    }
                }
                if ($matched) { return $true }
            } catch { }
            continue
        }

        if ([string]::Equals($p, $Ip, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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
        [string] $Path,
        [string] $Identity = ''
    )

    # Rate limiting disabled — 0 means no limit.
    if ($script:cfg.RateLimitRequests -le 0) {
        return [PSCustomObject]@{ Allowed = $true; RetryAfterSec = 0 }
    }

    # Exempt paths bypass rate limiting entirely.
    if ($script:cfg.RateLimitExemptPaths -contains $Path) {
        return [PSCustomObject]@{ Allowed = $true; RetryAfterSec = 0 }
    }

    # F4: key the table by API-key label (when RateLimitPerIdentity = $true AND the
    # request carries an authenticated label) or by client IP otherwise. Distinct
    # scopes ('id:' vs 'ip:') ensure label and IP namespaces never collide — important
    # because the table is shared and an IP literally named like a key label
    # ('default', say) must not aggregate with the label's quota.
    $rateLimitKey = if ($script:cfg.RateLimitPerIdentity -and
                       -not [string]::IsNullOrEmpty($Identity) -and
                       $Identity -ne 'anonymous' -and $Identity -ne '-') {
        "id:$Identity"
    } else {
        "ip:$ClientIP"
    }

    # Retrieve or create entry for this rate-limit key.
    # GetOrAdd requires a direct value — a ScriptBlock is stored as-is, not invoked.
    # Two threads may create $newEntry simultaneously, but GetOrAdd guarantees only one
    # is stored; both callers receive the same winner object.
    $newEntry = [PSCustomObject]@{
        Count        = [ref] 0L
        WindowStart  = [datetime]::UtcNow
        PenaltyUntil = [datetime]::MinValue   # MinValue = no active penalty
    }
    $entry = $script:rateLimitTable.GetOrAdd($rateLimitKey, $newEntry)

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
    FnAuthResolve    = ${function:Resolve-ApiKeyIdentity}
    FnAuditLog       = ${function:Write-AuditLog}
    FnSlowLog        = ${function:Write-SlowLog}
    FnScriptMeta     = ${function:Get-ScriptMetadata}
    FnPromMetrics    = ${function:Format-PromMetrics}
    FnRouteTable     = ${function:Get-RouteTable}
    FnResolveRoute   = ${function:Resolve-RoutedScript}
    FnOpenApiSchema  = ${function:Get-OpenApiSchemaForType}
    FnOpenApiSpec    = ${function:Build-OpenApiSpec}
    FnGetMime        = ${function:Get-MimeType}
    FnSendStatic     = ${function:Send-StaticFile}
    FnAddCors        = ${function:Add-CorsHeaders}
    FnCorsPreflight  = ${function:Send-CorsPreflight}
    FnIsScriptPath   = ${function:Test-IsScriptPath}
    FnScriptCT       = ${function:Get-ScriptContentType}
    FnInvScriptIP    = ${function:Invoke-ScriptInProcess}
    FnInvPhpCgi      = ${function:Invoke-PhpCgi}
    FnResolveError   = ${function:Resolve-ErrorPage}
    FnToApiXml       = ${function:ConvertTo-PoshApiXml}
    FnDirListing     = ${function:Send-DirectoryListing}
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
    ${function:Resolve-ApiKeyIdentity} = $shared.FnAuthResolve
    ${function:Write-AuditLog}   = $shared.FnAuditLog
    ${function:Write-SlowLog}    = $shared.FnSlowLog
    ${function:Get-ScriptMetadata} = $shared.FnScriptMeta
    ${function:Format-PromMetrics} = $shared.FnPromMetrics
    ${function:Get-RouteTable}   = $shared.FnRouteTable
    ${function:Resolve-RoutedScript} = $shared.FnResolveRoute
    ${function:Get-OpenApiSchemaForType} = $shared.FnOpenApiSchema
    ${function:Build-OpenApiSpec} = $shared.FnOpenApiSpec
    ${function:Get-MimeType}     = $shared.FnGetMime
    ${function:Send-StaticFile}  = $shared.FnSendStatic
    ${function:Add-CorsHeaders}  = $shared.FnAddCors
    ${function:Send-CorsPreflight} = $shared.FnCorsPreflight
    ${function:Test-IsScriptPath} = $shared.FnIsScriptPath
    ${function:Get-ScriptContentType} = $shared.FnScriptCT
    ${function:Invoke-ScriptInProcess} = $shared.FnInvScriptIP
    ${function:Invoke-PhpCgi}    = $shared.FnInvPhpCgi
    ${function:Resolve-ErrorPage} = $shared.FnResolveError
    ${function:ConvertTo-PoshApiXml} = $shared.FnToApiXml
    ${function:Send-DirectoryListing} = $shared.FnDirListing
    $script:cfg              = $shared.Cfg

    # Live .NET objects were injected via InitialSessionState.Variables — plain names.
    # Map them to $script: scope so injected functions (Write-Log, Test-RateLimit, etc.)
    # can access them via $script:logMutex / $script:rateLimitTable etc.
    $script:logMutex            = $logMutex
    $script:auditMutex          = $auditMutex
    $script:rateLimitTable      = $rateLimitTable
    $script:metadataCache       = $metadataCache
    $script:routeCache          = $routeCache
    $script:rateLimitedTotal    = $rateLimitedTotal
    $script:logDropsTotal       = $logDropsTotal
    $script:auditLogDropsTotal  = $auditLogDropsTotal
    $script:slowLogDropsTotal   = $slowLogDropsTotal
    # $semaphore, $startTime, $requestsTotal are used directly (no $script: needed)

    try {
        $req  = $context.Request
        $resp = $context.Response

        # Stash Accept-Encoding in $script: scope so Send-Response can pick it up without
        # every call site having to forward an extra parameter — the value is per-request
        # and per-runspace, so $script:-scope is safe here.
        $script:acceptEncoding = $req.Headers['Accept-Encoding']
        if ($null -eq $script:acceptEncoding) { $script:acceptEncoding = '' }
        # Same stashing pattern for the Accept header — used by Send-Response to decide
        # whether to substitute a CustomErrorPages HTML response for 4xx/5xx envelopes.
        $script:acceptType = $req.Headers['Accept']
        if ($null -eq $script:acceptType) { $script:acceptType = '' }
        # F3: per-request authentication identity. Default '-' (unknown/not-yet-resolved);
        # the auth block below sets it to a key label, 'basic:<user>', or 'anonymous'
        # for the auth-exempt routes. Flows into Write-Log, Test-RateLimit, Write-AuditLog.
        $script:authIdentity = '-'

        $clientIP    = $req.RemoteEndPoint.Address.ToString()
        $urlPath     = $req.Url.AbsolutePath
        $requestLine = '{0} {1}' -f $req.HttpMethod, $req.Url.PathAndQuery

        # Unique 8-character hex ID per request — correlates log entries to X-Request-Id response header.
        # Substring(0,8) of a GUID gives 32^8 combinations — sufficient for automation-scale traffic.
        $requestId = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # --------------------------------------------------------------
        # CORS preflight — OPTIONS is the only method besides GET/POST that the server
        # answers, and only when the request actually carries an Origin allowlisted in
        # CorsAllowedOrigins. Preflight short-circuits before auth and rate-limiting
        # so browsers can negotiate without an API key.
        # --------------------------------------------------------------
        if ($req.HttpMethod -eq 'OPTIONS') {
            $corsAllowed = $script:cfg.CorsAllowedOrigins -and $script:cfg.CorsAllowedOrigins.Count -gt 0
            if ($corsAllowed) {
                if (Send-CorsPreflight -Request $req -Response $resp -RequestId $requestId) {
                    Write-Log -ClientIP $clientIP -Request $requestLine -Status 'CORS PREFLIGHT' -ExitCode '-' -RequestId $requestId
                    return
                }
            }
            $body = New-JsonResponse -ExitCode 405 -Output '' -Err 'Method not allowed.'
            $resp.AddHeader('Allow', 'GET, POST')
            Send-Response -Response $resp -StatusCode 405 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-' -RequestId $requestId
            return
        }

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
        # CORS headers for non-preflight requests — added once here so every
        # subsequent Send-Response carries them (including auth failures).
        # --------------------------------------------------------------
        $null = Add-CorsHeaders -Request $req -Response $resp

        # --------------------------------------------------------------
        # Cookie / Session — opt-in via SessionEnabled. When the client did not
        # send a SessionCookieName cookie, a new GUID-based ID is minted and
        # echoed back via Set-Cookie. The cookie value (or the entire Cookie
        # header) is forwarded to webroot scripts via the POSH_SESSION_ID /
        # POSH_COOKIES env vars so scripts can implement their own session
        # logic — the server itself remains stateless.
        # --------------------------------------------------------------
        $rawCookieHeader = $req.Headers['Cookie']
        $sessionId       = $null
        if ($script:cfg.SessionEnabled) {
            $existingSid = $null
            try {
                $sessionCookie = $req.Cookies[$script:cfg.SessionCookieName]
                if ($null -ne $sessionCookie) { $existingSid = $sessionCookie.Value }
            } catch { }
            if ([string]::IsNullOrEmpty($existingSid)) {
                $sessionId = [Guid]::NewGuid().ToString('N')
                $secureAttr = if ($req.IsSecureConnection) { '; Secure' } else { '' }
                $resp.AddHeader('Set-Cookie', ('{0}={1}; Path=/; HttpOnly; SameSite=Lax{2}' -f $script:cfg.SessionCookieName, $sessionId, $secureAttr))
            } else {
                $sessionId = $existingSid
            }
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
            # F4: when RateLimitPerIdentity is on AND the request carries a valid X-Api-Key,
            # account against the key's label instead of the IP. Wrong / missing keys fall
            # back to per-IP — so brute-force attempts on the auth still hit the IP quota.
            # Resolve here without setting $script:authIdentity; the auth block below does
            # that authoritatively (same Resolve-ApiKeyIdentity call).
            $rateLimitIdentity = ''
            if ($script:cfg.RateLimitPerIdentity) {
                $earlyKey = $req.Headers['X-Api-Key']
                if (-not [string]::IsNullOrEmpty($earlyKey)) {
                    $earlyLabel = Resolve-ApiKeyIdentity -ProvidedKey $earlyKey
                    if ($null -ne $earlyLabel) { $rateLimitIdentity = $earlyLabel }
                }
            }
            $rl = Test-RateLimit -ClientIP $clientIP -Path $urlPath -Identity $rateLimitIdentity

            if (-not $rl.Allowed -and $script:cfg.RateLimitMode -eq 'queue') {
                # Queue mode: poll until the window resets or timeout expires.
                # Use Ticks arithmetic — [datetime] comparison operators (op_LessThan) and
                # .AddSeconds() fail in RunspacePool Runspace contexts on PS 7.x.
                $queueDeadlineTicks = [datetime]::UtcNow.Ticks + ($script:cfg.RateLimitQueueTimeoutSec * [timespan]::TicksPerSecond)
                while (-not $rl.Allowed -and [datetime]::UtcNow.Ticks -lt $queueDeadlineTicks) {
                    Start-Sleep -Milliseconds 200
                    $rl = Test-RateLimit -ClientIP $clientIP -Path $urlPath -Identity $rateLimitIdentity
                }
            }

            if (-not $rl.Allowed) {
                $body = New-JsonResponse -ExitCode 429 -Output '' -Err 'Too many requests. Please slow down.'
                $resp.AddHeader('Retry-After', [string]$rl.RetryAfterSec)
                Send-Response -Response $resp -StatusCode 429 -Body $body -RequestId $requestId
                $rlIdentity = if (-not [string]::IsNullOrEmpty($rateLimitIdentity)) { $rateLimitIdentity } else { '-' }
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'RATE LIMITED' -ExitCode '-' -RequestId $requestId -Identity $rlIdentity
                Write-AuditLog -EventName 'RATE_LIMITED' -Identity $rlIdentity -ClientIP $clientIP -Path $urlPath -Detail ("retryAfter={0}" -f $rl.RetryAfterSec)
                $null = [System.Threading.Interlocked]::Increment($script:rateLimitedTotal)
                return
            }
        }

        # --------------------------------------------------------------
        # Authentication — mode-aware. /health and /metrics are intentionally open
        # (monitoring tools must be able to scrape without credentials).
        # AuthMode = 'ApiKey' (default): X-Api-Key header required.
        # AuthMode = 'Basic':            Authorization: Basic <base64> required.
        # AuthMode = 'Both':             either X-Api-Key OR Authorization: Basic accepted.
        # Same generic 401 message regardless of which credential was wrong, so the
        # response does not leak which mechanism the server is actually checking.
        # WWW-Authenticate is added on Basic/Both so browsers display a login dialog.
        # --------------------------------------------------------------
        # Auth-exempt routes mark the identity as 'anonymous' so log + rate-limit
        # downstream can still attribute the request meaningfully. The list is
        # configurable via $cfg.AuthExemptPaths so operators can add custom
        # public endpoints (e.g. /version, /robots.txt) without code edits.
        $authExempt = @($script:cfg.AuthExemptPaths)
        if ($authExempt -contains $urlPath) {
            $script:authIdentity = 'anonymous'
        } else {
            $authMode    = $script:cfg.AuthMode
            $authPassed  = $false

            # IMPORTANT: PowerShell's -eq operator on strings is case-INSENSITIVE by default.
            # Credentials MUST be compared case-sensitively. [string]::Equals with
            # StringComparison.Ordinal is explicit and ordinal-binary.
            #
            # Multi-key API auth (F3): Resolve-ApiKeyIdentity walks $cfg.ApiKeys and returns
            # the matching label (or $null). Backward-compatible: when ApiKeys is empty,
            # the BC fallback in startup populates it with @{ 'default' = $cfg.ApiKey }.
            if ($authMode -eq 'ApiKey' -or $authMode -eq 'Both') {
                $providedKey  = $req.Headers['X-Api-Key']
                $matchedLabel = Resolve-ApiKeyIdentity -ProvidedKey $providedKey
                if ($null -ne $matchedLabel) {
                    $authPassed = $true
                    $script:authIdentity = $matchedLabel
                }
            }
            if (-not $authPassed -and ($authMode -eq 'Basic' -or $authMode -eq 'Both')) {
                $authHeader = $req.Headers['Authorization']
                if ($authHeader -and $authHeader.StartsWith('Basic ', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $b64 = $authHeader.Substring(6).Trim()
                    try {
                        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
                        $colonIx = $decoded.IndexOf(':')
                        if ($colonIx -ge 0) {
                            $providedUser = $decoded.Substring(0, $colonIx)
                            $providedPass = $decoded.Substring($colonIx + 1)
                            if ([string]::Equals($providedUser, $script:cfg.BasicAuthUser, [System.StringComparison]::Ordinal) -and
                                [string]::Equals($providedPass, $script:cfg.BasicAuthPass, [System.StringComparison]::Ordinal)) {
                                $authPassed = $true
                                # User name (NOT password) flows into identity for audit attribution.
                                $script:authIdentity = "basic:$providedUser"
                            }
                        }
                    } catch { } # malformed base64 — treat as auth failure, no diagnostic leak
                }
            }

            if (-not $authPassed) {
                $body = New-JsonResponse -ExitCode 401 -Output '' -Err 'Unauthorized.'
                if ($authMode -eq 'Basic' -or $authMode -eq 'Both') {
                    $resp.AddHeader('WWW-Authenticate', ('Basic realm="{0}"' -f $script:cfg.BasicAuthRealm))
                }
                Send-Response -Response $resp -StatusCode 401 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'UNAUTHORIZED' -ExitCode '-' -RequestId $requestId -Identity '-'
                # F5: audit security-relevant denial — operators can correlate with brute-force attempts.
                Write-AuditLog -EventName 'AUTH_FAIL' -ClientIP $clientIP -Path $urlPath -Detail ("mode=$authMode")
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
        # GET /metrics -> server metrics (auth-exempt, see exempt-route block above).
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
            $logDrops    = [System.Threading.Interlocked]::Read($script:logDropsTotal)
            $auditDrops  = [System.Threading.Interlocked]::Read($script:auditLogDropsTotal)
            $slowDrops   = [System.Threading.Interlocked]::Read($script:slowLogDropsTotal)
            $body        = [ordered]@{
                uptime              = $uptimeStr
                requestsTotal       = $total
                rateLimitedTotal    = $rateLimited
                logDropsTotal       = $logDrops
                auditLogDropsTotal  = $auditDrops
                slowLogDropsTotal   = $slowDrops
            } | ConvertTo-Json -Compress
            Send-Response -Response $resp -StatusCode 200 -Body $body -RequestId $requestId
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METRICS' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # F8: GET /metrics-prom -> Prometheus text-format scrape endpoint.
        # Same auth-exempt treatment as /metrics so scrapers don't need credentials.
        # --------------------------------------------------------------
        if ($urlPath -eq '/metrics-prom') {
            if (-not $script:cfg.PromMetricsEnabled) {
                $body = New-JsonResponse -ExitCode 404 -Output '' -Err 'Prometheus metrics endpoint disabled.'
                Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                return
            }
            $promBody = Format-PromMetrics
            Send-Response -Response $resp -StatusCode 200 -Body $promBody -RequestId $requestId -ContentType 'text/plain; version=0.0.4; charset=utf-8'
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METRICS-PROM' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # F10: GET /openapi.json -> auto-generated OpenAPI 3.1 spec for the
        # current webroot. Auth-exempt so tools (Swagger UI, Postman) can
        # discover the API without credentials.
        # --------------------------------------------------------------
        if ($urlPath -eq '/openapi.json') {
            if (-not $script:cfg.OpenApiEnabled) {
                $body = New-JsonResponse -ExitCode 404 -Output '' -Err 'OpenAPI endpoint disabled.'
                Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                return
            }
            $specBody = Build-OpenApiSpec
            Send-Response -Response $resp -StatusCode 200 -Body $specBody -RequestId $requestId -ContentType 'application/json; charset=utf-8'
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'OPENAPI' -ExitCode '-' -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # PHP-CGI branch (opt-in via PhpCgiEnabled).
        # Routes URLs ending in .php to an external php-cgi.exe with the standard
        # CGI/1.1 environment. POST bodies are streamed to PHP's stdin.
        # Security: legacy PoSH refused PHP scripts under \Windows\ — kept here.
        # --------------------------------------------------------------
        if ($script:cfg.PhpCgiEnabled -and $urlPath.EndsWith('.php', [System.StringComparison]::OrdinalIgnoreCase)) {

            if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'POST') {
                $body = New-JsonResponse -ExitCode 405 -Output '' -Err 'PHP-CGI handlers accept only GET and POST.'
                $resp.AddHeader('Allow', 'GET, POST')
                Send-Response -Response $resp -StatusCode 405 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-' -RequestId $requestId
                return
            }

            # Path-traversal — rooted at WebRoot (PHP shares the webroot with .ps1 endpoints).
            $phpRel  = $urlPath.TrimStart('/').Replace('/', '\')
            $phpFull = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.WebRoot $phpRel))
            $rootFull = [System.IO.Path]::GetFullPath($script:cfg.WebRoot)
            if (-not ($phpFull -eq $rootFull -or $phpFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
                $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Access denied.'
                Send-Response -Response $resp -StatusCode 403 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-' -RequestId $requestId
                return
            }

            # Defense in depth: never execute PHP files that resolve under the Windows folder —
            # this is the same hardening the legacy PoSH Server applied.
            if ($phpFull -match '(?i)\\Windows\\') {
                $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Access denied.'
                Send-Response -Response $resp -StatusCode 403 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-' -RequestId $requestId
                return
            }

            if (-not (Test-Path -LiteralPath $phpFull -PathType Leaf)) {
                $body = New-JsonResponse -ExitCode 404 -Output '' -Err "Script not found: $urlPath"
                Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                return
            }

            $phpRes = Invoke-PhpCgi -Request $req -ScriptPath $phpFull -TimeoutSec $script:cfg.PhpCgiTimeoutSec
            $null = [System.Threading.Interlocked]::Increment($requestsTotal)

            $resp.StatusCode      = $phpRes.StatusCode
            $resp.ContentType     = $phpRes.ContentType
            $resp.ContentLength64 = $phpRes.Body.Length
            foreach ($hk in $phpRes.Headers.Keys) {
                try { $resp.AddHeader($hk, [string]$phpRes.Headers[$hk]) } catch { }
            }
            if ($requestId) { $resp.AddHeader('X-Request-Id', $requestId) }
            try { $resp.OutputStream.Write($phpRes.Body, 0, $phpRes.Body.Length) } catch { }
            try { $resp.OutputStream.Close() } catch { }

            $statusText = if ($phpRes.TimedOut) { 'TIMEOUT' } elseif ($phpRes.StatusCode -ge 400) { 'ERROR' } else { 'OK PHP' }
            Write-Log -ClientIP $clientIP -Request $requestLine -Status $statusText -ExitCode "$($phpRes.StatusCode)" -RequestId $requestId
            return
        }

        # --------------------------------------------------------------
        # F9: Path-Placeholders — if the URL has no script extension but matches a
        # placeholder route (e.g. /users/123 → webroot/users/[id].ps1), treat it as
        # a script request. This runs BEFORE the static branch so REST-style routes
        # do not fall into static-file handling. $routedFromPath is consumed in the
        # script branch below to skip the exact-match Test-Path step.
        $routedFromPath = $null
        if ($script:cfg.PathPlaceholders -and -not (Test-IsScriptPath -Path $urlPath)) {
            $routedFromPath = Resolve-RoutedScript -UrlPath $urlPath
        }

        # Non-script path → static file branch (opt-in via StaticServingEnabled).
        # "Script path" = any URL ending in one of the extensions registered in
        # ScriptExtensionMap (.ps1, .psxml, .posh, .psapi by default).
        # POST requests to non-script paths are always rejected — static content is
        # GET-only by design and POST would otherwise silently no-op.
        # When StaticServingEnabled is off, fall back to the legacy HTTP 400.
        # --------------------------------------------------------------
        if (-not (Test-IsScriptPath -Path $urlPath) -and $null -eq $routedFromPath) {

            if (-not $script:cfg.StaticServingEnabled) {
                $body = New-JsonResponse -ExitCode 400 -Output '' -Err "Only registered script extensions are allowed. Requested: $urlPath"
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
            # If none exist AND DirectoryBrowsing is enabled, render an HTML listing.
            # Otherwise fall through to a 404.
            $isDir = Test-Path -LiteralPath $staticFull -PathType Container
            if ($isDir -or $urlPath.EndsWith('/')) {
                $resolvedDefault = $null
                foreach ($candidate in $script:cfg.DefaultDocuments) {
                    $probe = Join-Path $staticFull $candidate
                    if (Test-Path -LiteralPath $probe -PathType Leaf) { $resolvedDefault = $probe; break }
                }
                if ($null -eq $resolvedDefault) {
                    if ($script:cfg.DirectoryBrowsing -and $isDir) {
                        $dirRes = Send-DirectoryListing -Response $resp -DirPath $staticFull -UrlPath $urlPath -RequestId $requestId
                        $null   = [System.Threading.Interlocked]::Increment($requestsTotal)
                        Write-Log -ClientIP $clientIP -Request $requestLine -Status $dirRes.Reason -ExitCode "$($dirRes.StatusCode)" -RequestId $requestId
                        return
                    }
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
        # Script file must exist. F9: when an exact match fails, fall back to the
        # placeholder route table — either the pre-resolved hit from the route
        # block above (URL had no script extension) OR a fresh resolve for URLs
        # that DO end in a script extension (e.g. literal /users/[id].ps1).
        # Captured placeholder values flow into $scriptParams below.
        # --------------------------------------------------------------
        $routePlaceholders = $null
        if ($null -ne $routedFromPath) {
            # Pre-resolved from the no-script-extension path above; bypass the
            # exact-match Test-Path step (path came from file enumeration).
            $resolvedPath = $routedFromPath.ScriptPath
            $routePlaceholders = $routedFromPath.Placeholders
        } elseif (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $routed = Resolve-RoutedScript -UrlPath $urlPath
            if ($null -ne $routed) {
                $resolvedPath = $routed.ScriptPath
                $routePlaceholders = $routed.Placeholders
            } else {
                $body = New-JsonResponse -ExitCode 404 -Output '' -Err "Script not found: $urlPath"
                Send-Response -Response $resp -StatusCode 404 -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-' -RequestId $requestId
                return
            }
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
        $jsonFilePath  = ''
        $bodyResult    = $null
        $scriptParams  = @{}

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
                    415     { 'Content-Type must be one of the AcceptedContentTypes (application/json or application/x-www-form-urlencoded by default).' }
                    400     { 'Invalid request body.' }
                    default { 'Request error.' }
                }
                $body = New-JsonResponse -ExitCode $bodyResult.Error -Output '' -Err $errMsg
                Send-Response -Response $resp -StatusCode $bodyResult.Error -Body $body -RequestId $requestId
                Write-Log -ClientIP $clientIP -Request $requestLine -Status "HTTP $($bodyResult.Error)" -ExitCode '-' -RequestId $requestId
                return
            }

            $jsonFilePath = Save-PostJson -RawJson $bodyResult.RawJson -RequestId $requestId
        } else {
            $scriptParams = Get-QueryParams -QueryString $req.QueryString
        }

        # F9: when a placeholder route matched, merge the captured placeholders into the
        # script params alongside (or in addition to) query-string args. Placeholders win
        # on key collision — the URL is the authoritative source for those names.
        if ($null -ne $routePlaceholders) {
            foreach ($k in $routePlaceholders.Keys) {
                $scriptParams[$k] = $routePlaceholders[$k]
            }
        }

        # Env vars / context vars passed into the child process or runspace.
        $scriptEnvVars = @{}
        if (-not [string]::IsNullOrEmpty($rawCookieHeader)) { $scriptEnvVars['POSH_COOKIES']    = $rawCookieHeader }
        if (-not [string]::IsNullOrEmpty($sessionId))       { $scriptEnvVars['POSH_SESSION_ID'] = $sessionId }

        $contextVars = $null
        if ($script:cfg.ExecutionMode -eq 'InProcess' -and $script:cfg.InjectContextVars) {
            $contextVars = @{
                PoSHQuery   = $scriptParams
                PoSHCookies = $rawCookieHeader
                PoSHHeaders = @{}
            }
            foreach ($h in $req.Headers.AllKeys) { $contextVars.PoSHHeaders[$h] = $req.Headers[$h] }
            if ($null -ne $bodyResult -and $bodyResult.RawJson) {
                try {
                    $contextVars.PoSHPost = $bodyResult.RawJson | ConvertFrom-Json -AsHashtable -Depth 10
                } catch {
                    $contextVars.PoSHPost = $bodyResult.RawJson
                }
            } else {
                $contextVars.PoSHPost = @{}
            }
        }

        # F6: stopwatch around the script invocation so the elapsed time can flow into
        # Write-Log (new -ElapsedMs column) AND the slow-request log when over threshold.
        $execStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($script:cfg.ExecutionMode -eq 'InProcess') {
            $result = Invoke-ScriptInProcess -ScriptPath $resolvedPath -Params $scriptParams -TimeoutSec $script:cfg.ScriptTimeoutSec -JsonFilePath $jsonFilePath -ContextVars $contextVars
        } else {
            $result = Invoke-Script -ScriptPath $resolvedPath -Params $scriptParams -TimeoutSec $script:cfg.ScriptTimeoutSec -JsonFilePath $jsonFilePath -EnvVars $scriptEnvVars
        }
        $execStopwatch.Stop()
        $execElapsedMs = [int]$execStopwatch.ElapsedMilliseconds

        # Script request completed — increment counter atomically (thread-safe).
        $null = [System.Threading.Interlocked]::Increment($requestsTotal)

        $httpStatus = if     ($result.TimedOut)       { 504 }
                      elseif ($result.ExitCode -eq 0) { 200 }
                      else                            { 500 }

        # Response format depends on the script extension:
        #   .ps1   → JSON envelope { exitCode, output, error } (legacy behavior).
        #   .psxml → raw stdout passed through, Content-Type 'text/xml' (PoSH parity).
        #   .posh  → raw stdout, 'text/html'.
        #   .psapi → raw stdout, 'application/xml'.
        # On non-zero exit, the alt-extension paths emit the error stream as body —
        # the user-supplied Content-Type still applies, so callers see structured
        # error text rather than a generic JSON envelope. JSON envelope is preserved
        # for .ps1 because existing clients depend on it.
        $scriptContentType = Get-ScriptContentType -Path $urlPath
        if ([string]::IsNullOrEmpty($scriptContentType)) {
            $body = New-JsonResponse -ExitCode $result.ExitCode -Output $result.Output -Err $result.Error
            Send-Response -Response $resp -StatusCode $httpStatus -Body $body -RequestId $requestId
        } else {
            $rawBody = if ($result.TimedOut) {
                'Script execution timed out.'
            } elseif ($result.ExitCode -ne 0 -and -not [string]::IsNullOrEmpty($result.Error)) {
                $result.Error
            } else {
                $result.Output
            }
            Send-Response -Response $resp -StatusCode $httpStatus -Body $rawBody -RequestId $requestId -ContentType $scriptContentType
        }

        $statusText = if     ($result.TimedOut)       { 'TIMEOUT' }
                      elseif ($result.ExitCode -eq 0) { 'OK' }
                      else                            { 'ERROR' }
        Write-Log -ClientIP $clientIP -Request $requestLine -Status $statusText -ExitCode "$($result.ExitCode)" -RequestId $requestId -ElapsedMs $execElapsedMs

        # F6: separately log to slow.log when the threshold is configured and crossed.
        Write-SlowLog -ElapsedMs $execElapsedMs -ClientIP $clientIP -Identity $script:authIdentity -Request $requestLine -ExitCode "$($result.ExitCode)" -RequestId $requestId

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
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('semaphore',         $semaphore,                  $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('startTime',         $startTime,                  $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('requestsTotal',     $script:requestsTotal,       $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('logMutex',          $script:logMutex,            $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('auditMutex',        $script:auditMutex,          $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('rateLimitTable',    $script:rateLimitTable,      $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('rateLimitedTotal',  $script:rateLimitedTotal,    $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('metadataCache',     $script:metadataCache,       $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('routeCache',        $script:routeCache,          $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('logDropsTotal',     $script:logDropsTotal,       $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('auditLogDropsTotal',$script:auditLogDropsTotal,  $null),
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('slowLogDropsTotal', $script:slowLogDropsTotal,   $null)
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
# Background jobs — each `$cfg.BackgroundJobs` entry runs in its own dedicated
# runspace + Process. Output is appended to `$cfg.JobsLogFile` (separate from
# the request log so background activity does not pollute request traces).
# Jobs are tracked in $bgJobInstances so the shutdown handler can stop them
# cleanly. The loop is intentionally simple — the user wanted feature parity
# with the legacy PoSH Server's `-CustomJob`, not a full task scheduler.
# ---------------------------------------------------------------------------
$bgJobInstances = [System.Collections.Generic.List[object]]::new()

if ($cfg.BackgroundJobs -and $cfg.BackgroundJobs.Count -gt 0) {
    $bgScriptBlock = {
        param([string] $Path, [int] $Interval, [string] $LogFile, [string] $PwshExeLocal, [string] $MutexKey, [int] $MutexWaitMs)

        # Defensive: an empty $LogFile would silently swallow every write. Bail out so
        # the failure surfaces immediately. This also marks $LogFile as referenced at
        # the outer-block scope — PSScriptAnalyzer does not follow nested scriptblock
        # closures and would otherwise flag the parameter as unused. Same trick for
        # $MutexWaitMs (consumed by the nested $writeLog closure below).
        if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
        if ($MutexWaitMs -le 0) { $MutexWaitMs = 500 }

        # Named Mutex serialises all writes to JobsLogFile across the per-job runspaces.
        # 'Global\' makes it visible to every process / runspace on the box. Keyed on
        # the JobsLogFile path hash (passed in as $MutexKey) so multi-instance posh
        # deployments writing to different jobs.log files do not contend.
        # Acquired with a short WaitOne so a stuck holder cannot deadlock the job forever.
        $jobsMutex = [System.Threading.Mutex]::new($false, "Global\PoshWebserverJobsLog-$MutexKey")

        # Helper closure so each log call goes through the same mutex protocol.
        # Drops the line on timeout — without holding the mutex, parallel writes
        # would interleave bytes (cf. the request-log path).
        $writeLog = {
            param([string] $LogText)
            $acquired = $false
            try {
                $acquired = $jobsMutex.WaitOne($MutexWaitMs)
                if ($acquired) {
                    Add-Content -LiteralPath $LogFile -Value $LogText -Encoding UTF8
                }
            } catch { } finally {
                try { if ($acquired) { $jobsMutex.ReleaseMutex() } } catch { }
            }
        }

        try {
            while ($true) {
                $startTime = Get-Date
                try {
                    $psi = [System.Diagnostics.ProcessStartInfo]::new()
                    $psi.FileName               = $PwshExeLocal
                    $psi.UseShellExecute        = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError  = $true
                    $psi.CreateNoWindow         = $true
                    foreach ($a in @('-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path)) {
                        $null = $psi.ArgumentList.Add($a)
                    }
                    $proc = [System.Diagnostics.Process]::new()
                    $proc.StartInfo = $psi
                    $null = $proc.Start()
                    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
                    $stderrTask = $proc.StandardError.ReadToEndAsync()
                    $null = $proc.WaitForExit()
                    # stdout is drained but intentionally discarded — reading it is required to
                    # prevent the child from blocking on a full pipe buffer; the actual content
                    # is only of interest in stderr (errors) and the exit code.
                    $null   = $stdoutTask.GetAwaiter().GetResult()
                    $stderr = $stderrTask.GetAwaiter().GetResult()
                    $exitCode = $proc.ExitCode
                    $proc.Dispose()

                    $logLine = '{0} | JOB | {1} | EXIT:{2}' -f $startTime.ToString('yyyy-MM-dd HH:mm:ss'), $Path, $exitCode
                    & $writeLog $logLine
                    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                        foreach ($line in $stderr -split "(`r`n|`n)") {
                            if (-not [string]::IsNullOrWhiteSpace($line)) {
                                & $writeLog ('  STDERR: {0}' -f $line.TrimEnd())
                            }
                        }
                    }
                } catch {
                    $errLine = '{0} | JOB ERROR | {1} | {2}' -f $startTime.ToString('yyyy-MM-dd HH:mm:ss'), $Path, $_
                    & $writeLog $errLine
                }
                Start-Sleep -Seconds $Interval
            }
        } finally {
            try { $jobsMutex.Dispose() } catch { }
        }
    }

    # Stable 16-hex-char key per JobsLogFile path — used to namespace the
    # jobs-log mutex so two posh instances writing to different jobs.log
    # files don't share the same kernel object.
    $jobsMutexKey = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string]$cfg.JobsLogFile).ToLowerInvariant()))
    ).Replace('-', '').Substring(0, 16)

    foreach ($jobDef in $cfg.BackgroundJobs) {
        if (-not $jobDef.Path -or -not $jobDef.IntervalSec -or $jobDef.IntervalSec -le 0) {
            Write-StartupLog "WARN: skipping malformed BackgroundJob entry: $($jobDef | ConvertTo-Json -Compress)"
            continue
        }
        if (-not (Test-Path -LiteralPath $jobDef.Path -PathType Leaf)) {
            Write-StartupLog "WARN: BackgroundJob script not found: $($jobDef.Path)"
            continue
        }
        try {
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $rs.Open()
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.Runspace = $rs
            $null = $ps.AddScript($bgScriptBlock).AddArgument($jobDef.Path).AddArgument([int]$jobDef.IntervalSec).AddArgument($cfg.JobsLogFile).AddArgument($cfg.PwshExe).AddArgument($jobsMutexKey).AddArgument([int]$cfg.LogMutexTimeoutMs)
            $handle = $ps.BeginInvoke()
            $null   = $bgJobInstances.Add([PSCustomObject]@{ Ps = $ps; Rs = $rs; Handle = $handle; Path = $jobDef.Path; Interval = $jobDef.IntervalSec })
            Write-StartupLog ("BackgroundJob started: {0} every {1}s" -f $jobDef.Path, $jobDef.IntervalSec)
        } catch {
            Write-StartupLog ("ERROR: BackgroundJob start failed for {0}: {1}" -f $jobDef.Path, $_)
        }
    }
}

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
        # Paths listed in $cfg.IpFilterExemptPaths bypass both BlockedIPs and
        # AllowedIPs (default keeps /health reachable from external monitoring).
        # BlockedIPs is checked first — an IP on both lists is always blocked.
        # AllowedIPs empty = all IPs pass; non-empty = only listed IPs pass.
        # Direct [System.IO.File]::AppendAllText for logging — Write-Log lives in
        # the Runspace scope and is not available in the main thread.
        # ---------------------------------------------------------------------------
        $reqUrlPath = $context.Request.Url.AbsolutePath
        $ipFilterExempt = @($cfg.IpFilterExemptPaths)
        if (($ipFilterExempt -notcontains $reqUrlPath) -and
            ($cfg.BlockedIPs.Count -gt 0 -or $cfg.AllowedIPs.Count -gt 0)) {

            $reqClientIP = $context.Request.RemoteEndPoint.Address.ToString()
            $ipDenied    = $false
            $ipStatus    = ''

            if (Test-IpMatch -Ip $reqClientIP -Patterns $cfg.BlockedIPs) {
                $ipDenied = $true
                $ipStatus = 'IP BLOCKED'
            } elseif ($cfg.AllowedIPs.Count -gt 0 -and -not (Test-IpMatch -Ip $reqClientIP -Patterns $cfg.AllowedIPs)) {
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
                # Acquire the same Mutex Write-Log uses in the RunspacePool runspaces so
                # IP-filter log lines do not interleave with worker writes. Short timeout
                # so a stuck holder cannot block the main thread for long; the line is
                # dropped on contention (still echoed to stdout below).
                $ipMutexHeld = $false
                try {
                    if (-not (Test-Path -LiteralPath $cfg.LogDir -PathType Container)) {
                        $null = New-Item -ItemType Directory -Path $cfg.LogDir -Force
                    }
                    $ipMutexHeld = $script:logMutex.WaitOne(500)
                    [System.IO.File]::AppendAllText($ipLogFile, $ipLogLine + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
                } catch { } finally {
                    try { if ($ipMutexHeld) { $script:logMutex.ReleaseMutex() } } catch { }
                }
                Write-Output $ipLogLine
                # F5: audit IP rejections so the audit log captures all main-thread denials too.
                # Identity is '-' because auth never runs for blocked IPs. Write-AuditLog is in
                # scope here at script-level; it no-ops when AuditLogEnabled is $false.
                Write-AuditLog -EventName 'IP_BLOCKED' -ClientIP $reqClientIP -Path $reqUrlPath -Detail $ipStatus
                continue
            }
        }

        # Global throttle — enforce MinRequestIntervalSec between dispatched requests.
        # Checked in the main thread before any runspace is started — RunspacePool stays cold.
        # Paths in $cfg.GlobalThrottleExemptPaths bypass this (defaults to the
        # monitoring/discovery routes so Prometheus + Swagger UI are never throttled).
        # Stopwatch::GetTimestamp() / Frequency gives elapsed seconds as a plain long division —
        # no [datetime] operators, no .NET method dispatch issues.
        # $lastDispatchTick is only updated when the request is allowed through —
        # a 429 response must not reset the clock (a burst would otherwise push the deadline
        # forward indefinitely and block all subsequent legitimate requests).
        $globalThrottleExempt = @($cfg.GlobalThrottleExemptPaths)
        if ($cfg.MinRequestIntervalSec -gt 0 -and
            ($globalThrottleExempt -notcontains $reqUrlPath)) {

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
    # Stop background jobs — their script blocks loop forever, so Stop() is the only way out.
    try {
        if ($null -ne $bgJobInstances) {
            foreach ($bg in $bgJobInstances) {
                try { $bg.Ps.Stop()        } catch { }
                try { $bg.Ps.Dispose()     } catch { }
                try { $bg.Rs.Dispose()     } catch { }
            }
        }
    } catch { }
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
    try { $script:auditMutex.Dispose()                    } catch { }
    try { Write-StartupLog 'Web server stopped.'          } catch { }
    try { Write-Output 'Web server stopped.'              } catch { }
}
