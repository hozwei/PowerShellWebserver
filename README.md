# posh

A Windows HTTP/HTTPS server that maps URL paths directly to PowerShell scripts and returns their output as JSON.

Place a `.ps1` file in `webroot\` — it is immediately reachable as an HTTP endpoint. No registration, no framework, no restart required.

## Documentation

- [Overview](./docs/overview.md) — What posh is and the problem it solves
- [Setup](./docs/setup.md) — Installation and prerequisites
- [Usage](./docs/usage.md) — How to call endpoints and interpret responses
- [POST JSON File Passthrough](./docs/post-json.md) — How POST bodies are passed to scripts
- [Architecture](./docs/architecture.md) — System design and key components
- [Configuration](./docs/configuration.md) — All configuration options
- [Contributing](./docs/contributing.md) — Development workflow, conventions, and adding new endpoints
- [Changelog](./docs/changelog.md) — Version history

## Features

### Core
- **URL-to-script routing** — every `.ps1` file in `webroot\` is an HTTP endpoint; subdirectories map to URL path segments.
- **GET and POST support** — GET passes URL query parameters as named PowerShell arguments. POST writes the JSON (or `application/x-www-form-urlencoded`) body to a file and passes the path via `-JsonFilePath` — supports nested objects, arrays, and large payloads. See [POST JSON File Passthrough](./docs/post-json.md).
- **JSON response envelope** — `.ps1` responses follow `{ "exitCode", "output", "error" }`. Other registered extensions pass raw stdout through with a dedicated Content-Type — see [Usage](./docs/usage.md#calling-alternate-extension-scripts-pr-5).
- **HTTPS support** — optional TLS on a configurable port. Certificate creation, `netsh` binding, and firewall rules are handled automatically by `Register-ScheduledTask.ps1`.
- **Concurrent request handling** — up to `MaxConcurrent` (default: 10) requests in parallel via `RunspacePool` + `[PowerShell]::Create()` + `BeginInvoke()`; excess receives HTTP 503.

### Authentication & rate limiting
- **API key + Basic Auth** — `X-Api-Key` (default), HTTP Basic, or both. The key is configured via the `POSH_API_KEY` system environment variable; Basic credentials via `POSH_BASIC_USER` / `POSH_BASIC_PASS`. Case-sensitive ordinal comparison.
- **Multiple labelled API keys** — define `ApiKeys = @{ 'ci' = '...'; 'monitoring' = '...' }` in `config.psd1`. The matched label flows into every log line and into the per-key rate-limit / audit log.
- **Per-IP rate limiting** — Fixed Window with optional flat-penalty period, `'reject'` or `'queue'` mode, configurable exempt paths. Switch to per-API-key accounting via `RateLimitPerIdentity = $true`.
- **Global throttle** — minimum interval between dispatched requests (`MinRequestIntervalSec`, default 1 s) in the main thread before any runspace starts. `/health` and `/metrics` always exempt.
- **IP filter** — `AllowedIPs` / `BlockedIPs` with exact, CIDR (`10.0.0.0/8`), or regex (`~^192\.168\.`) entries.

### Static + alternate content
- **Static file serving** — opt-in via `StaticServingEnabled`. ~50 MIME types out of the box. RFC-7232 conditional GET (`ETag` + `Last-Modified` → 304), RFC-7233 byte ranges (incl. suffix `bytes=-N`), GZIP for text content with `GzipMaxBytes` upper cap, MIME blacklist, optional directory browsing.
- **Extension aliases** — `.psxml` → `text/xml`, `.posh` → `text/html`, `.psapi` → `application/xml` pass raw stdout through.
- **PHP-CGI handler** — opt-in `.php` routing through an external `php-cgi.exe`. CGI/1.1 environment, body streaming to stdin, `Status` / `Content-Type` / `Location` parsed from PHP stdout.

### Operations
- **Runtime config file (`config.psd1`)** — mandatory at startup; generated per install by `tools\Initialize-Config.ps1` from the inline `$cfg` defaults. Parsed via `Import-PowerShellDataFile` (data-only, no script execution). Edit directly or via the upcoming `tools\Edit-PoshSettings.ps1` browser editor.
- **Brotli + GZIP compression** — Brotli preferred when the client advertises `br`; falls back to GZIP, then uncompressed. Same eligibility gates (`GzipMinBytes`, `GzipMaxBytes`, `GzipMimeTypes`) for both.
- **Forms, cookies, CORS** — `application/x-www-form-urlencoded` POST bodies, opt-in HttpOnly session cookies (`SessionEnabled`), full CORS with `OPTIONS` preflight.
- **Custom HTML error pages** — when the client `Accept`s `text/html`, 4xx/5xx responses serve `<ErrorPagesRoot>\<code>.html` instead of the JSON envelope.
- **Background jobs on interval** — `BackgroundJobs = @(@{ Path; IntervalSec })` runs scripts on a recurring schedule, separately logged.
- **Multi-host prefixes** — explicit `Prefixes` list overrides the `+`-wildcard binding for hostname-bound listeners.
- **Request tracing** — every response carries an 8-character hex `X-Request-Id` matching the log line.
- **Script timeout enforcement** — scripts exceeding `ScriptTimeoutSec` (default 300 s) are killed and the caller receives HTTP 504.
- **Daily or hourly log rotation** — `LogSchedule = 'Daily' | 'Hourly'`. Optional `IIS-W3C` log format and MD5 integrity hashes (`LogIntegrityHash`) for audit.
- **NDJSON audit log** — opt-in via `AuditLogEnabled`. Security-relevant events (`AUTH_FAIL`, `IP_BLOCKED`, `RATE_LIMITED`) appended to `audit.log` as one JSON line per event — SIEM-friendly.
- **Slow-request log** — opt-in via `SlowRequestThresholdMs`. Requests exceeding the threshold get a parallel line in `slow.log`.
- **Built-in `/health` + `/metrics` + `/metrics-prom`** — `/health` and `/metrics` (JSON) for human consumption, `/metrics-prom` (Prometheus text-format) for scrapers.
- **OpenAPI 3.1 spec** — `GET /openapi.json` auto-generates a complete spec from each webroot script's comment-based help + `param()` block. Importable into Swagger UI, Postman, API gateways.

### REST routing & discovery
- **Path placeholders** — opt-in via `PathPlaceholders`. `webroot/users/[id].ps1` matches `/users/123` (Next.js convention); captured values arrive as `-id 123` named args. Multiple placeholders per route allowed; literal-segment specificity wins.
- **Index metadata** — `GET /` returns enriched objects (`{ path, methods, synopsis, description, parameters }`) parsed from each script's AST. Cached per file; re-parsed on edit. Toggle via `IndexShowMetadata`.

### Lifecycle
- **Windows Scheduled Task** — `Register-ScheduledTask.ps1` installs the server as an auto-starting task in one command.

## Quick Start

**Prerequisites:** Windows 10 / Server 2019, PowerShell 7, local administrator account with password.

```powershell
# 1. Copy to deployment directory
Copy-Item -Path ".\*" -Destination "C:\posh\" -Recurse -Force

# 2. Register as a Windows Scheduled Task (Administrator PowerShell 7)
cd C:\posh
.\Register-ScheduledTask.ps1        # prompts for username, password, API key, and optional HTTPS
                                    # also generates config.psd1 on first install

# 3. Start immediately (no reboot needed)
Start-ScheduledTask -TaskName 'PowerShell-Webserver'

# 4. Verify
Invoke-RestMethod -Uri 'http://localhost/health'
```

> If you deploy without `Register-ScheduledTask.ps1` (e.g. running the server manually for development), you must seed the runtime config yourself once: `.\tools\Initialize-Config.ps1`. The server hard-fails at startup without `config.psd1`.

Expected response from `/health`:

```json
{ "status": "ok", "uptime": "0h 0m 5s", "requestsTotal": 0 }
```

For the full installation guide including HTTPS setup, see [Setup](./docs/setup.md).

## Calling an Endpoint

Every `.ps1` file in `webroot\` is immediately callable via HTTP GET or POST. Include the `X-Api-Key` header.

**GET — parameters as query string:**

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1?ComputerName=WORKSTATION&Detail=true' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

**POST — JSON body as file:**

POST bodies are not passed as command-line parameters. Instead, the server writes the JSON body to a file and passes the absolute path as `-JsonFilePath`. The script reads and parses the file itself — nested objects, arrays, and large payloads are fully supported.

```powershell
$body = @{
    firstName  = 'Anna'
    department = @{ name = 'IT'; costCenter = '4200' }
    roles      = @('admin', 'user')
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri 'http://localhost/post-example.ps1' `
    -Method      Post `
    -ContentType 'application/json' `
    -Headers     @{ 'X-Api-Key' = 'your-api-key' } `
    -Body        $body
```

The script receives `-JsonFilePath "C:\posh\postjson\20260415_143000_a1b2c3d4.json"` and reads the file directly. For the full pattern and test examples, see [POST JSON File Passthrough](./docs/post-json.md).

Scripts in subdirectories are reachable by path:

```powershell
Invoke-RestMethod -Uri 'http://localhost/subdir/script2.ps1?Path=C:\Windows\Temp' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

**HTTPS** (add `-SkipCertificateCheck` for self-signed certificates):

```powershell
Invoke-RestMethod -Uri 'https://localhost/script1.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } `
    -SkipCertificateCheck
```

## Adding an Endpoint

Create a `.ps1` file anywhere inside `webroot\` — it is reachable immediately, no server restart needed:

```powershell
# webroot\script1.ps1
#Requires -Version 7.0
param(
    [string] $Name = 'World'
)

Write-Output "Hello, $Name!"
```

Call it:

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1?Name=Max' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Rules for webroot scripts: use `Write-Output` for normal output, `Write-Error` for errors, `exit 1` to signal HTTP 500, `exit 0` (or no explicit exit) for HTTP 200. GET query parameters arrive as `string` — cast explicitly when needed. POST scripts receive `-JsonFilePath` and must read the file themselves. See [Contributing](./docs/contributing.md) for the full rules.

## HTTP Status Codes

| Code | Meaning |
|---|---|
| `200` | Script exited with code `0` |
| `400` | Request path does not end in `.ps1`, POST body is not valid JSON, or query string parameters were included on a POST request |
| `401` | `X-Api-Key` header missing or incorrect |
| `403` | Path-traversal attempt detected — or client IP is in `BlockedIPs` — or `AllowedIPs` is non-empty and client IP is not listed |
| `404` | Script file not found in `webroot\` |
| `405` | HTTP method not allowed — only GET and POST are accepted |
| `413` | POST body exceeds `MaxRequestBodyBytes` |
| `415` | POST request `Content-Type` is not `application/json` |
| `429` | Rate limit exceeded (`RateLimitRequests` per `RateLimitWindowSec`) — or global throttle (`MinRequestIntervalSec`) exceeded — `Retry-After` header included in both cases |
| `500` | Script exited with a non-zero exit code |
| `503` | Server is at maximum concurrent request capacity |
| `504` | Script exceeded `ScriptTimeoutSec` and was terminated |

## Configuration

Configuration resolves from two layers:

1. **`config.psd1`** next to `Start-WebServer.ps1` (or `-ConfigFile <path>`) — runtime source of truth, **mandatory**, generated per install by `tools\Initialize-Config.ps1`. Gitignored.
2. Inline `$cfg` defaults inside `Start-WebServer.ps1` — schema and fallback. Supplies a default when a key is missing from `config.psd1` so old configs survive upgrades.

The server refuses to start if `config.psd1` does not exist. Generate it once via `.\tools\Initialize-Config.ps1` (or let `Register-ScheduledTask.ps1` do it for you on first install).

HTTP/HTTPS ports and HTTPS activation are runtime parameters:

| Option | Default | Description |
|---|---|---|
| `-HttpPort` | `80` | HTTP listen port; `0` = HTTP disabled |
| `-HttpsEnabled` | off | Enable HTTPS (requires `netsh sslcert` binding) |
| `-HttpsPort` | `443` | HTTPS listen port |
| `-ConfigFile` | auto = `<baseDir>\config.psd1` | Override path of the external PSD1 |
| `WebRoot` | `C:\posh\webroot` | Directory containing the `.ps1` endpoint scripts |
| `LogDir` | `C:\posh\logs` | Directory for daily log files |
| `ApiKey` | `$env:POSH_API_KEY` | API key — always read from the environment variable |
| `ScriptTimeoutSec` | `300` | Seconds before a running script is killed and HTTP 504 is returned |
| `MaxConcurrent` | `10` | Maximum parallel requests — excess requests receive HTTP 503 |
| `LogRetentionDays` | `180` | Days to keep log files; `0` disables rotation |
| `PostJsonDir` | `C:\posh\postjson` | Directory where POST body JSON files are stored |
| `PostJsonRetentionDays` | `30` | Days to keep POST JSON files; `0` disables cleanup |
| `MaxRequestBodyBytes` | `20971520` (20 MB) | Maximum POST body size in bytes |
| `RateLimitRequests` | `100` | Maximum requests per IP per window; `0` disables rate limiting |
| `RateLimitWindowSec` | `600` | Fixed window size in seconds (10 minutes) |
| `RateLimitPenaltySec` | `1800` | Penalty duration after first HTTP 429 (30 minutes) |
| `RateLimitMode` | `'reject'` | `'reject'` = immediate HTTP 429; `'queue'` = wait up to `RateLimitQueueTimeoutSec` |
| `RateLimitQueueTimeoutSec` | `10` | Max seconds to wait in queue mode before HTTP 429 |
| `RateLimitExemptPaths` | `@('/health', '/metrics')` | Paths excluded from per-IP rate limiting |
| `MinRequestIntervalSec` | `1` | Minimum seconds between dispatched requests globally; `0` disables; `/health` and `/metrics` always exempt |
| `AllowedIPs` | `@()` | IP allowlist — empty = all IPs allowed; non-empty = only listed IPs pass |
| `BlockedIPs` | `@()` | IP blocklist — listed IPs always receive HTTP 403 |

For the full options reference, see [Configuration](./docs/configuration.md).

## Architecture Overview

```
Client
  │  GET /subdir/script2.ps1?Path=C:\Temp   X-Api-Key: <key>
  │  POST /post-example.ps1   body: { "name": "Anna", ... }
  ▼
HttpListener  ──  http://+:80/  https://+:443/
  │  Main Loop (GetContext)
  │  IP filter:       BlockedIPs / AllowedIPs → HTTP 403   (/health exempt)
  │  Global throttle: MinRequestIntervalSec   → HTTP 429   (/health and /metrics exempt)
  │  SemaphoreSlim:   full                    → HTTP 503
  │  [PowerShell]::Create() + BeginInvoke() via RunspacePool
  ▼
$requestHandler (RunspacePool Runspace)
  │  Method check · Rate limit · Auth · Path validation
  │  GET:  Get-QueryParams → -Key Value arguments
  │  POST: Get-BodyParams → Save-PostJson → C:\posh\postjson\YYYYMMDD_HHmmss_<id>.json
  │  Invoke-Script
  ▼
GET:  pwsh.exe -File webroot\subdir\script2.ps1 -Path "C:\Temp"
POST: pwsh.exe -File webroot\post-example.ps1 -JsonFilePath "C:\posh\postjson\..."
  │  stdout + stderr via ReadToEndAsync()
  │  $proc.ExitCode → HTTP 200 / 500 / 504
  ▼
{ "exitCode": 0, "output": "...", "error": "" }
```

posh has no external dependencies beyond the .NET base class library and PowerShell 7 built-ins. For a full component breakdown, see [Architecture](./docs/architecture.md).
