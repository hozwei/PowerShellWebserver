# Usage

## Basic Usage

Send an HTTP GET or POST request to a `.ps1` file under the server's `webroot\`. Include the `X-Api-Key` header with every request. The server executes the script and returns a JSON object with the exit code, standard output, and error output.

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected response:

```json
{
  "exitCode": 0,
  "output": "=== Systeminformation ===\nHostname    : WORKSTATION\nZeitstempel : 2026-04-14 11:30:00\nAufgerufen  : C:\\posh\\webroot\\script1.ps1\n\nFertig.",
  "error": ""
}
```

For all configuration options see [Configuration](./configuration.md).

## Common Use Cases

### Listing all available endpoints

Retrieve a JSON array of every `.ps1` file currently in `webroot\`, including subdirectories.

```powershell
Invoke-RestMethod -Uri 'http://localhost/' -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
["/script1.ps1", "/subdir/script2.ps1"]
```

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
  "output": "=== Systeminformation ===\nHostname    : WORKSTATION\n...\n=== Details ===\nOS          : Microsoft Windows 11 Pro\nUptime      : 2.14:07:22.1234567\nCPU-Last    : 12%\nRAM         : 14.3 GB / 31.9 GB belegt\n\nFertig.",
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
  "output": "=== Verzeichnisliste ===\nPfad    : C:\\Windows\\Temp\nFilter  : *.log\nAnzahl  : 3 Eintraege\n...\nFertig.",
  "error": ""
}
```

---

### Calling a script via POST

Pass parameters as a flat JSON object in the request body. The `Content-Type` header must be `application/json`. Body keys and query parameters can be combined — body keys take precedence when names collide.

```powershell
Invoke-RestMethod -Uri 'http://localhost/script1.ps1' `
    -Method Post `
    -ContentType 'application/json' `
    -Body '{"ComputerName":"WORKSTATION","Detail":"true"}' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expected result:

```json
{
  "exitCode": 0,
  "output": "=== Systeminformation ===\nHostname    : WORKSTATION\n...\n=== Details ===\n...\nFertig.",
  "error": ""
}
```

The script receives POST body parameters identically to query string parameters — both arrive as `string` values via the `param()` block.

---

### Calling the server from a non-PowerShell client

The server accepts HTTP GET and POST requests. Use any HTTP client:

```bash
curl -H "X-Api-Key: your-api-key" "http://localhost/script1.ps1?Detail=true"
```

Expected result:

```json
{"exitCode":0,"output":"=== Systeminformation ===\n...","error":""}
```

## Tips & Tricks

- **HTTP status codes carry semantic meaning.** A `200` response guarantees `exitCode` is `0`. A `500` means the script called `exit 1` or encountered a terminating error — inspect the `error` field. A `504` means the script exceeded `ScriptTimeoutSec` and was forcibly terminated. A `401` means the `X-Api-Key` header is missing or incorrect. A `400` on a POST request means the body is not valid flat JSON. A `413` means the body exceeded `MaxRequestBodyBytes`. A `415` means `Content-Type` was not `application/json`.
- **Scripts are hot-reloaded automatically.** There is no cache and no restart required. Saving a new or updated `.ps1` file to `webroot\` makes it immediately available at the corresponding URL.
- **Boolean parameters must be passed as strings.** PowerShell's `param()` block receives all values — whether from query parameters or a JSON body — as strings. Write `?Detail=true` or `{"Detail":"true"}` and cast inside the script with `-eq 'true'` rather than using `[bool]` parameter types.
