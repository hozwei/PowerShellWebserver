# Configuration

## Configuration Sources

posh resolves its configuration in two layers:

1. **`config.psd1`** — the runtime source of truth. **Mandatory** at startup. Generated per install by `tools\Initialize-PoshConfig.ps1`, gitignored, contains every key with the install's chosen value.
2. **Inline `$cfg`** in `Start-WebServer.ps1` — the upstream schema and fallback. Supplies a default for any key missing from `config.psd1` so old configs keep working when new versions add keys.

The server hard-fails at startup if `config.psd1` does not exist. The inline `$cfg` block is never consulted on its own — it only fills in the gaps.

### Generating config.psd1

Run once per install:

```powershell
.\tools\Initialize-PoshConfig.ps1
```

The script asks `Start-WebServer.ps1 -DumpConfig` for its current inline defaults, then writes a grouped, human-readable `config.psd1` next to the server script. Re-running the script aborts unless `-Force` is passed; with `-Force`, the previous file is moved to `config.psd1.bak.<timestamp>` before the new one is written.

`Register-ScheduledTask.ps1` invokes `Initialize-PoshConfig.ps1` automatically during installation when no `config.psd1` exists yet — fresh installs are wired up end-to-end.

### Editing config.psd1

Two supported paths:

- `.\Edit-PoshSettings.ps1` — browser-based editor with validation, diff preview, and backups (recommended for junior admins)
- Direct edit (`notepad`, VSCode, …) — `Import-PowerShellDataFile` only parses static data, so the file is safe to keep in version-controlled local notes; a syntactically broken `.psd1` causes a hard startup failure with a clear error message.

```powershell
# C:\posh\config.psd1 — excerpt
@{
    HttpPort               = 18080
    LogRetentionDays       = 7
    RateLimitPerIdentity   = $true
    AuditLogEnabled        = $true
    SlowRequestThresholdMs = 5000
    # ...all other keys stay at their generated defaults
}
```

Override the file location with the `-ConfigFile` parameter on the server:

```powershell
.\Start-WebServer.ps1 -ConfigFile 'D:\posh\custom.psd1'
```

**Inline file location:** `C:\posh\Start-WebServer.ps1`

**Minimal example (defaults as shipped):**

```powershell
$baseDir = 'C:\posh'

$cfg = @{
    HttpsEnabled             = $HttpsEnabled.IsPresent
    HttpPort                 = $HttpPort
    HttpsPort                = $HttpsPort
    WebRoot                  = Join-Path $baseDir 'webroot'
    LogDir                   = Join-Path $baseDir 'logs'
    PwshExe                  = (Get-Process -Id $PID).MainModule.FileName
    ApiKey                   = $env:POSH_API_KEY
    ScriptTimeoutSec         = 300
    MaxConcurrent            = 10
    LogRetentionDays         = 180
    PostJsonDir              = Join-Path $baseDir 'postjson'
    PostJsonRetentionDays    = 30
    MaxRequestBodyBytes      = 20MB
    RateLimitRequests        = 100
    RateLimitWindowSec       = 600
    RateLimitPenaltySec      = 300
    RateLimitMode            = 'reject'
    RateLimitQueueTimeoutSec = 10
    RateLimitExemptPaths     = @('/health', '/metrics')
    MinRequestIntervalSec    = 1
    AllowedIPs               = @()
    BlockedIPs               = @()
    GzipEnabled              = $true
    GzipMinBytes             = 1024
    GzipMimeTypes            = @('application/json', 'application/xml', 'application/javascript', 'text/html', 'text/plain', 'text/css', 'text/javascript', 'text/xml')
    LogIntegrityHash         = $false
    LogSchedule              = 'Daily'
    LogFormat                = 'Native'
    StaticServingEnabled     = $false
    StaticRoot               = ''     # empty = use WebRoot
    DefaultDocuments         = @('index.html', 'index.htm')
    StaticCacheHeaders       = $true
    BlockedMimeTypes         = @()
    # MimeTypeMap left at defaults — ~50 entries covering text/web/image/audio/video/font/archive types
    SessionEnabled           = $false
    SessionCookieName        = 'POSH-Session-Id'
    CorsAllowedOrigins       = @()
    CorsAllowedMethods       = 'GET, POST, OPTIONS'
    CorsAllowedHeaders       = 'X-Api-Key, Content-Type, Authorization'
    CorsAllowCredentials     = $false
    CorsMaxAgeSec            = 600
    AcceptedContentTypes     = @('application/json', 'application/x-www-form-urlencoded')
    AuthMode                 = 'ApiKey'
    BasicAuthUser            = $env:POSH_BASIC_USER
    BasicAuthPass            = $env:POSH_BASIC_PASS
    BasicAuthRealm           = 'posh'
    ExecutionMode            = 'Subprocess'
    InjectContextVars        = $false
    ScriptExtensionMap       = @{ '.ps1' = ''; '.psxml' = 'text/xml; charset=utf-8'; '.posh' = 'text/html; charset=utf-8'; '.psapi' = 'application/xml; charset=utf-8' }
    PhpCgiEnabled            = $false
    PhpCgiPath               = ''
    PhpCgiTimeoutSec         = 60
    CustomErrorPages         = $false
    ErrorPagesRoot           = ''     # empty = '<WebRoot>\_error'
    Prefixes                 = @()    # empty = build from HttpPort/HttpsPort with '+' wildcard binding
    BackgroundJobs           = @()
    JobsLogFile              = ''     # empty = '<LogDir>\jobs.log'
    DirectoryBrowsing        = $false
    DirectoryBrowsingHidden  = @('_error', '.git', '.gitignore')
}
```

**Complete example with non-default values:**

```powershell
$baseDir = 'D:\automation\posh'

$cfg = @{
    HttpsEnabled             = $HttpsEnabled.IsPresent
    HttpPort                 = $HttpPort
    HttpsPort                = $HttpsPort
    WebRoot                  = Join-Path $baseDir 'webroot'
    LogDir                   = Join-Path $baseDir 'logs'
    PwshExe                  = (Get-Process -Id $PID).MainModule.FileName
    ApiKey                   = $env:POSH_API_KEY
    ScriptTimeoutSec         = 300
    MaxConcurrent            = 5
    LogRetentionDays         = 30
    PostJsonDir              = Join-Path $baseDir 'postjson'
    PostJsonRetentionDays    = 14
    MaxRequestBodyBytes      = 5MB
    RateLimitRequests        = 30
    RateLimitWindowSec       = 600
    RateLimitPenaltySec      = 3600
    RateLimitMode            = 'queue'
    RateLimitQueueTimeoutSec = 5
    RateLimitExemptPaths     = @('/health', '/metrics')
    MinRequestIntervalSec    = 1
    AllowedIPs               = @('192.168.1.0', '192.168.1.1', '10.0.0.5')
    BlockedIPs               = @()
    GzipEnabled              = $true
    GzipMinBytes             = 2048
    GzipMimeTypes            = @('application/json', 'text/html', 'text/plain')
    LogIntegrityHash         = $true
    LogSchedule              = 'Hourly'
    LogFormat                = 'IIS-W3C'
    StaticServingEnabled     = $true
    StaticRoot               = 'D:\automation\posh\public'
    DefaultDocuments         = @('index.html', 'index.htm', 'home.html')
    StaticCacheHeaders       = $true
    BlockedMimeTypes         = @('video/', 'audio/')
    SessionEnabled           = $true
    SessionCookieName        = 'POSH-Session-Id'
    CorsAllowedOrigins       = @('https://app.example.com', 'https://admin.example.com')
    CorsAllowedMethods       = 'GET, POST, OPTIONS'
    CorsAllowedHeaders       = 'X-Api-Key, Content-Type, Authorization'
    CorsAllowCredentials     = $true
    CorsMaxAgeSec            = 600
    AcceptedContentTypes     = @('application/json')   # narrow gate: JSON only, reject form-encoded
    AuthMode                 = 'Both'                  # accept either X-Api-Key or Basic-Auth
    BasicAuthUser            = $env:POSH_BASIC_USER
    BasicAuthPass            = $env:POSH_BASIC_PASS
    BasicAuthRealm           = 'posh-admin'
    ExecutionMode            = 'InProcess'             # faster, less isolation — see PR-5 notes
    InjectContextVars        = $true                   # expose $PoSHQuery / $PoSHPost / $PoSHCookies / $PoSHHeaders to scripts
    PhpCgiEnabled            = $true
    PhpCgiPath               = 'C:\Program Files\PHP\v8.3\php-cgi.exe'
    PhpCgiTimeoutSec         = 30
    CustomErrorPages         = $true
    ErrorPagesRoot           = 'D:\automation\posh\public\_error'
    Prefixes                 = @('https://api.internal.example.com:443/', 'https://localhost:443/')
    BackgroundJobs           = @(
        @{ Path = 'D:\automation\posh\jobs\refresh-cache.ps1'; IntervalSec = 300 }
        @{ Path = 'D:\automation\posh\jobs\rotate-tokens.ps1'; IntervalSec = 3600 }
    )
    JobsLogFile              = 'D:\automation\posh\logs\jobs.log'
    DirectoryBrowsing        = $true
    DirectoryBrowsingHidden  = @('_error', '.git', '.gitignore', 'private')
}
```

> After editing `config.psd1` (or, more rarely, `Start-WebServer.ps1` itself for a new schema key), restart the Scheduled Task for changes to take effect:
> ```powershell
> Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
> Start-ScheduledTask -TaskName 'PowerShell-Webserver'
> ```

## Environment Variables

| Variable | Description |
|---|---|
| `POSH_API_KEY` | API key required in the `X-Api-Key` request header. Must be set as a `Machine`-scope system environment variable before the server starts. Set automatically by `Register-ScheduledTask.ps1`. The server refuses to start if this variable is empty or missing. |
| `POSH_CERT_THUMBPRINT` | Thumbprint of the certificate bound to the HTTPS port. Set automatically by `Register-ScheduledTask.ps1` after a successful `netsh` binding. Not a secret — used for diagnostics only. |
| `POSH_BASIC_USER` | Basic-Auth username. Required only when `$cfg.AuthMode` is `'Basic'` or `'Both'`. Must be set as a `Machine`-scope system environment variable before the server starts. |
| `POSH_BASIC_PASS` | Basic-Auth password. Same scope and requirement as `POSH_BASIC_USER`. Kept in process memory only — never written to disk. |

To set manually (requires an Administrator session):

```powershell
[Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key-here', 'Machine')
```

## Options Reference

### Start-WebServer.ps1 — Script Parameters

These are passed on the command line when starting the server. `Register-ScheduledTask.ps1` writes them into the Scheduled Task action arguments automatically.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-HttpsEnabled` | `switch` | off | Enables HTTPS. Requires a valid `netsh http sslcert` binding for `-HttpsPort`. The server exits with an error if HTTPS is enabled but no binding exists. |
| `-HttpPort` | `int` | `80` | HTTP listen port. Set to `0` to disable HTTP entirely (HTTPS-only mode). |
| `-HttpsPort` | `int` | `443` | HTTPS listen port. Only evaluated when `-HttpsEnabled` is set. |
| `-ConfigFile` | `string` | `''` (resolves to `<baseDir>\config.psd1`) | Absolute path to the runtime PSD1 config file. **Mandatory** — the server hard-fails at startup if the resolved path does not exist. Generate it once via `tools\Initialize-PoshConfig.ps1`. A malformed file also aborts startup with a clear error. |

### Start-WebServer.ps1 — $cfg Hashtable

> **`$baseDir`** (line 60 in `Start-WebServer.ps1`, not part of `$cfg`): Hardcoded deployment path (`"C:\posh"`). Change this single line to relocate the entire server. Used as the base path for `WebRoot` and `LogDir`.

| Option | Type | Default | Description |
|---|---|---|---|
| `WebRoot` | `string` | `"C:\posh\webroot"` | Absolute path to the directory that contains the `.ps1` endpoint scripts. URL paths are resolved relative to this directory. |
| `LogDir` | `string` | `"C:\posh\logs"` | Absolute path to the directory where daily log files are written. Created automatically at startup if it does not exist. |
| `PwshExe` | `string` | `(Get-Process -Id $PID).MainModule.FileName` | Absolute path to `pwsh.exe` used to execute webroot scripts. Resolved from the currently running process — no hardcoded path. |
| `ApiKey` | `string` | `$env:POSH_API_KEY` | Legacy single API key value checked against the `X-Api-Key` request header. Sourced from the `POSH_API_KEY` environment variable — do not hardcode. Auto-merged into `ApiKeys` under the `'default'` label when `ApiKeys` is empty (backward compatibility). For multi-key setups use `ApiKeys`. |
| `ApiKeys` | `hashtable` | `[ordered]@{}` (auto-populated from legacy `ApiKey` when empty) | Multi-key map `label → key` for identity-aware auth. Defined in the external config file: `@{ ApiKeys = @{ 'ci' = 'key1'; 'monitoring' = 'key2' } }`. The matching label flows into the request log, audit log, and per-key rate-limit table. Compared byte-exact (ordinal). |
| `ScriptTimeoutSec` | `integer` | `300` | Maximum number of seconds a webroot script may run before it is forcibly terminated. The caller receives HTTP 504 when this limit is exceeded. |
| `MaxConcurrent` | `integer` | `10` | Maximum number of requests processed simultaneously. Requests that arrive when all slots are occupied immediately receive HTTP 503. |
| `LogRetentionDays` | `integer` | `180` | Number of days to retain log files in `LogDir`. Log files older than this value are deleted at startup. Set to `0` to disable log rotation entirely. |
| `PostJsonDir` | `string` | `"C:\posh\postjson"` | Absolute path to the directory where POST body JSON files are stored. Created automatically at startup if it does not exist. Files are kept after script execution for audit and debugging. See [POST JSON File Passthrough](./post-json.md). |
| `PostJsonRetentionDays` | `integer` | `30` | Number of days to retain POST JSON files in `PostJsonDir`. Files older than this value are deleted at startup. Set to `0` to disable cleanup entirely. |
| `MaxRequestBodyBytes` | `integer` | `20971520` (20 MB) | Maximum allowed size of a POST request body in bytes. Requests exceeding this limit receive HTTP 413 immediately. Use PowerShell byte literals for readability: `5MB`, `10MB`. |
| `RateLimitRequests` | `integer` | `100` | Maximum number of requests allowed per client IP per window (`RateLimitWindowSec`). Requests exceeding this limit receive HTTP 429 with a `Retry-After` header. Set to `0` to disable rate limiting entirely. |
| `RateLimitWindowSec` | `integer` | `600` (10 min) | Duration in seconds of the Fixed Window used for rate limiting. The request counter resets when the window expires. |
| `RateLimitPenaltySec` | `integer` | `300` (5 min) | Duration in seconds for which a client IP is fully blocked after the first HTTP 429. The `Retry-After` header reflects the remaining penalty time. Set to `0` to fall back to window-end behaviour (no flat penalty). |
| `RateLimitMode` | `string` | `'reject'` | Behaviour when a client exceeds the rate limit. `'reject'`: return HTTP 429 immediately. `'queue'`: wait up to `RateLimitQueueTimeoutSec` seconds for the window to reset before returning HTTP 429. |
| `RateLimitPerIdentity` | `bool` | `$false` | When `$true`, requests carrying a valid `X-Api-Key` are rate-limited per API-key label instead of per client IP. Useful when several clients sit behind the same NAT or proxy. Anonymous / auth-exempt requests still use the client IP. Wrong/missing keys also fall back to per-IP, so brute-force attempts on the API key continue to hit the IP quota. |
| `RateLimitQueueTimeoutSec` | `integer` | `10` | Maximum seconds a request waits in queue mode before receiving HTTP 429. Only evaluated when `RateLimitMode = 'queue'`. |
| `RateLimitExemptPaths` | `string[]` | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | URL paths excluded from rate limiting. Must be an array even if only one path is exempt. Comparison is case-insensitive. |
| `MinRequestIntervalSec` | `integer` | `1` | Minimum number of seconds that must elapse between two dispatched requests, globally across all clients. Requests arriving before this interval elapses receive HTTP 429 with a `Retry-After` header. Enforced in the main thread before any runspace is started — the RunspacePool is never touched for throttled requests. Paths in `GlobalThrottleExemptPaths` are exempt. Set to `0` to disable. |
| `GlobalThrottleExemptPaths` | `string[]` | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | URL paths exempt from the `MinRequestIntervalSec` throttle. Defaults to the monitoring/discovery routes so Prometheus + Swagger UI are never throttled. Comparison is case-insensitive. |
| `IpFilterExemptPaths` | `string[]` | `@('/health')` | URL paths exempt from `AllowedIPs` / `BlockedIPs` enforcement. Default keeps `/health` reachable from external monitoring even when IP filtering is enabled. Comparison is case-insensitive. |
| `AuthExemptPaths` | `string[]` | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | URL paths that bypass authentication entirely. Identity is logged as `'anonymous'`. Add `/version`, `/robots.txt`, or similar public endpoints here without code edits. Comparison is case-insensitive. |
| `AllowedIPs` | `string[]` | `@()` | IP address allowlist. Empty = all IPs allowed (default). Non-empty = only matching client IPs pass. Each entry may be an exact IP (`'192.168.1.10'`), a CIDR range (`'10.0.0.0/8'`), or a regex when prefixed with `~` (`'~^192\.168\.'`). IPv4 and IPv6 both supported. `GET /health` is always exempt. |
| `BlockedIPs` | `string[]` | `@()` | IP address blocklist. Same matching syntax as `AllowedIPs` (exact / CIDR / `~regex`). Listed IPs are always rejected with HTTP 403, regardless of `AllowedIPs`. Checked first. `GET /health` is always exempt. |
| `Prefixes` | `string[]` | `@()` | Explicit `HttpListener` URL prefixes. When non-empty, overrides the default `+`-wildcard binding constructed from `HttpPort` / `HttpsPort`. Each prefix MUST end with `/` (`HttpListener` requirement). Allows hostname-bound listeners and mixed-port scenarios. Empty = legacy behavior. |
| `BackgroundJobs` | `hashtable[]` | `@()` | Array of background jobs to run on a recurring interval. Each entry: `@{ Path = '<absolute path to a .ps1 script>'; IntervalSec = <seconds> }`. Each job runs in its own runspace; the script is invoked via `pwsh.exe` (same isolation as the request handler's Subprocess mode). Job output is appended to `JobsLogFile`. Jobs are stopped during graceful shutdown. Replacement for the legacy PoSH Server `-CustomJob` option. |
| `JobsLogFile` | `string` | `''` (= `<LogDir>\jobs.log`) | Absolute path of the log file for `BackgroundJobs`. Kept separate from the request log so background activity does not pollute request traces. Empty = `<LogDir>\jobs.log`. |
| `DirectoryBrowsing` | `bool` | `$false` | When enabled (and `StaticServingEnabled = $true`), requests that resolve to a directory with no matching `DefaultDocuments` render an HTML index listing instead of returning HTTP 404. Path-traversal protection still applies. Filenames in `DirectoryBrowsingHidden` are omitted. |
| `DirectoryBrowsingHidden` | `string[]` | `@('_error', '.git', '.gitignore')` | Names hidden from directory listings (case-insensitive). Useful for keeping internal directories like `_error` or VCS metadata out of public indexes. |
| `AuditLogEnabled` | `bool` | `$false` | When `$true`, write security-relevant events (`AUTH_FAIL`, `IP_BLOCKED`, `RATE_LIMITED`) as NDJSON to `AuditLogFile`. One JSON object per line with `{ ts, event, identity, ip, path, detail }` — SIEM-friendly. Successful auth is NOT audited (already in the request log). Serialised via a dedicated Mutex (`Global\PoshWebserverAudit`) so audit bursts cannot block request logging. |
| `AuditLogFile` | `string` | `''` (= `<LogDir>\audit.log`) | Absolute path to the audit log file. Only consulted when `AuditLogEnabled = $true`. |
| `SlowRequestThresholdMs` | `integer` | `0` (disabled) | When `> 0`, any request whose `Invoke-Script` execution took at least this many milliseconds gets an extra line in `SlowLogFile`. Helps profile bottlenecks without pulling logs apart by hand. Independent of `ScriptTimeoutSec` — slow requests still finish normally and produce the regular request log line; the slow log just adds a parallel entry. |
| `SlowLogFile` | `string` | `''` (= `<LogDir>\slow.log`) | Absolute path to the slow-request log file. Only consulted when `SlowRequestThresholdMs > 0`. Format: pipe-delimited (`ts \| Nms \| ip \| identity=... \| METHOD path \| EXIT:n \| reqId`). Reuses the request-log mutex (`Global\PoshWebserverLog`) since slow events are rare by design. |
| `IndexShowMetadata` | `bool` | `$true` | When `$true`, `GET /` returns an array of `{ path, methods, synopsis, description, parameters }` objects parsed from each webroot script's AST (`.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` comment-help + `param()` block). When `$false`, the legacy flat path-string list is returned. Metadata is cached per-file and re-parsed on `LastWriteTimeUtc` change. |
| `PromMetricsEnabled` | `bool` | `$true` | When `$true`, `GET /metrics-prom` returns the live counters in Prometheus text-format (Content-Type `text/plain; version=0.0.4`). Auth-exempt (same treatment as `/metrics`). Exposes `posh_uptime_seconds`, `posh_requests_total`, `posh_rate_limited_total`, `posh_in_flight_requests`, `posh_rate_limit_table_size`, `posh_script_metadata_cache_size`. |
| `PathPlaceholders` | `bool` | `$false` | When `$true`, webroot files named with `[name]` segments (e.g. `users/[id].ps1`, `api/[version]/users/[id].ps1`) match URLs that substitute one path segment for each placeholder. Captured values are injected as named `-Key Value` args alongside any query-string params. Exact-path matches always win over placeholder matches; routes with fewer placeholders win over routes with more. Adding/removing top-level webroot subdirectories invalidates the route-table cache automatically; deeper edits require a restart. |
| `OpenApiEnabled` | `bool` | `$true` | When `$true`, `GET /openapi.json` returns an OpenAPI 3.1 specification auto-generated from the webroot scripts. Auth-exempt; consumed directly by Swagger UI, Postman, API gateways, etc. Path placeholders (F9) are emitted as `{name}` in the OpenAPI path template with `in: path, required: true`. Response schema is the `{ exitCode, output, error }` envelope for `.ps1`; alternate-extension scripts get a string response with the script-mapped Content-Type. |
| `OpenApiTitle` | `string` | `'posh'` | Value of `info.title` in the generated OpenAPI document. |
| `OpenApiVersion` | `string` | `'1.0.0'` | Value of `info.version` in the generated OpenAPI document. Bump alongside meaningful API changes so clients can detect them. |
| `GzipEnabled` | `bool` | `$true` | Enable GZIP response compression. Only applied when the client advertises `Accept-Encoding: gzip` AND the response body size is ≥ `GzipMinBytes` AND the response Content-Type starts with one of the entries in `GzipMimeTypes`. Pre-compressed binary types (images, ZIPs) are never compressed regardless of this setting because their MIME prefixes do not match. |
| `BrotliEnabled` | `bool` | `$true` | Enable Brotli response compression. Preferred over GZIP when both server-enabled and client-advertised (~15-25 % smaller output for text payloads). Same eligibility gates as GZIP (`GzipMinBytes`, `GzipMaxBytes`, `GzipMimeTypes`). Falls back to GZIP when client only advertises `gzip`, or to uncompressed when neither is advertised. |
| `GzipMinBytes` | `integer` | `1024` | Minimum response body size in bytes for which GZIP compression is attempted. Smaller responses are sent uncompressed because compression overhead would exceed the savings. |
| `GzipMaxBytes` | `integer` | `10485760` (10 MB) | Maximum response body size in bytes that may be GZIP-compressed. Larger responses are streamed uncompressed instead of buffered in memory for compression — guards the server against OOM when a giant text payload (HTML build artifact, JSON dump, …) matches a `GzipMimeTypes` prefix. Use PowerShell byte literals for readability: `10MB`, `50MB`. |
| `GzipMimeTypes` | `string[]` | see code | Allow-list of Content-Type prefixes eligible for GZIP. Matched via `StartsWith` so `'application/json'` covers `'application/json; charset=utf-8'`. Defaults include JSON, XML, JavaScript, HTML, CSS, and plain text. |
| `LogIntegrityHash` | `bool` | `$false` | At startup, write an `.md5` companion file next to every completed log file in `LogDir`. The currently-active log file is intentionally skipped so its hash never goes stale. Output format matches `md5sum` (lowercase hash + two spaces + filename). Provides a basic audit trail for log files at rest. |
| `LogSchedule` | `string` | `'Daily'` | Log file rotation schedule. `'Daily'` (default): file name is `YYYY-MM-DD.log`. `'Hourly'`: file name is `YYYY-MM-DDTHH.log` (one file per hour). `LogRetentionDays` is interpreted as days in both cases — at hourly granularity, ~24 files per day age out together. |
| `LogFormat` | `string` | `'Native'` | Log line format. `'Native'` (default): pipe-delimited columns matching the existing format. `'IIS-W3C'`: W3C Extended Log File Format with `#Software`, `#Version`, `#Date`, and `#Fields` header lines emitted on first write to a new file — consumable by `logparser` and similar tools. Fields: `date time c-ip cs-method cs-uri-stem cs-uri-query sc-status cs(User-Agent) x-request-id`. |
| `StaticServingEnabled` | `bool` | `$false` | Serve non-`.ps1` files (HTML, CSS, JS, images, fonts, …) from `StaticRoot`. Opt-in for backward compatibility — when off, every non-`.ps1` request still returns HTTP 400 as before. Only `GET` is accepted on static resources; `POST` returns HTTP 405. |
| `StaticRoot` | `string` | `""` (= `WebRoot`) | Filesystem root for static content. Empty string means: reuse `WebRoot`, so static files live alongside `.ps1` endpoints. Path-traversal protection is applied identically to the `.ps1` branch. |
| `DefaultDocuments` | `string[]` | `@('index.html', 'index.htm')` | When a static request resolves to a directory (or a path ending in `/`), each file name in this list is tried in order under that directory; the first existing one is served. If none exist, the response is HTTP 404 — directory browsing is opt-in (PR-9, not yet implemented). |
| `StaticCacheHeaders` | `bool` | `$true` | Emit `ETag` and `Last-Modified` on static responses and honor `If-None-Match` / `If-Modified-Since` with HTTP 304. ETag format: `"<length>-<utcTicksHex>"`. Set to `$false` to disable caching headers entirely (every request gets a fresh 200). |
| `BlockedMimeTypes` | `string[]` | `@()` | MIME-type blacklist for static responses — matched via `StartsWith` so `'video/'` blocks every video subtype. Matching entries trigger HTTP 403. Legacy PoSH Server "content filter" parity. |
| `MimeTypeMap` | `hashtable` | ~50 entries | Map of file extension (lowercase, with leading dot — `'.png'`) to Content-Type string. Defaults cover the common web/image/audio/video/font/archive types. Unknown extensions fall back to `application/octet-stream`. Override entries by editing the hashtable directly in `Start-WebServer.ps1`. |
| `SessionEnabled` | `bool` | `$false` | Auto-set an `HttpOnly` session cookie (`SessionCookieName`) when the request did not carry one. The value is a fresh GUID (32 hex chars, no dashes); `Secure` is added on HTTPS connections; `SameSite=Lax`. The server itself remains stateless — the cookie value is only forwarded to webroot scripts via the `POSH_SESSION_ID` env var so scripts can implement their own session logic. |
| `SessionCookieName` | `string` | `'POSH-Session-Id'` | Name of the session cookie. Only consulted when `SessionEnabled = $true`. |
| `CorsAllowedOrigins` | `string[]` | `@()` | List of allowed `Origin` values for CORS. Use `@('*')` for any origin (incompatible with `CorsAllowCredentials = $true` per CORS spec — when both are set, the actual origin is echoed back instead of `*`). Empty array = CORS disabled (default). |
| `CorsAllowedMethods` | `string` | `'GET, POST, OPTIONS'` | Value of the `Access-Control-Allow-Methods` header sent on OPTIONS preflight responses. |
| `CorsAllowedHeaders` | `string` | `'X-Api-Key, Content-Type, Authorization'` | Value of the `Access-Control-Allow-Headers` header sent on OPTIONS preflight responses. |
| `CorsAllowCredentials` | `bool` | `$false` | Set `Access-Control-Allow-Credentials: true` when the request origin matches the allowlist. Browsers send cookies / `Authorization` only when this is enabled. Incompatible with `@('*')` per CORS spec. |
| `CorsMaxAgeSec` | `integer` | `600` | Value of `Access-Control-Max-Age` on OPTIONS preflight responses — how long the browser may cache the preflight result. `0` omits the header entirely. |
| `AcceptedContentTypes` | `string[]` | `@('application/json', 'application/x-www-form-urlencoded')` | Allowed POST `Content-Type` prefixes. Matched via `StartsWith`. Requests with a non-listed Content-Type receive HTTP 415. Narrow this list (e.g. to `@('application/json')`) to reject form-encoded bodies entirely. |
| `AuthMode` | `string` | `'ApiKey'` | Authentication mode. `'ApiKey'`: only `X-Api-Key` is accepted (default). `'Basic'`: only HTTP Basic Auth (`Authorization: Basic <base64>`) is accepted. `'Both'`: either credential is accepted, whichever the client sends. Failed auth on `'Basic'` or `'Both'` emits a `WWW-Authenticate: Basic realm="…"` header so browsers display a login dialog. |
| `BasicAuthUser` | `string` | `$env:POSH_BASIC_USER` | Basic-Auth username. Sourced from the `POSH_BASIC_USER` env var — do not hardcode. Validated at startup when `AuthMode` requires Basic. |
| `BasicAuthPass` | `string` | `$env:POSH_BASIC_PASS` | Basic-Auth password. Sourced from the `POSH_BASIC_PASS` env var — kept in process memory only, never written to disk. |
| `BasicAuthRealm` | `string` | `'posh'` | Realm string in the `WWW-Authenticate` header. Browsers display this label in the login dialog. |
| `ExecutionMode` | `string` | `'Subprocess'` | How webroot scripts are executed. `'Subprocess'` (default): each request spawns a new `pwsh.exe` process — slow startup but reliable exit codes (`exit 0` / `exit 1`) and hard timeout enforcement via `Process.Kill()`. `'InProcess'`: each request runs in a fresh runspace within the server process — ~400 ms faster but exit codes are best-effort (any error → `exitCode=1`), `Runspace.Stop()` may not interrupt native long-running calls immediately, and module state can leak between scripts. Default keeps the existing semantics. |
| `InjectContextVars` | `bool` | `$false` | When `ExecutionMode = 'InProcess'`, expose `$PoSHQuery`, `$PoSHPost`, `$PoSHCookies`, `$PoSHHeaders` as variables in the script's runspace — legacy PoSH Server compatibility. Ignored when `ExecutionMode = 'Subprocess'`. |
| `ScriptExtensionMap` | `hashtable` | `{ '.ps1' = ''; '.psxml' = 'text/xml; charset=utf-8'; '.posh' = 'text/html; charset=utf-8'; '.psapi' = 'application/xml; charset=utf-8' }` | File extensions that the server treats as executable webroot scripts, mapped to the Content-Type used for the response. Empty string = use the JSON envelope `{ exitCode, output, error }` (default for `.ps1`); a non-empty value means the script's stdout is passed through verbatim with that Content-Type. Add custom extensions by extending the hashtable. |
| `PhpCgiEnabled` | `bool` | `$false` | Route `.php` URLs through an external `php-cgi.exe`. When enabled, `PhpCgiPath` must point at the binary. The server constructs the standard CGI/1.1 environment (`REQUEST_METHOD`, `SCRIPT_FILENAME`, `QUERY_STRING`, `HTTP_*`, …), streams POST bodies to PHP's stdin, parses the `Status:` / `Content-Type:` / `Location:` headers from PHP's stdout, and forwards the body as-is. PHP files resolving under `\Windows\` are refused (legacy PoSH hardening). |
| `PhpCgiPath` | `string` | `''` | Absolute path to `php-cgi.exe`. Validated at startup when `PhpCgiEnabled = $true`. |
| `PhpCgiTimeoutSec` | `integer` | `60` | Max seconds a PHP-CGI process may run. Long-running PHP scripts are killed and the caller receives HTTP 504 (analogous to `ScriptTimeoutSec` for `.ps1`). |
| `CustomErrorPages` | `bool` | `$false` | When `$true` and the client's `Accept` header advertises `text/html`, 4xx/5xx responses serve `<ErrorPagesRoot>\<code>.html` instead of the JSON envelope. Clients that prefer JSON (`Accept: application/json` or `*/*` without `text/html`) still receive the existing envelope. |
| `ErrorPagesRoot` | `string` | `''` (= `<WebRoot>\_error`) | Directory containing one HTML file per HTTP status code (`401.html`, `403.html`, `404.html`, `500.html`, …). Only consulted when `CustomErrorPages = $true`. The directory does not need to be pre-populated — missing files fall back to the JSON envelope. |

### Register-ScheduledTask.ps1 — Scheduled Task Options

The following values are hardcoded in `Register-ScheduledTask.ps1` and affect how the server is registered as a Windows Scheduled Task.

| Option | Type | Default | Description |
|---|---|---|---|
| `$TASK_NAME` | `string` | `"PowerShell-Webserver"` | The name of the Windows Scheduled Task as it appears in Task Scheduler. Used to start, stop, and unregister the task via `*-ScheduledTask` cmdlets. |
| `$SCRIPT_PATH` | `string` | `"<baseDir>\Start-WebServer.ps1"` | Absolute path to `Start-WebServer.ps1` passed as the `-File` argument to `pwsh.exe`. Resolved automatically from `$PSScriptRoot`. |
| `$WORK_DIR` | `string` | `"<baseDir>"` | Working directory for the `pwsh.exe` process. Must be the directory containing `Start-WebServer.ps1`. |
| `$POSH_APP_GUID` | `string` | `"a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d"` | Fixed AppID GUID used in `netsh http add sslcert`. Kept constant across re-installations so old bindings are cleanly replaced. |
| Restart count | `integer` | `3` | Number of automatic restart attempts after a crash. Configured on `$settings.RestartCount`. |
| Restart interval | `string` | `"PT1M"` | ISO 8601 duration between restart attempts. Configured on `$settings.RestartInterval`. |
