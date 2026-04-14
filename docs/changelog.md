# Changelog

## [Unreleased]

### Added
- POST request support for webroot script endpoints — scripts can now be called via `POST` with a flat JSON object as the request body. Body parameters are passed to the script identically to query string parameters; body keys take precedence when the same key appears in both. `Content-Type: application/json` is required. Built-in endpoints (`GET /` and `GET /health`) continue to accept GET only.
- `MaxRequestBodyBytes` configuration key (default: `20MB`) — POST request bodies exceeding this limit are rejected with HTTP 413. Bodies with an unknown size are validated after reading.
- HTTP 413 response when a POST body exceeds `MaxRequestBodyBytes`.
- HTTP 415 response when a POST request is made with a `Content-Type` other than `application/json`.
- Graceful shutdown signal — mechanism to trigger a clean shutdown without relying on Ctrl+C or process termination.

---

## 2026-04

### Added
- API key authentication via `X-Api-Key` request header — all endpoints except `GET /health` now require a valid key. The key is configured via the `POSH_API_KEY` system environment variable, set automatically by `Register-ScheduledTask.ps1`.
- `Register-ScheduledTask.ps1` now prompts for the API key and stores it as a `Machine`-scope system environment variable during task registration.
- Health-check endpoint `GET /health` — returns server status, uptime since last start, and total completed script request count. No authentication required, no webroot script needed.
- Log rotation on startup: log files older than `LogRetentionDays` days (default: 180) are deleted automatically when the server starts. Set `LogRetentionDays = 0` to disable.
- HTTP 405 response for non-GET requests — all endpoints now reject POST, DELETE, and other methods with a `405 Method Not Allowed` response and an `Allow: GET` header.
- Script execution timeout (`ScriptTimeoutSec = 900`): scripts running longer than 15 minutes are terminated and the caller receives HTTP 504 instead of waiting indefinitely.
- HTTP 503 response when the concurrent request limit is exceeded — returned directly from the main loop without consuming a thread slot.
- `ThreadJob` module availability check on startup — installs the module automatically if it is missing from the PowerShell 7 environment.
- `AGENTS.md` — full agent-facing documentation covering architecture, deployment, code style, naming conventions, and error-handling strategies.

### Changed
- Concurrency architecture replaced: `RunspacePool` + `BeginGetContext` + `[System.AsyncCallback]` replaced by a `while` loop with synchronous `GetContext()` and `Start-ThreadJob` per request — eliminates `PSInvalidOperationException` crashes caused by ScriptBlock delegates running on .NET ThreadPool threads without a PowerShell runspace (PS 7.4+).
- Webroot scripts now executed as a separate `pwsh.exe` process via `System.Diagnostics.Process` instead of `Start-ThreadJob` inside a running job — `Start-ThreadJob` nested inside a `Start-ThreadJob` fails with `JobSourceAdapter not registered`; `$proc.ExitCode` is the only reliable way to read `exit 0`/`exit 1`.
- Stdout and stderr now read via `ReadToEndAsync()` before `WaitForExit()` — prevents deadlock when the child process fills its output buffer.
- `Register-ScheduledTask.ps1` now runs the server via `pwsh.exe` (PowerShell 7) instead of `powershell.exe` (Windows PowerShell 5.1).
- Scheduled Task now runs under a configurable local administrator account instead of `SYSTEM` — required because GPU access and network authentication do not function correctly under `SYSTEM`.
- Password variable in `Register-ScheduledTask.ps1` is zeroed from memory in a `finally` block — previously zeroed in `try` and `catch` separately, leaving a gap if an unexpected error occurred between decryption and use.
- `Start-WebServer.ps1` now requires PowerShell 7 (`#Requires -Version 7.0`) — PowerShell 5.1 is no longer supported.
- `Get-ScriptIndex` rewritten as a single `if/else` expression — eliminates an unnecessary initial assignment that was immediately overwritten.
- Shutdown sequence now stops the `HttpListener` before the 5-second grace period — prevents a race condition where callbacks could access already-disposed objects.

### Fixed
- `$cfg.ApiKey` was always `$null` because `$env:POSH_API_KEY` was read after `$cfg` was defined — moved the environment variable read to before the `$cfg` hashtable definition so the value is available at evaluation time.
- `Write-Log`: `ReleaseMutex()` is now only called when `WaitOne()` returned `$true` — calling it from a thread that does not hold the mutex caused an `ApplicationException`.
- `Invoke-Script`: job state is now read into a local variable before `Remove-Job` is called — previously `$job.ChildJobs[0]` was accessed after the job object was already removed, causing a null reference error.
- `Get-ScriptIndex` now wraps its result in `@(...)` before serialising — empty arrays lost their array type in the pipeline and serialised as `null` instead of `[]`.
- `script1.ps1`: `Get-CimInstance Win32_OperatingSystem` called once and stored — previously called twice, wasting a WMI round-trip.
