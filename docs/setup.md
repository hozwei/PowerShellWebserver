# Setup

## Prerequisites

| Tool | Minimum Version | Link |
|---|---|---|
| Windows | 10 / Server 2019 | — |
| PowerShell 7 (`pwsh.exe`) | 7.0 | https://github.com/PowerShell/PowerShell/releases |
| Administrator account | — | Local account with password (not SYSTEM) |

> **Port 80 requires Administrator privileges.** The server must run under a local administrator account with a password — not the SYSTEM account — because some operations (GPU access, network authentication) do not work under SYSTEM.

## Installation

1. Copy the repository contents to `C:\posh\`:

    ```powershell
    Copy-Item -Path ".\*" -Destination "C:\posh\" -Recurse -Force
    ```

2. Open a PowerShell 7 terminal as Administrator:

    ```powershell
    # Verify you are running PowerShell 7
    $PSVersionTable.PSVersion
    ```

3. Change to the deployment directory:

    ```powershell
    cd C:\posh
    ```

4. Register the server as a Windows Scheduled Task:

    ```powershell
    .\Register-ScheduledTask.ps1
    ```

    The script will prompt for:
    - A local administrator username (default: `Administrator`) and password
    - An API key — this value is stored as the `POSH_API_KEY` system environment variable and is required to authenticate all requests

5. Start the task immediately without rebooting:

    ```powershell
    Start-ScheduledTask -TaskName 'PowerShell-Webserver'
    ```

## Configuration

All configuration is inline in `Start-WebServer.ps1`. The deployment path is hardcoded to `C:\posh\`. The API key is read from the `POSH_API_KEY` system environment variable at startup.

For a full description of all options, see [Configuration](./configuration.md).

## Verify Installation

Run the following command from any machine that can reach port 80 on the host. Replace `<key>` with the API key set during installation:

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = '<key>' }
```

Expected output:

```json
{
  "exitCode": 0,
  "output": "=== Systeminformation ===\nHostname    : ...\nZeitstempel : ...\nAufgerufen  : C:\\posh\\webroot\\script1.ps1\n\nFertig.",
  "error": ""
}
```

The health endpoint is available without authentication:

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

Expected output:

```json
{ "status": "ok", "uptime": "0h 0m 12s", "requestsTotal": 0 }
```

### Optional: Manual start (without Scheduled Task)

To run the server interactively in an Administrator PowerShell 7 terminal, set the environment variable first:

```powershell
$env:POSH_API_KEY = '<key>'
cd C:\posh
.\Start-WebServer.ps1
```

Press `Ctrl+C` to stop. The server performs a graceful shutdown, waiting up to 5 seconds for in-flight requests to complete.

### Optional: Remove the Scheduled Task

```powershell
Unregister-ScheduledTask -TaskName 'PowerShell-Webserver' -Confirm:$false
```
