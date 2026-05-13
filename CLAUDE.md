# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file Windows HTTP/HTTPS server (`Start-WebServer.ps1`, ~5000 lines) built on `System.Net.HttpListener` + `RunspacePool`. Every `.ps1` file under `webroot\` is automatically reachable as an HTTP endpoint — the server spawns a separate `pwsh.exe` subprocess per request, captures stdout/stderr/exit-code, and returns a uniform JSON envelope `{ exitCode, output, error }`.

There is **no build system, no test framework, and no external dependencies** beyond the .NET BCL and PowerShell 7.

## Read these first

The repo has extensive documentation — prefer reading these over re-deriving from the code:

- [README.md](README.md) — Quick-start, HTTP status codes, calling examples.
- [docs/architecture.md](docs/architecture.md) — Component breakdown and request lifecycle.
- [docs/configuration.md](docs/configuration.md) — Every `$cfg` option.
- [docs/contributing.md](docs/contributing.md) — Conventions, branching, commit format, endpoint rules.
- [docs/post-json.md](docs/post-json.md) — POST-body-as-file passthrough pattern.

## Common commands

```powershell
# Run the server locally (HTTP only, default port 80)
.\Start-WebServer.ps1

# Run on a custom port
.\Start-WebServer.ps1 -HttpPort 8080

# Run with HTTPS enabled (requires netsh sslcert binding — see Register-ScheduledTask.ps1)
.\Start-WebServer.ps1 -HttpsEnabled -HttpPort 80 -HttpsPort 443

# Lint a single file
Invoke-ScriptAnalyzer -Path .\Start-WebServer.ps1

# Lint the whole repo (must be green before commit)
Invoke-ScriptAnalyzer -Path . -Recurse

# Parser-only syntax check (no PSScriptAnalyzer required)
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Start-WebServer.ps1), [ref]$null, [ref]$errors)
$errors
```

There is no automated test suite — verification is done by running the server and calling endpoints with `Invoke-RestMethod` or `curl`.

## Non-obvious design decisions

These are easy to "improve" by accident — don't, unless you've understood the reasoning:

- **Subprocess execution per request is intentional**, not a performance oversight. It's the only reliable way to read PowerShell exit codes (`exit 0` vs `exit 1`) and to enforce hard timeouts via `Process.Kill()`. An in-process execution mode exists as an opt-in (`ExecutionMode = 'InProcess'`), but `Subprocess` stays the default.
- **`RunspacePool` deliberately replaced `Start-ThreadJob`** (see comment around line ~1067 in `Start-WebServer.ps1`). `Start-ThreadJob` serialized live .NET objects, corrupted state under load, and degraded due to `JobSourceAdapter` issues in PS 7.6.
- **`$cfg` is eager-evaluated**: any variable referenced inside the `$cfg = @{ ... }` hashtable must be defined **before** the hashtable literal. PowerShell does not lazily resolve hashtable values.
- **POST bodies are passed as files, not arguments.** The server writes the JSON body to `PostJsonDir\YYYYMMDD_HHmmss_<requestId>.json` and passes the absolute path via `-JsonFilePath`. This avoids `ARG_MAX`-style limits and preserves nested types / arrays / large payloads. Scripts must read and parse the file themselves.
- **`POSH_API_KEY` is read from the system environment variable.** It is not stored in a config file. `Register-ScheduledTask.ps1` is the canonical way to set it.
- **HTTPS requires a `netsh sslcert` binding** to exist before startup. The server validates this at startup and exits if missing — don't remove that check.
- **Rate-limiting uses Fixed Window + flat penalty**, not sliding window. Penalty applies after the *first* 429, not after every violation in the window.
- **`X-Request-Id` correlates response ↔ log line.** Don't drop it — clients rely on it for tracing.

## Coding conventions (essentials)

Full reference is in [docs/contributing.md](docs/contributing.md) and the gitignored `AGENTS.md`. Quick form:

| Element | Convention | Example |
|---|---|---|
| Functions | `Verb-Noun` PascalCase | `Write-JsonResponse` |
| Script constants | `SCREAMING_SNAKE_CASE` | `$RATE_LIMIT_TABLE` |
| Local variables | `camelCase` | `$clientIp` |
| Config keys / script params | `PascalCase` | `$cfg.HttpPort`, `param([string] $JsonFilePath)` |
| `param()` blocks | Always explicit types | `param([int] $Port = 80)` |
| String formatting | `-f` operator, never `+` | `"hello {0}" -f $name` |
| Output suppression | `$null = ...` | not `\| Out-Null` |
| Comments | English, explain *why* | not what the code obviously does |

## Deployment vs source layout

- **Source** lives in this repo (worktree root).
- **Deployment** target is `C:\posh\` (see `$cfg.WebRoot`, `$cfg.LogDir`, `$cfg.PostJsonDir` defaults).
- `Register-ScheduledTask.ps1` is the install/setup helper — it handles copying, certificate creation, netsh binding, firewall rules, and Scheduled-Task registration interactively.

## Commit convention

```
<type>(<scope>): <imperative summary>
```

- **type:** `feat`, `fix`, `chore`, `docs`, `refactor`
- **scope:** affected component without extension (e.g. `server`, `webroot`, `task`, `logging`)
- **summary:** imperative mood, no trailing period, max 72 characters

Examples:

```
feat(server): add GZIP response compression for text MIME types
fix(logging): only call ReleaseMutex when WaitOne succeeded
```
