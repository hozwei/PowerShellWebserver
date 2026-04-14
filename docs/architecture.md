# Architecture

## Overview

posh is a single-process PowerShell 7 HTTP server built on `System.Net.HttpListener`. Incoming requests are accepted synchronously in a `while` loop via `GetContext()`, then dispatched to a `Start-ThreadJob` for parallel execution. Each request resolves its URL path to a `.ps1` file inside the `webroot\` directory, executes it as a separate `pwsh.exe` process, and returns the result as a JSON envelope. The server runs as a Windows Scheduled Task under a local administrator account and writes daily-rotating log files to `logs\`. All logic is contained in two PowerShell scripts with no external dependencies beyond the .NET base class library.

## Directory Structure

```
C:\posh\
├── Start-WebServer.ps1          # Entry point: HttpListener, main loop, ThreadJob dispatch
├── Register-ScheduledTask.ps1   # One-time setup: registers the server as a Windows Scheduled Task
├── logs\                        # Runtime logs, one file per day (YYYY-MM-DD.log)
└── webroot\                     # HTTP endpoints — each .ps1 file is a route
    ├── script1.ps1              # Example: returns system information
    └── subdir\                  # Subdirectories map to URL path segments
        └── script2.ps1          # Example: lists files in a directory
```

## Key Components

### HttpListener

**Purpose:** Accepts incoming TCP connections on port 80 and produces `HttpListenerContext` objects.

**Responsibilities:**
- Binds to `http://+:80/` (all network interfaces)
- Blocks synchronously on `GetContext()` in the main loop until a request arrives
- Stopping the listener causes `GetContext()` to throw, which exits the main loop cleanly

**Dependencies on other components:**
- `System.Net.HttpListener` (.NET BCL)

---

### Main Loop & Request Dispatch

**Purpose:** Accepts one request at a time and hands each off to a parallel `ThreadJob`.

**Responsibilities:**
- Calls `GetContext()` synchronously — blocks at near-zero CPU cost until a request arrives
- Checks `SemaphoreSlim.Wait(0)` immediately: if all slots are occupied, returns HTTP 503 directly without starting a job
- Starts a `Start-ThreadJob` per accepted request, passing `$context` and `$shared`
- Cleans up completed jobs (`Get-Job -State Completed | Remove-Job -Force`) once per loop iteration

**Dependencies on other components:**
- `$semaphore` (capacity check)
- `$requestHandler` ScriptBlock (executed inside each ThreadJob)
- `$shared` hashtable (carries all configuration and function references into the job)

---

### Request Handler (`$requestHandler`)

**Purpose:** Processes a single HTTP request inside a ThreadJob.

**Responsibilities:**
- Validates HTTP method — rejects non-GET requests with HTTP 405
- Validates `X-Api-Key` header against `$cfg.ApiKey` — rejects missing or incorrect keys with HTTP 401; `/health` is exempt
- Serves built-in endpoints `GET /` (script index) and `GET /health` (server status) without invoking webroot scripts
- Resolves the URL path to a file under `webroot\`: validates `.ps1` extension, checks for path traversal, checks file existence
- Dispatches the resolved script to `Invoke-Script`
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
- Passes URL query parameters as named PowerShell arguments (`-Key "Value"`)
- Reads stdout and stderr asynchronously via `ReadToEndAsync()` — started before `WaitForExit()` to prevent deadlock when buffers fill
- Calls `WaitForExit(TimeoutMs)` then a second `WaitForExit()` without timeout to ensure all buffered stream data is flushed before reading
- Returns a `PSCustomObject` with `ExitCode`, `Output`, `Error`, and `TimedOut` fields
- Terminates the process via `Kill()` and sets `TimedOut = $true` if `ScriptTimeoutSec` elapses

**Dependencies on other components:**
- `$script:cfg.PwshExe` (path to the running `pwsh.exe` — no hardcoded path)
- `$script:cfg.ScriptTimeoutSec` (timeout threshold)

---

### Logging

**Purpose:** Writes a structured log line for every completed request and for startup/shutdown events.

**Responsibilities:**
- `Write-Log` appends one line per request to `logs\YYYY-MM-DD.log`, including timestamp, client IP, request line, exit code, and status text
- `Write-StartupLog` appends to `logs\startup.log` for events that occur before the listener is running
- Both functions also write to stdout so output is visible in Scheduled Task history
- A named `Mutex` (`Global\PoshWebserverLog`) serializes concurrent writes from multiple ThreadJob threads; `ReleaseMutex()` is only called when `WaitOne()` succeeded

**Dependencies on other components:**
- `$script:cfg.LogDir` (log directory path)
- `$script:logMutex` (thread-safe write serialization)

---

### Register-ScheduledTask

**Purpose:** One-time installation script that registers `Start-WebServer.ps1` as a Windows Scheduled Task.

**Responsibilities:**
- Prompts for a local administrator username and password interactively
- Prompts for the API key and sets it as a `Machine`-scope system environment variable (`POSH_API_KEY`)
- Creates or replaces the `PowerShell-Webserver` task with an `AtStartup` trigger
- Configures the task for indefinite runtime, up to 3 automatic restarts after crash (1-minute interval), and `RunLevel Highest`
- Zeroes the password variable from memory in a `finally` block after use

**Dependencies on other components:**
- `Start-WebServer.ps1` must be present in the same directory

---

### Webroot Scripts

**Purpose:** The actual HTTP endpoints — each `.ps1` file is an independently callable unit of work.

**Responsibilities:**
- Accept parameters via `param()` block (values arrive from URL query parameters)
- Write results to `Write-Output` (captured as `output` in the JSON response)
- Write errors to `Write-Error` and call `exit 1` to signal HTTP 500
- Exit with `exit 0` (or no explicit exit) to signal HTTP 200

**Dependencies on other components:**
- None — webroot scripts are isolated; they have no knowledge of the server

## Dependencies

| Package | Version | Purpose | Reason chosen |
|---|---|---|---|
| `System.Net.HttpListener` | .NET BCL | Accepts HTTP connections | Built into .NET; no external web framework needed |
| `System.Threading.SemaphoreSlim` | .NET BCL | Limits concurrent request slots | Lightweight; `Wait(0)` enables non-blocking capacity check |
| `System.Threading.Mutex` | .NET BCL | Serializes log file writes across threads | Named mutex works across ThreadJob boundaries |
| `System.Diagnostics.Process` | .NET BCL | Executes webroot scripts as child processes | Only reliable way to read `exit 0`/`exit 1` and enforce timeouts from within a ThreadJob |
| `Microsoft.PowerShell.ThreadJob` | PS7 built-in | Runs each request handler as a thread | `Start-ThreadJob` is built into PS7; lower overhead than `Start-Job`; does not require a separate process |

## Data Flow

```
Client
  │
  │  GET /script1.ps1?Detail=true
  │  X-Api-Key: <key>
  ▼
HttpListener (System.Net.HttpListener)
  │  GetContext() — blocks synchronously
  ▼
Main Loop
  │  SemaphoreSlim.Wait(0)
  │    ├─ full → write HTTP 503 directly, continue
  │    └─ available → acquire slot
  │  Start-ThreadJob { $requestHandler }
  ▼
$requestHandler (ThreadJob thread)
  │  Method check: non-GET → HTTP 405, return
  │  Auth check: X-Api-Key missing/wrong → HTTP 401, return  (skipped for /health)
  │  Path: /  → Get-ScriptIndex → HTTP 200, return
  │  Path: /health → uptime + requestsTotal → HTTP 200, return
  │  Validate: must be .ps1, no path traversal, file must exist
  │    ├─ invalid → HTTP 400 / 403 / 404, return
  │    └─ valid → Get-QueryParams → Invoke-Script
  ▼
Invoke-Script (blocks ThreadJob thread)
  │  System.Diagnostics.Process: pwsh.exe -File <script> -Key "Value"
  │  ReadToEndAsync() started before WaitForExit() — prevents buffer deadlock
  │  WaitForExit(ScriptTimeoutSec * 1000)
  │    ├─ timeout → Kill(), return TimedOut=$true → HTTP 504
  │    └─ finished → second WaitForExit() → GetAwaiter().GetResult()
  │  $proc.ExitCode → 0 = HTTP 200, non-zero = HTTP 500
  ▼
$requestHandler (resumes)
  │  New-JsonResponse → { "exitCode", "output", "error" }
  │  Send-Response → HTTP 200 / 500 / 504
  │  Write-Log → logs\YYYY-MM-DD.log + stdout
  │  finally: SemaphoreSlim.Release()
  ▼
Client receives JSON response
```
