# Usage

## Basic Usage

Send an HTTP GET or POST request to a `.ps1` file under the server's `webroot\`. Include the `X-Api-Key` header with every request. The server executes the script and returns a JSON object with the exit code, standard output, and error output.

```powershell
# HTTP
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = 'your-api-key' }

# HTTPS (add -SkipCertificateCheck for self-signed certificates)
Invoke-RestMethod -Uri 'https://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = 'your-api-key' } -SkipCertificateCheck
```

Expected response:

```json
{
  "exitCode": 0,
  "output": "=== System Information ===\nHostname    : WORKSTATION\nTimestamp   : 2026-04-14 11:30:00\nCalled from : C:\\posh\\webroot\\script1.ps1\n\nDone.",
  "error": ""
}
```

For all configuration options see [Configuration](./configuration.md).

## Common Use Cases

### Listing all available endpoints

By default (`IndexShowMetadata = $true`), `GET /` returns an enriched object per script — the path, the methods it accepts, the synopsis pulled from comment-based help, and the parsed `param()` block:

```powershell
Invoke-RestMethod -Uri 'http://localhost/' -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
[
  {
    "path":     "/script1.ps1",
    "methods":  ["GET", "POST"],
    "synopsis": "Returns basic system information.",
    "description": "Used by monitoring dashboards as a smoke check.",
    "parameters": [
      { "name": "ComputerName", "type": "String", "default": "$env:COMPUTERNAME", "description": "Target host." },
      { "name": "Detail",       "type": "Boolean", "default": "$false", "description": "Include extended OS info." }
    ]
  }
]
```

Metadata is parsed lazily via the script's AST and cached per file; edits invalidate the cache automatically. Set `IndexShowMetadata = $false` to revert to the legacy flat path array (`["/script1.ps1", "/subdir/script2.ps1"]`).

---

### Checking server health

Retrieve the current server status, uptime since last start, and the total number of completed script requests. The health endpoint does not require authentication.

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

Expected result:

```json
{
  "status": "ok",
  "uptime": "2h 14m 37s",
  "requestsTotal": 42
}
```

`requestsTotal` counts only completed script executions — requests to `/`, `/health`, and error responses (400, 401, 403, 404) are not included.

---

### Checking server metrics

Retrieve counters and uptime for operational monitoring. Requires the `X-Api-Key` header.

```powershell
Invoke-RestMethod -Uri 'http://localhost/metrics' -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
{
  "uptime":           "2h 14m 37s",
  "requestsTotal":    42,
  "rateLimitedTotal": 3
}
```

| Field | Description |
|---|---|
| `uptime` | Time elapsed since the server process started |
| `requestsTotal` | Completed script executions (exit-code-independent; excludes `/`, `/health`, `/metrics`, and error responses) |
| `rateLimitedTotal` | Per-IP rate-limit rejections (HTTP 429 from `Test-RateLimit`). Global-throttle 429s (`MinRequestIntervalSec`, main thread) are intentionally not counted. |

---

### Calling a script with query parameters

Pass named arguments to a script by appending them as URL query parameters. Each parameter name must match a `param()` argument in the target script.

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1?ComputerName=WORKSTATION&Detail=true' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
{
  "exitCode": 0,
  "output": "=== System Information ===\nHostname    : WORKSTATION\n...\n=== Details ===\nOS          : Microsoft Windows 11 Pro\nUptime      : 2.14:07:22.1234567\nCPU load    : 12%\nRAM         : 14.3 GB / 31.9 GB used\n\nDone.",
  "error": ""
}
```

---

### Calling a script in a subdirectory

Scripts in subdirectories under `webroot\` are reachable by including the relative path in the URL.

```powershell
Invoke-RestMethod -Uri 'http://localhost/subdir/script2.ps1?Path=C:\Windows\Temp&Filter=*.log' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
{
  "exitCode": 0,
  "output": "=== Directory Listing ===\nPath    : C:\\Windows\\Temp\nFilter  : *.log\nCount   : 3 entries\n...\nDone.",
  "error": ""
}
```

---

### Calling a script via POST

POST request bodies are not passed as command-line parameters. Instead, the server writes the full JSON body to a file in `C:\posh\postjson\` and passes the absolute file path to the script as `-JsonFilePath`. The script reads and parses the file itself.

This approach works with any JSON structure — nested objects, arrays, large payloads, and values containing special characters.

```powershell
$body = @{
    firstName  = 'Anna'
    department = @{ name = 'IT'; costCenter = '4200' }
    roles      = @('admin', 'user')
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri 'http://localhost/script1.ps1' `
    -Method      Post `
    -ContentType 'application/json' `
    -Body        $body `
    -Headers     @{ 'X-Api-Key' = 'your-api-key' }
```

The target script receives `-JsonFilePath "C:\posh\postjson\20260415_143000_a1b2c3d4.json"` and reads the file:

```powershell
$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
$firstName  = $data.firstName
$deptName   = $data.department.name   # nested object
$roles      = $data.roles             # array
```

**Rules for POST requests:**
- `Content-Type` must be `application/json`
- Query string parameters (`?key=val`) are not allowed on POST requests — the server returns HTTP 400
- An empty body (`{}` or whitespace) is valid — the script receives an empty JSON object file
- The JSON file is kept after execution for audit and debugging purposes

For the full pattern including validation, error handling, and test examples, see [POST JSON File Passthrough](./post-json.md).

**POST via curl:**

```bash
curl -X POST http://localhost/script1.ps1 \
    -H "X-Api-Key: your-api-key" \
    -H "Content-Type: application/json" \
    -d '{"firstName":"Anna","department":{"name":"IT","costCenter":"4200"},"roles":["admin","user"]}'
```

---

### Calling the server from a non-PowerShell client

The server accepts HTTP GET and POST requests. Use any HTTP client:

**GET:**

```bash
curl -H "X-Api-Key: your-api-key" "http://localhost/script1.ps1?Detail=true"
```

**POST** (the script receives `-JsonFilePath` — see [POST JSON File Passthrough](./post-json.md)):

```bash
curl -X POST http://localhost/script1.ps1 \
    -H "X-Api-Key: your-api-key" \
    -H "Content-Type: application/json" \
    -d '{"firstName":"Anna","department":{"name":"IT","costCenter":"4200"},"roles":["admin","user"]}'
```

Expected result:

```json
{"exitCode":0,"output":"...","error":""}
```

---

### Posting form-urlencoded data (PR-3)

When `AcceptedContentTypes` includes `application/x-www-form-urlencoded` (default), the server accepts classic HTML-form bodies in addition to JSON. The body is parsed into an ordered hashtable, re-serialised as JSON, and forwarded to the script via the same `-JsonFilePath` contract — scripts handle both encodings identically.

```bash
curl -X POST http://localhost/post-example.ps1 \
    -H "X-Api-Key: your-api-key" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data 'firstName=Anna&department=IT&tags[]=admin&tags[]=user'
```

`tags[]=admin&tags[]=user` collapses into `{ tags: ['admin', 'user'] }`. Multiple plain occurrences of the same key (without `[]`) also collapse into an array.

---

### Using session cookies (PR-3)

Set `$cfg.SessionEnabled = $true` to auto-mint a `POSH-Session-Id` cookie on requests that did not carry one. The cookie value is `HttpOnly`, `SameSite=Lax`, and `Secure` on HTTPS connections.

The server itself remains stateless. Webroot scripts read the value via two environment variables that the server injects per request:

```powershell
# webroot\with-session.ps1
$sessionId = $env:POSH_SESSION_ID   # the value of the SessionCookieName cookie
$allCookies = $env:POSH_COOKIES     # the full raw Cookie: header

Write-Output "Session: $sessionId"
```

---

### CORS preflight (PR-3)

Set `$cfg.CorsAllowedOrigins = @('https://app.example.com')` (or `@('*')` for any origin) to enable CORS. The server responds to `OPTIONS` preflight requests with HTTP 204 and the configured `Access-Control-Allow-*` headers — preflight bypasses auth and rate-limiting so browsers can negotiate without an API key.

```bash
# Preflight
curl -X OPTIONS http://localhost/script1.ps1 \
    -H "Origin: https://app.example.com" \
    -H "Access-Control-Request-Method: POST" \
    -i

# Actual request (browser sends this after a successful preflight)
curl -X POST http://localhost/script1.ps1 \
    -H "X-Api-Key: your-api-key" \
    -H "Content-Type: application/json" \
    -H "Origin: https://app.example.com" \
    --data '{"foo":"bar"}'
```

---

### Serving static files (PR-2)

Set `$cfg.StaticServingEnabled = $true` to serve non-`.ps1` files (HTML, CSS, JS, images, fonts, …) from `$cfg.StaticRoot` (defaults to `WebRoot`). The server emits `ETag` + `Last-Modified` for client-side caching, honours `If-None-Match` / `If-Modified-Since` with HTTP 304, and supports byte-range requests:

```bash
# Conditional GET — second request gets 304 if file unchanged
curl -H "If-None-Match: \"1234-1A2B3C\"" http://localhost/style.css -i

# Byte range — first 1024 bytes
curl -H "Range: bytes=0-1023" http://localhost/big.bin -i

# Suffix range — last 100 bytes
curl -H "Range: bytes=-100" http://localhost/big.bin -i
```

---

### Calling alternate-extension scripts (PR-5)

`.psxml`, `.posh`, and `.psapi` are aliases for `.ps1` execution that bypass the JSON envelope and pass the script's stdout through verbatim with a dedicated Content-Type — legacy PoSH Server parity for HTML / XML endpoints:

```powershell
# webroot\api-status.psxml
#Requires -Version 7.0
@"
<?xml version="1.0" encoding="utf-8"?>
<Result>
  <Code>1</Code>
  <Message>OK</Message>
  <Item><Hostname>$env:COMPUTERNAME</Hostname></Item>
</Result>
"@
```

Calling `GET /api-status.psxml` returns `text/xml` with the script's stdout as the body (no `{ exitCode, output, error }` wrapper).

| Extension | Response Content-Type |
|---|---|
| `.ps1` | `application/json` (JSON envelope) |
| `.psxml` | `text/xml; charset=utf-8` (raw stdout) |
| `.posh` | `text/html; charset=utf-8` (raw stdout) |
| `.psapi` | `application/xml; charset=utf-8` (raw stdout) |

---

### Scraping Prometheus metrics (F8)

`GET /metrics-prom` exposes the same counters as `/metrics` in Prometheus text-format. Auth-exempt — point any scraper at it:

```bash
curl http://localhost/metrics-prom
```

```text
# HELP posh_uptime_seconds Server uptime since process start.
# TYPE posh_uptime_seconds gauge
posh_uptime_seconds 8061
# HELP posh_requests_total Number of completed script requests.
# TYPE posh_requests_total counter
posh_requests_total 42
# HELP posh_rate_limited_total Per-identity/IP rate-limit rejections from Test-RateLimit.
# TYPE posh_rate_limited_total counter
posh_rate_limited_total 3
# HELP posh_in_flight_requests Currently occupied request slots.
# TYPE posh_in_flight_requests gauge
posh_in_flight_requests 0
# HELP posh_rate_limit_table_size Per-key/IP rate-limit table entries.
# TYPE posh_rate_limit_table_size gauge
posh_rate_limit_table_size 12
# HELP posh_script_metadata_cache_size Cached AST metadata entries.
# TYPE posh_script_metadata_cache_size gauge
posh_script_metadata_cache_size 6
```

Toggle via `PromMetricsEnabled` in `config.psd1` (default `$true`).

---

### REST routing with path placeholders (F9)

Set `PathPlaceholders = $true` and name files Next.js-style. Each `[name]` segment in the filename matches one URL segment, and the captured value is injected as a named parameter:

```powershell
# webroot\users\[id].ps1
param([string] $id)
Write-Output "user=$id"
```

```bash
curl -H "X-Api-Key: ..." http://localhost/users/123
# → {"exitCode":0,"output":"user=123","error":""}
```

Multiple placeholders work too — `webroot\api\[v]\users\[id].ps1` matches `/api/v2/users/123` and the script receives `-v v2 -id 123`. Literal segments win over placeholders (so `webroot\users\admin.ps1` shadows `webroot\users\[id].ps1` for `/users/admin`). Adding or removing top-level subdirectories invalidates the route cache automatically; deeper edits require a restart.

---

### OpenAPI 3.1 spec (F10)

`GET /openapi.json` returns an auto-generated OpenAPI spec for the entire webroot. Auth-exempt, importable into Swagger UI, Postman, or any API gateway:

```bash
curl http://localhost/openapi.json | jq '.paths | keys'
```

The spec is rebuilt fresh per request (the per-file AST cache from F7 carries the heavy lifting). Title and version are controlled via `OpenApiTitle` / `OpenApiVersion`. Path placeholders (F9) appear as `{name}` in the spec with `in: path, required: true`.

## Tips & Tricks

- **HTTP status codes carry semantic meaning.** A `200` response guarantees `exitCode` is `0`. A `500` means the script called `exit 1` or encountered a terminating error — inspect the `error` field. A `504` means the script exceeded `ScriptTimeoutSec` and was forcibly terminated. A `401` means the `X-Api-Key` header is missing or incorrect. A `400` on a POST request means the body is not valid JSON or query string parameters were included. A `413` means the body exceeded `MaxRequestBodyBytes`. A `415` means `Content-Type` was not `application/json`.
- **Maximum 1 request per second.** posh is designed for infrequent, manually-triggered or scheduled automation calls — not for high-frequency polling. Sending requests faster than `MinRequestIntervalSec` (default: 1s) triggers an immediate HTTP 429 with a `Retry-After` header. Add a `Start-Sleep -Seconds 1` between calls in any loop, or honour the `Retry-After` header. `GET /health` is always exempt from this limit.
- **Scripts are hot-reloaded automatically.** There is no cache and no restart required. Saving a new or updated `.ps1` file to `webroot\` makes it immediately available at the corresponding URL.
- **GET query parameters arrive as strings.** PowerShell's `param()` block receives all GET query parameter values as strings. Write `?Detail=true` and cast inside the script with `-eq 'true'` rather than using `[bool]` parameter types. POST scripts receive `-JsonFilePath` and parse the JSON themselves — field types are preserved by `ConvertFrom-Json` (strings stay strings, numbers become integers, booleans become `[bool]`).
