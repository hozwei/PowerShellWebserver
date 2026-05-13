# Client examples

Sample PowerShell clients for every endpoint shipped in `webroot/`,
plus the three built-in routes (`/health`, `/metrics-prom`,
`/openapi.json`). Each client demonstrates one scenario; run them from
this directory.

## Setup

The clients pick up the base URL and API key from environment
variables, falling back to `http://localhost` and a placeholder string
when they're unset:

```powershell
$env:POSH_BASE_URL = 'https://api.internal.example.com'
$env:POSH_API_KEY  = 'your-real-key'
```

For HTTPS deployments with a self-signed cert, append
`-SkipCertificateCheck` to the `Invoke-RestMethod` / `Invoke-WebRequest`
calls in `_Common.ps1`, or trust the certificate at the OS level.

## Endpoints + matching clients

| Server endpoint | Client | Demonstrates |
|---|---|---|
| [`webroot/hello.ps1`](../../webroot/hello.ps1) | [Invoke-Hello.ps1](Invoke-Hello.ps1) | Simple GET with query params + JSON envelope |
| [`webroot/subdir/system-info.ps1`](../../webroot/subdir/system-info.ps1) | [Get-SystemInfo.ps1](Get-SystemInfo.ps1) | Subdirectory routing + nested-JSON parsing |
| [`webroot/post-json.ps1`](../../webroot/post-json.ps1) | [Send-PostJson.ps1](Send-PostJson.ps1) | POST with structured JSON body |
| [`webroot/post-form.ps1`](../../webroot/post-form.ps1) | [Send-PostForm.ps1](Send-PostForm.ps1) | POST with `application/x-www-form-urlencoded` |
| [`webroot/users/[id].ps1`](../../webroot/users/[id].ps1) + [`admin.ps1`](../../webroot/users/admin.ps1) | [Get-User.ps1](Get-User.ps1) | F9 path placeholders + exact-filename priority |
| [`webroot/session.ps1`](../../webroot/session.ps1) | [Test-Session.ps1](Test-Session.ps1) | Cookie round-trip via `-WebSession` |
| [`webroot/api-status.psxml`](../../webroot/api-status.psxml) | [Get-ApiStatus.ps1](Get-ApiStatus.ps1) | Alternate-extension endpoint (raw XML) |
| [`webroot/errors.ps1`](../../webroot/errors.ps1) | [Test-Errors.ps1](Test-Errors.ps1) | Exit codes and HTTP-status mapping |
| `/health`        (built-in) | [Get-Health.ps1](Get-Health.ps1) | Auth-exempt liveness probe |
| `/metrics`, `/metrics-prom` (built-in) | [Get-Metrics.ps1](Get-Metrics.ps1) | JSON + Prometheus text format |
| `/openapi.json`  (built-in) | [Get-OpenApiSpec.ps1](Get-OpenApiSpec.ps1) | Auto-generated OpenAPI 3.1 spec |

Run a comprehensive end-to-end smoke against all the above with
[Test-AllEndpoints.ps1](Test-AllEndpoints.ps1):

```powershell
$env:POSH_API_KEY = 'your-key'
.\Test-AllEndpoints.ps1
```

## How they share boilerplate

Every client dot-sources [`_Common.ps1`](_Common.ps1), which exposes:

- `Invoke-Posh -Path /endpoint -Query @{} -Body @{}` — wraps
  `Invoke-RestMethod`, adds the `X-Api-Key` header, joins the base URL.
- `Write-Envelope` — pretty-prints the `{ exitCode, output, error }`
  envelope returned by `.ps1` endpoints.
- `Get-PoshBaseUrl` / `Get-PoshApiKey` — accessors used by clients that
  call `Invoke-WebRequest` directly (XML / Prometheus endpoints).

Treat `_Common.ps1` as a starting point — you can copy a helper into a
production tool and trim it to your specific needs.
