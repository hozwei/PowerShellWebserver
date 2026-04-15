# Changelog

## [Unreleased]

### Changed
- **POST request handling**: JSON body is no longer parsed into flat `-Key Value` parameters. Instead the raw body is written to `C:\posh\postjson\YYYYMMDD_HHmmss_<requestId>.json` and the absolute file path is passed to the webroot script as `-JsonFilePath`. Nested objects, arrays, and large payloads are fully supported. Query string parameters on POST requests are rejected with HTTP 400.
- `ScriptTimeoutSec` default reduced from `900` (15 min) to `300` (5 min) — scripts running longer than 5 minutes are forcibly terminated and the caller receives HTTP 504.
- `GET /metrics` is now open (no `X-Api-Key` required) and exempt from both per-IP rate limiting (`RateLimitExemptPaths`) and the global throttle (`MinRequestIntervalSec`) — same treatment as `GET /health`. `RateLimitExemptPaths` default updated from `@('/health')` to `@('/health', '/metrics')`.

### Added
- **`PostJsonDir`** configuration key (`C:\posh\postjson` by default): directory where POST body JSON files are stored. Created automatically at startup.
- **`PostJsonRetentionDays`** configuration key (`30` by default): POST JSON files older than N days are deleted at startup. `0` disables cleanup.
- **`Remove-OldPostJsonFiles`** function: deletes `.json` files in `PostJsonDir` older than `PostJsonRetentionDays` days. Runs at startup, result logged to `startup.log`.
- **`Save-PostJson`** function: writes the raw POST body UTF-8 to a timestamped, request-ID-correlated file in `PostJsonDir`. File name format: `YYYYMMDD_HHmmss_<requestId>.json`.
- **`webroot\post-example.ps1`**: example script demonstrating the JSON file passthrough pattern — reads and parses `-JsonFilePath`, accesses scalar fields, nested objects, and arrays.
- **`docs/post-json.md`**: full documentation for the POST JSON file passthrough feature including concept, script pattern, `curl` and `Invoke-RestMethod` test examples, configuration reference, and error table.
- **Rate-limit table cleanup** at startup: `Remove-StaleRateLimitEntries` removes per-IP entries from `$script:rateLimitTable` whose penalty has expired and whose rate-limit window has elapsed. Prevents unbounded memory growth during long uptimes with many distinct client IPs. Skipped when `RateLimitRequests = 0`. Result logged to `startup.log`.
- **`GET /metrics`** built-in endpoint (open): returns `{ "uptime", "requestsTotal", "rateLimitedTotal" }`. `rateLimitedTotal` counts per-IP rate-limit rejections (HTTP 429 from `Test-RateLimit`); global-throttle 429s (`MinRequestIntervalSec`, main thread) are intentionally excluded. Logged as `METRICS`.
- **Rate limiting** — per-IP Fixed Window rate limiter (`RateLimitRequests = 100` per `RateLimitWindowSec = 600`). Violations receive HTTP 429 with a `Retry-After` header. After the first violation, a flat penalty period blocks the IP for `RateLimitPenaltySec = 1800` seconds. Supports `'reject'` (immediate, default) and `'queue'` (wait up to `RateLimitQueueTimeoutSec`) modes. Configurable exempt paths via `RateLimitExemptPaths`. Separate atomic counter `$script:rateLimitedTotal`.
- **Global request throttle** (`MinRequestIntervalSec = 1`): requests arriving faster than 1 per second receive HTTP 429 with a `Retry-After` header. Enforced in the main thread before any runspace is started — the RunspacePool is never touched for throttled requests. `GET /health` and `GET /metrics` are always exempt. Throttled requests are **not logged** (file I/O in the main thread under burst traffic blocks `GetContext()`).
- **IP filter** (`AllowedIPs` / `BlockedIPs`): checked in the main thread before the global throttle. `BlockedIPs` always rejects with HTTP 403; `AllowedIPs` non-empty restricts access to listed IPs only. `GET /health` is always exempt. Rejections logged via direct `[System.IO.File]::AppendAllText`.
- **`X-Request-Id` response header**: every response (including error responses and IP-filter rejections) includes an 8-character hex request ID. The same value is written as the 6th column in `Write-Log`, allowing clients to correlate HTTP responses to log lines. Global-throttle 429 responses carry `X-Request-Id` but are not logged.
- HTTPS support via `System.Net.HttpListener` with `https://+:<port>/` prefix. Enabled with `-HttpsEnabled` switch; requires a `netsh http sslcert` binding for the configured port.
- `Register-ScheduledTask.ps1` HTTPS setup flow: interactive prompts for certificate source (new self-signed, existing thumbprint, or PFX import), `netsh http add sslcert` binding, optional Windows Firewall rules, and optional HTTP disable.
- Self-signed certificate creation with full SAN support: machine hostname, `localhost`, `127.0.0.1`, and all local IPv4 addresses included automatically via `-TextExtension`.
- `POSH_CERT_THUMBPRINT` system environment variable set after successful certificate binding — for diagnostics only, not a secret.
- `-HttpPort`, `-HttpsEnabled`, `-HttpsPort` parameters on `Start-WebServer.ps1` — HTTP/HTTPS ports and HTTPS activation are now runtime parameters instead of hardcoded values.
- Startup validation: when `-HttpsEnabled` is set, `Start-WebServer.ps1` verifies the `netsh sslcert` binding exists before starting the listener. Exits with `exit 1` and a clear error message if the binding is missing.

### Changed
- **Concurrency architecture**: `Start-ThreadJob` replaced by `RunspacePool` + `[PowerShell]::Create()` + `BeginInvoke()`. Root cause of all previous crashes: `Start-ThreadJob` serialises `-ArgumentList` → live .NET objects become dead `Deserialized.*` snapshots; `$using:` on ScriptBlock-variables resolves to `$null` in PS 7.6; `JobSourceAdapter` degrades under rapid repeated invocations. `RunspacePool` with `InitialSessionState::CreateDefault2()` (minimal ISS) and `InitialSessionState.Variables` injects live objects directly into every runspace — no serialisation, no `JobSourceAdapter`, no shared module state contention.
- `$baseDir` moved before the PowerShell version check — the early-exit log path uses `Join-Path $baseDir 'logs'` instead of a separate hardcoded string.

### Fixed
- `InitialSessionState::CreateDefault()` replaced with `CreateDefault2()` — eliminates auto-module-loading and shared module state contention under rapid RunspacePool load in PS 7.6. Under sustained burst traffic, `CreateDefault()` caused worker runspaces to start silently without executing any code, and eventually corrupted the main runspace's cmdlet registry.
- `GetAwaiter().GetResult()` on stdout/stderr stream tasks blocked forever under load. Root cause: `pwsh.exe` startup takes 3-10s under process-creation contention. Second `WaitForExit(2000)` timed out while process still running — `GetResult()` blocked indefinitely, semaphore slot held, server hung permanently. Fix: second `WaitForExit` raised to 10000ms; `GetResult()` replaced with `Task.WaitAll(..., 5000)` + `IsCompleted` guard.
- Server hang under sustained load: (1) `[PowerShell]` instances created per request were never `EndInvoke()`+`Dispose()`'d — RunspacePool slots leaked. Fix: track `(Ps, Handle)` pairs in `$psInstances`; dispose completed instances each loop iteration. (2) Second `$proc.WaitForExit()` without timeout blocked forever under process-creation contention. Fix: `$proc.WaitForExit(10000)`.
- `[datetime]` `-` operator and `.Subtract()` both fail in RunspacePool runspace contexts (PS 7.x); replaced all occurrences in `Test-RateLimit` with Ticks arithmetic.
- `Register-ScheduledTask.ps1`: `$input` (PowerShell automatic variable) renamed to `$raw` in `Read-HostWithDefault` and `Read-YesNo` — removes `PSAvoidAssignmentToAutomaticVariable` PSScriptAnalyzer warning.
- `webroot\script1.ps1`: `Get-CimInstance Win32_OperatingSystem` and `Get-CimInstance Win32_Processor` now pass `-ComputerName $ComputerName` — previously both always queried the local machine regardless of the parameter value.
- `webroot\script1.ps1` + `webroot\subdir\script2.ps1`: All German strings, comments, and output messages translated to English.
- `netsh http add sslcert` binding in `Register-ScheduledTask.ps1` now correctly deletes any existing binding before adding the new one — previously the delete was silently ignored, causing `add` to fail with error 183 (`ERROR_ALREADY_EXISTS`) on re-installation.
- HTTPS startup validation in `Start-WebServer.ps1` now checks for `IP:Port` in `netsh` output instead of `Certificate Hash` — the latter is locale-specific and absent on non-English Windows installations.

---

## 2026-04

### Added
- POST request support for webroot script endpoints — scripts can now be called via `POST` with a flat JSON object as the request body. Body parameters are passed to the script identically to query string parameters; body keys take precedence when the same key appears in both. `Content-Type: application/json` is required. Built-in endpoints (`GET /` and `GET /health`) continue to accept GET only.
- `MaxRequestBodyBytes` configuration key (default: `20MB`) — POST request bodies exceeding this limit are rejected with HTTP 413. Bodies with an unknown size are validated after reading.
- HTTP 413 response when a POST body exceeds `MaxRequestBodyBytes`.
- HTTP 415 response when a POST request is made with a `Content-Type` other than `application/json`.
- API key authentication via `X-Api-Key` request header — all endpoints except `GET /health` now require a valid key. The key is configured via the `POSH_API_KEY` system environment variable, set automatically by `Register-ScheduledTask.ps1`.
- `Register-ScheduledTask.ps1` now prompts for the API key and stores it as a `Machine`-scope system environment variable during task registration.
- Health-check endpoint `GET /health` — returns server status, uptime since last start, and total completed script request count. No authentication required, no webroot script needed.
- Log rotation on startup: log files older than `LogRetentionDays` days (default: 180) are deleted automatically when the server starts. Set `LogRetentionDays = 0` to disable.
- Script execution timeout (`ScriptTimeoutSec = 900`): scripts running longer than 15 minutes are terminated and the caller receives HTTP 504 instead of waiting indefinitely.
- HTTP 503 response when the concurrent request limit is exceeded — returned directly from the main loop without consuming a thread slot.
- `AGENTS.md` — full agent-facing documentation covering architecture, deployment, code style, naming conventions, and error-handling strategies.

### Changed
- Concurrency architecture replaced: `RunspacePool` + `BeginGetContext` + `[System.AsyncCallback]` replaced by a `while` loop with synchronous `GetContext()` and `Start-ThreadJob` per request — eliminates `PSInvalidOperationException` crashes caused by ScriptBlock delegates running on .NET ThreadPool threads without a PowerShell runspace (PS 7.4+).
- Webroot scripts now executed as a separate `pwsh.exe` process via `System.Diagnostics.Process` instead of `Start-ThreadJob` inside a running job — `Start-ThreadJob` nested inside a `Start-ThreadJob` fails with `JobSourceAdapter not registered`; `$proc.ExitCode` is the only reliable way to read `exit 0`/`exit 1`.
- Stdout and stderr now read via `ReadToEndAsync()` before `WaitForExit()` — prevents deadlock when the child process fills its output buffer.
- `Register-ScheduledTask.ps1` now runs the server via `pwsh.exe` (PowerShell 7) instead of `powershell.exe` (Windows PowerShell 5.1).
- Scheduled Task now runs under a configurable local administrator account instead of `SYSTEM` — required because GPU access and network authentication do not function correctly under `SYSTEM`.
- Password variable in `Register-ScheduledTask.ps1` is zeroed from memory in a `finally` block — previously zeroed in `try` and `catch` separately, leaving a gap if an unexpected error occurred between decryption and use.
- `Start-WebServer.ps1` now requires PowerShell 7 (`#Requires -Version 7.0`) — PowerShell 5.1 is no longer supported.
- HTTP 405 now covers all non-GET/POST methods — previously only non-GET requests were rejected.
- `Get-ScriptIndex` rewritten as a single `if/else` expression — eliminates an unnecessary initial assignment that was immediately overwritten.
- Shutdown sequence now stops the `HttpListener` before the 5-second grace period — prevents a race condition where callbacks could access already-disposed objects.

### Fixed
- `$cfg.ApiKey` was always `$null` because `$env:POSH_API_KEY` was read after `$cfg` was defined — moved the environment variable read to before the `$cfg` hashtable definition so the value is available at evaluation time.
- `Write-Log`: `ReleaseMutex()` is now only called when `WaitOne()` returned `$true` — calling it from a thread that does not hold the mutex caused an `ApplicationException`.
- `Invoke-Script`: job state is now read into a local variable before `Remove-Job` is called — previously `$job.ChildJobs[0]` was accessed after the job object was already removed, causing a null reference error.
- `Get-ScriptIndex` now wraps its result in `@(...)` before serialising — empty arrays lost their array type in the pipeline and serialised as `null` instead of `[]`.
- `script1.ps1`: `Get-CimInstance Win32_OperatingSystem` called once and stored — previously called twice, wasting a WMI round-trip.
