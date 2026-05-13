# Feature Comparison: posh vs. OLD POSH (PoSH Server 3.7)

This document compares the current `Start-WebServer.ps1` against the legacy **PoSH Server 3.7** by Yusuf Ozturk (April 2014, GPL v2), located in the (gitignored) sibling folder `OLD POSH/`. All nine planned PRs in the roadmap below are now implemented — every option ships with backward-compatible defaults, so a fresh install behaves identically to the pre-roadmap baseline unless an option is explicitly enabled.

## About OLD POSH

PoSH Server 3.7 was a stand-alone PowerShell HTTP server built on `System.Net.HttpListener` with a modular architecture (separate sub-modules for auth, IP restriction, content filtering, logging). It supported dynamic `.ps1` execution by dot-sourcing into the listener's runspace, PHP-CGI handlers, static file serving with ~40 MIME types, Basic/NTLM/Integrated Windows authentication, hourly/daily log rotation in IIS W3C format, MD5 log integrity, custom HTML error pages, directory browsing, and Windows Scheduled Task daemonization via `schtasks.exe`.

It is **GPL v2 licensed** — code is referenced for logic only, never copied 1:1, to keep this project under its current license.

## Comparison Table

Legend: ✅ present · ❌ missing · 🔶 implemented differently · — not applicable / no gap

The "Before" column reflects the state of `Start-WebServer.ps1` prior to the PR roadmap below; the "Status / PR" column shows where each gap was closed. Anything marked "Implemented — PR-X" is present in the current code (opt-in via `$cfg`).

| # | Feature | OLD POSH | Before | Status / PR |
|---|---|:-:|:-:|---|
| 1 | Static File Serving (HTML/CSS/JS/Images/PDF/Fonts) | ✅ 40+ MIME types | ❌ | Implemented — PR-2 |
| 2 | MIME-Type Mapping (~40 types) | ✅ | ❌ | Implemented — PR-2 |
| 3 | `application/x-www-form-urlencoded` POST parsing | ✅ | ❌ | Implemented — PR-3 |
| 4 | Cookies / Session-IDs | ✅ Auto-`PoSHSessionID` | ❌ | Implemented — PR-3 |
| 5 | Custom HTML Error Pages | ✅ 404 / security | 🔶 JSON envelope | Implemented — PR-7 |
| 6 | Directory Browsing | ✅ HTML listing | ❌ | Implemented — PR-9 |
| 7 | Basic / NTLM / Integrated-Win Auth | ✅ switchable | 🔶 API key only | Implemented — PR-4 (Basic only) |
| 8 | HTTPS / TLS | ✅ | ✅ | — |
| 9 | Auto-Generated Self-Signed Cert | ✅ inline | 🔶 separate `Register-ScheduledTask.ps1` | — (current approach is cleaner) |
| 10 | Multi-Host / URL-Prefix Routing | ✅ multiple hostnames | 🔶 `+` wildcard only | Implemented — PR-8 |
| 11 | GZIP Compression | 🔶 header only | ❌ | Implemented — PR-1 |
| 12 | PHP-CGI Integration | ✅ | ❌ | Implemented — PR-6 |
| 13 | `.psxml` / `.posh` / `.psapi` Extension Aliases | ✅ | ❌ | Implemented — PR-5 |
| 14 | In-Process `.ps1` Execution (dot-sourcing) | ✅ | 🔶 subprocess | Implemented — PR-5 (opt-in, subprocess stays default) |
| 15 | XML API Helper (`New-PoSHAPIXML`) | ✅ | ❌ | Implemented — PR-7 |
| 16 | IIS W3C Log Format | ✅ | 🔶 custom format | Implemented — PR-1 (option) |
| 17 | Hourly Log Rotation | ✅ | 🔶 daily only | Implemented — PR-1 |
| 18 | Log Integrity / MD5 Hash | ✅ | ❌ | Implemented — PR-1 |
| 19 | IP Whitelist via Regex / CIDR | ✅ regex | 🔶 exact list | Implemented — PR-8 |
| 20 | IP Blocklist | ❌ | ✅ | — (current is better) |
| 21 | Rate Limiting (per-IP) | ❌ | ✅ Fixed Window + penalty | — (current is better) |
| 22 | Global Min-Interval Throttle | ❌ | ✅ | — (current is better) |
| 23 | Concurrency Limit (configurable Semaphore) | 🔶 fixed 3 threads | ✅ `MaxConcurrent` | — (current is better) |
| 24 | Request IDs / Tracing | ❌ | ✅ `X-Request-Id` | — (current is better) |
| 25 | Script Timeout (HTTP 504) | ❌ | ✅ `ScriptTimeoutSec` | — (current is better) |
| 26 | Path-Traversal Protection | ❓ unclear | ✅ `GetFullPath` check | — (current is better) |
| 27 | POST-Body Size Limit | ❌ | ✅ `MaxRequestBodyBytes` | — (current is better) |
| 28 | `/health` + `/metrics` Endpoints | ❌ | ✅ | — (current is better) |
| 29 | Content Filter (MIME blacklist) | ✅ | ❌ | Implemented — PR-2 (follows from #1) |
| 30 | Windows Scheduled Task Install | ✅ `-asJob` | ✅ `Register-ScheduledTask.ps1` | — |
| 31 | Background Jobs on Interval (1/5/10/20/30/60 min) | ✅ `-CustomJob` | ❌ | Implemented — PR-8 |
| 32 | Inject Request-Context Variables (`$PoSHQuery`, `$PoSHPost`, `$PoSHCookies`) | ✅ in-process | ❌ | Implemented — PR-5 (coupled with #14) |
| 33 | Range Requests / 206 Partial Content | ❌ | ❌ | Implemented — PR-2 (follows from #1) |
| 34 | CORS Headers | ❌ | ❌ | Implemented — PR-3 |
| 35 | ETag / Last-Modified Cache Headers | ❌ | ❌ | Implemented — PR-2 (follows from #1) |

## Implementation Roadmap

Nine PRs covered every gap. All are now merged.

| PR | Theme | Depends on |
|---|---|---|
| PR-1 | GZIP, MD5 log hash, hourly rotation, IIS W3C log option | — |
| PR-2 | Static file serving, MIME map, Range, ETag/Last-Modified, MIME blacklist | — |
| PR-3 | `x-www-form-urlencoded` POST, cookies/session, CORS, OPTIONS preflight | — |
| PR-4 | Basic Auth option (NTLM/Integrated explicitly out-of-scope) | — |
| PR-5 | `.psxml/.posh/.psapi` aliases, in-process execution option, context-variable injection | — |
| PR-6 | PHP-CGI handler | — |
| PR-7 | XML API helper, custom HTML error pages | PR-5 (for XML) |
| PR-8 | Background jobs on interval, multi-host prefix routing, IP regex/CIDR | — |
| PR-9 | Directory browsing | PR-2 |

### Principles applied across all PRs

- All new options ship with **backward-compatible defaults**. A fresh install with no `$cfg` changes behaves identically to the pre-roadmap baseline.
- Every PR updates [docs/changelog.md](changelog.md) and — where new options are added — [docs/configuration.md](configuration.md).
- `Invoke-ScriptAnalyzer -Path . -Recurse` must remain green.
- OLD POSH is GPL v2 — its logic is referenced, never its code.

### Explicit non-goals (will not be implemented)

- **NTLM / Integrated Windows Authentication.** `HttpListener.AuthenticationSchemes` is per-listener, not per-request. Mixing NTLM with the existing API-key model is high-risk for low gain. If ever needed, a separate dedicated PR using `AuthenticationSchemeSelectorDelegate` would be required.
- **`Start-ThreadJob`-based concurrency.** Already replaced by `RunspacePool` for a reason — see code comment around line ~1067 in `Start-WebServer.ps1`.
- **Persistent session store.** Cookies/sessions in PR-3 are echo-only; no server-side state.
