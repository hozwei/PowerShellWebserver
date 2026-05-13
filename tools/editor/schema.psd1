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
        @{ Id = 'server';     Title = 'Server ports and TLS' }
        @{ Id = 'auth';       Title = 'Authentication and limits' }
        @{ Id = 'logging';    Title = 'Logging' }
        @{ Id = 'features';   Title = 'Quality-of-life features' }
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
            Name      = 'LogIntegrityHash'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'LogIntegrityHash'
            Help      = "Writes <logfile>.md5 next to every completed log file (audit trail)."
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
    )
}
