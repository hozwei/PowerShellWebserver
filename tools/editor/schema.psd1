# ---------------------------------------------------------------------------
#  Field metadata for tools\Edit-PoshSettings.ps1
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
        @{ Id = 'server';     Title = 'Server-Ports und TLS' }
        @{ Id = 'auth';       Title = 'Authentifizierung und Limits' }
        @{ Id = 'logging';    Title = 'Logging' }
        @{ Id = 'features';   Title = 'Komfort-Features' }
        @{ Id = 'setup';      Title = 'Setup-Helfer' }
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
            Help      = "FQDN des Active-Directory-Servers."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'DomainDnsSuffix'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$DomainDnsSuffix'
            Help      = "DNS-Domäne des AD (z.B. 'example.local')."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'SmtpRelay'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$SmtpRelay'
            Help      = "FQDN des SMTP-Relays für ausgehende Mails."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'AdminMail'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$AdminMail'
            Help      = "Mail-Adresse für Notifications und Fehler-Mails."
            Validator = '^([^@\s]+@[^@\s]+\.[^@\s]+)?$'
        }
        @{
            Name      = 'PoshServerFqdn'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$PoshServerFqdn'
            Help      = "Externer Hostname dieses posh-Servers (für Cert-Subject und Self-Links)."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'LdapUsers'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapUsers'
            Help      = "Distinguished Name der Benutzer-OU (z.B. 'OU=Users,DC=example,DC=local')."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapUsersDisabled'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapUsersDisabled'
            Help      = "DN der Disabled-Users-OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapServers'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapServers'
            Help      = "DN der Server-OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapClients'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapClients'
            Help      = "DN der Client-OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapGroups'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$LdapGroups'
            Help      = "DN der Gruppen-OU."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'DefaultTargetHost'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'string'
            Label     = '$DefaultTargetHost'
            Help      = "Hostname, der als Default für `$TargetHost in Webroot-Skripten dient."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'PasswordRetentionDays'
            File      = 'globalvars.ps1'
            Group     = 'globalvars'
            Type      = 'int'
            Label     = '$PasswordRetentionDays'
            Help      = "Tage, nach denen ein Passwort als abgelaufen gilt."
            Min       = 0
            Max       = 3650
        }

        # -- Server-Ports und TLS (config.psd1) -----------------------------
        @{
            Name      = 'HttpPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HttpPort'
            Help      = "TCP-Port für HTTP. 0 = HTTP deaktiviert (nur sinnvoll mit HttpsEnabled)."
            Min       = 0
            Max       = 65535
        }
        @{
            Name      = 'HttpsPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HttpsPort'
            Help      = "TCP-Port für HTTPS. Wirkt nur mit HttpsEnabled = `$true."
            Min       = 1
            Max       = 65535
        }
        @{
            Name      = 'HttpsEnabled'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'bool'
            Label     = 'HttpsEnabled'
            Help      = "Voraussetzung: netsh-sslcert-Binding via Register-ScheduledTask.ps1."
        }
        @{
            Name      = 'MaxRequestBodyBytes'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'MaxRequestBodyBytes'
            Help      = "Maximale Größe von POST-Bodys in Bytes (20 MB = 20971520). Größer → HTTP 413."
            Min       = 1024
            Max       = 1073741824
        }

        # -- Authentifizierung und Limits (config.psd1) ---------------------
        @{
            Name      = 'AuthMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'AuthMode'
            Help      = "ApiKey: nur X-Api-Key. Basic: nur HTTP-Basic. Both: beides erlaubt."
            Choices   = @('ApiKey', 'Basic', 'Both')
        }
        @{
            Name      = 'MaxConcurrent'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'MaxConcurrent'
            Help      = "Mehr gleichzeitige Requests → HTTP 503."
            Min       = 1
            Max       = 1000
        }
        @{
            Name      = 'ScriptTimeoutSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'ScriptTimeoutSec'
            Help      = "Wenn ein Skript länger läuft → HTTP 504."
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitRequests'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitRequests'
            Help      = "Max. Anzahl Requests pro IP pro Fenster (0 = Rate-Limit deaktiviert)."
            Min       = 0
            Max       = 1000000
        }
        @{
            Name      = 'RateLimitWindowSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitWindowSec'
            Help      = "Dauer des Rate-Limit-Fensters in Sekunden."
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitPenaltySec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'RateLimitPenaltySec'
            Help      = "Sperrzeit nach erstem 429 (0 = nur normales Fensterverhalten)."
            Min       = 0
            Max       = 86400
        }
        @{
            Name      = 'RateLimitMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'RateLimitMode'
            Help      = "reject: sofort HTTP 429. queue: bis RateLimitQueueTimeoutSec warten."
            Choices   = @('reject', 'queue')
        }
        @{
            Name      = 'RateLimitPerIdentity'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'bool'
            Label     = 'RateLimitPerIdentity'
            Help      = "Gut bei NAT/Proxy. Anonyme Requests bleiben pro IP gelimitet."
        }
        @{
            Name      = 'AllowedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'AllowedIPs'
            Help      = "Eine Zeile pro Eintrag. Leer = alle erlaubt. Beispiele: '192.168.1.10', '10.0.0.0/8', '~^192\.168\.'."
        }
        @{
            Name      = 'BlockedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'BlockedIPs'
            Help      = "Eine Zeile pro Eintrag. Wird vor AllowedIPs ausgewertet."
        }

        # -- Logging (config.psd1) ------------------------------------------
        @{
            Name      = 'LogRetentionDays'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'LogRetentionDays'
            Help      = "Logs älter als N Tage werden beim Start gelöscht (0 = aus)."
            Min       = 0
            Max       = 3650
        }
        @{
            Name      = 'LogSchedule'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'LogSchedule'
            Help      = "Daily: ein File pro Tag. Hourly: ein File pro Stunde."
            Choices   = @('Daily', 'Hourly')
        }
        @{
            Name      = 'LogFormat'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'LogFormat'
            Help      = "Native: pipe-delimited. IIS-W3C: W3C Extended (für logparser)."
            Choices   = @('Native', 'IIS-W3C')
        }
        @{
            Name      = 'AuditLogEnabled'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'AuditLogEnabled'
            Help      = "Schreibt AUTH_FAIL, IP_BLOCKED, RATE_LIMITED als NDJSON in audit.log."
        }
        @{
            Name      = 'SlowRequestThresholdMs'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'SlowRequestThresholdMs'
            Help      = "Requests >= N ms bekommen einen Eintrag in slow.log (0 = aus)."
            Min       = 0
            Max       = 86400000
        }
        @{
            Name      = 'LogIntegrityHash'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'LogIntegrityHash'
            Help      = "Schreibt <logfile>.md5 neben jedes abgeschlossene Logfile (Audit-Trail)."
        }

        # -- Komfort-Features (config.psd1) ---------------------------------
        @{
            Name      = 'GzipEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'GzipEnabled'
            Help      = "Komprimiert Text-Antworten (HTML/JSON/CSS/JS) wenn der Client gzip akzeptiert."
        }
        @{
            Name      = 'BrotliEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'BrotliEnabled'
            Help      = "Bevorzugt Brotli vor GZIP wenn beides angeboten wird (~15-25 % kleiner)."
        }
        @{
            Name      = 'StaticServingEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'StaticServingEnabled'
            Help      = "Liefert non-.ps1-Dateien aus dem WebRoot aus."
        }
        @{
            Name      = 'IndexShowMetadata'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'IndexShowMetadata'
            Help      = "GET / liefert Synopsis + Parameter aus jedem Skript (statt nur Pfad)."
        }
        @{
            Name      = 'PromMetricsEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'PromMetricsEnabled'
            Help      = "Aktiviert GET /metrics-prom im Prometheus-Text-Format."
        }
        @{
            Name      = 'OpenApiEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'OpenApiEnabled'
            Help      = "Aktiviert GET /openapi.json mit auto-generierter OpenAPI-3.1-Spec."
        }
        @{
            Name      = 'PathPlaceholders'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'PathPlaceholders'
            Help      = "Aktiviert '[id].ps1' als Platzhalter für /users/123 etc."
        }
    )
}
