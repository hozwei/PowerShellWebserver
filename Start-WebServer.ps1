#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell HTTP-Webserver - fuehrt lokale .ps1-Skripte per HTTP-Request aus.

.DESCRIPTION
    Lauscht auf Port 80 (alle Interfaces).
    URL-Pfade werden direkt auf .\webroot\ gemappt.
    Query-Parameter werden als benannte Argumente an das Skript uebergeben.
    Jeder Request wird in .\logs\YYYY-MM-DD.log protokolliert.

    Erfordert PowerShell 7 (pwsh.exe).
    Muss als Administrator ausgefuehrt werden (Port 80).

.EXAMPLE
    http://localhost/script1.ps1
    http://localhost/subdir/script2.ps1?Name=Max&Wert=42
    http://localhost/                    <- listet alle verfuegbaren Skripte
    http://localhost/health              <- Serverstatus, Uptime, Request-Zaehler
#>

# ---------------------------------------------------------------------------
# PowerShell 7 - Pflichtpruefung
# Muss als allererstes laufen - vor $cfg, vor Logging, vor allem.
# $PSVersionTable.PSEdition ist 'Core' in PS 7, 'Desktop' in PS 5.x
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Core') {
    $logDir  = 'C:\posh\logs'
    $logFile = Join-Path $logDir 'startup.log'
    $line    = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | PowerShell 7 required. Laufende Version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    try {
        if (-not (Test-Path $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        [System.IO.File]::AppendAllText($logFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    exit 1
}

# ---------------------------------------------------------------------------
# Start-ThreadJob sicherstellen - in PS 7 bereits in Microsoft.PowerShell.ThreadJob
# eingebaut. Nur wenn der Befehl wirklich fehlt wird das separate Modul installiert.
# ---------------------------------------------------------------------------
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Output 'Start-ThreadJob nicht verfuegbar - wird installiert...'
    Install-Module -Name ThreadJob -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    Import-Module ThreadJob -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# ErrorActionPreference NICHT auf Stop setzen - der Prozess laeuft dauerhaft
# Fehler werden pro Request behandelt, nie global
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Basispfad - hardcoded fuer zuverlaessigen Betrieb unter allen Kontexten.
# Anpassen falls das Deployment-Verzeichnis abweicht.
# ---------------------------------------------------------------------------
$baseDir = 'C:\posh'

# ---------------------------------------------------------------------------
# API-Key-Pruefung - muss vor $cfg laufen, damit $apiKey beim Aufbau der
# Hashtable bereits gesetzt ist. POSH_API_KEY muss als System-Umgebungsvariable
# gesetzt sein (via Register-ScheduledTask.ps1 oder manuell:
# [Environment]::SetEnvironmentVariable('POSH_API_KEY','...','Machine'))
# Kein Key = kein Start - ungeschuetzter Betrieb ist nicht erlaubt
# ---------------------------------------------------------------------------
$apiKey = $env:POSH_API_KEY
if ([string]::IsNullOrEmpty($apiKey)) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | STARTUP | FEHLER: Umgebungsvariable POSH_API_KEY ist nicht gesetzt. Server wird nicht gestartet."
    try {
        if (-not (Test-Path $baseDir)) { $null = New-Item -ItemType Directory -Path $baseDir -Force }
        $startupLog = Join-Path $baseDir 'logs\startup.log'
        [System.IO.File]::AppendAllText($startupLog, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
    Write-Output $line
    Write-Output ''
    Write-Output 'Loesung: POSH_API_KEY als System-Umgebungsvariable setzen und Server neu starten.'
    Write-Output "  [Environment]::SetEnvironmentVariable('POSH_API_KEY', 'dein-key', 'Machine')"
    exit 1
}

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
$cfg = @{
    Prefix           = 'http://+:80/'
    WebRoot          = Join-Path $baseDir 'webroot'
    LogDir           = Join-Path $baseDir 'logs'
    PwshExe          = (Get-Process -Id $PID).MainModule.FileName   # pwsh.exe des laufenden Prozesses - kein Pfad-Hardcode
    ApiKey           = $apiKey                                       # aus $env:POSH_API_KEY - bereits auf Leerstring geprueft
    ScriptTimeoutSec    = 900    # 15 Minuten - Skripte die laenger laufen werden abgebrochen (HTTP 504)
    MaxConcurrent       = 10     # Maximale parallele Requests - darueber wird HTTP 503 zurueckgegeben
    LogRetentionDays    = 180    # Logdateien aelter als N Tage werden beim Start geloescht (0 = deaktiviert)
    MaxRequestBodyBytes = 20MB   # Maximale POST-Body-Groesse in Bytes - groessere Requests: HTTP 413
}

# Laufzeitmessung ab Serverstart - fuer Health-Check-Uptime
$startTime = [System.Diagnostics.Stopwatch]::StartNew()

# Zaehlt abgeschlossene Script-Requests (exitCode-unabhaengig).
# [ref] + Interlocked::Increment garantiert Thread-Sicherheit ohne Mutex.
$script:requestsTotal = [ref] 0L

# Mutex sichert parallele Schreibzugriffe auf die Logdatei ab.
# Global\ damit der Mutex prozessuebergreifend eindeutig ist.
$script:logMutex = [System.Threading.Mutex]::new($false, 'Global\PoshWebserverLog')

# ---------------------------------------------------------------------------
# Logging
# Schreibt in Logdatei UND auf stdout (fuer Scheduled Task Event Log sichtbar)
# Kein Write-Host mit -ForegroundColor - wirft IOException in nicht-interaktiven Kontexten
# $script:cfg statt $cfg - Funktion laeuft auch in RunspacePool-Instanzen
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

    # Mutex verhindert korrupte Zeilen bei parallelen Schreibzugriffen aus den ThreadJobs
    # WaitOne(500): max 500ms warten - bei Fehler still weitermachen, nie den Prozess toeten
    # $acquired merken: ReleaseMutex() nur aufrufen wenn WaitOne() erfolgreich war -
    # sonst ApplicationException weil der aufrufende Thread den Mutex nicht haelt
    $acquired = $false
    try {
        $acquired = $script:logMutex.WaitOne(500)
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { } finally {
        try { if ($acquired) { $script:logMutex.ReleaseMutex() } } catch { }
    }

    # Auch auf stdout - im Scheduled Task landet das im Task-History-Output
    Write-Output $line
}

# Startup-Ereignisse (vor dem Listener) in separates startup.log
function Write-StartupLog {
    param([string] $Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp | STARTUP | $Message"

    # LogDir wird im Startup-Flow bereits sichergestellt - kein Test-Path noetig
    try {
        Add-Content -LiteralPath (Join-Path $script:cfg.LogDir 'startup.log') -Value $line -Encoding UTF8
    } catch { }

    Write-Output $line
}

# ---------------------------------------------------------------------------
# Log-Rotation
# Loescht .log-Dateien in LogDir die aelter als RetentionDays Tage sind.
# Laeuft einmalig beim Start - nie waehrend des Betriebs.
# RetentionDays = 0: Rotation deaktiviert (expliziter Opt-out).
# Gibt die Anzahl geloeschter Dateien zurueck - Logging obliegt dem Aufrufer.
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
# Admin-Pruefung
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-StartupLog 'FEHLER: Nicht als Administrator gestartet. Port 80 erfordert Adminrechte.'
    Write-Output ''
    Write-Output 'FEHLER: Dieses Skript muss als Administrator ausgefuehrt werden.'
    Write-Output 'Loesung: pwsh.exe als Administrator oeffnen und erneut ausfuehren.'
    exit 1
}

# ---------------------------------------------------------------------------
# Startup-Info loggen
# ---------------------------------------------------------------------------
Write-StartupLog "Webserver startet. BaseDir=$baseDir  WebRoot=$($cfg.WebRoot)  LogDir=$($cfg.LogDir)  PS=$($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------------------
# Verzeichnisse sicherstellen
# ---------------------------------------------------------------------------
foreach ($dir in @($cfg.WebRoot, $cfg.LogDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Write-StartupLog "Verzeichnis erstellt: $dir"
    }
}

# ---------------------------------------------------------------------------
# Log-Rotation beim Start
# ---------------------------------------------------------------------------
$deletedLogs = Remove-OldLogs -LogDir $cfg.LogDir -RetentionDays $cfg.LogRetentionDays
if ($deletedLogs -gt 0) {
    Write-StartupLog "Log-Rotation: $deletedLogs Datei(en) aelter als $($cfg.LogRetentionDays) Tage geloescht."
}

# ---------------------------------------------------------------------------
# HTTP-Listener starten
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($cfg.Prefix)

try {
    $listener.Start()
} catch {
    Write-StartupLog "FEHLER: HttpListener konnte nicht gestartet werden: $_"
    Write-Output "FEHLER: Port 80 ist moeglicherweise bereits belegt."
    Write-Output "Pruefen: netstat -ano | findstr :80"
    exit 1
}

Write-StartupLog "Webserver gestartet. Lauscht auf $($cfg.Prefix)"
Write-Output ''
Write-Output "PowerShell Webserver gestartet"
Write-Output "Prefix  : $($cfg.Prefix)"
Write-Output "WebRoot : $($cfg.WebRoot)"
Write-Output "LogDir  : $($cfg.LogDir)"
Write-Output ''

# ---------------------------------------------------------------------------
# Concurrency-Infrastruktur
# Semaphor: begrenzt aktive Requests auf MaxConcurrent - Schutz vor Burst
# ---------------------------------------------------------------------------
$semaphore = [System.Threading.SemaphoreSlim]::new($cfg.MaxConcurrent, $cfg.MaxConcurrent)

# ---------------------------------------------------------------------------
# Hilfsfunktionen fuer die Request-Verarbeitung
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

    # Content-Type pruefen - muss application/json sein
    # StartsWith erlaubt Varianten wie "application/json; charset=utf-8"
    $ct = $Request.ContentType
    if (-not $ct -or -not $ct.StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Error = 415; Params = $null }
    }

    # Body-Groesse pruefen bevor gelesen wird - ContentLength64 ist -1 wenn kein Content-Length-Header gesetzt
    # Nur ablehnen wenn Groesse bekannt UND zu gross - unbekannte Groesse wird nach dem Lesen geprueft
    if ($Request.ContentLength64 -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; Params = $null }
    }

    # Body lesen - StreamReader wird nicht disposed, InputStream gehoert dem HttpListenerRequest
    $reader  = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
    $rawBody = $reader.ReadToEnd()

    # Groesse nochmal pruefen falls Content-Length fehlte
    if ($rawBody.Length -gt $script:cfg.MaxRequestBodyBytes) {
        return [PSCustomObject]@{ Error = 413; Params = $null }
    }

    # Leerer Body ist erlaubt - entspricht einem Aufruf ohne Parameter
    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return [PSCustomObject]@{ Error = 0; Params = @{} }
    }

    # JSON parsen
    try {
        $parsed = $rawBody | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Error = 400; Params = $null }
    }

    # Flache Struktur validieren - keine Arrays, keine verschachtelten Objekte.
    # ConvertFrom-Json gibt PSCustomObject zurueck - dessen Properties iterieren.
    $params = @{}
    foreach ($prop in $parsed.PSObject.Properties) {
        $val = $prop.Value
        if ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [System.Object[]]) {
            return [PSCustomObject]@{ Error = 400; Params = $null }
        }
        # Wert als String - identisch zur Query-String-Behandlung in Get-QueryParams
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

    # pwsh.exe als separater Prozess - einzige zuverlaessige Methode um:
    # 1. $proc.ExitCode korrekt zu lesen (exit 0 / exit 1 aus Webroot-Skripten)
    # 2. Timeout per WaitForExit(ms) + Kill() durchzusetzen
    # 3. Verschachtelte ThreadJob-Probleme zu vermeiden (Invoke-Script laeuft selbst im ThreadJob)
    # ReadToEndAsync VOR WaitForExit - kein ScriptBlock-Delegate, kein Runspace noetig, kein Deadlock

    # Parameter als separate Eintraege in ArgumentList aufbauen - kein manuelles Quoting noetig.
    # ArgumentList (Collection) statt Arguments (String): Windows escaped jeden Eintrag korrekt,
    # Sonderzeichen wie " oder Leerzeichen in Query-Parameter-Werten koennen die Argument-Liste nicht korrumpieren.
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

    # Streams asynchron lesen BEVOR WaitForExit - verhindert Deadlock wenn stdout/stderr-Buffer voll laufen.
    # GetAwaiter().GetResult() blockiert synchron bis der Stream geschlossen ist - reines .NET, kein ScriptBlock.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $finished) {
        # Timeout - Prozess abwuergen
        try { $proc.Kill() } catch { }
        $proc.Dispose()
        return [PSCustomObject]@{
            ExitCode = -1
            Output   = ''
            Error    = "Timeout: Skript wurde nach $TimeoutSec Sekunden abgebrochen."
            TimedOut = $true
        }
    }

    # Zweites WaitForExit() ohne Timeout - stellt sicher dass alle Stream-Daten gepuffert sind
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
    # @() erzwingt Array-Serialisierung auch bei leerem Ergebnis - verhindert $null statt []
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
# $shared: buendelt alle Werte die in ThreadJob-Instanzen benoetigt werden.
# ThreadJobs haben keinen Zugriff auf den Scope des Hauptskripts - alles muss
# explizit uebergeben werden. Funktionen werden als ScriptBlocks exportiert
# und im Job per ${function:Name} = $shared.FnName eingebunden.
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
# $requestHandler: vollstaendige Request-Verarbeitungslogik als ScriptBlock.
# Wird pro Request in einem eigenen Start-ThreadJob ausgefuehrt.
# Gibt dem Client erst eine Antwort wenn Invoke-Script zurueckgekehrt ist
# (egal ob OK, ERROR oder TIMEOUT nach ScriptTimeoutSec Sekunden).
# ---------------------------------------------------------------------------
$requestHandler = {
    param(
        [System.Net.HttpListenerContext] $context,
        [hashtable]                      $shared
    )

    # Funktionen und Konfiguration aus $shared in den lokalen Scope einspielen.
    # $script:cfg und $script:logMutex - script:-Scope macht sie in allen
    # eingebundenen Funktionen (Write-Log, Get-ScriptIndex) sichtbar.
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
        # Nur GET und POST erlaubt - alle anderen Methoden werden abgewiesen
        # --------------------------------------------------------------
        if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'POST') {
            $body = New-JsonResponse -ExitCode 405 -Output '' -Err "Methode nicht erlaubt: $($req.HttpMethod). Nur GET und POST werden unterstuetzt."
            $resp.AddHeader('Allow', 'GET, POST')
            Send-Response -Response $resp -StatusCode 405 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'METHOD NOT ALLOWED' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # API-Key-Authentifizierung
        # /health ist bewusst offen (Monitoring ohne Key moeglich)
        # Alle anderen Routen erfordern X-Api-Key-Header
        # Gleiche Antwort bei fehlendem und falschem Key - kein Hinweis welcher Fall vorliegt
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
        # GET / -> Skript-Index
        # --------------------------------------------------------------
        if ($urlPath -eq '/') {
            $json = Get-ScriptIndex
            Send-Response -Response $resp -StatusCode 200 -Body $json
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'INDEX' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # GET /health -> Health-Check (kein Webroot-Skript)
        # Uptime als lesbare Zeichenkette, requestsTotal nur Script-Requests
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
        # Nur .ps1 erlaubt
        # --------------------------------------------------------------
        if (-not $urlPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $body = New-JsonResponse -ExitCode 400 -Output '' -Err "Nur .ps1-Dateien erlaubt. Angefordert: $urlPath"
            Send-Response -Response $resp -StatusCode 400 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'BAD REQUEST' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Path-Traversal-Schutz
        # Sicherstellen dass der aufgeloeste Pfad innerhalb von WebRoot liegt
        # --------------------------------------------------------------
        $relativePath = $urlPath.TrimStart('/').Replace('/', '\')
        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $script:cfg.WebRoot $relativePath))
        $webrootFull  = [System.IO.Path]::GetFullPath($script:cfg.WebRoot)

        if (-not $resolvedPath.StartsWith($webrootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $body = New-JsonResponse -ExitCode 403 -Output '' -Err 'Zugriff verweigert.'
            Send-Response -Response $resp -StatusCode 403 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'FORBIDDEN' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Skript-Datei muss existieren
        # --------------------------------------------------------------
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $body = New-JsonResponse -ExitCode 404 -Output '' -Err "Skript nicht gefunden: $urlPath"
            Send-Response -Response $resp -StatusCode 404 -Body $body
            Write-Log -ClientIP $clientIP -Request $requestLine -Status 'NOT FOUND' -ExitCode '-'
            return
        }

        # --------------------------------------------------------------
        # Parameter zusammenstellen und Skript ausfuehren.
        # GET: Query-String-Parameter werden als benannte Argumente uebergeben.
        # POST: JSON-Body-Keys werden als benannte Argumente uebergeben.
        #       Bei Namenskollision gewinnt der Body (Query-Keys werden ueberschrieben).
        # Invoke-Script blockiert bis das Skript fertig ist oder der Timeout
        # (ScriptTimeoutSec) ablaeuft - der Client wartet entsprechend.
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
            # Body-Keys in scriptParams einspielen - ueberschreiben Query-Keys bei Namenskollision
            foreach ($key in $bodyResult.Params.Keys) {
                $scriptParams[$key] = $bodyResult.Params[$key]
            }
        }

        $result = Invoke-Script -ScriptPath $resolvedPath -Params $scriptParams -TimeoutSec $script:cfg.ScriptTimeoutSec

        # Script-Request abgeschlossen - Zaehler atomisch erhoehen (thread-sicher)
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
        # Fehler in der Request-Verarbeitung - loggen, weitermachen
        # Prozess wird NICHT beendet
        Write-Log -ClientIP '-' -Request '-' -Status "REQUEST-FEHLER: $_" -ExitCode '1'
        try {
            $body = New-JsonResponse -ExitCode 500 -Output '' -Err "Interner Fehler: $_"
            Send-Response -Response $context.Response -StatusCode 500 -Body $body
        } catch { }
    } finally {
        # Semaphor-Slot immer freigeben - auch bei Fehler oder Timeout
        try { $shared.Semaphore.Release() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Hauptschleife
# GetContext() blockiert synchron bis ein Request eintrifft.
# Pro Request wird ein Start-ThreadJob gestartet - der Hauptthread ist sofort
# wieder frei fuer den naechsten Request.
# Shutdown: $listener.Stop() wirft eine Exception in GetContext() - die
# IsListening-Pruefung beendet die Schleife sauber.
# ---------------------------------------------------------------------------
try {
    Write-Output 'Webserver laeuft. Warte auf Requests...'

    while ($listener.IsListening) {
        # Blockiert bis Request eintrifft oder Listener gestoppt wird
        try {
            $context = $listener.GetContext()
        } catch {
            # Listener wurde gestoppt (Shutdown) - Schleife beenden
            if (-not $listener.IsListening) { break }
            continue
        }

        # Abgeschlossene Jobs aufraumen - non-blocking, einmal pro Loop
        Get-Job -State Completed -ErrorAction SilentlyContinue | Remove-Job -Force

        # Semaphor: sofort pruefen ohne zu warten (Timeout 0ms)
        # Bei Ueberlast direkt 503 zurueckgeben - kein Job noetig
        if (-not $semaphore.Wait(0)) {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
                '{"exitCode":503,"output":"","error":"Server ausgelastet. Bitte spaeter erneut versuchen."}'
            )
            $resp503 = $context.Response
            $resp503.StatusCode      = 503
            $resp503.ContentType     = 'application/json; charset=utf-8'
            $resp503.ContentLength64 = $bodyBytes.Length
            try { $resp503.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
            try { $resp503.OutputStream.Close()                                  } catch { }
            continue
        }

        # ThreadJob starten - laeuft parallel, Hauptthread kehrt sofort zurueck
        $null = Start-ThreadJob -ScriptBlock $requestHandler -ArgumentList $context, $shared
    }

} finally {
    # Wird immer ausgefuehrt - egal ob normales Ende, Ctrl+C oder Absturz.
    # Reihenfolge ist kritisch:
    #   1. Listener stoppen - unterbricht laufendes GetContext() sofort
    #   2. 5s warten - gibt laufende Jobs Zeit sauber abzuschliessen
    #   3. Restliche Ressourcen freigeben
    Write-StartupLog 'Shutdown eingeleitet - warte auf laufende Requests (max. 5s)...'

    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    Start-Sleep -Seconds 5
    try { $listener.Close()                               } catch { }
    try { Get-Job | Remove-Job -Force                     } catch { }
    try { $semaphore.Dispose()                            } catch { }
    try { $script:logMutex.Dispose()                      } catch { }

    Write-StartupLog 'Webserver beendet.'
    Write-Output 'Webserver beendet.'
}
