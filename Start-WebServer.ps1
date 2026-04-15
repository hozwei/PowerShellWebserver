#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell HTTP/HTTPS web server — executes local .ps1 scripts via HTTP requests.

.DESCRIPTION
    Listens on port 80 (HTTP) by default and optionally on port 443 (HTTPS).
    URL paths are mapped directly to .\webroot\.
    Query parameters are passed as named arguments to the script.
    Every request is logged to .\logs\YYYY-MM-DD.log.

    Requires PowerShell 7 (pwsh.exe).
    Must be run as Administrator.

    HTTPS prerequisite: a netsh sslcert binding must have been configured via
    Register-ScheduledTask.ps1. The server checks this at startup and exits with
    exit 1 if the binding is missing.

.PARAMETER HttpsEnabled
    Enable HTTPS. Requires a netsh sslcert binding for HttpsPort.

.PARAMETER HttpPort
    HTTP port. Default: 80. Value 0 = HTTP disabled (only useful with -HttpsEnabled).

.PARAMETER HttpsPort
    HTTPS port. Default: 443. Only evaluated when -HttpsEnabled is set.

.EXAMPLE
    # HTTP only (default)
    .\Start-WebServer.ps1

    # HTTP on port 8080
    .\Start-WebServer.ps1 -HttpPort 8080

    # HTTPS on 443, HTTP on 80 still active
    .\Start-WebServer.ps1 -HttpsEnabled -HttpPort 80 -HttpsPort 443

    # HTTPS only (HTTP disabled)
    .\Start-WebServer.ps1 -HttpsEnabled -HttpPort 0 -HttpsPort 443

    http://localhost/script1.ps1
    http://localhost/subdir/script2.ps1?Name=Max&Value=42
    http://localhost/                    <- lists all available scripts
    http://localhost/health              <- server status, uptime, request counter
#>

param(
    [switch] $HttpsEnabled,
    [int]    $HttpPort  = 80,
    [int]    $HttpsPort = 443
)

# ---------------------------------------------------------------------------
# Base path — hardcoded for reliable operation across all execution contexts.
# Defined before all checks so every early-exit path shares the same value.
# Adjust if the deployment directory differs.
# ---------------------------------------------------------------------------
$baseDir = 'C:\posh'

# ---------------------------------------------------------------------------
# PowerShell 7 — mandatory check
# Must run before $cfg and logging setup.
# $PSVersionTable.PSEdition is 'Core' in PS 7, 'Desktop' in PS 5.x
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Core') {
    $logDir  = Join-Path $baseDir 'logs'
    $logFile = Join-Path $logDir 'startup.log'
    $line    = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | PowerShell 7 required. Running version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    try {
        if (-not (Test-Path $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($logFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    exit 1
}

# ---------------------------------------------------------------------------
# Ensure Start-ThreadJob is available — already built into PS 7 via
# Microsoft.PowerShell.ThreadJob. The separate module is only installed
# when the command is genuinely missing.
# ---------------------------------------------------------------------------
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Output 'Start-ThreadJob not available — installing...'
    Install-Module -Name ThreadJob -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    Import-Module ThreadJob -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Do NOT set ErrorActionPreference to Stop — the process runs indefinitely.
# Errors are handled per request, never globally.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# API key check — must run before $cfg so $apiKey is set when the hashtable
# is constructed. POSH_API_KEY must be set as a system environment variable
# (via Register-ScheduledTask.ps1 or manually:
# [Environment]::SetEnvironmentVariable('POSH_API_KEY','...','Machine'))
# No key = no start — unprotected operation is not permitted.
# ---------------------------------------------------------------------------
$apiKey = $env:POSH_API_KEY
if ([string]::IsNullOrEmpty($apiKey)) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | ERROR: Environment variable POSH_API_KEY is not set. Server will not start."
    try {
        if (-not (Test-Path $baseDir)) { $null = New-Item -ItemType Directory -Path $baseDir -Force }
        $startupLog = Join-Path $baseDir 'logs\startup.log'
        [System.IO.File]::AppendAllText($startupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output 'Solution: set POSH_API_KEY as a system environment variable and restart the server.'
    Write-Output "  [Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key', 'Machine')"
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration
# The prefix is no longer stored in $cfg — it is built dynamically from
# HttpPort/HttpsPort and added directly to the listener.
# HttpPort = 0 signals: HTTP disabled (only useful with HttpsEnabled).
# ---------------------------------------------------------------------------
$cfg = @{
    HttpsEnabled        = $HttpsEnabled.IsPresent                    # HTTPS active?
    HttpPort            = $HttpPort                                  # HTTP port (0 = disabled)
    HttpsPort           = $HttpsPort                                 # HTTPS port (only relevant when HttpsEnabled)
    WebRoot             = Join-Path $baseDir 'webroot'
    LogDir              = Join-Path $baseDir 'logs'
    PwshExe             = (Get-Process -Id $PID).MainModule.FileName # pwsh.exe of the running process — no hardcoded path
    ApiKey              = $apiKey                                    # from $env:POSH_API_KEY — already checked for empty string
    ScriptTimeoutSec    = 900    # 15 minutes — scripts running longer are terminated (HTTP 504)
    MaxConcurrent       = 10     # maximum parallel requests — excess requests receive HTTP 503
    LogRetentionDays    = 180    # log files older than N days are deleted at startup (0 = disabled)
    MaxRequestBodyBytes = 20MB   # maximum POST body size in bytes — larger requests: HTTP 413
}

# Runtime measurement from server start — used for health check uptime.
$startTime = [System.Diagnostics.Stopwatch]::StartNew()

# Counts completed script requests (exit-code-independent).
# [ref] + Interlocked::Increment guarantees thread safety without a mutex.
$script:requestsTotal = [ref] 0L

# Mutex serializes concurrent write access to the log file.
# Global\ makes the mutex unique across process boundaries.
$script:logMutex = [System.Threading.Mutex]::new($false, 'Global\PoshWebserverLog')

# ---------------------------------------------------------------------------
# Logging
# Writes to the log file AND to stdout (visible in Scheduled Task event log).
# No Write-Host with -ForegroundColor — throws IOException in non-interactive contexts.
# $script:cfg instead of $cfg — function also runs in RunspacePool instances.
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string] $ClientIP   = '-',
        [string] $Request    = '-',
        [string] $Status     = '-',
        [string] $ExitCode   = '-'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} | {1} | {2} | EXIT:{3} | {4}' -f `
        $timestamp,
        $ClientIP.PadRight(15),
        $Request.PadRight(60),
        $ExitCode.PadRight(4),
        $Status

    $logFile = Join-Path $script:cfg.LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')

    # Mutex prevents corrupted lines from parallel writes across ThreadJobs.
    # WaitOne(500): wait at most 500ms — on failure continue silently, never kill the process.
    # Track $acquired: ReleaseMutex() must only be called when WaitOne() succeeded —
    # otherwise ApplicationException because the calling thread does not hold the mutex.
    $acquired = $false
    try {
        $acquired = $script:logMutex.WaitOne(500)
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { } finally {
        try { if ($acquired) { $script:logMutex.ReleaseMutex() } } catch { }
    }

    # Also to stdout — appears in Scheduled Task history output.
    Write-Output $line
}

# Startup events (before the listener) are written to a separate startup.log.
function Write-StartupLog {
    param([string] $Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp | STARTUP | $Message"

    # LogDir is already ensured in the startup flow — no Test-Path needed.
    try {
        Add-Content -LiteralPath (Join-Path $script:cfg.LogDir 'startup.log') -Value $line -Encoding UTF8
    } catch { }

    Write-Output $line
}

# ---------------------------------------------------------------------------
# Log rotation
# Deletes .log files in LogDir that are older than RetentionDays days.
# Runs once at startup — never during operation.
# RetentionDays = 0: rotation disabled (explicit opt-out).
# Returns the number of deleted files — logging is the caller's responsibility.
# ---------------------------------------------------------------------------
function Remove-OldLogs {
    param(
        [string] $LogDir,
        [int]    $RetentionDays
    )

    if ($RetentionDays -le 0) { return 0 }

    $cutoff  = (Get-Date).AddDays(-$RetentionDays)
    $deleted = 0

    Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
            } catch { }
        }

    return $deleted
}

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-StartupLog 'ERROR: Not running as Administrator. Port binding requires admin privileges.'
    Write-Output ''
    Write-Output 'ERROR: This script must be run as Administrator.'
    Write-Output 'Solution: open pwsh.exe as Administrator and run again.'
    exit 1
}

# ---------------------------------------------------------------------------
# HTTPS validation
# Check whether a netsh sslcert binding exists for the configured HTTPS port
# before starting the listener. Missing binding: hard exit with exit 1.
# Silent fallback to HTTP would be dangerous — unencrypted communication
# would occur without notice.
# ---------------------------------------------------------------------------
if ($cfg.HttpsEnabled) {
    $netshOut = netsh http show sslcert "ipport=0.0.0.0:$($cfg.HttpsPort)" 2>&1
    if ($LASTEXITCODE -ne 0 -or ($netshOut -join '') -notmatch 'IP:Port') {
        Write-StartupLog "ERROR: No netsh sslcert binding found for port $($cfg.HttpsPort)."
        Write-StartupLog 'Solution: run Register-ScheduledTask.ps1 again and configure HTTPS.'
        Write-Output ''
        Write-Output "ERROR: HTTPS configured but no certificate binding found for port $($cfg.HttpsPort)."
        Write-Output "Check: netsh http show sslcert ipport=0.0.0.0:$($cfg.HttpsPort)"
        Write-Output 'Solution: run Register-ScheduledTask.ps1 again.'
        exit 1
    }
    Write-StartupLog "HTTPS validation OK: netsh sslcert binding found for port $($cfg.HttpsPort)."
}

# ---------------------------------------------------------------------------
# Log startup information
# ---------------------------------------------------------------------------
$httpsInfo = if ($cfg.HttpsEnabled) { "  HTTPS=:$($cfg.HttpsPort)" } else { '' }
$httpInfo  = if ($cfg.HttpPort -gt 0) { "  HTTP=:$($cfg.HttpPort)" } else { '  HTTP=disabled' }
Write-StartupLog "Web server starting. BaseDir=$baseDir  WebRoot=$($cfg.WebRoot)  LogDir=$($cfg.LogDir)  PS=$($PSVersionTable.PSVersion)$httpInfo$httpsInfo"

# ---------------------------------------------------------------------------
# Ensure directories exist
# ---------------------------------------------------------------------------
foreach ($dir in @($cfg.WebRoot, $cfg.LogDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Write-StartupLog "Directory created: $dir"
    }
}

# ---------------------------------------------------------------------------
# Log rotation at startup
# ---------------------------------------------------------------------------
$deletedLogs = Remove-OldLogs -LogDir $cfg.LogDir -RetentionDays $cfg.LogRetentionDays
if ($deletedLogs -gt 0) {
    Write-StartupLog "Log rotation: $deletedLogs file(s) older than $($cfg.LogRetentionDays) days deleted."
}

# ---------------------------------------------------------------------------
# Configure HTTP listener
# Prefixes are built dynamically from HttpPort/HttpsPort.
# HttpPort = 0: no HTTP prefix — HTTPS only.
# Both protocols can be active simultaneously — HttpListener supports
# mixed http/https prefixes without restrictions.
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()

$activePrefixes = [System.Collections.Generic.List[string]]::new()
if ($cfg.HttpsEnabled) {
    $null = $activePrefixes.Add("https://+:$($cfg.HttpsPort)/")
}
if ($cfg.HttpPort -gt 0) {
    $null = $activePrefixes.Add("http://+:$($cfg.HttpPort)/")
}
foreach ($prefix in $activePrefixes) {
    $listener.Prefixes.Add($prefix)
}

try {
    $listener.Start()
} catch {
    Write-StartupLog "ERROR: HttpListener could not be started: $_"
    $portHint = if ($cfg.HttpPort -gt 0) { $cfg.HttpPort } else { $cfg.HttpsPort }
    Write-Output "ERROR: Port $portHint may already be in use."
    Write-Output "Check: netstat -ano | findstr :$portHint"
    exit 1
}

foreach ($prefix in $activePrefixes) {
    Write-StartupLog "Web server listening on $prefix"
}

Write-Output ''
Write-Output 'PowerShell web server started'
foreach ($prefix in $activePrefixes) {
    Write-Output "Prefix  : $prefix"
}
Write-Output "WebRoot : $($cfg.WebRoot)"
Write-Output "LogDir  : $($cfg.LogDir)"
Write-Output ''

# ---------------------------------------------------------------------------
# Concurrency infrastructure
# Semaphore: limits active requests to MaxConcurrent — protects against bursts.
# ---------------------------------------------------------------------------
$semaphore = [System.Threading.SemaphoreSlim]::new($cfg.MaxConcurrent, $cfg.MaxConcurrent)

# ---------------------------------------------------------------------------
# Helper functions for request processing
# ---------------------------------------------------------------------------

function New-JsonResponse {
    param(
        [int]    $ExitCode,
        [string] $Output,
        [string] $Err
    )
    [ordered]@{
        exitCode = $ExitCode
        output   = $Output
        error    = $Err
    } | ConvertTo-Json -Compress -Depth 2
}

function Send-Response {
    param(
        [System.Net.HttpListenerResponse] $Response,
        [int]    $StatusCode,
        [string] $Body
    )
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Response.StatusCode      = $StatusCode
        $Response.ContentType     = 'application/json; charset=utf-8'
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { }
    finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Get-QueryParams {
    param([System.Collections.Specialized.NameValueCollection] $QueryString)
    $params = @{}
    foreach ($key in $QueryString.AllKeys) {
        if ($null -ne $key -and $key -ne '') {
            $params[$key] = $QueryString[$key]
        }
    }
    return $params
}

function Get-BodyParams {
    param([System.Net.HttpListenerRequest] $Request)

    # Check Content-Type — must be application/json.
    # StartsWith allows variants like "application/json; charset=utf-8".
    $ct = $Request.ContentType
    if (-not $ct -or -not $ct.StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Error = 415; Params = $null }
    }

    # Check body size before reading — ContentLength64 is -1 when no Content-Length header is set.
    # Only reject when size is known AND too large — unknown size is checked after reading.
    if ($Request.ContentLength64 -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; Params = $null }
    }

    # Read body — StreamReader is not disposed; InputStream belongs to the HttpListenerRequest.
    $reader  = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
    $rawBody = $reader.ReadToEnd()

    # Check size again in case Content-Length was missing.
    if ($rawBody.Length -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; Params = $null }
    }

    # Empty body is allowed — equivalent to a call with no parameters.
    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return [PSCustomObject]@{ Error = 0; Params = @{} }
    }

    # Parse JSON.
    try {
        $parsed = $rawBody | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Error = 400; Params = $null }
    }

    # Validate flat structure — no arrays, no nested objects.
    # ConvertFrom-Json returns a PSCustomObject — iterate its properties.
    $params = @{}
    foreach ($prop in $parsed.PSObject.Properties) {
        $val = $prop.Value
        if ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [System.Object[]]) {
            return [PSCustomObject]@{ Error = 400; Params = $null }
        }
        # Value as string — identical to query string handling in Get-QueryParams.
        $params[$prop.Name] = if ($null -eq $val) { '' } else { [string]$val }
    }

    return [PSCustomObject]@{ Error = 0; Params = $params }
}

function Invoke-Script {
    param(
        [string]    $ScriptPath,
        [hashtable] $Params,
        [int]       $TimeoutSec
    )

    # pwsh.exe as a separate process — the only reliable method to:
    # 1. Read $proc.ExitCode correctly (exit 0 / exit 1 from webroot scripts)
    # 2. Enforce timeout via WaitForExit(ms) + Kill()
    # 3. Avoid nested ThreadJob issues (Invoke-Script itself runs inside a ThreadJob)
    # ReadToEndAsync BEFORE WaitForExit — no ScriptBlock delegate, no runspace needed, no deadlock.

    # Build parameters as separate entries in ArgumentList — no manual quoting needed.
    # ArgumentList (Collection) instead of Arguments (String): Windows escapes each entry correctly;
    # special characters like " or spaces in query parameter values cannot corrupt the argument list.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $script:cfg.PwshExe
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    foreach ($arg in @('-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        $null = $psi.ArgumentList.Add($arg)
    }
    foreach ($key in $Params.Keys) {
        $null = $psi.ArgumentList.Add("-$key")
        $null = $psi.ArgumentList.Add($Params[$key])
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    # Read streams asynchronously BEFORE WaitForExit — prevents deadlock when stdout/stderr buffer fills up.
    # GetAwaiter().GetResult() blocks synchronously until the stream is closed — pure .NET, no ScriptBlock.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $finished) {
        # Timeout — kill the process.
        try { $proc.Kill() } catch { }
        $proc.Dispose()
        return [PSCustomObject]@{
            ExitCode = -1
            Output   = ''
            Error    = "Timeout: script was terminated after $TimeoutSec seconds."
            TimedOut = $true
        }
    }

    # Second WaitForExit() without timeout — ensures all buffered stream data is flushed
    # before GetAwaiter().GetResult() is called.
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    $stdout   = $stdoutTask.GetAwaiter().GetResult()
    $stderr   = $stderrTask.GetAwaiter().GetResult()
    $proc.Dispose()

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $stdout.TrimEnd()
        Error    = $stderr.TrimEnd()
        TimedOut = $false
    }
}

function Get-ScriptIndex {
    # @() forces array serialisation even on an empty result — prevents $null instead of [].
    $list = if (Test-Path -LiteralPath $script:cfg.WebRoot -PathType Container) {
        Get-ChildItem -Path $script:cfg.WebRoot -Recurse -Filter '*.ps1' | ForEach-Object {
            '/' + $_.FullName.Substring($script:cfg.WebRoot.Length).TrimStart('\').Replace('\','/')
        }
    } else {
        @()
    }
    return @($list) | ConvertTo-Json -Compress -Depth 3
}

# ---------------------------------------------------------------------------
# $shared: bundles all values needed inside ThreadJob instances.
# ThreadJobs have no access to the main script's scope — everything must be
# passed explicitly. Functions are exported as ScriptBlocks and injected
# into the job via ${function:Name} = $shared.FnName.
# ---------------------------------------------------------------------------
$shared = @{
    Cfg              = $cfg
    LogMutex         = $script:logMutex
    Semaphore        = $semaphore
    StartTime        = $startTime
    RequestsTotal    = $script:requestsTotal
    FnWriteLog       = ${function:Write-Log}
    FnSendResp       = ${function:Send-Response}
    FnNewJson        = ${function:New-JsonResponse}
    FnGetParams      = ${function:Get-QueryParams}
    FnGetBodyParams  = ${function:Get-BodyParams}
    FnInvScript      = ${function:Invoke-Script}
    FnGetIndex       = ${function:Get-ScriptIndex}
}

# ---------------------------------------------------------------------------
# $requestHandler: complete request processing logic as a ScriptBlock.
# Executed per request inside its own Start-ThreadJob.
# Sends the response to the client only after Invoke-Script returns
# (whether OK, ERROR, or TIMEOUT after ScriptTimeoutSec seconds).
# ---------------------------------------------------------------------------
$requestHandler = {
    param(
        [System.Net.HttpListenerContext] $context,
        [hashtable]                      $shared
    )

    # Inject functions and configuration from $shared into the local scope.
    # $script:cfg and $script:logMutex — the script: scope makes them visible
    # in all injected functions (Write-Log, Get-ScriptIndex).
    ${function:Write-Log}        = $shared.FnWriteLog
    ${function:Send-Response}    = $shared.FnSendResp
    ${function:New-JsonResponse} = $shared.FnNewJson
    ${function:Get-QueryParams}  = $shared.FnGetParams
    ${function:Get-BodyParams}   = $shared.FnGetBodyParams
    ${function:Invoke-Script}    = $shared.FnInvScript
    ${function:Get-ScriptIndex}  = $shared.FnGetIndex
    $script:cfg      = $shared.Cfg
    $script:logMutex = $shared.LogMutex

    try {
        $req  = $context.Request
        $resp = $context.Response

        $clientIP    = $req.RemoteEndPoint.Address.ToString()
        $urlPath     = $req.Url.AbsolutePath
        $requestLine = '{0} {1}' -f $req.HttpMethod, $req.Url.PathAndQuery

        # --------------------------------------------------------------
        # Only GET and POST are allowed — all other methods are rejected.
        # --------------------------------------------------------------
        if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'POST') {
            $body = New-JsonResponse -ExitCode 405 -Output '' -Err "Method not allowed: $($req.HttpMethod). Only GET and POST are supported."
            $resp.AddHeader('Allow', 'GET, POST')
            Send-Response -Response $resp -StatusCode 405 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # API key authentication
        # /health is intentionally open (monitoring without key is possible).
        # All other routes require the X-Api-Key header.
        # Same response for missing and incorrect key — no hint which case applies.
        # --------------------------------------------------------------
        if ($urlPath -ne '/health') {
            $providedKey = $req.Headers['X-Api-Key']
            if ($providedKey -ne $script:cfg.ApiKey) {
                $body = New-JsonResponse -ExitCode 401 -Output '' -Err 'Unauthorized.'
                Send-Response -Response $resp -StatusCode 401 -Body $body
                Write-Log -ClientIP $clientIP -Request $requestLine -Status 'UNAUTHORIZED' -ExitCode '-'
                return
            }
        }

        # --------------------------------------------------------------
        # GET / -> script index
        # --------------------------------------------------------------
        if ($urlPath -eq '/') {
            $json = Get-ScriptIndex
            Send-Response -Response $resp -StatusCode 200 -Body $json
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'INDEX' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # GET /health -> health check (no webroot script)
        # Uptime as a human-readable string, requestsTotal counts script requests only.
        # --------------------------------------------------------------
        if ($urlPath -eq '/health') {
            $uptimeSec = [long] $shared.StartTime.Elapsed.TotalSeconds
            $h         = [int]($uptimeSec / 3600)
            $m         = [int](($uptimeSec % 3600) / 60)
            $s         = $uptimeSec % 60
            $uptimeStr = '{0}h {1}m {2}s' -f $h, $m, $s
            $total     = [System.Threading.Interlocked]::Read($shared.RequestsTotal)
            $body      = [ordered]@{
                status        = 'ok'
                uptime        = $uptimeStr
                requestsTotal = $total
            } | ConvertTo-Json -Compress
            Send-Response -Response $resp -StatusCode 200 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'HEALTH' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Only .ps1 allowed
        # --------------------------------------------------------------
        if (-not $urlPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $body = New-JsonResponse -ExitCode 400 -Output '' -Err "Only .ps1 files are allowed. Requested: $urlPath"
            Send-Response -Response $resp -StatusCode 400 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'BAD REQUEST' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Path traversal protection
        # Ensure the resolved path is inside WebRoot.
        # --------------------------------------------------------------
        $relativePath = $urlPath.TrimStart('/').Replace('/', '\')
        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.WebRoot $relativePath))
        $webrootFull  = [System.IO.Path]::GetFullPath($script:cfg.WebRoot)

        if (-not $resolvedPath.StartsWith($webrootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Access denied.'
            Send-Response -Response $resp -StatusCode 403 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Script file must exist
        # --------------------------------------------------------------
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $body = New-JsonResponse -ExitCode 404 -Output '' -Err "Script not found: $urlPath"
            Send-Response -Response $resp -StatusCode 404 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Assemble parameters and execute the script.
        # GET: query string parameters are passed as named arguments.
        # POST: JSON body keys are passed as named arguments.
        #       On name collision, body wins (query keys are overwritten).
        # Invoke-Script blocks until the script finishes or the timeout
        # (ScriptTimeoutSec) elapses — the client waits accordingly.
        # --------------------------------------------------------------
        $scriptParams = Get-QueryParams -QueryString $req.QueryString

        if ($req.HttpMethod -eq 'POST') {
            $bodyResult = Get-BodyParams -Request $req
            if ($bodyResult.Error -ne 0) {
                $errMsg = switch ($bodyResult.Error) {
                    413 { 'Request body too large. Maximum size: {0} MB.' -f [math]::Round($script:cfg.MaxRequestBodyBytes / 1MB) }
                    415 { 'Content-Type must be application/json.' }
                    400 { 'Invalid JSON body. Only flat key-value objects are supported — no nested objects or arrays.' }
                }
                $body = New-JsonResponse -ExitCode $bodyResult.Error -Output '' -Err $errMsg
                Send-Response -Response $resp -StatusCode $bodyResult.Error -Body $body
                Write-Log -ClientIP $clientIP -Request $requestLine -Status "HTTP $($bodyResult.Error)" -ExitCode '-'
                return
            }
            # Merge body keys into scriptParams — body keys overwrite query keys on collision.
            foreach ($key in $bodyResult.Params.Keys) {
                $scriptParams[$key] = $bodyResult.Params[$key]
            }
        }

        $result = Invoke-Script -ScriptPath $resolvedPath -Params $scriptParams -TimeoutSec $script:cfg.ScriptTimeoutSec

        # Script request completed — increment counter atomically (thread-safe).
        $null = [System.Threading.Interlocked]::Increment($shared.RequestsTotal)

        $httpStatus = if     ($result.TimedOut)       { 504 }
                      elseif ($result.ExitCode -eq 0) { 200 }
                      else                            { 500 }
        $body       = New-JsonResponse -ExitCode $result.ExitCode -Output $result.Output -Err $result.Error

        Send-Response -Response $resp -StatusCode $httpStatus -Body $body

        $statusText = if     ($result.TimedOut)       { 'TIMEOUT' }
                      elseif ($result.ExitCode -eq 0) { 'OK' }
                      else                            { 'ERROR' }
        Write-Log -ClientIP $clientIP -Request $requestLine -Status $statusText -ExitCode "$($result.ExitCode)"

    } catch {
        # Error in request processing — log and continue.
        # The process is NOT terminated.
        Write-Log -ClientIP '-' -Request '-' -Status "REQUEST-ERROR: $_" -ExitCode '1'
        try {
            $body = New-JsonResponse -ExitCode 500 -Output '' -Err "Internal error: $_"
            Send-Response -Response $context.Response -StatusCode 500 -Body $body
        } catch { }
    } finally {
        # Always release the semaphore slot — even on error or timeout.
        try { $shared.Semaphore.Release() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Main loop
# GetContext() blocks synchronously until a request arrives.
# A Start-ThreadJob is started per request — the main thread returns
# immediately to accept the next request.
# Shutdown: $listener.Stop() throws an exception in GetContext() — the
# IsListening check exits the loop cleanly.
# ---------------------------------------------------------------------------
try {
    Write-Output 'Web server running. Waiting for requests...'

    while ($listener.IsListening) {
        # Blocks until a request arrives or the listener is stopped.
        try {
            $context = $listener.GetContext()
        } catch {
            # Listener was stopped (shutdown) — exit the loop.
            if (-not $listener.IsListening) { break }
            continue
        }

        # Clean up completed jobs — non-blocking, once per loop iteration.
        Get-Job -State Completed -ErrorAction SilentlyContinue | Remove-Job -Force

        # Semaphore: check immediately without waiting (timeout 0ms).
        # Under overload, return 503 immediately — no job needed.
        if (-not $semaphore.Wait(0)) {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
                '{"exitCode":503,"output":"","error":"Server busy. Please try again later."}'
            )
            $resp503 = $context.Response
            $resp503.StatusCode      = 503
            $resp503.ContentType     = 'application/json; charset=utf-8'
            $resp503.ContentLength64 = $bodyBytes.Length
            try { $resp503.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
            try { $resp503.OutputStream.Close()                                  } catch { }
            continue
        }

        # Start ThreadJob — runs in parallel, main thread returns immediately.
        $null = Start-ThreadJob -ScriptBlock $requestHandler -ArgumentList $context, $shared
    }

} finally {
    # Always executed — regardless of normal exit, Ctrl+C, or crash.
    # Order is critical:
    #   1. Stop listener — interrupts running GetContext() immediately
    #   2. Wait 5s — gives running jobs time to finish cleanly
    #   3. Release remaining resources
    Write-StartupLog 'Shutdown initiated — waiting for in-flight requests (max. 5s)...'

    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    Start-Sleep -Seconds 5
    try { $listener.Close()                               } catch { }
    try { Get-Job | Remove-Job -Force                     } catch { }
    try { $semaphore.Dispose()                            } catch { }
    try { $script:logMutex.Dispose()                      } catch { }

    Write-StartupLog 'Web server stopped.'
    Write-Output 'Web server stopped.'
}
