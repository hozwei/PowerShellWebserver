# Architecture

## Overview

posh is a single-process PowerShell 7 HTTP/HTTPS server built on `System.Net.HttpListener`. Incoming requests are accepted synchronously in a `while` loop via `GetContext()`, then dispatched to a `RunspacePool` via `[PowerShell]::Create()` + `BeginInvoke()` for parallel execution. Each request resolves its URL path to a `.ps1` file inside the `webroot\` directory, executes it as a separate `pwsh.exe` process, and returns the result as a JSON envelope. The server runs as a Windows Scheduled Task under a local administrator account and writes daily-rotating log files to `logs\`. All logic is contained in two PowerShell scripts with no external dependencies beyond the .NET base class library.

## Directory Structure

```
C:\posh\
├── Start-WebServer.ps1          # Entry point: HttpListener, main loop, RunspacePool dispatch
├── Register-ScheduledTask.ps1   # One-time setup: Scheduled Task, HTTPS certificate, firewall
├── logs\                        # Runtime logs, one file per day (YYYY-MM-DD.log)
└── webroot\                     # HTTP endpoints — each .ps1 file is a route
    ├── script1.ps1              # Example: returns system information
    └── subdir\                  # Subdirectories map to URL path segments
        └── script2.ps1          # Example: lists files in a directory
```

## Key Components

### HttpListener

**Purpose:** Accepts incoming TCP connections on the configured HTTP and/or HTTPS ports and produces `HttpListenerContext` objects.

**Responsibilities:**
- Binds to `http://+:<HttpPort>/` and/or `https://+:<HttpsPort>/` depending on parameters
- Blocks synchronously on `GetContext()` in the main loop until a request arrives
- Stopping the listener causes `GetContext()` to throw, which exits the main loop cleanly

**Dependencies on other components:**
- `System.Net.HttpListener` (.NET BCL)

---

### Main Loop & Request Dispatch

**Purpose:** Accepts one request at a time and hands each off to a parallel Runspace via `RunspacePool`.

**Responsibilities:**
- Calls `GetContext()` synchronously — blocks at near-zero CPU cost until a request arrives
- Checks `BlockedIPs` / `AllowedIPs`: if the client IP is blocked or not in the allowlist, returns HTTP 403 + `X-Request-Id` directly and logs the rejection via `[System.IO.File]::AppendAllText`; `GET /health` is always exempt
- Enforces `MinRequestIntervalSec` (default: 1s) via `$lastDispatchTick` + `Stopwatch::GetTimestamp()` / `Frequency` — requests arriving too fast receive HTTP 429 + `Retry-After` + `X-Request-Id` immediately, before any runspace is started; `GET /health` is always exempt; throttled requests are **not logged** (file I/O in the main thread under burst traffic blocks `GetContext()`)
- Checks `SemaphoreSlim.Wait(0)` immediately: if all slots are occupied, returns HTTP 503 + `X-Request-Id` directly without starting a job
- Starts a `[PowerShell]::Create()` + `BeginInvoke()` per accepted request via `RunspacePool`, passing `$context` and `$shared`
- Cleans up completed `[PowerShell]` instances (`EndInvoke()` + `Dispose()`) once per loop iteration to release RunspacePool slots

**Dependencies on other components:**
- `$semaphore` (capacity check)
- `$lastDispatchTick` (global throttle — `MinRequestIntervalSec`)
- `$cfg.BlockedIPs` / `$cfg.AllowedIPs` (IP filter)
- `$requestHandler` ScriptBlock (executed inside each Runspace)
- `$shared` hashtable (carries all configuration and function references into the Runspace)
- `$psInstances` list (tracks active `[PowerShell]` instances for cleanup)

---

### Request Handler (`$requestHandler`)

**Purpose:** Processes a single HTTP request inside a RunspacePool Runspace.

**Responsibilities:**
- Validates HTTP method — rejects non-GET and non-POST requests with HTTP 405
- Validates `X-Api-Key` header against `$cfg.ApiKey` — rejects missing or incorrect keys with HTTP 401; `/health` and `/metrics` are exempt
- Generates a unique `$requestId` (8-character hex from GUID) at the start of each request — passed to `Send-Response` as `X-Request-Id` header and to `Write-Log` as the 6th log column
- Serves built-in endpoints `GET /` (script index) and `GET /health` (server status) without invoking webroot scripts
- Resolves the URL path to a file under `webroot\`: validates `.ps1` extension, checks for path traversal, checks file existence
- For POST requests, rejects query string parameters with HTTP 400 (all input must be in the JSON body)
- For POST requests, calls `Get-BodyParams` to validate Content-Type and JSON syntax — returns HTTP 400, 413, or 415 on error; then calls `Save-PostJson` to write the raw body to `PostJsonDir` and obtains the file path
- For GET requests, calls `Get-QueryParams` to extract URL query parameters as `-Key Value` pairs
- Dispatches the resolved script to `Invoke-Script` (GET: with query params; POST: with `-JsonFilePath`)
- Sends the JSON response via `Send-Response` and logs the outcome via `Write-Log`
- Releases the semaphore slot in `finally` — always, even on error

**Dependencies on other components:**
- `Invoke-Script` (executes the target script)
- `Send-Response` / `New-JsonResponse` (formats and writes the HTTP response)
- `Write-Log` (records the outcome)
- `$semaphore` (releases slot in `finally`)
- `$script:cfg` (configuration, including `ApiKey`)

---

### Invoke-Script

**Purpose:** Executes a single `.ps1` file from `webroot\` and captures its output, error stream, and exit code.

**Responsibilities:**
- Starts the target script as a separate `pwsh.exe` process via `System.Diagnostics.Process`
- **GET:** passes query string key/value pairs as named PowerShell arguments (`-Key "Value"`) via `$psi.ArgumentList`
- **POST:** passes a single `-JsonFilePath "<absolute-path>"` argument pointing to the JSON file written by `Save-PostJson` — no `-Key Value` pairs; the script reads and parses the file itself
- Reads stdout and stderr asynchronously via `ReadToEndAsync()` — started before `WaitForExit()` to prevent deadlock when buffers fill
- Calls `WaitForExit(TimeoutMs)` then a second `WaitForExit()` with a 10-second timeout to ensure all buffered stream data is flushed before reading
- Returns a `PSCustomObject` with `ExitCode`, `Output`, `Error`, and `TimedOut` fields
- Terminates the process via `Kill()` and sets `TimedOut = $true` if `ScriptTimeoutSec` elapses

**Dependencies on other components:**
- `$script:cfg.PwshExe` (path to the running `pwsh.exe` — no hardcoded path)
- `$script:cfg.ScriptTimeoutSec` (timeout threshold)

---

### Logging

**Purpose:** Writes a structured log line for every completed request and for startup/shutdown events.

**Responsibilities:**
- `Write-Log` appends one line per request to `logs\YYYY-MM-DD.log`, including timestamp, client IP, request line, exit code, status text, and request ID (`X-Request-Id`). Status values for built-in endpoints: `INDEX`, `HEALTH`, `METRICS`; for script requests: `OK` / `ERROR` / `TIMEOUT`; for rejections: `BAD REQUEST`, `FORBIDDEN`, `NOT FOUND`, `METHOD NOT ALLOWED`, `RATE LIMITED`, `UNAUTHORIZED`
- `Write-StartupLog` appends to `logs\startup.log` for events that occur before the listener is running
- Both functions also write to stdout so output is visible in Scheduled Task history
- A named `Mutex` (`Global\PoshWebserverLog`) serializes concurrent writes from multiple Runspace threads; `ReleaseMutex()` is only called when `WaitOne()` succeeded
- IP-filter rejections in the main thread are logged via direct `[System.IO.File]::AppendAllText` — `Write-Log` lives in the Runspace scope and is not available in the main thread; global-throttle 429 rejections are intentionally not logged to avoid blocking `GetContext()` under burst traffic

**Dependencies on other components:**
- `$script:cfg.LogDir` (log directory path)
- `$script:logMutex` (thread-safe write serialization)

---

### Register-ScheduledTask

**Purpose:** One-time installation script that registers `Start-WebServer.ps1` as a Windows Scheduled Task and optionally configures HTTPS.

**Responsibilities:**
- Prompts for a local administrator username and password interactively
- Prompts for the API key and sets it as a `Machine`-scope system environment variable (`POSH_API_KEY`)
- Optionally configures HTTPS: creates a self-signed certificate or imports an existing one (by thumbprint or PFX file), binds it to the HTTPS port via `netsh http add sslcert`, and optionally opens Windows Firewall rules
- Creates or replaces the `PowerShell-Webserver` task with an `AtStartup` trigger
- Configures the task for indefinite runtime, up to 3 automatic restarts after crash (1-minute interval), and `RunLevel Highest`
- Zeroes the password variable from memory in a `finally` block after use

**Dependencies on other components:**
- `Start-WebServer.ps1` must be present in the same directory

---

### Webroot Scripts

**Purpose:** The actual HTTP endpoints — each `.ps1` file is an independently callable unit of work.

**Responsibilities:**
- Accept parameters via `param()` block (values arrive as strings from URL query parameters or POST JSON body)
- Write results to `Write-Output` (captured as `output` in the JSON response)
- Write errors to `Write-Error` and call `exit 1` to signal HTTP 500
- Exit with `exit 0` (or no explicit exit) to signal HTTP 200

**Dependencies on other components:**
- None — webroot scripts are isolated; they have no knowledge of the server

## Dependencies

| Package | Version | Purpose | Reason chosen |
|---|---|---|---|
| `System.Net.HttpListener` | .NET BCL | Accepts HTTP/HTTPS connections | Built into .NET; no external web framework needed |
| `System.Threading.SemaphoreSlim` | .NET BCL | Limits concurrent request slots | Lightweight; `Wait(0)` enables non-blocking capacity check |
| `System.Threading.Mutex` | .NET BCL | Serializes log file writes across threads | Named mutex works across RunspacePool Runspace boundaries |
| `System.Diagnostics.Process` | .NET BCL | Executes webroot scripts as child processes | Only reliable way to read `exit 0`/`exit 1` and enforce timeouts from within a Runspace |
| `System.Management.Automation.Runspaces.RunspacePool` | PS7 built-in | Runs each request handler in its own Runspace | Native .NET API; no serialisation of live objects; `BeginInvoke()` is non-blocking |

## Data Flow

```
Client
  │
  │  GET /script1.ps1?Detail=true          POST /script1.ps1
  │  X-Api-Key: <key>                      X-Api-Key: <key>
  │                                        Content-Type: application/json
  │                                        Body: {"Detail":"true"}
  ▼
HttpListener (System.Net.HttpListener)
  │  http://+:80/  and/or  https://+:443/
  │  GetContext() — blocks synchronously
  ▼
Main Loop
  │  IP filter: BlockedIPs / AllowedIPs
  │    ├─ blocked/not allowed → write HTTP 403 + X-Request-Id, log directly, continue
  │    └─ allowed → proceed
  │  Global throttle: MinRequestIntervalSec
  │    ├─ too fast → write HTTP 429 + X-Request-Id + Retry-After, continue (no log)
  │    └─ ok → proceed
  │  SemaphoreSlim.Wait(0)
  │    ├─ full → write HTTP 503 + X-Request-Id directly, continue
  │    └─ available → acquire slot
  │  [PowerShell]::Create() + BeginInvoke() via RunspacePool
  ▼
$requestHandler (RunspacePool Runspace)
  │  $requestId = [Guid]::NewGuid().ToString('N').Substring(0,8)
  │  Method check: non-GET/POST → HTTP 405 + X-Request-Id, return
  │  Rate limit: Test-RateLimit → HTTP 429 + X-Request-Id + Retry-After, return
  │  Auth check: X-Api-Key missing/wrong → HTTP 401 + X-Request-Id, return  (skipped for /health and /metrics)
  │  Path: /  → Get-ScriptIndex → HTTP 200 + X-Request-Id, return
  │  Path: /health → uptime + requestsTotal → HTTP 200 + X-Request-Id, return
  │  Path: /metrics → uptime + requestsTotal + rateLimitedTotal → HTTP 200 + X-Request-Id, return
  │  Validate: must be .ps1, no path traversal, file must exist
  │    ├─ invalid → HTTP 400 / 403 / 404 + X-Request-Id, return
  │    └─ valid
  │  GET:  Get-QueryParams → -Key Value arguments
  │  POST: query string present → HTTP 400 + X-Request-Id, return
  │        Get-BodyParams → validate Content-Type / size / JSON syntax
  │          ├─ error → HTTP 400 / 413 / 415 + X-Request-Id, return
  │          └─ ok → Save-PostJson → C:\posh\postjson\YYYYMMDD_HHmmss_<id>.json
  │  Invoke-Script
  ▼
Invoke-Script (blocks Runspace)
  │  GET:  System.Diagnostics.Process: pwsh.exe -File <script> -Key "Value"
  │  POST: System.Diagnostics.Process: pwsh.exe -File <script> -JsonFilePath "C:\posh\postjson\..."
  │  ReadToEndAsync() started before WaitForExit() — prevents buffer deadlock
  │  WaitForExit(ScriptTimeoutSec * 1000)
  │    ├─ timeout → Kill(), return TimedOut=$true → HTTP 504 + X-Request-Id
  │    └─ finished → second WaitForExit(10000) → Task.WaitAll(stdout, stderr, 5000) + IsCompleted guard
  │  $proc.ExitCode → 0 = HTTP 200, non-zero = HTTP 500
  ▼
$requestHandler (resumes)
  │  New-JsonResponse → { "exitCode", "output", "error" }
  │  Send-Response → HTTP 200 / 500 / 504 + X-Request-Id header
  │  Write-Log → logs\YYYY-MM-DD.log + stdout  (includes $requestId as 6th column)
  │  finally: SemaphoreSlim.Release()
  ▼
Client receives JSON response + X-Request-Id header
```
