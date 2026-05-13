# ---------------------------------------------------------------------------
#  Field metadata for Edit-PoshSettings.ps1
#
#  Single source of truth for what the browser editor exposes:
#  which keys are documented, where they live, how they validate. The
#  same schema drives both the client-side <input> attributes and the
#  server validation in PoshSettingsIO.psm1.
#
#  globalvars.ps1: the file itself is authoritative for "which vars
#  exist". This schema only contributes per-variable metadata for the
#  ones it knows about (Validator, Min/Max). Anything in globalvars.ps1
#  that isn't listed here still shows up in the editor under the same
#  "globalvars.ps1" tab — just without a custom validator.
#
#  Labels for globalvars fields are intentionally the literal variable
#  name (e.g. '$AdminMail'). Operators reading the editor are working
#  with PowerShell variables, not with marketing copy.
#
#  Validator regex anchors are intentionally explicit (^...$). Empty
#  strings are accepted on every optional field — match an empty input
#  with the alternation '|^$'.
# ---------------------------------------------------------------------------
@{
    Groups = @(
        @{ Id = 'globalvars'; Title = 'globalvars.ps1' }
        @{ Id = 'server';     Title = 'Server runtime' }
        @{ Id = 'auth';       Title = 'Authentication and limits' }
        @{ Id = 'cors';       Title = 'CORS' }
        @{ Id = 'static';     Title = 'Static files and MIME' }
        @{ Id = 'logging';    Title = 'Logging' }
        @{ Id = 'features';   Title = 'Quality-of-life features' }
        @{ Id = 'paths';      Title = 'Filesystem paths' }
        @{ Id = 'setup';      Title = 'Setup helpers' }
    )

    # ---------------------------------------------------------------
    # Fields are saved by writing the same key/value back into the
    # configured File. Type drives input-rendering AND server-side
    # validation. Validator is a regex that the value's string form
    # must match.
    # ---------------------------------------------------------------
    Fields = @(
        # -- globalvars.ps1 (baseline) -------------------------------------
        @{
            Name      = 'DomainController'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$DomainController'
            Help      = "FQDN of the Active Directory server."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'DomainDnsSuffix'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$DomainDnsSuffix'
            Help      = "DNS domain of the AD forest (e.g. 'example.local')."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'SmtpRelay'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$SmtpRelay'
            Help      = "FQDN of the SMTP relay for outbound mail."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'AdminMail'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$AdminMail'
            Help      = "Mail address for notifications and error mails."
            Validator = '^([^@\s]+@[^@\s]+\.[^@\s]+)?$'
        }
        @{
            Name      = 'PoshServerFqdn'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$PoshServerFqdn'
            Help      = "External hostname of this posh server (used for cert subject and self-links)."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'LdapUsers'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapUsers'
            Help      = "Distinguished Name of the users OU (e.g. 'OU=Users,DC=example,DC=local')."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapUsersDisabled'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapUsersDisabled'
            Help      = "DN of the disabled-users OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapServers'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapServers'
            Help      = "DN of the servers OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapClients'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapClients'
            Help      = "DN of the clients OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapGroups'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapGroups'
            Help      = "DN of the groups OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'DefaultTargetHost'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$DefaultTargetHost'
            Help      = "Hostname used as the default for `$TargetHost in webroot scripts."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'PasswordRetentionDays'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'int'
            Label     = '$PasswordRetentionDays'
            Help      = "Days after which a password is considered expired."
            Min       = 0
            Max       = 3650
        }

        # -- Server ports and TLS (config.psd1) -----------------------------
        @{
            Name      = 'HttpPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HttpPort'
            Help      = "TCP port for HTTP. 0 = HTTP disabled (only useful together with HttpsEnabled)."
            Min       = 0
            Max       = 65535
        }
        @{
            Name      = 'HttpsPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HttpsPort'
            Help      = "TCP port for HTTPS. Only takes effect with HttpsEnabled = `$true."
            Min       = 1
            Max       = 65535
        }
        @{
            Name      = 'HttpsEnabled'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'bool'
            Label     = 'HttpsEnabled'
            Help      = "Requires a netsh sslcert binding via Register-ScheduledTask.ps1."
        }
        @{
            Name      = 'MaxRequestBodyBytes'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'MaxRequestBodyBytes'
            Help      = "Maximum POST body size in bytes (20 MB = 20971520). Larger -> HTTP 413."
            Min       = 1024
            Max       = 1073741824
        }
        @{
            Name      = 'ExecutionMode'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'enum'
            Label     = 'ExecutionMode'
            Help      = "Subprocess: every request spawns pwsh.exe (isolated, slower, default). Same-Process: dispatch in-process (faster, shares state, no per-request hard timeout)."
            Choices   = @('Subprocess', 'Same-Process')
        }
        @{
            Name      = 'InjectContextVars'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'bool'
            Label     = 'InjectContextVars'
            Help      = "Inject `$AuthUser, `$AuthKey, `$ClientIP into every script's session-state before dispatch. Off by default to keep scripts portable."
        }

        # -- Authentication and limits (config.psd1) ------------------------
        @{
            Name      = 'AuthMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'AuthMode'
            Help      = "ApiKey: X-Api-Key only. Basic: HTTP Basic only. Both: either accepted."
            Choices   = @('ApiKey', 'Basic', 'Both')
        }
        @{
            Name      = 'BasicAuthUser'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string'
            Label     = 'BasicAuthUser'
            Help      = "HTTP Basic auth username. Leave empty to disable. Can also be set via POSH_BASIC_USER env var (env wins)."
            Validator = '^[^\s:]*$'
        }
        @{
            Name      = 'BasicAuthPass'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'password'
            Label     = 'BasicAuthPass'
            Help      = "HTTP Basic auth password. Stored as plaintext in config.psd1 — prefer the POSH_BASIC_PASS env var for production."
        }
        @{
            Name      = 'BasicAuthRealm'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string'
            Label     = 'BasicAuthRealm'
            Help      = "Realm string sent in the WWW-Authenticate header on 401 challenges."
            Validator = '^[\w\s\-\.]+$|^$'
        }
        @{
            Name      = 'ApiKeys'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'keymap'
            Label     = 'ApiKeys'
            Help      = "Label -> X-Api-Key map. The legacy single-key 'ApiKey' is auto-merged as 'default' at startup if this is empty. Labels must be unique and match A-Z, 0-9, _, -. Keys must be at least 16 characters."
        }
        @{
            Name      = 'MaxConcurrent'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'MaxConcurrent'
            Help      = "More concurrent requests -> HTTP 503."
            Min       = 1
            Max       = 1000
        }
        @{
            Name      = 'RunspacePoolOverprovision'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RunspacePoolOverprovision'
            Help      = "RunspacePool max size = MaxConcurrent x this. Needs >= 2 to absorb the gap between semaphore.Release() and Dispose() under burst; raise for slow-request profiles. 1 = no headroom (risk of dispatch hang)."
            Min       = 1
            Max       = 16
        }
        @{
            Name      = 'ScriptTimeoutSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'ScriptTimeoutSec'
            Help      = "If a script runs longer than this -> HTTP 504."
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitRequests'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitRequests'
            Help      = "Max requests per IP per window (0 = rate limit disabled)."
            Min       = 0
            Max       = 1000000
        }
        @{
            Name      = 'RateLimitWindowSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitWindowSec'
            Help      = "Length of the rate-limit window in seconds."
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitPenaltySec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitPenaltySec'
            Help      = "Lockout duration after the first 429 (0 = window-only behaviour)."
            Min       = 0
            Max       = 86400
        }
        @{
            Name      = 'RateLimitMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'RateLimitMode'
            Help      = "reject: immediate HTTP 429. queue: wait up to RateLimitQueueTimeoutSec."
            Choices   = @('reject', 'queue')
        }
        @{
            Name      = 'RateLimitPerIdentity'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'bool'
            Label     = 'RateLimitPerIdentity'
            Help      = "Useful behind NAT/proxy. Anonymous requests still get rate-limited per IP."
        }
        @{
            Name      = 'AllowedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'AllowedIPs'
            Help      = "One entry per line. Empty = all allowed. Examples: '192.168.1.10', '10.0.0.0/8', '~^192\.168\.'."
        }
        @{
            Name      = 'BlockedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'BlockedIPs'
            Help      = "One entry per line. Evaluated before AllowedIPs."
        }
        @{
            Name      = 'MinRequestIntervalSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'MinRequestIntervalSec'
            Help      = "Global minimum seconds between dispatched requests (coarse throttle, applies to all callers). 0 = disabled."
            Min       = 0
            Max       = 3600
        }
        @{
            Name      = 'RateLimitSweepIntervalSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitSweepIntervalSec'
            Help      = "How often the rate-limit ConcurrentDictionary is swept for stale entries (request-driven, in the main loop). 0 = disabled (table grows unbounded)."
            Min       = 0
            Max       = 86400
        }
        @{
            Name      = 'RateLimitTableSizeWarnThreshold'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitTableSizeWarnThreshold'
            Help      = "Emit WARN + AUDIT entry when the rate-limit table stays above this size after a sweep (DoS-by-IP-spray indicator). 0 = disabled."
            Min       = 0
            Max       = 100000000
        }
        @{
            Name      = 'RateLimitQueuePollMs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitQueuePollMs'
            Help      = "Re-check interval (ms) while the request waits in queue mode. Lower = faster pickup of window-reset, higher = less CPU."
            Min       = 10
            Max       = 60000
        }
        @{
            Name      = 'AcceptedContentTypes'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'AcceptedContentTypes'
            Help      = "Whitelist of Content-Type prefixes accepted for POST bodies. One per line. Default: application/json, application/x-www-form-urlencoded."
        }
        @{
            Name      = 'AuthExemptPaths'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'AuthExemptPaths'
            Help      = "URL paths that skip authentication (logged as 'anonymous'). One per line. Default exposes /health, /metrics, /metrics-prom, /openapi.json for monitoring tools."
        }
        @{
            Name      = 'IpFilterExemptPaths'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'IpFilterExemptPaths'
            Help      = "URL paths that bypass AllowedIPs / BlockedIPs. One per line. Default is just /health so external monitoring still reaches the server even when an allowlist is set."
        }
        @{
            Name      = 'GlobalThrottleExemptPaths'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'GlobalThrottleExemptPaths'
            Help      = "URL paths that bypass the MinRequestIntervalSec global throttle. One per line."
        }
        @{
            Name      = 'RateLimitExemptPaths'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'RateLimitExemptPaths'
            Help      = "URL paths excluded from per-IP rate limiting (RateLimitRequests/Window). One per line."
        }
        @{
            Name      = 'RateLimitQueueTimeoutSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitQueueTimeoutSec'
            Help      = "Only consulted when RateLimitMode is 'queue': max seconds a request waits in the queue before returning HTTP 429."
            Min       = 1
            Max       = 3600
        }

        # -- Logging (config.psd1) ------------------------------------------
        @{
            Name      = 'LogRetentionDays'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'LogRetentionDays'
            Help      = "Logs older than N days are deleted at startup (0 = off)."
            Min       = 0
            Max       = 3650
        }
        @{
            Name      = 'LogSchedule'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'LogSchedule'
            Help      = "Daily: one file per day. Hourly: one file per hour."
            Choices   = @('Daily', 'Hourly')
        }
        @{
            Name      = 'LogFormat'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'LogFormat'
            Help      = "Native: pipe-delimited. IIS-W3C: W3C Extended (for logparser)."
            Choices   = @('Native', 'IIS-W3C')
        }
        @{
            Name      = 'AuditLogEnabled'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'AuditLogEnabled'
            Help      = "Writes AUTH_FAIL, IP_BLOCKED, RATE_LIMITED as NDJSON to audit.log."
        }
        @{
            Name      = 'SlowRequestThresholdMs'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'SlowRequestThresholdMs'
            Help      = "Requests >= N ms get an entry in slow.log (0 = off)."
            Min       = 0
            Max       = 86400000
        }
        @{
            Name      = 'PostJsonRetentionDays'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'PostJsonRetentionDays'
            Help      = "Days to keep captured POST-body JSON files in PostJsonDir (0 = forever). Pruned at server start."
            Min       = 0
            Max       = 3650
        }
        @{
            Name      = 'LogIntegrityHash'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'LogIntegrityHash'
            Help      = "Writes <logfile>.md5 next to every completed log file (audit trail)."
        }
        @{
            Name      = 'LogMutexTimeoutMs'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'LogMutexTimeoutMs'
            Help      = "Max ms a log writer waits for the mutex. On timeout the line is DROPPED (and posh_log_drops_total ticks)."
            Min       = 1
            Max       = 60000
        }
        @{
            Name      = 'AuditLogMaxBytes'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'AuditLogMaxBytes'
            Help      = "audit.log size limit. At startup, files >= this byte size are rotated to .<timestamp>. 0 = unbounded."
            Min       = 0
            Max       = 10737418240
        }
        @{
            Name      = 'SlowLogMaxBytes'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'SlowLogMaxBytes'
            Help      = "slow.log size limit. Same rotation as AuditLogMaxBytes. 0 = unbounded."
            Min       = 0
            Max       = 10737418240
        }
        @{
            Name      = 'JobsLogMaxBytes'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'JobsLogMaxBytes'
            Help      = "jobs.log size limit. Same rotation as AuditLogMaxBytes. 0 = unbounded."
            Min       = 0
            Max       = 10737418240
        }

        # -- Quality-of-life features (config.psd1) -------------------------
        @{
            Name      = 'GzipEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'GzipEnabled'
            Help      = "Compresses text responses (HTML/JSON/CSS/JS) when the client accepts gzip."
        }
        @{
            Name      = 'BrotliEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'BrotliEnabled'
            Help      = "Prefers Brotli over GZIP when both are offered (~15-25 % smaller)."
        }
        @{
            Name      = 'StaticServingEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'StaticServingEnabled'
            Help      = "Serves non-.ps1 files out of the webroot."
        }
        @{
            Name      = 'IndexShowMetadata'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'IndexShowMetadata'
            Help      = "GET / returns synopsis + parameters for every script (instead of just the path)."
        }
        @{
            Name      = 'PromMetricsEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'PromMetricsEnabled'
            Help      = "Enables GET /metrics-prom in Prometheus text format."
        }
        @{
            Name      = 'OpenApiEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'OpenApiEnabled'
            Help      = "Enables GET /openapi.json with an auto-generated OpenAPI 3.1 spec."
        }
        @{
            Name      = 'PathPlaceholders'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'PathPlaceholders'
            Help      = "Enables '[id].ps1' as a placeholder for /users/123 etc."
        }

        # -- CORS (config.psd1) ---------------------------------------------
        @{
            Name      = 'CorsAllowedOrigins'
            File      = 'config.psd1'
            Group     = 'cors'
            Type      = 'string-array'
            Label     = 'CorsAllowedOrigins'
            Help      = "Allowed CORS origins. One per line. Empty = CORS disabled. Use '*' to allow any origin (incompatible with CorsAllowCredentials per spec)."
        }
        @{
            Name      = 'CorsAllowedMethods'
            File      = 'config.psd1'
            Group     = 'cors'
            Type      = 'string'
            Label     = 'CorsAllowedMethods'
            Help      = "Comma-separated method list. Sent in Access-Control-Allow-Methods on preflight responses."
            Validator = '^[A-Z, ]+$|^$'
        }
        @{
            Name      = 'CorsAllowedHeaders'
            File      = 'config.psd1'
            Group     = 'cors'
            Type      = 'string'
            Label     = 'CorsAllowedHeaders'
            Help      = "Comma-separated header list sent in Access-Control-Allow-Headers."
            Validator = '^[A-Za-z0-9\-, ]+$|^$'
        }
        @{
            Name      = 'CorsAllowCredentials'
            File      = 'config.psd1'
            Group     = 'cors'
            Type      = 'bool'
            Label     = 'CorsAllowCredentials'
            Help      = "Send Access-Control-Allow-Credentials: true on responses to allowed origins. Cannot be combined with CorsAllowedOrigins='*'."
        }
        @{
            Name      = 'CorsMaxAgeSec'
            File      = 'config.psd1'
            Group     = 'cors'
            Type      = 'int'
            Label     = 'CorsMaxAgeSec'
            Help      = "Access-Control-Max-Age — seconds the browser may cache preflight responses."
            Min       = 0
            Max       = 86400
        }

        # -- Static files and MIME (config.psd1) ----------------------------
        @{
            Name      = 'DefaultDocuments'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'string-array'
            Label     = 'DefaultDocuments'
            Help      = "Filenames served for directory requests (one per line). First match wins. Falls back to DirectoryBrowsing when none exist."
        }
        @{
            Name      = 'StaticCacheHeaders'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'bool'
            Label     = 'StaticCacheHeaders'
            Help      = "Emit ETag + Last-Modified on static responses and honour If-None-Match / If-Modified-Since (HTTP 304)."
        }
        @{
            Name      = 'BlockedMimeTypes'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'string-array'
            Label     = 'BlockedMimeTypes'
            Help      = "MIME-type prefix blacklist for static responses (one per line). Matched via StartsWith — entries trigger HTTP 403."
        }
        @{
            Name      = 'GzipMinBytes'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'int'
            Label     = 'GzipMinBytes'
            Help      = "Responses smaller than this byte count are never compressed (overhead exceeds savings)."
            Min       = 0
            Max       = 1048576
        }
        @{
            Name      = 'GzipMaxBytes'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'int'
            Label     = 'GzipMaxBytes'
            Help      = "Responses larger than this byte count are streamed uncompressed (guards against OOM). 10 MB = 10485760."
            Min       = 1024
            Max       = 1073741824
        }
        @{
            Name      = 'GzipMimeTypes'
            File      = 'config.psd1'
            Group     = 'static'
            Type      = 'string-array'
            Label     = 'GzipMimeTypes'
            Help      = "Content-Type prefixes eligible for compression (one per line). Matched via StartsWith."
        }

        # -- Filesystem paths (config.psd1) ---------------------------------
        @{
            Name      = 'WebRoot'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'WebRoot'
            Help      = "Directory containing .ps1 endpoints. Absolute path."
        }
        @{
            Name      = 'StaticRoot'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'StaticRoot'
            Help      = "Directory for non-.ps1 static files. Empty = use WebRoot. Absolute path."
        }
        @{
            Name      = 'LogDir'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'LogDir'
            Help      = "Directory for request and worker logs. Used as the parent for default AuditLogFile / SlowLogFile / JobsLogFile when those are empty."
        }
        @{
            Name      = 'AuditLogFile'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'AuditLogFile'
            Help      = "Absolute path to audit.log. Empty = <LogDir>\audit.log. Only consulted when AuditLogEnabled = true."
        }
        @{
            Name      = 'SlowLogFile'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'SlowLogFile'
            Help      = "Absolute path to slow.log. Empty = <LogDir>\slow.log. Only consulted when SlowRequestThresholdMs > 0."
        }
        @{
            Name      = 'JobsLogFile'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'JobsLogFile'
            Help      = "Absolute path to jobs.log. Empty = <LogDir>\jobs.log. Used by BackgroundJobs."
        }
        @{
            Name      = 'PwshExe'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'PwshExe'
            Help      = "Absolute path to pwsh.exe used for Subprocess execution mode. Defaults to the server process's own pwsh."
        }
        @{
            Name      = 'ErrorPagesRoot'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'ErrorPagesRoot'
            Help      = "Directory containing <code>.html templates for CustomErrorPages. Empty = <WebRoot>\\_error."
        }
        @{
            Name      = 'PostJsonDir'
            File      = 'config.psd1'
            Group     = 'paths'
            Type      = 'string'
            Label     = 'PostJsonDir'
            Help      = "Directory where POST-body JSON files are captured by post-json.ps1."
        }

        # -- OpenAPI metadata (config.psd1) ---------------------------------
        @{
            Name      = 'OpenApiTitle'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'string'
            Label     = 'OpenApiTitle'
            Help      = "'info.title' field in the generated OpenAPI 3.1 spec at GET /openapi.json."
        }
        @{
            Name      = 'OpenApiVersion'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'string'
            Label     = 'OpenApiVersion'
            Help      = "'info.version' field in the generated OpenAPI 3.1 spec."
            Validator = '^[A-Za-z0-9\-\.\+]+$|^$'
        }
        @{
            Name      = 'Prefixes'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'string-array'
            Label     = 'Prefixes'
            Help      = "Explicit HttpListener prefixes (one per line, e.g. http://api.example.com:80/). Empty = build from HttpPort/HttpsPort with the '+' wildcard binding (default)."
        }
        @{
            Name      = 'SessionEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'SessionEnabled'
            Help      = "Sets an HttpOnly session cookie on responses so scripts can keep per-client state across requests."
        }
        @{
            Name      = 'SessionCookieName'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'string'
            Label     = 'SessionCookieName'
            Help      = "Name of the session cookie. Letters, digits, dash, underscore, dot only."
            Validator = '^[A-Za-z0-9_\-\.]+$|^$'
        }
        @{
            Name      = 'DirectoryBrowsing'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'DirectoryBrowsing'
            Help      = "Serve an HTML listing for directory URLs that don't have an index file. Off by default."
        }
        @{
            Name      = 'DirectoryBrowsingHidden'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'string-array'
            Label     = 'DirectoryBrowsingHidden'
            Help      = "Names hidden from directory listings (one per line). Default: _error, .git, .gitignore."
        }
        @{
            Name      = 'CustomErrorPages'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'CustomErrorPages'
            Help      = "Serve <ErrorPagesRoot>\\<code>.html for 4xx/5xx when the client Accepts text/html. Falls back to JSON envelope otherwise."
        }
        # ErrorPagesRoot, PostJsonDir grouped under "Filesystem paths" below.
        @{
            Name      = 'PhpCgiEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'PhpCgiEnabled'
            Help      = "Route .php requests through an external php-cgi.exe (CGI/1.1). PhpCgiPath must point at the executable."
        }
        @{
            Name      = 'PhpCgiPath'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'string'
            Label     = 'PhpCgiPath'
            Help      = "Absolute path to php-cgi.exe. Only consulted when PhpCgiEnabled is true."
        }
        @{
            Name      = 'PhpCgiTimeoutSec'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'int'
            Label     = 'PhpCgiTimeoutSec'
            Help      = "Per-request timeout for the php-cgi subprocess. Exceeded -> HTTP 504."
            Min       = 1
            Max       = 3600
        }
    )
}
