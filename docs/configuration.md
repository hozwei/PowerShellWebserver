# Configuration

## Configuration File

There is no external configuration file. All configuration is defined inline in `Start-WebServer.ps1` as the `$cfg` hashtable and the `$baseDir` variable. To change any setting, edit the file directly.

**File location:** `C:\posh\Start-WebServer.ps1`

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
    RateLimitPenaltySec      = 1800
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
}
```

> After editing `Start-WebServer.ps1`, restart the Scheduled Task for changes to take effect:
> ```powershell
> Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
> Start-ScheduledTask -TaskName 'PowerShell-Webserver'
> ```

## Environment Variables

| Variable | Description |
|---|---|
| `POSH_API_KEY` | API key required in the `X-Api-Key` request header. Must be set as a `Machine`-scope system environment variable before the server starts. Set automatically by `Register-ScheduledTask.ps1`. The server refuses to start if this variable is empty or missing. |
| `POSH_CERT_THUMBPRINT` | Thumbprint of the certificate bound to the HTTPS port. Set automatically by `Register-ScheduledTask.ps1` after a successful `netsh` binding. Not a secret — used for diagnostics only. |

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

### Start-WebServer.ps1 — $cfg Hashtable

> **`$baseDir`** (line 60 in `Start-WebServer.ps1`, not part of `$cfg`): Hardcoded deployment path (`"C:\posh"`). Change this single line to relocate the entire server. Used as the base path for `WebRoot` and `LogDir`.

| Option | Type | Default | Description |
|---|---|---|---|
| `WebRoot` | `string` | `"C:\posh\webroot"` | Absolute path to the directory that contains the `.ps1` endpoint scripts. URL paths are resolved relative to this directory. |
| `LogDir` | `string` | `"C:\posh\logs"` | Absolute path to the directory where daily log files are written. Created automatically at startup if it does not exist. |
| `PwshExe` | `string` | `(Get-Process -Id $PID).MainModule.FileName` | Absolute path to `pwsh.exe` used to execute webroot scripts. Resolved from the currently running process — no hardcoded path. |
| `ApiKey` | `string` | `$env:POSH_API_KEY` | API key value checked against the `X-Api-Key` request header. Always sourced from the `POSH_API_KEY` environment variable — do not hardcode a value here. |
| `ScriptTimeoutSec` | `integer` | `300` | Maximum number of seconds a webroot script may run before it is forcibly terminated. The caller receives HTTP 504 when this limit is exceeded. |
| `MaxConcurrent` | `integer` | `10` | Maximum number of requests processed simultaneously. Requests that arrive when all slots are occupied immediately receive HTTP 503. |
| `LogRetentionDays` | `integer` | `180` | Number of days to retain log files in `LogDir`. Log files older than this value are deleted at startup. Set to `0` to disable log rotation entirely. |
| `PostJsonDir` | `string` | `"C:\posh\postjson"` | Absolute path to the directory where POST body JSON files are stored. Created automatically at startup if it does not exist. Files are kept after script execution for audit and debugging. See [POST JSON File Passthrough](./post-json.md). |
| `PostJsonRetentionDays` | `integer` | `30` | Number of days to retain POST JSON files in `PostJsonDir`. Files older than this value are deleted at startup. Set to `0` to disable cleanup entirely. |
| `MaxRequestBodyBytes` | `integer` | `20971520` (20 MB) | Maximum allowed size of a POST request body in bytes. Requests exceeding this limit receive HTTP 413 immediately. Use PowerShell byte literals for readability: `5MB`, `10MB`. |
| `RateLimitRequests` | `integer` | `100` | Maximum number of requests allowed per client IP per window (`RateLimitWindowSec`). Requests exceeding this limit receive HTTP 429 with a `Retry-After` header. Set to `0` to disable rate limiting entirely. |
| `RateLimitWindowSec` | `integer` | `600` (10 min) | Duration in seconds of the Fixed Window used for rate limiting. The request counter resets when the window expires. |
| `RateLimitPenaltySec` | `integer` | `1800` (30 min) | Duration in seconds for which a client IP is fully blocked after the first HTTP 429. The `Retry-After` header reflects the remaining penalty time. Set to `0` to fall back to window-end behaviour (no flat penalty). |
| `RateLimitMode` | `string` | `'reject'` | Behaviour when a client exceeds the rate limit. `'reject'`: return HTTP 429 immediately. `'queue'`: wait up to `RateLimitQueueTimeoutSec` seconds for the window to reset before returning HTTP 429. |
| `RateLimitQueueTimeoutSec` | `integer` | `10` | Maximum seconds a request waits in queue mode before receiving HTTP 429. Only evaluated when `RateLimitMode = 'queue'`. |
| `RateLimitExemptPaths` | `string[]` | `@('/health', '/metrics')` | URL paths excluded from rate limiting. Must be an array even if only one path is exempt. Comparison is case-insensitive. |
| `MinRequestIntervalSec` | `integer` | `1` | Minimum number of seconds that must elapse between two dispatched requests, globally across all clients. Requests arriving before this interval elapses receive HTTP 429 with a `Retry-After` header. Enforced in the main thread before any runspace is started — the RunspacePool is never touched for throttled requests. `GET /health` and `GET /metrics` are always exempt regardless of this setting. Set to `0` to disable. |
| `AllowedIPs` | `string[]` | `@()` | IP address allowlist. Empty array = all client IPs are allowed (default). Non-empty = only the listed IP addresses may send requests. Checked in the main thread after the IP blocklist. `GET /health` is always exempt. Use exact IP strings (e.g. `'192.168.1.10'`). |
| `BlockedIPs` | `string[]` | `@()` | IP address blocklist. Listed IPs are always rejected with HTTP 403, regardless of `AllowedIPs`. Checked in the main thread before `AllowedIPs`. `GET /health` is always exempt. Empty array = no IPs blocked (default). |
| `GzipEnabled` | `bool` | `$true` | Enable GZIP response compression. Only applied when the client advertises `Accept-Encoding: gzip` AND the response body size is ≥ `GzipMinBytes` AND the response Content-Type starts with one of the entries in `GzipMimeTypes`. Pre-compressed binary types (images, ZIPs) are never compressed regardless of this setting because their MIME prefixes do not match. |
| `GzipMinBytes` | `integer` | `1024` | Minimum response body size in bytes for which GZIP compression is attempted. Smaller responses are sent uncompressed because compression overhead would exceed the savings. |
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
