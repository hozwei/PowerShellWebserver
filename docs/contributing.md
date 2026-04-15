# Contributing

## Development Setup

Complete the [Setup](./setup.md) first, then:

1. Install PSScriptAnalyzer for static analysis (requires an Administrator PowerShell 7 session):

    ```powershell
    Install-Module -Name PSScriptAnalyzer -Scope AllUsers -Force
    ```

2. Verify the installation:

    ```powershell
    Get-Module -ListAvailable -Name PSScriptAnalyzer
    ```

No build system, test framework, or additional tooling is required.

## Branching Strategy

The recommended branch naming schema:

| Type | Pattern | Example |
|---|---|---|
| New feature | `feat/<short-description>` | `feat/graceful-shutdown` |
| Bug fix | `fix/<short-description>` | `fix/mutex-release-ownership` |
| Maintenance | `chore/<short-description>` | `chore/update-comfyui-path` |
| Documentation | `docs/<short-description>` | `docs/add-auth-reference` |

## Commit Convention

```
<type>(<scope>): <imperative summary>
```

```
✓  feat(auth): add X-Api-Key header validation for all non-health endpoints
✓  fix(logging): only call ReleaseMutex when WaitOne succeeded
✓  chore(deps): install ThreadJob module at startup when missing
✗  fixed bug
✗  changes to Start-WebServer
```

- **type:** `feat`, `fix`, `chore`, `docs`, `refactor`
- **scope:** the affected file or component without extension, e.g. `server`, `webroot`, `task`, `logging`
- **summary:** imperative mood, no trailing period, max 72 characters

## Pull Request Process

1. Create a branch from `main` following the naming schema above.
2. Make changes. Run the syntax checks (see [Running Tests](#running-tests)) before pushing.
3. Open a pull request against `main` with a description that explains *why* the change is needed, not just what was changed.
4. Merge only when all syntax checks pass. No approvals are currently enforced.

## Running Tests

There is no automated test suite. Use the following checks before committing.

**Check a single file with PSScriptAnalyzer:**

```powershell
Invoke-ScriptAnalyzer -Path .\Start-WebServer.ps1
```

**Check the entire repository:**

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse
```

**Check syntax only (without PSScriptAnalyzer):**

```powershell
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Start-WebServer.ps1),
    [ref]$null,
    [ref]$errors
)
$errors
```

An empty result means no syntax errors were detected.

## Adding a New Endpoint

Create a new `.ps1` file anywhere inside `webroot\`. It is immediately reachable via HTTP — no registration or server restart required.

```powershell
# webroot\script1.ps1
#Requires -Version 7.0
<#
.SYNOPSIS
    Example endpoint.
.PARAMETER Name
    A string parameter passed from the query string or POST body.
#>
param(
    [string] $Name = 'World'
)

Write-Output "Hello, $Name!"
```

Call via GET:

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1?Name=Max' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Call via POST — the script receives `-JsonFilePath` and reads the file itself:

```powershell
# Script must declare param([string] $JsonFilePath = '')
# and read the file with Get-Content | ConvertFrom-Json -Depth 10
$body = @{ Name = 'Max' } | ConvertTo-Json

Invoke-RestMethod -Uri 'http://localhost/script1.ps1' `
    -Method      Post `
    -ContentType 'application/json' `
    -Body        $body `
    -Headers     @{ 'X-Api-Key' = 'your-api-key' }
```

See [POST JSON File Passthrough](./post-json.md) for the full script pattern.

**Rules for webroot scripts:**

- Start with `#Requires -Version 7.0`
- Use `$ErrorActionPreference = 'Stop'` (recommended for webroot scripts to surface errors clearly)
- Write normal output to `Write-Output` — it appears in `response.output`
- Write errors to `Write-Error` — they appear in `response.error`
- Signal failure with `exit 1` → HTTP 500; success with `exit 0` or no explicit exit → HTTP 200
- **GET:** all query parameters arrive as `string` — cast explicitly when another type is needed
- **POST:** the script receives `-JsonFilePath` (absolute path to a UTF-8 JSON file); read and parse the file with `Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10`; field types are preserved by `ConvertFrom-Json` (booleans, numbers, nested objects, and arrays work natively)
- No access to `$cfg`, server internals, or other scope variables

## Code Style

Run the full PSScriptAnalyzer check and fix all warnings before submitting:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse
```

Key conventions enforced by convention (not by tooling) — see `AGENTS.md` for the full reference:

- Functions: `Verb-Noun` PascalCase
- Script constants: `SCREAMING_SNAKE_CASE`
- Local variables: `camelCase`
- Configuration keys: `PascalCase`
- Script parameters: `PascalCase`
- All `param()` blocks have explicit type annotations
- String formatting uses the `-f` operator, not `+` concatenation
- Suppressed output uses `$null = ...`, not `| Out-Null`
- All comments are written in English and explain *why*, not *what*
- Variables referenced inside `$cfg = @{...}` must be defined before the hashtable — PowerShell evaluates values at definition time, not lazily
