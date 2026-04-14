# posh

A Windows HTTP/HTTPS server that maps URL paths directly to PowerShell scripts and returns their output as JSON.

Place a `.ps1` file in `webroot\` — it is immediately reachable as an HTTP endpoint. No registration, no framework, no restart required.

## Documentation

- [Overview](./docs/overview.md) — What posh is and the problem it solves
- [Setup](./docs/setup.md) — Installation and prerequisites
- [Usage](./docs/usage.md) — How to call endpoints and interpret responses
- [Architecture](./docs/architecture.md) — System design and key components
- [Configuration](./docs/configuration.md) — All configuration options
- [Contributing](./docs/contributing.md) — Development workflow, conventions, and adding new endpoints
- [Changelog](./docs/changelog.md) — Version history

## Features

- **URL-to-script routing** — every `.ps1` file in `webroot\` is an HTTP endpoint; subdirectories map to URL path segments.
- **GET and POST support** — URL query parameters (GET) and flat JSON body keys (POST) are passed as named PowerShell arguments to the target script. Body keys take precedence when names collide.
- **JSON response envelope** — all responses follow `{ "exitCode", "output", "error" }`, regardless of which script ran.
- **HTTPS support** — optional TLS on a configurable port. Certificate creation, `netsh` binding, and firewall rules are handled automatically by `Register-ScheduledTask.ps1`.
- **API key authentication** — all endpoints except `GET /health` require an `X-Api-Key` header. The key is configured via the `POSH_API_KEY` system environment variable.
- **Concurrent request handling** — up to `MaxConcurrent` (default: 10) requests are processed in parallel using `Start-ThreadJob`. Requests beyond the limit receive HTTP 503 immediately.
- **Script timeout enforcement** — scripts exceeding `ScriptTimeoutSec` (default: 900 s) are terminated and the caller receives HTTP 504.
- **Log rotation** — daily log files in `logs\`; files older than `LogRetentionDays` days are deleted at startup.
- **Built-in health endpoint** — `GET /health` returns server status, uptime, and total request count without authentication.
- **Windows Scheduled Task** — `Register-ScheduledTask.ps1` installs the server as an auto-starting task in one command.

## Quick Start

**Prerequisites:** Windows 10 / Server 2019, PowerShell 7, local administrator account with password.

```powershell
# 1. Copy to deployment directory
Copy-Item -Path ".\*" -Destination "C:\posh\" -Recurse -Force

# 2. Register as a Windows Scheduled Task (Administrator PowerShell 7)
cd C:\posh
.\Register-ScheduledTask.ps1        # prompts for username, password, API key, and optional HTTPS

# 3. Start immediately (no reboot needed)
Start-ScheduledTask -TaskName 'PowerShell-Webserver'

# 4. Verify
Invoke-RestMethod -Uri 'http://localhost/health'
```

Expected response from `/health`:

```json
{ "status": "ok", "uptime": "0h 0m 5s", "requestsTotal": 0 }
```

For the full installation guide including HTTPS setup, see [Setup](./docs/setup.md).

## Calling an Endpoint

Every `.ps1` file in `webroot\` is immediately callable via HTTP GET or POST. Include the `X-Api-Key` header and pass script parameters as URL query parameters (GET) or as a flat JSON body (POST).

**GET — parameters as query string:**

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1?ComputerName=WORKSTATION&Detail=true' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

**POST — parameters as JSON body:**

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' `
    -Method Post `
    -ContentType 'application/json' `
    -Body '{"ComputerName":"WORKSTATION","Detail":"true"}' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Both calls produce the same result:

```json
{
  "exitCode": 0,
  "output": "=== Systeminformation ===\nHostname    : WORKSTATION\n...",
  "error": ""
}
```

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
# webroot\my-script.ps1
#Requires -Version 7.0
param(
    [string] $Name = 'World'
)

Write-Output "Hello, $Name!"
```

Call it:

```powershell
Invoke-RestMethod -Uri 'http://localhost/my-script.ps1?Name=Max' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Rules for webroot scripts: use `Write-Output` for normal output, `Write-Error` for errors, `exit 1` to signal HTTP 500, `exit 0` (or no explicit exit) for HTTP 200. All query parameters and POST body parameters arrive as `string` — cast explicitly when needed. See [Contributing](./docs/contributing.md) for the full rules.

## HTTP Status Codes

| Code | Meaning |
|---|---|
| `200` | Script exited with code `0` |
| `400` | Request path does not end in `.ps1`, or POST body is not valid flat JSON |
| `401` | `X-Api-Key` header missing or incorrect |
| `403` | Path-traversal attempt detected |
| `404` | Script file not found in `webroot\` |
| `405` | HTTP method not allowed — only GET and POST are accepted |
| `413` | POST body exceeds `MaxRequestBodyBytes` |
| `415` | POST request `Content-Type` is not `application/json` |
| `500` | Script exited with a non-zero exit code |
| `503` | Server is at maximum concurrent request capacity |
| `504` | Script exceeded `ScriptTimeoutSec` and was terminated |

## Configuration

All configuration is inline in `Start-WebServer.ps1` as the `$cfg` hashtable. There is no external config file. HTTP/HTTPS ports and HTTPS activation are runtime parameters.

| Option | Default | Description |
|---|---|---|
| `-HttpPort` | `80` | HTTP listen port; `0` = HTTP disabled |
| `-HttpsEnabled` | off | Enable HTTPS (requires `netsh sslcert` binding) |
| `-HttpsPort` | `443` | HTTPS listen port |
| `WebRoot` | `C:\posh\webroot` | Directory containing the `.ps1` endpoint scripts |
| `LogDir` | `C:\posh\logs` | Directory for daily log files |
| `ApiKey` | `$env:POSH_API_KEY` | API key — always read from the environment variable |
| `ScriptTimeoutSec` | `900` | Seconds before a running script is killed and HTTP 504 is returned |
| `MaxConcurrent` | `10` | Maximum parallel requests — excess requests receive HTTP 503 |
| `LogRetentionDays` | `180` | Days to keep log files; `0` disables rotation |
| `MaxRequestBodyBytes` | `20971520` (20 MB) | Maximum POST body size in bytes |

For the full options reference, see [Configuration](./docs/configuration.md).

## Architecture Overview

```
Client
  │  GET /subdir/script2.ps1?Path=C:\Temp   X-Api-Key: <key>
  ▼
HttpListener  ──  http://+:80/  https://+:443/
  │  Main Loop (GetContext)
  │  SemaphoreSlim: full → HTTP 503
  │  Start-ThreadJob { $requestHandler }
  ▼
$requestHandler (ThreadJob)
  │  Auth · Method · Path validation
  │  Invoke-Script
  ▼
pwsh.exe -File webroot\subdir\script2.ps1 -Path "C:\Temp"
  │  stdout + stderr via ReadToEndAsync()
  │  $proc.ExitCode → HTTP 200 / 500 / 504
  ▼
{ "exitCode": 0, "output": "...", "error": "" }
```

posh has no external dependencies beyond the .NET base class library and PowerShell 7 built-ins. For a full component breakdown, see [Architecture](./docs/architecture.md).
