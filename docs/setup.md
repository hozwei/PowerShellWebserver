# Setup

## Prerequisites

| Tool | Minimum Version | Link |
|---|---|---|
| Windows | 10 / Server 2019 | — |
| PowerShell 7 (`pwsh.exe`) | 7.0 | https://github.com/PowerShell/PowerShell/releases |
| Administrator account | — | Local account with password (not SYSTEM) |

> **Ports 80 and 443 require Administrator privileges.** The server must run under a local administrator account with a password — not the SYSTEM account — because some operations (GPU access, network authentication) do not work under SYSTEM.

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

    The script will prompt interactively for:
    - A local administrator username (default: `Administrator`) and password
    - An API key — stored as the `POSH_API_KEY` system environment variable; required to authenticate all requests
    - Whether to enable HTTPS (optional — see [HTTPS Configuration](#https-configuration) below)
    - Whether to open the configured ports in Windows Firewall

5. Start the task immediately without rebooting:

    ```powershell
    Start-ScheduledTask -TaskName 'PowerShell-Webserver'
    ```

## HTTPS Configuration

HTTPS is configured interactively during `Register-ScheduledTask.ps1`. When prompted:

1. Answer **y** to enable HTTPS
2. Confirm or change the HTTP port (default: `80`) and HTTPS port (default: `443`)
3. Choose a certificate source:
   - **Option 1 — New self-signed certificate:** created automatically, stored in `Cert:\LocalMachine\My`, bound to the HTTPS port via `netsh http add sslcert`. Includes the machine hostname, `localhost`, and all local IPv4 addresses as Subject Alternative Names.
   - **Option 2A — Existing certificate by thumbprint:** the certificate must already be in `Cert:\LocalMachine\My`. Enter the thumbprint when prompted.
   - **Option 2B — Import a PFX file:** enter the path to the `.pfx` file and its password. The certificate is imported into `Cert:\LocalMachine\My` and bound to the port.
4. Optionally disable HTTP (HTTP-only mode is off by default)
5. Optionally open the ports in Windows Firewall

`Register-ScheduledTask.ps1` can be run again at any time to replace the certificate or reconfigure HTTPS. The existing `netsh` binding is deleted and recreated on each run.

**Manual HTTPS prerequisites (if setting up without `Register-ScheduledTask.ps1`):**

```powershell
# Create a self-signed certificate
$san  = "2.5.29.17={text}DNS=$env:COMPUTERNAME&DNS=localhost&IPAddress=127.0.0.1"
$cert = New-SelfSignedCertificate -Subject "CN=$env:COMPUTERNAME" `
    -TextExtension     @($san) `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -NotAfter          (Get-Date).AddYears(10)

# Bind the certificate to port 443
$thumb = $cert.Thumbprint -replace '[^a-fA-F0-9]', ''
netsh http add sslcert ipport=0.0.0.0:443 certhash=$thumb "appid={a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d}"
```

> `Start-WebServer.ps1` checks for a valid `netsh` binding on startup when `-HttpsEnabled` is passed. If no binding is found, the server exits with an error message.

## Configuration

All configuration is inline in `Start-WebServer.ps1`. The deployment path is hardcoded to `C:\posh\`. The API key is read from the `POSH_API_KEY` system environment variable at startup.

For a full description of all options, see [Configuration](./configuration.md).

## Verify Installation

Run the following from any machine that can reach the server. Replace `<key>` with the API key set during installation:

```powershell
# HTTP
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = '<key>' }

# HTTPS (if configured; -SkipCertificateCheck for self-signed certificates)
Invoke-RestMethod -Uri 'https://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = '<key>' } -SkipCertificateCheck
```

Expected output:

```json
{
  "exitCode": 0,
  "output": "=== System Information ===\nHostname    : ...\nTimestamp   : ...\nCalled from : C:\\posh\\webroot\\script1.ps1\n\nDone.",
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

# HTTP only
.\Start-WebServer.ps1

# HTTP + HTTPS
.\Start-WebServer.ps1 -HttpPort 80 -HttpsEnabled -HttpsPort 443

# HTTPS only
.\Start-WebServer.ps1 -HttpPort 0 -HttpsEnabled -HttpsPort 443
```

Press `Ctrl+C` to stop. The server performs a graceful shutdown, waiting up to 5 seconds for in-flight requests to complete.

### Optional: Remove the Scheduled Task

```powershell
Unregister-ScheduledTask -TaskName 'PowerShell-Webserver' -Confirm:$false
```
