# ---------------------------------------------------------------------------
#  Field metadata for tools\Edit-PoshSettings.ps1
#
#  Single source of truth for what the browser editor exposes:
#  which keys are editable, where they live, how they validate. The same
#  schema drives both the client-side <input> attributes and the server
#  validation in PoshSettingsIO.psm1.
#
#  Validator regex anchors are intentionally explicit (^...$). Empty
#  strings are accepted on every optional field — match an empty input
#  with the alternation '|^$' or by including the empty case in the body.
# ---------------------------------------------------------------------------
@{
    Groups = @(
        @{ Id = 'domain';   Title = 'Domäne und AD' }
        @{ Id = 'mail';     Title = 'Mail und Tickets' }
        @{ Id = 'infra';    Title = 'Infrastruktur' }
        @{ Id = 'server';   Title = 'Server-Ports und TLS' }
        @{ Id = 'auth';     Title = 'Authentifizierung und Limits' }
        @{ Id = 'logging';  Title = 'Logging' }
        @{ Id = 'features'; Title = 'Komfort-Features' }
        @{ Id = 'other';    Title = 'Sonstige (selbst hinzugefügt)' }
        @{ Id = 'setup';    Title = 'Setup-Helfer' }
    )

    # ---------------------------------------------------------------
    # Fields are saved by writing the same key/value back into the
    # configured File. Type drives input-rendering AND server-side
    # validation. Validator is a regex that the value's string form
    # must match.
    # ---------------------------------------------------------------
    Fields = @(
        # -- Domäne und AD (globalvars.ps1) ---------------------------------
        @{
            Name      = 'DomainController'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'Domain Controller (FQDN)'
            Help      = 'Vollqualifizierter Hostname des Active-Directory-Servers.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'DomainDnsSuffix'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'AD-DNS-Suffix'
            Help      = "DNS-Domäne des AD (z.B. 'example.local')."
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'LdapUsers'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'LDAP Base DN: aktive Benutzer'
            Help      = "Distinguished Name der Benutzer-OU (z.B. 'OU=Users,DC=example,DC=local')."
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapUsersDisabled'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'LDAP Base DN: deaktivierte Benutzer'
            Help      = 'Distinguished Name der Disabled-Users-OU.'
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapServers'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'LDAP Base DN: Server'
            Help      = 'Distinguished Name der Server-OU.'
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapClients'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'LDAP Base DN: Clients'
            Help      = 'Distinguished Name der Client-OU.'
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'LdapGroups'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'LDAP Base DN: Gruppen'
            Help      = 'Distinguished Name der Gruppen-OU.'
            Validator = '^((OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*)?$'
        }
        @{
            Name      = 'DefaultTargetHost'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'string'
            Label     = 'Default-Zielhost für Skripte'
            Help      = 'Hostname, der als Default für $TargetHost in Webroot-Skripten dient.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'PasswordRetentionDays'
            File      = 'globalvars.ps1'
            Group     = 'domain'
            Type      = 'int'
            Label     = 'Passwort-Aufbewahrung (Tage)'
            Help      = 'Tage, nach denen ein Passwort als abgelaufen gilt (für Verwaltungs-Skripte).'
            Min       = 0
            Max       = 3650
        }

        # -- Mail und Tickets (globalvars.ps1) ------------------------------
        @{
            Name      = 'ExchangeServer'
            File      = 'globalvars.ps1'
            Group     = 'mail'
            Type      = 'string'
            Label     = 'Exchange-Server (FQDN)'
            Help      = 'On-Prem-Exchange-Hostname für Remote-PowerShell-Sessions.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'SmtpRelay'
            File      = 'globalvars.ps1'
            Group     = 'mail'
            Type      = 'string'
            Label     = 'SMTP-Relay (FQDN)'
            Help      = 'Hostname des SMTP-Relays für ausgehende Mails.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'AdminMail'
            File      = 'globalvars.ps1'
            Group     = 'mail'
            Type      = 'string'
            Label     = 'Admin-Empfänger-Adresse'
            Help      = 'Mail-Adresse für Notifications und Fehler-Mails.'
            Validator = '^([^@\s]+@[^@\s]+\.[^@\s]+)?$'
        }
        @{
            Name      = 'JiraServerUri'
            File      = 'globalvars.ps1'
            Group     = 'mail'
            Type      = 'string'
            Label     = 'Jira-Server-URI'
            Help      = "Basis-URL des Jira-Servers (z.B. 'https://jira.example.local')."
            Validator = '^(https?://[^\s]+)?$'
        }

        # -- Infrastruktur (globalvars.ps1) ---------------------------------
        @{
            Name      = 'PoshServerFqdn'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'posh-Server-FQDN'
            Help      = 'Externer Hostname dieses posh-Servers (für Cert-Subject und Self-Links).'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'VCenterFqdn'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'vCenter (FQDN)'
            Help      = 'VMware-vCenter-Hostname.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'VeeamBackupServer'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'Veeam-Backup-Server (FQDN)'
            Help      = 'Hostname des Veeam-Backup-Servers.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'LansweeperUri'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'Lansweeper-URI'
            Help      = "Basis-URL der Lansweeper-Web-UI (z.B. 'https://lansweeper.example.local/')."
            Validator = '^(https?://[^\s]+)?$'
        }
        @{
            Name      = 'WsusServer'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'WSUS-Server (FQDN)'
            Help      = 'Hostname des WSUS-Servers.'
            Validator = '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$|^$'
        }
        @{
            Name      = 'WsusPort'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'int'
            Label     = 'WSUS-Port'
            Help      = "TCP-Port des WSUS-Webservices (Standard 8531 für SSL, 8530 ohne)."
            Min       = 1
            Max       = 65535
        }
        @{
            Name      = 'SccmSiteCode'
            File      = 'globalvars.ps1'
            Group     = 'infra'
            Type      = 'string'
            Label     = 'SCCM-Site-Code'
            Help      = 'Drei-Zeichen-Sitecode des SCCM/MECM (z.B. "ABC").'
            Validator = '^[A-Z0-9]{0,3}$'
        }

        # -- Server-Ports und TLS (config.psd1) -----------------------------
        @{
            Name      = 'HttpPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HTTP-Port'
            Help      = 'TCP-Port für HTTP. 0 = HTTP deaktiviert (nur sinnvoll mit HttpsEnabled).'
            Min       = 0
            Max       = 65535
        }
        @{
            Name      = 'HttpsPort'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'HTTPS-Port'
            Help      = 'TCP-Port für HTTPS. Wirkt nur mit HttpsEnabled = $true.'
            Min       = 1
            Max       = 65535
        }
        @{
            Name      = 'HttpsEnabled'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'bool'
            Label     = 'HTTPS aktivieren'
            Help      = 'Voraussetzung: netsh-sslcert-Binding via Register-ScheduledTask.ps1.'
        }
        @{
            Name      = 'MaxRequestBodyBytes'
            File      = 'config.psd1'
            Group     = 'server'
            Type      = 'int'
            Label     = 'Max. POST-Body (Bytes)'
            Help      = 'Maximale Größe von POST-Bodys in Bytes (20 MB = 20971520). Größer → HTTP 413.'
            Min       = 1024
            Max       = 1073741824
        }

        # -- Authentifizierung und Limits (config.psd1) ---------------------
        @{
            Name      = 'AuthMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'Authentifizierungsmodus'
            Help      = "ApiKey: nur X-Api-Key. Basic: nur HTTP-Basic. Both: beides erlaubt."
            Choices   = @('ApiKey', 'Basic', 'Both')
        }
        @{
            Name      = 'MaxConcurrent'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'Max. parallele Requests'
            Help      = 'Mehr gleichzeitige Requests → HTTP 503.'
            Min       = 1
            Max       = 1000
        }
        @{
            Name      = 'ScriptTimeoutSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'Skript-Timeout (Sekunden)'
            Help      = 'Wenn ein Skript länger läuft → HTTP 504.'
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitRequests'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'Rate-Limit Requests pro Fenster'
            Help      = 'Max. Anzahl Requests pro IP pro Fenster (0 = Rate-Limit deaktiviert).'
            Min       = 0
            Max       = 1000000
        }
        @{
            Name      = 'RateLimitWindowSec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'Rate-Limit-Fenster (Sekunden)'
            Help      = 'Dauer des Rate-Limit-Fensters in Sekunden.'
            Min       = 1
            Max       = 86400
        }
        @{
            Name      = 'RateLimitPenaltySec'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'int'
            Label     = 'Rate-Limit-Penalty (Sekunden)'
            Help      = 'Sperrzeit nach erstem 429 (0 = nur normales Fensterverhalten).'
            Min       = 0
            Max       = 86400
        }
        @{
            Name      = 'RateLimitMode'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'enum'
            Label     = 'Rate-Limit-Verhalten'
            Help      = "reject: sofort HTTP 429. queue: bis RateLimitQueueTimeoutSec warten."
            Choices   = @('reject', 'queue')
        }
        @{
            Name      = 'RateLimitPerIdentity'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'bool'
            Label     = 'Rate-Limit pro API-Key (statt pro IP)'
            Help      = 'Gut bei NAT/Proxy. Anonyme Requests bleiben pro IP gelimitet.'
        }
        @{
            Name      = 'AllowedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'Erlaubte IPs / CIDR / Regex'
            Help      = "Eine Zeile pro Eintrag. Leer = alle erlaubt. Beispiele: '192.168.1.10', '10.0.0.0/8', '~^192\.168\.'."
        }
        @{
            Name      = 'BlockedIPs'
            File      = 'config.psd1'
            Group     = 'auth'
            Type      = 'string-array'
            Label     = 'Blockierte IPs / CIDR / Regex'
            Help      = 'Eine Zeile pro Eintrag. Wird vor AllowedIPs ausgewertet.'
        }

        # -- Logging (config.psd1) ------------------------------------------
        @{
            Name      = 'LogRetentionDays'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'Log-Aufbewahrung (Tage)'
            Help      = 'Logs älter als N Tage werden beim Start gelöscht (0 = aus).'
            Min       = 0
            Max       = 3650
        }
        @{
            Name      = 'LogSchedule'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'Log-Rotation'
            Help      = "Daily: ein File pro Tag. Hourly: ein File pro Stunde."
            Choices   = @('Daily', 'Hourly')
        }
        @{
            Name      = 'LogFormat'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'enum'
            Label     = 'Log-Format'
            Help      = "Native: pipe-delimited. IIS-W3C: W3C Extended (für logparser)."
            Choices   = @('Native', 'IIS-W3C')
        }
        @{
            Name      = 'AuditLogEnabled'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'Audit-Log aktivieren'
            Help      = 'Schreibt AUTH_FAIL, IP_BLOCKED, RATE_LIMITED als NDJSON in audit.log.'
        }
        @{
            Name      = 'SlowRequestThresholdMs'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'int'
            Label     = 'Slow-Request-Schwelle (ms)'
            Help      = 'Requests >= N ms bekommen einen Eintrag in slow.log (0 = aus).'
            Min       = 0
            Max       = 86400000
        }
        @{
            Name      = 'LogIntegrityHash'
            File      = 'config.psd1'
            Group     = 'logging'
            Type      = 'bool'
            Label     = 'MD5-Hash neben Log-Files'
            Help      = 'Schreibt <logfile>.md5 neben jedes abgeschlossene Logfile (Audit-Trail).'
        }

        # -- Komfort-Features (config.psd1) ---------------------------------
        @{
            Name      = 'GzipEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'GZIP-Kompression'
            Help      = 'Komprimiert Text-Antworten (HTML/JSON/CSS/JS) wenn der Client gzip akzeptiert.'
        }
        @{
            Name      = 'BrotliEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'Brotli-Kompression'
            Help      = 'Bevorzugt Brotli vor GZIP wenn beides angeboten wird (~15-25 % kleiner).'
        }
        @{
            Name      = 'StaticServingEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'Statisches Serving (HTML/CSS/JS)'
            Help      = 'Liefert non-.ps1-Dateien aus dem WebRoot aus.'
        }
        @{
            Name      = 'IndexShowMetadata'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'Index zeigt Skript-Metadaten'
            Help      = 'GET / liefert Synopsis + Parameter aus jedem Skript (statt nur Pfad).'
        }
        @{
            Name      = 'PromMetricsEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'Prometheus-Metriken'
            Help      = 'Aktiviert GET /metrics-prom im Prometheus-Text-Format.'
        }
        @{
            Name      = 'OpenApiEnabled'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'OpenAPI-Spezifikation'
            Help      = 'Aktiviert GET /openapi.json mit auto-generierter OpenAPI-3.1-Spec.'
        }
        @{
            Name      = 'PathPlaceholders'
            File      = 'config.psd1'
            Group     = 'features'
            Type      = 'bool'
            Label     = 'Pfad-Platzhalter (Next.js-Style)'
            Help      = "Aktiviert '[id].ps1' als Platzhalter für /users/123 etc."
        }
    )
}
