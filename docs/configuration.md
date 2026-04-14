# Configuration

## Configuration File

There is no external configuration file. All configuration is defined inline in `Start-WebServer.ps1` as the `$cfg` hashtable and the `$baseDir` variable. To change any setting, edit the file directly.

**File location:** `C:\posh\Start-WebServer.ps1`

**Minimal example (defaults as shipped):**

```powershell
$baseDir = 'C:\posh'

$cfg = @{
    Prefix           = 'http://+:80/'
    WebRoot          = Join-Path $baseDir 'webroot'
    LogDir           = Join-Path $baseDir 'logs'
    PwshExe          = (Get-Process -Id $PID).MainModule.FileName
    ApiKey           = $env:POSH_API_KEY
    ScriptTimeoutSec = 900
    MaxConcurrent    = 10
    LogRetentionDays = 180
}
```

**Complete example with non-default values:**

```powershell
$baseDir = 'D:\automation\posh'

$cfg = @{
    Prefix           = 'http://+:8080/'
    WebRoot          = Join-Path $baseDir 'webroot'
    LogDir           = Join-Path $baseDir 'logs'
    PwshExe          = (Get-Process -Id $PID).MainModule.FileName
    ApiKey           = $env:POSH_API_KEY
    ScriptTimeoutSec = 300
    MaxConcurrent    = 5
    LogRetentionDays = 30
}
```

> After editing `Start-WebServer.ps1`, restart the Scheduled Task for changes to take effect:
> ```powershell
> Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
> Start-ScheduledTask -TaskName 'PowerShell-Webserver'
> ```

## Environment Variables

| Variable | Overrides Option | Description |
|---|---|---|
| `POSH_API_KEY` | `ApiKey` | API key required in the `X-Api-Key` request header. Must be set as a `Machine`-scope system environment variable before the server starts. Set automatically by `Register-ScheduledTask.ps1`. The server refuses to start if this variable is empty or missing. |

To set manually (requires an Administrator session):

```powershell
[Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key-here', 'Machine')
```

## Options Reference

| Option | Type | Default | Required | Description |
|---|---|---|---|---|
| `$baseDir` | `string` | `"C:\posh"` | Yes | Absolute path to the deployment directory. Used as the base for `WebRoot` and `LogDir`. Must exist before the server starts. |
| `Prefix` | `string` | `"http://+:80/"` | Yes | The `HttpListener` URL prefix. `+` binds to all network interfaces. Change the port number here to use a port other than 80. Must end with `/`. |
| `WebRoot` | `string` | `"C:\posh\webroot"` | Yes | Absolute path to the directory that contains the `.ps1` endpoint scripts. URL paths are resolved relative to this directory. |
| `LogDir` | `string` | `"C:\posh\logs"` | Yes | Absolute path to the directory where daily log files are written. Created automatically at startup if it does not exist. |
| `PwshExe` | `string` | `(Get-Process -Id $PID).MainModule.FileName` | Yes | Absolute path to `pwsh.exe` used to execute webroot scripts. Resolved from the currently running process — no hardcoded path. |
| `ApiKey` | `string` | `$env:POSH_API_KEY` | Yes | API key value checked against the `X-Api-Key` request header. Always sourced from the `POSH_API_KEY` environment variable — do not hardcode a value here. |
| `ScriptTimeoutSec` | `integer` | `900` | Yes | Maximum number of seconds a webroot script may run before it is forcibly terminated. The caller receives HTTP 504 when this limit is exceeded. |
| `MaxConcurrent` | `integer` | `10` | Yes | Maximum number of requests processed simultaneously. Requests that arrive when all slots are occupied immediately receive HTTP 503. |
| `LogRetentionDays` | `integer` | `180` | Yes | Number of days to retain log files in `LogDir`. Log files older than this value are deleted at startup. Set to `0` to disable log rotation entirely. |

### Scheduled Task Options

The following values are hardcoded in `Register-ScheduledTask.ps1` and affect how the server is registered as a Windows Scheduled Task.

| Option | Type | Default | Required | Description |
|---|---|---|---|---|
| `$TASK_NAME` | `string` | `"PowerShell-Webserver"` | Yes | The name of the Windows Scheduled Task as it appears in Task Scheduler. Used to start, stop, and unregister the task via `*-ScheduledTask` cmdlets. |
| `$SCRIPT_PATH` | `string` | `"<baseDir>\Start-WebServer.ps1"` | Yes | Absolute path to `Start-WebServer.ps1` passed as the `-File` argument to `pwsh.exe`. Resolved automatically from `$PSScriptRoot`. |
| `$WORK_DIR` | `string` | `"<baseDir>"` | Yes | Working directory for the `pwsh.exe` process. Must be the directory containing `Start-WebServer.ps1`. |
| Restart count | `integer` | `3` | — | Number of automatic restart attempts after a crash. Configured on `$settings.RestartCount`. |
| Restart interval | `string` | `"PT1M"` | — | ISO 8601 duration between restart attempts. Configured on `$settings.RestartInterval`. |
