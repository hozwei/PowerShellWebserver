# Configuration

## Configuration File

There is no external configuration file. All configuration is defined inline in `Start-WebServer.ps1` as the `$cfg` hashtable and the `$baseDir` variable. To change any setting, edit the file directly.

**File location:** `C:\posh\Start-WebServer.ps1`

**Minimal example (defaults as shipped):**

```powershell
$baseDir = 'C:\posh'

$cfg = @{
    HttpsEnabled        = $HttpsEnabled.IsPresent
    HttpPort            = $HttpPort
    HttpsPort           = $HttpsPort
    WebRoot             = Join-Path $baseDir 'webroot'
    LogDir              = Join-Path $baseDir 'logs'
    PwshExe             = (Get-Process -Id $PID).MainModule.FileName
    ApiKey              = $env:POSH_API_KEY
    ScriptTimeoutSec    = 900
    MaxConcurrent       = 10
    LogRetentionDays    = 180
    MaxRequestBodyBytes = 20MB
}
```

**Complete example with non-default values:**

```powershell
$baseDir = 'D:\automation\posh'

$cfg = @{
    HttpsEnabled        = $HttpsEnabled.IsPresent
    HttpPort            = $HttpPort
    HttpsPort           = $HttpsPort
    WebRoot             = Join-Path $baseDir 'webroot'
    LogDir              = Join-Path $baseDir 'logs'
    PwshExe             = (Get-Process -Id $PID).MainModule.FileName
    ApiKey              = $env:POSH_API_KEY
    ScriptTimeoutSec    = 300
    MaxConcurrent       = 5
    LogRetentionDays    = 30
    MaxRequestBodyBytes = 5MB
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

> **`$baseDir`** (line 91 in `Start-WebServer.ps1`, not part of `$cfg`): Hardcoded deployment path (`"C:\posh"`). Change this single line to relocate the entire server. Used as the base path for `WebRoot` and `LogDir`.

| Option | Type | Default | Description |
|---|---|---|---|
| `WebRoot` | `string` | `"C:\posh\webroot"` | Absolute path to the directory that contains the `.ps1` endpoint scripts. URL paths are resolved relative to this directory. |
| `LogDir` | `string` | `"C:\posh\logs"` | Absolute path to the directory where daily log files are written. Created automatically at startup if it does not exist. |
| `PwshExe` | `string` | `(Get-Process -Id $PID).MainModule.FileName` | Absolute path to `pwsh.exe` used to execute webroot scripts. Resolved from the currently running process — no hardcoded path. |
| `ApiKey` | `string` | `$env:POSH_API_KEY` | API key value checked against the `X-Api-Key` request header. Always sourced from the `POSH_API_KEY` environment variable — do not hardcode a value here. |
| `ScriptTimeoutSec` | `integer` | `900` | Maximum number of seconds a webroot script may run before it is forcibly terminated. The caller receives HTTP 504 when this limit is exceeded. |
| `MaxConcurrent` | `integer` | `10` | Maximum number of requests processed simultaneously. Requests that arrive when all slots are occupied immediately receive HTTP 503. |
| `LogRetentionDays` | `integer` | `180` | Number of days to retain log files in `LogDir`. Log files older than this value are deleted at startup. Set to `0` to disable log rotation entirely. |
| `MaxRequestBodyBytes` | `integer` | `20971520` (20 MB) | Maximum allowed size of a POST request body in bytes. Requests exceeding this limit receive HTTP 413 immediately. Use PowerShell byte literals for readability: `5MB`, `10MB`. |

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
