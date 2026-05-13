# Edit-PoshSettings — local web editor

A standalone, loopback-only web editor for the most-used posh settings. Runs only while you edit and shuts itself down afterwards.

## When to use it

Use this instead of opening `globalvars.ps1` / `config.psd1` in an editor when you want:

- Form fields with validation (FQDN regex, port range, LDAP-DN check)
- A diff preview before any file is touched
- Automatic backups (`<file>.bak.<timestamp>`, last 5 kept)
- One UI for both files plus the setup helpers (AES key generation, encrypted-secret storage, `POSH_API_KEY` machine env var)

It is **not** a replacement for `git diff` / your editor when you need to add or remove keys, change comments, or touch keys that the editor does not expose (background jobs, full `MimeTypeMap`, nested `ApiKeys` hashtable). Open the files directly for those.

## Launching it

Prerequisite: `config.psd1` exists (run [tools/Initialize-Config.ps1](../tools/Initialize-Config.ps1) once if not).

```powershell
.\tools\Edit-PoshSettings.ps1
```

Defaults: picks a free loopback port, generates a one-time access token, opens the default browser. The console window shows the live URL and stays open for the lifetime of the editor — close it with `Ctrl+C` if needed.

Useful flags:

| Flag | Purpose |
|---|---|
| `-NoBrowser` | Don't auto-open a browser. Use when you want to paste the URL into a remote-desktop session by hand. |
| `-Port <int>` | Pin the loopback port instead of picking randomly. Useful for tests or when the auto-picked port collides. |
| `-InactivityTimeoutSec <int>` | Idle seconds before the editor stops itself. Default 600. |
| `-RepoRoot <path>` | Override the repo root. Defaults to the directory above the `tools/` folder this script lives in. |

The editor stops itself when:

- You click **Beenden** in the UI (preferred)
- You click **Speichern** and the save succeeds (5 s grace, then auto-quit)
- No request hits the server for `InactivityTimeoutSec`
- The brute-force counter trips (20 bad token attempts)

## Security model

Threat model: a local script on the same machine, or a malicious browser tab navigating to `http://127.0.0.1:<port>/`. We assume the local user is trusted — same as `Read-Host -AsSecureString` in a terminal.

| Concern | Mitigation |
|---|---|
| Network reach | Listener binds **`127.0.0.1` literally**, not `localhost` or `+`. Every request also re-checks `RemoteEndPoint.Address` is loopback before any work runs. |
| Random URL | 16-byte (128-bit) random token, URL-safe Base64. New token every start, only in memory. |
| Drive-by browser tab | HttpOnly cookie + `X-Posh-CSRF` header double-submit. Cross-origin POSTs can't forge the header → request rejected. `SameSite=Strict` keeps the cookie from being sent by anyone else. |
| Timing attacks on the token | `CryptographicOperations.FixedTimeEquals`. |
| Brute force | 20 token mismatches → editor stops itself + closes the listener. Each failure also adds a 2 s sleep. |
| Large bodies | 256 KB hard cap on POST bodies → HTTP 413. |
| Path traversal | Every write goes through a hard-coded whitelist: `globalvars.ps1`, `config.psd1`, `encrypted_pw\encryptedString_<label>.txt`. Anything else throws. |
| Plaintext HTTP | Loopback only, no other listener can MITM the traffic. Same threat model as `Read-Host -AsSecureString` typed into a terminal on the same machine. |

## What the editor edits

See [tools/editor/schema.psd1](../tools/editor/schema.psd1) for the live source of truth. As of writing, 47 fields across 8 tabs:

- **Domäne und AD** — `DomainController`, `DomainDnsSuffix`, all `Ldap*` base DNs, `DefaultTargetHost`, `PasswordRetentionDays`
- **Mail und Tickets** — `ExchangeServer`, `SmtpRelay`, `AdminMail`, `JiraServerUri`
- **Infrastruktur** — `PoshServerFqdn`, `VCenterFqdn`, `VeeamBackupServer`, `LansweeperUri`, `WsusServer`, `WsusPort`, `SccmSiteCode`
- **Server-Ports und TLS** — `HttpPort`, `HttpsPort`, `HttpsEnabled`, `MaxRequestBodyBytes`
- **Authentifizierung und Limits** — `AuthMode`, `MaxConcurrent`, `ScriptTimeoutSec`, `RateLimit*`, `AllowedIPs`, `BlockedIPs`
- **Logging** — `LogRetentionDays`, `LogSchedule`, `LogFormat`, `AuditLogEnabled`, `SlowRequestThresholdMs`, `LogIntegrityHash`
- **Komfort-Features** — `GzipEnabled`, `BrotliEnabled`, `StaticServingEnabled`, `IndexShowMetadata`, `PromMetricsEnabled`, `OpenApiEnabled`, `PathPlaceholders`
- **Setup-Helfer** — generate AES key, store encrypted secret, set `POSH_API_KEY` (machine env, admin only)

Out of scope on purpose (open the file by hand):

- The `$key` byte array (only the generator button writes it)
- `BackgroundJobs` (nested hashtable array)
- Full `MimeTypeMap` and `ScriptExtensionMap`
- Cert / netsh sslcert binding (stays in `Register-ScheduledTask.ps1`)
- Live reload — restart the Scheduled Task after saving

## How saves work

1. Click **Speichern** when one or more fields are dirty.
2. Editor calls `POST /api/diff` — server returns the list of changed fields (Vorher → Nachher).
3. Modal shows the diff. You confirm.
4. Editor calls `POST /api/save`. The server:
   1. Validates every value again (defense in depth — the client is untrusted even when it just confirmed).
   2. Backs up each touched file once: `<file>.bak.YYYYMMDD-HHmmss`, prunes older backups so only the last 5 remain per file.
   3. Writes each field individually via an AST-based replacement that preserves all surrounding comments and whitespace. `git diff` after a save shows only the lines you actually changed.
5. Toast confirms success and lists the backup file paths.

Restarting the server is on you — the editor does not bounce the Scheduled Task.

## FAQ

**Why a separate tool instead of an `/admin` route in the main server?**
Different threat models. The main server is intentionally network-exposed (with auth). The editor must never be reachable across the network — separating the listener makes that promise easy to verify.

**Why not HTTPS?**
Loopback only, no other listener can intercept. Same plaintext model as typing into a local terminal. Adding HTTPS would mean a per-install cert, certificate trust prompts, and complexity that doesn't buy anything against the actual threat.

**Where do backups go?**
Next to the file being edited: `globalvars.ps1.bak.<ts>` and `config.psd1.bak.<ts>`. Both backup patterns are gitignored.

**The editor refused to start ("config.psd1 not found").**
Run [tools/Initialize-Config.ps1](../tools/Initialize-Config.ps1) once. The server itself also hard-fails at startup without `config.psd1` — that's by design as of PR 1.

**The "POSH_API_KEY setzen"-Button is disabled.**
You launched the editor as a normal user. `[Environment]::SetEnvironmentVariable(..., 'Machine')` needs admin. Relaunch the editor from an elevated PowerShell to use that button.

**Can I edit `BackgroundJobs` / `MimeTypeMap` / `ApiKeys` here?**
No — those are nested data structures. Open `config.psd1` directly. The editor preserves them on every save because it only rewrites the keys it knows about.

**Where do I rebind the URL ACL / open the Windows Firewall?**
Neither needed. Loopback bind requires no `netsh http add urlacl` reservation, and the firewall blocks nothing on `127.0.0.1`.
