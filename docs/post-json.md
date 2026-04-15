# POST JSON File Passthrough

posh passes POST request bodies to webroot scripts as files — not as command-line parameters.

---

## Why files instead of parameters?

The classic approach passes JSON keys as `-Key Value` pairs via `ArgumentList`. This breaks with:

- **Nested objects** — `{ "department": { "name": "IT" } }` cannot be expressed as a flat parameter
- **Arrays** — `{ "roles": ["admin", "user"] }` has no CLI equivalent
- **Large payloads** — Windows `ArgumentList` has practical size limits
- **Special characters** — quotes, backslashes, and Unicode in values require fragile escaping

The file approach is unconditionally reliable regardless of payload size or structure.

---

## How it works

1. Client sends `POST /script.ps1` with `Content-Type: application/json` and a JSON body
2. Server validates the body (size ≤ `MaxRequestBodyBytes`, syntactically valid JSON)
3. Server writes the body UTF-8 to `C:\posh\postjson\YYYYMMDD_HHmmss_<requestId>.json`
4. Server calls `pwsh.exe -File script.ps1 -JsonFilePath "C:\posh\postjson\...json"`
5. The script reads and parses the file; the server returns the script's output as usual

The JSON file is **kept after execution** — useful for auditing, debugging, and re-processing.
Cleanup runs at server startup: files older than `PostJsonRetentionDays` (default: 30 days) are deleted.

---

## File name format

```
20260415_143000_a1b2c3d4.json
│         │      └── requestId (8-char hex, same as X-Request-Id response header)
│         └────────── time (HHmmss)
└──────────────────── date (YYYYMMDD)
```

The `requestId` in the file name matches the `X-Request-Id` response header and the log entry — all three are correlated.

---

## Script pattern

Every POST-capable webroot script follows this pattern:

```powershell
#Requires -Version 7.0
param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

# Validate
if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
    Write-Error 'JsonFilePath parameter is missing. This script must be called via POST.'
    exit 1
}
if (-not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error "JSON file not found: $JsonFilePath"
    exit 1
}

# Read and parse
$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 10

# Access fields
$name       = $data.name
$department = $data.department.name          # nested object
$roles      = $data.roles                    # array
```

> **Note:** Use `-Depth 10` (or higher) with `ConvertFrom-Json` to fully parse deeply nested structures. The default depth is 3 in PowerShell 7.

---

## Example: `webroot\post-example.ps1`

A ready-to-use example script is included at `webroot\post-example.ps1`. It demonstrates:

- `$JsonFilePath` validation
- Reading and parsing the JSON file
- Accessing scalar top-level fields
- Accessing nested objects
- Accessing arrays

### Test with `curl`

```bash
curl -X POST http://localhost/post-example.ps1 \
     -H "Content-Type: application/json" \
     -H "X-Api-Key: your-api-key" \
     -d '{
           "firstName": "Anna",
           "lastName": "Müller",
           "department": { "name": "IT", "costCenter": "4200" },
           "roles": ["admin", "user"]
         }'
```

### Test with `Invoke-RestMethod`

```powershell
$body = @{
    firstName  = 'Anna'
    lastName   = 'Müller'
    department = @{ name = 'IT'; costCenter = '4200' }
    roles      = @('admin', 'user')
} | ConvertTo-Json -Depth 5

$response = Invoke-RestMethod `
    -Method      POST `
    -Uri         'http://localhost/post-example.ps1' `
    -ContentType 'application/json' `
    -Headers     @{ 'X-Api-Key' = $env:POSH_API_KEY } `
    -Body        $body

$response.output
```

### Expected response

```json
{
  "exitCode": 0,
  "output": "Name:        Anna Müller\nDepartment:  IT (Cost Center: 4200)\nRoles (2): admin, user\nJSON file:   C:\\posh\\postjson\\20260415_143000_a1b2c3d4.json",
  "error": ""
}
```

---

## Configuration

| Key | Default | Description |
|---|---|---|
| `PostJsonDir` | `C:\posh\postjson` | Directory where POST body files are stored |
| `PostJsonRetentionDays` | `30` | Files older than N days are deleted at startup. `0` = disabled |
| `MaxRequestBodyBytes` | `20971520` (20 MB) | Maximum POST body size. Larger bodies → HTTP 413 |

---

## Error responses

| Situation | HTTP status | Error message |
|---|---|---|
| Missing or wrong `Content-Type` | `415` | `Content-Type must be application/json.` |
| Body exceeds `MaxRequestBodyBytes` | `413` | `Request body too large. Maximum size: N MB.` |
| Body is not valid JSON | `400` | `Invalid JSON body.` |
| Query string parameters present on POST | `400` | `Query string parameters are not allowed on POST requests.` |

---

## Extended Example: User Onboarding

This extended example demonstrates a realistic automation scenario — creating a new Active Directory user account with mailbox provisioning. It shows all patterns that appear in production scripts: required vs. optional fields, nested objects, arrays, type casting, field validation, and structured output.

### JSON Payload

```json
{
  "user": {
    "firstName":   "Anna",
    "lastName":    "Müller",
    "displayName": "Anna Müller",
    "upn":         "anna.mueller@contoso.com",
    "samAccount":  "a.mueller",
    "password":    "Init1234!"
  },
  "account": {
    "ou":          "OU=Users,OU=Berlin,DC=contoso,DC=com",
    "enabled":     true,
    "mustChange":  false,
    "description": "Onboarded via posh 2026-04-15"
  },
  "mailbox": {
    "enabled":  true,
    "database": "MBX-DB01",
    "quota":    50
  },
  "groups": ["GRP-VPN", "GRP-FileShare-Berlin", "GRP-M365-E3"],
  "notify": {
    "enabled":  true,
    "recipient": "helpdesk@contoso.com"
  }
}
```

### Calling the Endpoint

```powershell
$body = @{
    user    = @{
        firstName   = 'Anna'
        lastName    = 'Müller'
        displayName = 'Anna Müller'
        upn         = 'anna.mueller@contoso.com'
        samAccount  = 'a.mueller'
        password    = 'Init1234!'
    }
    account = @{
        ou          = 'OU=Users,OU=Berlin,DC=contoso,DC=com'
        enabled     = $true
        mustChange  = $false
        description = 'Onboarded via posh 2026-04-15'
    }
    mailbox = @{
        enabled  = $true
        database = 'MBX-DB01'
        quota    = 50
    }
    groups  = @('GRP-VPN', 'GRP-FileShare-Berlin', 'GRP-M365-E3')
    notify  = @{
        enabled   = $true
        recipient = 'helpdesk@contoso.com'
    }
} | ConvertTo-Json -Depth 5

$response = Invoke-RestMethod `
    -Method      POST `
    -Uri         'http://localhost/user-onboard.ps1' `
    -ContentType 'application/json' `
    -Headers     @{ 'X-Api-Key' = $env:POSH_API_KEY } `
    -Body        $body

$response.output
```

### Webroot Script Pattern

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Creates an Active Directory user account with optional mailbox and group assignments.
.PARAMETER JsonFilePath
    Absolute path to the JSON file written by the server. Passed automatically by Start-WebServer.ps1.
#>

param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# 1. Validate file path — always the first check in a POST script.
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
    Write-Error 'JsonFilePath parameter is missing. This script must be called via POST.'
    exit 1
}
if (-not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error "JSON file not found: $JsonFilePath"
    exit 1
}

# ------------------------------------------------------------------
# 2. Read and parse.
#    -Depth 10 covers deeply nested structures.
#    ConvertFrom-Json preserves types: booleans stay [bool],
#    numbers stay [int]/[long]/[double], strings stay [string].
# ------------------------------------------------------------------
$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 10

# ------------------------------------------------------------------
# 3. Validate required fields before doing any work.
#    Fail fast — better to reject early than to create a partial user.
# ------------------------------------------------------------------
$required = @('user', 'account', 'groups')
foreach ($field in $required) {
    if ($null -eq $data.$field) {
        Write-Error "Required field missing in JSON body: '$field'"
        exit 1
    }
}

$userRequired = @('firstName', 'lastName', 'upn', 'samAccount', 'password')
foreach ($field in $userRequired) {
    if ([string]::IsNullOrWhiteSpace($data.user.$field)) {
        Write-Error "Required field missing in JSON body: 'user.$field'"
        exit 1
    }
}

# ------------------------------------------------------------------
# 4. Extract fields — nested objects and arrays, with defaults for
#    optional fields.
# ------------------------------------------------------------------
$firstName   = $data.user.firstName
$lastName    = $data.user.lastName
$displayName = if ($data.user.displayName) { $data.user.displayName } else { "$firstName $lastName" }
$upn         = $data.user.upn
$samAccount  = $data.user.samAccount
$password    = $data.user.password | ConvertTo-SecureString -AsPlainText -Force

$ou          = $data.account.ou
$enabled     = [bool] $data.account.enabled     # JSON boolean → PowerShell [bool]
$mustChange  = [bool] $data.account.mustChange
$description = $data.account.description

# groups is a JSON array — @() wraps it to guarantee an array even if only one entry
$groups      = @($data.groups)

# Optional sections — check for $null before using
$mailboxEnabled  = $null -ne $data.mailbox -and [bool] $data.mailbox.enabled
$mailboxDatabase = if ($null -ne $data.mailbox) { $data.mailbox.database } else { $null }
$mailboxQuotaGB  = if ($null -ne $data.mailbox) { [int] $data.mailbox.quota } else { 0 }

$notifyEnabled   = $null -ne $data.notify -and [bool] $data.notify.enabled
$notifyRecipient = if ($null -ne $data.notify) { $data.notify.recipient } else { $null }

# ------------------------------------------------------------------
# 5. Create the AD user.
# ------------------------------------------------------------------
Write-Output "Creating AD user: $samAccount ($displayName)"

New-ADUser `
    -SamAccountName       $samAccount `
    -UserPrincipalName    $upn `
    -GivenName            $firstName `
    -Surname              $lastName `
    -DisplayName          $displayName `
    -Path                 $ou `
    -AccountPassword      $password `
    -Enabled              $enabled `
    -ChangePasswordAtLogon $mustChange `
    -Description          $description `
    -ErrorAction          Stop

Write-Output "AD user created: $upn"

# ------------------------------------------------------------------
# 6. Assign group memberships.
# ------------------------------------------------------------------
foreach ($group in $groups) {
    try {
        Add-ADGroupMember -Identity $group -Members $samAccount -ErrorAction Stop
        Write-Output "Group assigned: $group"
    } catch {
        # Non-fatal — log and continue with remaining groups.
        Write-Output "WARNING: Could not assign group '$group': $_"
    }
}

# ------------------------------------------------------------------
# 7. Enable mailbox (optional — only when requested).
# ------------------------------------------------------------------
if ($mailboxEnabled) {
    Write-Output "Enabling mailbox on database: $mailboxDatabase (quota: ${mailboxQuotaGB} GB)"

    Enable-Mailbox -Identity $upn -Database $mailboxDatabase -ErrorAction Stop

    if ($mailboxQuotaGB -gt 0) {
        $quota = "$($mailboxQuotaGB)GB"
        Set-Mailbox -Identity $upn `
            -ProhibitSendReceiveQuota $quota `
            -ProhibitSendQuota        $quota `
            -IssueWarningQuota        "$([int]($mailboxQuotaGB * 0.9))GB" `
            -ErrorAction Stop
    }

    Write-Output "Mailbox enabled: $upn"
}

# ------------------------------------------------------------------
# 8. Send notification email (optional — only when requested).
# ------------------------------------------------------------------
if ($notifyEnabled -and -not [string]::IsNullOrWhiteSpace($notifyRecipient)) {
    $subject = "New account created: $displayName"
    $bodyTxt = "Account '$samAccount' ($upn) was created successfully.`n" +
               "Groups: $($groups -join ', ')`n" +
               "Mailbox: $(if ($mailboxEnabled) { 'enabled' } else { 'not provisioned' })"

    Send-MailMessage `
        -To      $notifyRecipient `
        -Subject $subject `
        -Body    $bodyTxt `
        -SmtpServer 'smtp.contoso.com' `
        -ErrorAction Stop

    Write-Output "Notification sent to: $notifyRecipient"
}

# ------------------------------------------------------------------
# 9. Summary.
# ------------------------------------------------------------------
Write-Output ''
Write-Output "Done. User '$samAccount' provisioned successfully."
Write-Output "  UPN         : $upn"
Write-Output "  OU          : $ou"
Write-Output "  Groups      : $($groups -join ', ')"
Write-Output "  Mailbox     : $(if ($mailboxEnabled) { "enabled ($mailboxDatabase)" } else { 'not provisioned' })"
Write-Output "  JSON file   : $JsonFilePath"
```

### Expected Response

```json
{
  "exitCode": 0,
  "output": "Creating AD user: a.mueller (Anna Müller)\nAD user created: anna.mueller@contoso.com\nGroup assigned: GRP-VPN\nGroup assigned: GRP-FileShare-Berlin\nGroup assigned: GRP-M365-E3\nEnabling mailbox on database: MBX-DB01 (quota: 50 GB)\nMailbox enabled: anna.mueller@contoso.com\nNotification sent to: helpdesk@contoso.com\n\nDone. User 'a.mueller' provisioned successfully.\n  UPN         : anna.mueller@contoso.com\n  OU          : OU=Users,OU=Berlin,DC=contoso,DC=com\n  Groups      : GRP-VPN, GRP-FileShare-Berlin, GRP-M365-E3\n  Mailbox     : enabled (MBX-DB01)\n  JSON file   : C:\\posh\\postjson\\20260415_143000_a1b2c3d4.json",
  "error": ""
}
```

### Key Patterns Demonstrated

| Pattern | How it appears in the example |
|---|---|
| Required field validation | `foreach ($field in $required)` before any work begins |
| Nested object access | `$data.user.upn`, `$data.account.ou`, `$data.mailbox.database` |
| JSON boolean → PowerShell `[bool]` | `[bool] $data.account.enabled` |
| JSON number → PowerShell `[int]` | `[int] $data.mailbox.quota` |
| JSON array → guaranteed PS array | `@($data.groups)` |
| Optional section with default | `if ($null -ne $data.mailbox) { ... } else { $null }` |
| Non-fatal error in loop | `try { Add-ADGroupMember ... } catch { Write-Output "WARNING: ..." }` |
| Secure string from JSON field | `$data.user.password | ConvertTo-SecureString -AsPlainText -Force` |

---

## Rules

- POST requests must **not** include query string parameters (`?key=val`). The server rejects them with HTTP 400. All input goes into the JSON body.
- The JSON body must be a valid JSON value (object, array, string, number — any valid JSON). Nested objects and arrays are fully supported.
- An empty body (`{}` or whitespace) is valid — the script receives an empty JSON object file.
- GET requests are unaffected. Query string parameters continue to work as before for GET.
