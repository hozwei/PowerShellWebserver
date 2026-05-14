# PowerShell Webserver — Administrator Handbook

A complete, self-contained manual for **PowerShell Webserver** (codename **posh**) — a
single-file Windows HTTP/HTTPS server that turns every `.ps1` script in a folder into a
callable web endpoint.

This handbook is written for a **junior administrator**. It assumes you know your way around
Windows and can run commands in PowerShell, but it does *not* assume you have seen this tool
before. Read it top to bottom and you will understand how the server works, how to use it,
how to install and configure it, how to keep it running, and how to fix it when it breaks.
You do not need to open any other file — everything is here.

> **How this handbook is ordered.** The early parts (0–3) explain the tool and show you how to
> use it day to day. The middle parts (4–8) cover installing, configuring, operating, and
> securing it. The later parts (9–11) and the appendices are an exhaustive reference — the
> full feature catalog, every configuration key, the glossary. If you only have ten minutes,
> read Part 0 and Part 1.

---

## Table of contents

**[Part 0. Front matter](#part-0-front-matter)**
- [0.1 What this server is](#01-what-this-server-is)
- [0.2 How to read this handbook](#02-how-to-read-this-handbook)
- [0.3 Quick reference card](#03-quick-reference-card)

**[Part 1. Understanding the server](#part-1-understanding-the-server)**
- [1.1 The core idea, a file is an endpoint](#11-the-core-idea-a-file-is-an-endpoint)
- [1.2 The pieces and where they live](#12-the-pieces-and-where-they-live)
- [1.3 How a request is handled](#13-how-a-request-is-handled)
- [1.4 The JSON envelope and request IDs](#14-the-json-envelope-and-request-ids)
- [1.5 The security model in one page](#15-the-security-model-in-one-page)

**[Part 2. Everyday use](#part-2-everyday-use)**
- [2.1 Orienting yourself on a server you inherited](#21-orienting-yourself-on-a-server-you-inherited)
- [2.2 Calling an endpoint with GET](#22-calling-an-endpoint-with-get)
- [2.3 Calling an endpoint with POST](#23-calling-an-endpoint-with-post)
- [2.4 Reading the response](#24-reading-the-response)
- [2.5 HTTP status codes explained](#25-http-status-codes-explained)
- [2.6 The built-in endpoints](#26-the-built-in-endpoints)
- [2.7 The one request per second rule](#27-the-one-request-per-second-rule)
- [2.8 Non-PowerShell clients and the bundled scripts](#28-non-powershell-clients-and-the-bundled-scripts)

**[Part 3. Writing endpoints](#part-3-writing-endpoints)**
- [3.1 Your first endpoint](#31-your-first-endpoint)
- [3.2 The anatomy of a good endpoint script](#32-the-anatomy-of-a-good-endpoint-script)
- [3.3 Handling GET parameters](#33-handling-get-parameters)
- [3.4 Handling POST bodies](#34-handling-post-bodies)
- [3.5 Exit codes, errors, and HTTP status](#35-exit-codes-errors-and-http-status)
- [3.6 Organizing endpoints in subdirectories](#36-organizing-endpoints-in-subdirectories)
- [3.7 Shared configuration with globalvars.ps1](#37-shared-configuration-with-globalvarsps1)
- [3.8 Using secrets in endpoints](#38-using-secrets-in-endpoints)
- [3.9 Testing and debugging an endpoint](#39-testing-and-debugging-an-endpoint)
- [3.10 Endpoint authoring checklist](#310-endpoint-authoring-checklist)

**[Part 4. Installing and setting up](#part-4-installing-and-setting-up)**
- [4.1 Prerequisites checklist](#41-prerequisites-checklist)
- [4.2 Installing with Register-ScheduledTask.ps1](#42-installing-with-register-scheduledtaskps1)
- [4.3 Setting up HTTPS](#43-setting-up-https)
- [4.4 Post-install validation](#44-post-install-validation)
- [4.5 Running the server manually](#45-running-the-server-manually)
- [4.6 Removing or reinstalling](#46-removing-or-reinstalling)

**[Part 5. Configuring](#part-5-configuring)**
- [5.1 How configuration works, the two layers](#51-how-configuration-works-the-two-layers)
- [5.2 Generating and regenerating config.psd1](#52-generating-and-regenerating-configpsd1)
- [5.3 Editing config.psd1](#53-editing-configpsd1)
- [5.4 Common configuration patterns](#54-common-configuration-patterns)
- [5.5 Environment variables](#55-environment-variables)
- [5.6 Command-line parameters](#56-command-line-parameters)

**[Part 6. Day-2 operations](#part-6-day-2-operations)**
- [6.1 Starting, stopping, and restarting](#61-starting-stopping-and-restarting)
- [6.2 Reading and understanding the logs](#62-reading-and-understanding-the-logs)
- [6.3 Monitoring health and uptime](#63-monitoring-health-and-uptime)
- [6.4 Rotating the API key](#64-rotating-the-api-key)
- [6.5 Renewing or replacing the TLS certificate](#65-renewing-or-replacing-the-tls-certificate)
- [6.6 Managing log and POST-body disk usage](#66-managing-log-and-post-body-disk-usage)
- [6.7 Reviewing the audit log](#67-reviewing-the-audit-log)
- [6.8 Running scripts on a schedule](#68-running-scripts-on-a-schedule)

**[Part 7. Troubleshooting and diagnostics](#part-7-troubleshooting-and-diagnostics)**
- [7.1 The general diagnostic method](#71-the-general-diagnostic-method)
- [7.2 The server will not start](#72-the-server-will-not-start)
- [7.3 The scheduled task will not run](#73-the-scheduled-task-will-not-run)
- [7.4 HTTPS and certificate problems](#74-https-and-certificate-problems)
- [7.5 The server is unreachable from another machine](#75-the-server-is-unreachable-from-another-machine)
- [7.6 Authentication failures](#76-authentication-failures)
- [7.7 Rate-limit and throttle rejections](#77-rate-limit-and-throttle-rejections)
- [7.8 Endpoints return 500](#78-endpoints-return-500)
- [7.9 Endpoints time out](#79-endpoints-time-out)
- [7.10 Capacity and request errors](#710-capacity-and-request-errors)
- [7.11 Configuration did not take effect](#711-configuration-did-not-take-effect)
- [7.12 Diagnostic command reference](#712-diagnostic-command-reference)

**[Part 8. Security hardening](#part-8-security-hardening)**
- [8.1 The threat model in plain terms](#81-the-threat-model-in-plain-terms)
- [8.2 Authentication hardening](#82-authentication-hardening)
- [8.3 Network-level controls](#83-network-level-controls)
- [8.4 Transport security](#84-transport-security)
- [8.5 Rate limiting and abuse protection](#85-rate-limiting-and-abuse-protection)
- [8.6 Secret management for endpoints](#86-secret-management-for-endpoints)
- [8.7 Auditing and log integrity](#87-auditing-and-log-integrity)
- [8.8 Security hardening checklist](#88-security-hardening-checklist)

**[Part 9. Full feature catalog](#part-9-full-feature-catalog)**
- [9.1 Core](#91-core)
- [9.2 Authentication and access control](#92-authentication-and-access-control)
- [9.3 Request and response handling](#93-request-and-response-handling)
- [9.4 Routing and content](#94-routing-and-content)
- [9.5 Discovery and monitoring](#95-discovery-and-monitoring)
- [9.6 Logging and operations](#96-logging-and-operations)

**[Part 10. Advanced feature deep-dives](#part-10-advanced-feature-deep-dives)**
- [10.1 Static file serving](#101-static-file-serving)
- [10.2 CORS and browser clients](#102-cors-and-browser-clients)
- [10.3 Sessions and cookies](#103-sessions-and-cookies)
- [10.4 The PHP-CGI handler](#104-the-php-cgi-handler)
- [10.5 Path placeholders](#105-path-placeholders)
- [10.6 OpenAPI spec generation](#106-openapi-spec-generation)
- [10.7 Background jobs](#107-background-jobs)
- [10.8 Execution modes](#108-execution-modes)
- [10.9 Multi-host and prefix binding](#109-multi-host-and-prefix-binding)
- [10.10 Alternate script extensions](#1010-alternate-script-extensions)

**[Part 11. Complete configuration reference](#part-11-complete-configuration-reference)**
- [11.1 Command-line parameters](#111-command-line-parameters)
- [11.2 config.psd1 keys](#112-configpsd1-keys)
- [11.3 An annotated example config.psd1](#113-an-annotated-example-configpsd1)
- [11.4 Register-ScheduledTask.ps1 hardcoded values](#114-register-scheduledtaskps1-hardcoded-values)

**Appendices**
- [Appendix A. Glossary](#appendix-a-glossary)
- [Appendix B. HTTP status code reference](#appendix-b-http-status-code-reference)
- [Appendix C. Environment variable reference](#appendix-c-environment-variable-reference)
- [Appendix D. File and directory map](#appendix-d-file-and-directory-map)
- [Appendix E. Bundled client scripts](#appendix-e-bundled-client-scripts)
- [Appendix F. Shipped webroot examples](#appendix-f-shipped-webroot-examples)
- [Appendix G. Version history digest](#appendix-g-version-history-digest)
- [Appendix H. Quick command reference](#appendix-h-quick-command-reference)

> **Callout legend.** Throughout this handbook:
> **Note** adds useful context · **Tip** is a shortcut or good habit · **Warning** is something
> that can break or surprise you · **Security** is something that affects who can do what.

---

# Part 0. Front matter

## 0.1 What this server is

PowerShell Webserver is a single PowerShell script — `Start-WebServer.ps1` — that runs as a
long-lived Windows service and listens for HTTP (and optionally HTTPS) requests. Its job is
simple to state:

> **Every `.ps1` file you place in the `webroot\` folder becomes a web endpoint. When someone
> requests that URL, the server runs the script and returns its output as JSON.**

That is the whole idea. There is no framework to learn, no routing table to maintain, no
build step, and no restart needed when you add a script. You drop `webroot\hello.ps1` into
place and `http://your-server/hello.ps1` works immediately.

**Why this exists.** Administrators accumulate piles of useful PowerShell scripts — "restart
this service", "report disk space", "create an AD user". On their own, those scripts can only
be run by someone logged into the box. PowerShell Webserver gives every one of them a stable
HTTP interface so that other tools — monitoring systems, CI pipelines, ticketing automations,
a colleague's browser — can trigger them safely, with an API key, over the network.

**What it is good at:**

- Exposing local automation scripts as authenticated HTTP endpoints.
- Low-to-moderate request rates — it is built for *automation traffic*, not for serving a
  busy public website.
- Running on a single Windows machine with no dependencies beyond PowerShell 7 and the .NET
  libraries that ship with Windows.

**What it is not:**

- It is **not** a public-internet web server. It runs as a privileged account so that the
  scripts it runs can do real administrative work; you keep it on a trusted network behind
  authentication.
- It is **not** a high-throughput application server. A built-in throttle deliberately limits
  how fast requests are dispatched (see [2.7](#27-the-one-request-per-second-rule)).
- It is **not** a replacement for IIS for hosting static websites, although it *can* serve
  static files if you turn that on (see [10.1](#101-static-file-serving)).

Throughout this handbook the tool is called **posh** for short — that is the codename used
in its own configuration keys (`POSH_API_KEY`), log files, and folder name (`C:\posh`).

## 0.2 How to read this handbook

People arrive at this server in different situations. Pick the path that matches yours.

**"I inherited a server that is already running."**
Start with [Part 1](#part-1-understanding-the-server) to build a mental model, then go
straight to [Part 2](#part-2-everyday-use) — it is written so you can use a live server
without installing anything. [2.1](#21-orienting-yourself-on-a-server-you-inherited) tells
you the three things to find out from whoever handed it over. When you need to change a
script, read [Part 3](#part-3-writing-endpoints). When something breaks, jump to
[Part 7](#part-7-troubleshooting-and-diagnostics).

**"I need to install it fresh."**
Read [Part 1](#part-1-understanding-the-server) for the mental model, then jump to
[Part 4](#part-4-installing-and-setting-up). After install, come back and read
[Part 5](#part-5-configuring) and [Part 6](#part-6-day-2-operations).

**"I just need to look something up."**
[Part 9](#part-9-full-feature-catalog) is the feature catalog, [Part 11](#part-11-complete-configuration-reference)
is every configuration key, and the [appendices](#appendix-a-glossary) hold the glossary,
status codes, environment variables, and a one-page command list.

Technical terms are **bold** the first time they appear and all are defined in
[Appendix A, the glossary](#appendix-a-glossary).

## 0.3 Quick reference card

Everything you need most often, on one screen. Each item is explained in full later — the
section number is in brackets.

**Call an endpoint** (`[2.2]`):

```powershell
# GET — parameters go in the query string
Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Max' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }

# POST — a JSON body
Invoke-RestMethod -Uri 'http://localhost/post-json.ps1' -Method Post `
    -ContentType 'application/json' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } `
    -Body (@{ firstName = 'Anna' } | ConvertTo-Json)
```

**The response envelope** for a `.ps1` endpoint (`[1.4]`):

```json
{ "exitCode": 0, "output": "Hello, Max!", "error": "" }
```

`exitCode` 0 means the script succeeded (HTTP 200). Non-zero means it failed (HTTP 500).

**Status codes you will actually see** (`[2.5]`, full table in [Appendix B](#appendix-b-http-status-code-reference)):

| Code | Meaning in one line |
|---|---|
| 200 | Script ran and exited 0 |
| 401 | Missing or wrong `X-Api-Key` |
| 404 | No such script in `webroot\` |
| 429 | You are calling too fast, or hit the rate limit |
| 500 | The script itself failed (exited non-zero or threw) |
| 503 | Server is at its concurrency limit, try again |
| 504 | The script ran too long and was killed |

**Operate the server** (`[6.1]`):

```powershell
# Restart after any configuration change
Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
Start-ScheduledTask -TaskName 'PowerShell-Webserver'

# Is it alive? (no API key needed)
Invoke-RestMethod -Uri 'http://localhost/health'
```

**Where things live** (full map in [Appendix D](#appendix-d-file-and-directory-map)):

| Thing | Location |
|---|---|
| The server script | `C:\posh\Start-WebServer.ps1` |
| Your endpoints | `C:\posh\webroot\` |
| Runtime configuration | `C:\posh\config.psd1` |
| Logs | `C:\posh\logs\` |
| The API key | the `POSH_API_KEY` machine environment variable (not a file) |

---

# Part 1. Understanding the server

This part builds the mental model. Once these five sections click, the rest of the handbook
is mostly detail.

## 1.1 The core idea, a file is an endpoint

A **webroot** is a folder — by default `C:\posh\webroot\` — that the server watches. Every
`.ps1` script inside it is automatically reachable over HTTP. The URL path *is* the file path:

```
   webroot\hello.ps1                 ->   http://your-server/hello.ps1
   webroot\subdir\system-info.ps1    ->   http://your-server/subdir/system-info.ps1
```

There is no registration step. You do not edit a config file to "add a route". You do not
restart the server. You copy a `.ps1` file into `webroot\`, and the next request to that URL
runs it. Delete the file and the URL returns 404. This is called **hot reload**, and it is
the single most important thing to understand about posh.

Here is the whole flow for one request:

```
   Client                                              Client
   GET /hello.ps1?Name=Max          { "exitCode": 0,
   X-Api-Key: <key>                   "output": "Hello, Max!",
        |                              "error": "" }
        |  HTTP request                     ^
        v                                   |  HTTP response (JSON)
   +-----------------------------+           |
   |  Start-WebServer.ps1        |           |
   |  the listening server       | ----------+
   +-----------------------------+
        |                      ^
        |  runs the script     |  captures its output
        v                      |
   webroot\hello.ps1  --------->
   (an ordinary PowerShell script)
```

The server's job is to be the reliable middle layer: accept the request, check the API key,
find the matching script, run it safely, capture whatever it printed, and hand that back to
the caller as a tidy JSON object.

**The one rule:** *webroot is your routing table.* If you want a new endpoint, add a file. If
you want to organise endpoints, use subfolders — they become URL path segments. If you want
an endpoint gone, delete the file. Nothing else routes requests.

> **Note.** A handful of URLs are *built in* and do not come from `webroot\` — `/health`,
> `/metrics`, `/`, and a couple of others. They are covered in
> [2.6](#26-the-built-in-endpoints). Everything else is a file.

## 1.2 The pieces and where they live

A posh installation is a folder — `C:\posh\` by default — containing a small number of
scripts and several working directories. You will touch only three of the scripts; the rest
are machinery or examples.

```
C:\posh\
├── Start-WebServer.ps1        The server itself. You rarely edit this.
├── Register-ScheduledTask.ps1 The installer. Run once to set everything up.
├── Edit-PoshSettings.ps1      A browser-based configuration editor.
├── globalvars.ps1             Shared values your endpoint scripts read.
├── config.psd1                The runtime configuration. Generated per install.
│
├── webroot\                   Your endpoints. Every .ps1 here is a URL.
│   ├── hello.ps1
│   ├── errors.ps1
│   ├── post-json.ps1
│   ├── ... (more example scripts)
│   ├── subdir\
│   │   └── system-info.ps1
│   └── users\
│       ├── [id].ps1
│       └── admin.ps1
│
├── logs\                      All log files.
│   ├── startup.log            What happened the last time the server booted.
│   ├── 2026-05-14.log         One request log per day.
│   ├── audit.log              Security events (optional, off by default).
│   ├── slow.log               Slow requests (optional, off by default).
│   └── jobs.log               Background-job output (only if you use jobs).
│
├── postjson\                  POST request bodies, saved as files (see 1.4).
├── encrypted_pw\              Encrypted credentials your scripts can decrypt.
│
├── tools\                     Setup helpers.
│   ├── Initialize-PoshConfig.ps1   Generates config.psd1.
│   ├── New-PoshAesKey.ps1          Generates the encryption key.
│   ├── Set-PoshSecret.ps1          Stores an encrypted password.
│   └── editor\                     Runtime files for Edit-PoshSettings.ps1.
│
├── examples\clients\          Ready-to-run client scripts that call each endpoint.
└── docs\                      The original per-topic documentation.
```

**The three scripts you will actually touch:**

| Script | When you use it |
|---|---|
| `Register-ScheduledTask.ps1` | Once, at install time. It is interactive and sets up the certificate, the firewall, the API key, and the auto-start task. See [Part 4](#part-4-installing-and-setting-up). |
| `Edit-PoshSettings.ps1` | Whenever you want to change configuration through a form instead of editing a file by hand. See [5.3](#53-editing-configpsd1). |
| `Start-WebServer.ps1` | Almost never directly — the scheduled task runs it for you. You *can* run it by hand for development ([4.5](#45-running-the-server-manually)). |

**Source repository vs deployment folder.** The files above are also what you find in the
project's Git repository. The difference is that `config.psd1`, the contents of `logs\`,
`postjson\`, and `encrypted_pw\`, and a personalised `globalvars.ps1` are *not* committed to
Git — they are local to each installation. The deployment folder `C:\posh\` is a *copy* of
the repository plus those local, machine-specific files.

> **Note.** `C:\posh\` is just the default. You can install elsewhere — the server takes a
> `-BaseDir` parameter and every working directory is derived from it. This handbook uses
> `C:\posh\` throughout; substitute your path if you chose a different one.

## 1.3 How a request is handled

When a request arrives, it passes through a fixed sequence of checks — think of them as
gates. A request must clear every gate before the server will run a script. Each gate has a
specific failure response, and knowing the sequence is the key to troubleshooting: the status
code you get back tells you exactly which gate stopped you.

```
   HTTP request arrives
        |
        v
   [ Gate 1 ] IP filter            -- blocked IP / not on allowlist --> 403
        |
        v
   [ Gate 2 ] Global throttle      -- requests arriving too fast ------> 429
        |
        v
   [ Gate 3 ] Concurrency limit    -- all worker slots busy -----------> 503
        |
        v
   --- the request is now handed to a worker ---
        |
        v
   [ Gate 4 ] HTTP method          -- not GET / POST / OPTIONS --------> 405
        |
        v
   [ Gate 5 ] Rate limit           -- too many requests this window ---> 429
        |
        v
   [ Gate 6 ] Authentication       -- missing / wrong API key ---------> 401
        |
        v
   [ Gate 7 ] Find the target      -- no matching file in webroot -----> 404
        |
        v
   Run the script in a pwsh.exe subprocess
        |
        v   (script runs longer than the timeout) -----------------> 504
        |
        v
   Wrap stdout / stderr / exit code in the JSON envelope -----------> 200 or 500
        |
        v
   Write a log line, send the response
```

A few things in that sequence deserve a closer look.

**Gates run in order, and the order matters.** Authentication (gate 6) happens *after* rate
limiting (gate 5). That means a flood of unauthenticated requests is still subject to the
rate limiter. Conversely, the IP filter (gate 1) runs before everything, so a blocked IP
never even reaches the API-key check.

**The subprocess model.** When the server runs your script, it does *not* run it inside
itself. It launches a brand-new `pwsh.exe` process, passes your parameters on the command
line (for GET) or as a file path (for POST), waits for it to finish, and captures its
standard output, standard error, and exit code. This is called **subprocess execution**, and
it is deliberate:

- It is the only reliable way to read a script's **exit code** (`exit 0` vs `exit 1`) — and
  the exit code is how the server decides between HTTP 200 and HTTP 500.
- It allows a hard **timeout**: if the script runs longer than `ScriptTimeoutSec` (default
  300 seconds), the server simply kills the process and returns 504.
- It gives each request a clean, isolated environment — one script cannot corrupt another's
  variables or modules.

The cost is a few hundred milliseconds of process-startup time per request. For automation
traffic that is a fine trade, which is why subprocess execution is the default. (An
in-process mode exists for the rare case where you need lower latency — see
[10.8](#108-execution-modes) — but it gives up the isolation and the reliable exit codes.)

**Workers and the RunspacePool.** The server can handle several requests at once. It keeps a
pool of PowerShell **runspaces** (lightweight worker threads) — the
**RunspacePool** — and hands each incoming request to a free one. The number of
simultaneous requests is capped by `MaxConcurrent` (default 10); request number 11, while 10
are still in flight, gets an immediate 503 rather than being queued forever.

**Logging.** After the response is sent, the server writes one line to the day's log file in
`logs\`. That line records the time, the client IP, the request, the status, the exit code,
the **request ID**, the caller's identity, and how long it took. You will spend real time in
these logs — [6.2](#62-reading-and-understanding-the-logs) explains every column.

## 1.4 The JSON envelope and request IDs

When a `.ps1` endpoint finishes, the server does not just return whatever the script printed.
It wraps the result in a fixed three-field JSON object called the **envelope**:

```json
{
  "exitCode": 0,
  "output": "Hello, Max!",
  "error": ""
}
```

| Field | What it contains |
|---|---|
| `exitCode` | The script's exit code. `0` means success. Anything else means failure. |
| `output` | Everything the script wrote to **standard output** (`Write-Output`). |
| `error` | Everything the script wrote to **standard error** (`Write-Error`), plus the text of any unhandled exception. |

The envelope is the contract between the server and every caller. A client never has to guess
how to interpret a response: check the HTTP status, then look at `exitCode`, then read
`output` or `error`.

**How the exit code becomes an HTTP status:**

| The script did this | `exitCode` | HTTP status |
|---|---|---|
| Finished normally, `exit 0` (or no explicit `exit`) | `0` | 200 |
| Finished with `exit 1` (or any non-zero) | that number | 500 |
| Threw an unhandled exception (`throw`) | non-zero | 500 |
| Ran past `ScriptTimeoutSec` and was killed | `-1` | 504 |

> **Note.** `Write-Error` on its own does *not* make a request fail. It populates the `error`
> field, but the HTTP status is still 200 unless the script also exits non-zero. This lets a
> script return a successful result *and* a non-fatal warning at the same time. The shipped
> `errors.ps1` example demonstrates exactly this with its `?Mode=warn` path.

**Alternate extensions skip the envelope.** Three other extensions are recognised —
`.psxml`, `.posh`, and `.psapi` — and they do *not* get the JSON envelope. Their script's
output is sent back verbatim with an XML or HTML content type. This is for endpoints that
need to return raw markup. It is covered in [10.10](#1010-alternate-script-extensions); for
now just know that `.ps1` means "JSON envelope" and the others mean "raw passthrough".

**Request IDs tie everything together.** Every response carries a header called
`X-Request-Id` — an 8-character hex string like `a1b2c3d4`. That same ID appears in three
places:

```
   X-Request-Id: a1b2c3d4
        |
        +--> the response header the client received
        +--> the matching line in logs\2026-05-14.log
        +--> the POST body file postjson\20260514_142233_a1b2c3d4.json (POST only)
```

When a caller reports "my request failed at 14:22", you ask for the request ID, grep the log
for it, and you have the exact log line — identity, timing, status — plus, for a POST, the
exact body that was sent. This is your single most powerful tracing tool.

## 1.5 The security model in one page

Security is covered in depth in [Part 8](#part-8-security-hardening). This is the one-page
primer so the rest of the handbook makes sense.

**Authentication: every endpoint needs an API key.** By default, every request must carry an
`X-Api-Key` header whose value matches the server's configured key. A request without it, or
with the wrong value, gets **401 Unauthorized** and the script never runs.

```powershell
Invoke-RestMethod -Uri 'http://localhost/hello.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }   # <-- required
```

**The key lives in an environment variable, not a file.** The API key is read from the
`POSH_API_KEY` **machine-scope environment variable**. It is deliberately *not* stored in
`config.psd1` or any file in the repository, so it cannot be committed to Git by accident.
The installer sets it; you can also set it by hand (see [5.5](#55-environment-variables)).

**The server refuses to start without a key.** If `POSH_API_KEY` is not set, `Start-WebServer.ps1`
writes an error to `startup.log` and exits. There is no "unprotected mode" — running the
server with no authentication is simply not allowed.

**A few paths are exempt.** The monitoring and discovery endpoints — `/health`, `/metrics`,
`/metrics-prom`, and `/openapi.json` — skip authentication so that monitoring tools can reach
them without holding the key. Their identity is logged as `anonymous`. You can change this
exempt list in configuration.

**The defense layers.** Authentication is one of several independent layers. From the
outside in:

| Layer | What it does | Default |
|---|---|---|
| IP filter | Allowlist / blocklist of client IPs | off (all IPs allowed) |
| Global throttle | Minimum interval between dispatched requests | 1 second |
| Concurrency cap | Maximum simultaneous requests | 10 |
| Rate limit | Maximum requests per IP per time window | 100 per 10 minutes |
| Authentication | API key (or Basic auth) | API key, required |
| Path validation | Blocks `..\` path-traversal and symlink escapes | always on |
| Body-size cap | Maximum POST body size | 20 MB |

Most layers are tunable; some, like path validation, are always on and cannot be disabled.
The point to absorb now is that posh is *designed* to be reachable over a network but expects
to sit on a trusted one — it authenticates and rate-limits, but it is not hardened for the
open internet, and it runs as a privileged account by necessity.

---

# Part 2. Everyday use

This part is about *using* a running server: calling its endpoints, reading what comes back,
and understanding what the server is telling you. It is written so you can follow along
against a server that is already installed — you do not need [Part 4](#part-4-installing-and-setting-up)
first.

All examples use `Invoke-RestMethod`, the PowerShell command for calling HTTP APIs. The same
calls work from `curl`, a browser, or any HTTP client — [2.8](#28-non-powershell-clients-and-the-bundled-scripts)
shows the `curl` equivalents.

## 2.1 Orienting yourself on a server you inherited

If someone handed you a running posh server, find out three things before you do anything
else.

**1. The base URL — host and port(s).** Is it `http://servername/` or `https://servername/`?
What ports? The defaults are HTTP on 80 and, if HTTPS is enabled, 443 — but a server can run
on any port, or HTTP-only, or HTTPS-only.

**2. Whether HTTPS is on, and what kind of certificate.** If HTTPS is enabled with a
self-signed certificate (common for internal servers), your client calls will need
`-SkipCertificateCheck` or the certificate must be trusted by your machine.

**3. The API key, and where it is stored.** Almost every call needs the `X-Api-Key` header.
The key is the `POSH_API_KEY` machine environment variable *on the server*. To read it, on
the server:

```powershell
[Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')
```

> **Security.** Treat the API key like a password. Do not paste it into chat, tickets, or
> scripts committed to Git. When you need it in a client script, read it from an environment
> variable on the client too — see [2.8](#28-non-powershell-clients-and-the-bundled-scripts).

**Confirm the server is alive — no key needed.** The `/health` endpoint is authentication-exempt,
so it is the fastest "is it up?" check:

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

```json
{ "status": "ok", "uptime": "3h 12m 45s", "requestsTotal": 1840 }
```

If that responds, the server process is running and listening. If it times out or refuses
the connection, the server is down or unreachable — go to
[7.5](#75-the-server-is-unreachable-from-another-machine).

> **Try it now.** Run the `/health` call against your server. Note the `uptime` — if it is
> very small, the server restarted recently, which is worth knowing.

## 2.2 Calling an endpoint with GET

A **GET** request runs a script and passes parameters through the URL **query string** — the
`?name=value&name=value` part of the URL. Use GET for endpoints that *read* or *report*
something.

The simplest possible call, against the shipped `hello.ps1`:

```powershell
Invoke-RestMethod -Uri 'http://localhost/hello.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

```json
{ "exitCode": 0, "output": "Hello, World! (from posh.example.local)", "error": "" }
```

**Passing parameters.** `hello.ps1` accepts `Name`, `Count`, and `Loud`. They go in the query
string:

```powershell
Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Anna&Count=3&Loud=true' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

```json
{
  "exitCode": 0,
  "output": "HELLO, ANNA! (FROM POSH.EXAMPLE.LOCAL)\nHELLO, ANNA! (FROM POSH.EXAMPLE.LOCAL)\nHELLO, ANNA! (FROM POSH.EXAMPLE.LOCAL)",
  "error": ""
}
```

Each query-string name becomes a named parameter of the script. `?Name=Anna` arrives as the
script's `-Name Anna`. Parameter names are matched to the script's `param()` block.

**Calling a script in a subdirectory.** Subfolders in `webroot\` are just URL path segments.
The shipped `webroot\subdir\system-info.ps1` is reached at `/subdir/system-info.ps1`:

```powershell
Invoke-RestMethod -Uri 'http://localhost/subdir/system-info.ps1?Detail=true' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

**Parameters always arrive as strings.** This is the single most common surprise. HTTP
carries everything as text, so `?Count=3` arrives in the script as the *string* `'3'`, not
the number `3`. Well-written endpoints declare their parameters as `[string]` and cast them
internally — `hello.ps1` does `[int]$Count`. As a caller you do not have to do anything
special; just be aware that if an endpoint misbehaves on numeric input, this is usually why.
See [3.3](#33-handling-get-parameters) for the authoring side.

> **Try it now.** Call `hello.ps1` with `?Count=3`. Then try `?Count=abc` — `hello.ps1`
> handles it gracefully because it clamps the value, but a less careful script might 500.

## 2.3 Calling an endpoint with POST

A **POST** request sends a **body** — typically a JSON document. Use POST for endpoints that
*create* or *change* something, or that need structured input too complex for a query string
(nested objects, arrays, long text).

```powershell
$body = @{
    firstName  = 'Anna'
    lastName   = 'Mueller'
    department = @{ name = 'IT'; costCenter = '4200' }
    roles      = @('admin', 'reader')
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri 'http://localhost/post-json.ps1' -Method Post `
    -ContentType 'application/json' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } `
    -Body $body
```

The shipped `post-json.ps1` echoes the body back, structured:

```json
{
  "receivedAt": "2026-05-14T14:22:33.1234567+02:00",
  "server": "posh.example.local",
  "bodyPath": "C:\\posh\\postjson\\20260514_142233_a1b2c3d4.json",
  "bodyBytes": 142,
  "parsed": {
    "fullName": "Anna Mueller",
    "department": { "name": "IT", "costCenter": "4200" },
    "roleCount": 2,
    "roles": ["admin", "reader"]
  }
}
```

**Why posh uses files for POST bodies.** This is a design decision worth understanding. The
server does *not* pass the POST body as a command-line argument. Instead it:

1. Writes the body verbatim to a file: `postjson\YYYYMMDD_HHmmss_<requestId>.json`.
2. Passes the *absolute path* of that file to your script as the `-JsonFilePath` parameter.
3. Your script reads and parses the file itself.

```
   POST body  --->  postjson\20260514_142233_a1b2c3d4.json  --->  your script
                                                                  reads -JsonFilePath
```

Command-line arguments have length limits and choke on special characters, nested structures,
and large payloads. A file has none of those problems — a 5 MB JSON document with deeply
nested objects passes through untouched. The trade is that POST endpoint scripts must do a
little work to read the file; [3.4](#34-handling-post-bodies) shows the pattern.

> **Note.** The body file is kept on disk after the request, which is useful for tracing
> (the request ID is in the filename — see [1.4](#14-the-json-envelope-and-request-ids)).
> Old body files are cleaned up automatically after `PostJsonRetentionDays` days (default 30).

**POST rules:**

- **No query string on a POST.** Putting `?name=value` on a POST URL is rejected with 400.
  Parameters for a POST go in the body, not the URL.
- **The `Content-Type` must be accepted.** By default the server accepts
  `application/json` and `application/x-www-form-urlencoded`. Anything else gets 415.
- **The body must be valid JSON** (for a JSON content type). Malformed JSON gets 400.

**Form-encoded bodies work too.** If you POST with
`Content-Type: application/x-www-form-urlencoded`, the server parses the form fields,
collapses repeated `key[]=...` fields into arrays, re-serialises the result as JSON, and
hands it to your script through the *same* `-JsonFilePath` mechanism. Your script cannot tell
the difference. The shipped `post-form.ps1` demonstrates this; the authoring side is covered
in [3.4](#34-handling-post-bodies).

## 2.4 Reading the response

A response has two layers: the **HTTP status code** (the transport-level result) and, for
`.ps1` endpoints, the **JSON envelope** (the script-level result). Read them in that order.

**Step 1 — the HTTP status.** `Invoke-RestMethod` throws a terminating error on a 4xx or 5xx
status by default, which can hide the envelope. To see the body even on an error status, add
`-SkipHttpErrorCheck`:

```powershell
$response = Invoke-RestMethod -Uri 'http://localhost/errors.ps1?Mode=fail' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } `
    -SkipHttpErrorCheck
$response
```

**Step 2 — the envelope.** Once you have the body, check `exitCode`, then read `output` or
`error`:

```
   A successful response (HTTP 200)        A failed response (HTTP 500)
   {                                       {
     "exitCode": 0,                          "exitCode": 1,
     "output": "OK: demo message ...",       "output": "Partial output before failure: ...",
     "error": ""                             "error": "Operation failed: demo message"
   }                                       }
```

Note that even a *failed* response can have content in `output` — a script may print partial
results before it hits the error. Both fields are always present; one or both may be empty.

**HTTPS and self-signed certificates.** If the server uses HTTPS with a self-signed
certificate, an ordinary call fails with a certificate-validation error. Add
`-SkipCertificateCheck` to bypass the check (acceptable for internal servers; for production,
trust the certificate properly):

```powershell
Invoke-RestMethod -Uri 'https://localhost/hello.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } `
    -SkipCertificateCheck
```

## 2.5 HTTP status codes explained

The status code tells you *which gate* (from [1.3](#13-how-a-request-is-handled)) handled
your request, and therefore what to do about it. Here is every code posh returns.

| Code | Name | When posh returns it | What you do |
|---|---|---|---|
| **200** | OK | The script ran and exited 0 | Nothing — success. Read `output`. |
| **304** | Not Modified | Static file unchanged since your cached copy | Nothing — use your cache. (Static serving only.) |
| **400** | Bad Request | Path is not a known script type, JSON body is malformed, or a query string was sent on a POST | Fix the request — check the URL, the body, the method. |
| **401** | Unauthorized | `X-Api-Key` header missing or wrong | Add the correct API key. See [7.6](#76-authentication-failures). |
| **403** | Forbidden | Path-traversal attempt, your IP is blocked, or your IP is not on the allowlist | Check the URL for `..\`; check the IP filter. See [7.5](#75-the-server-is-unreachable-from-another-machine). |
| **404** | Not Found | No matching file in `webroot\` | Check the spelling and the subfolder. The file may not exist. |
| **405** | Method Not Allowed | HTTP method other than GET, POST, or OPTIONS | Use GET or POST. |
| **413** | Payload Too Large | POST body bigger than `MaxRequestBodyBytes` (default 20 MB) | Send less, or raise the limit ([5.4](#54-common-configuration-patterns)). |
| **415** | Unsupported Media Type | POST `Content-Type` not in the accepted list | Use `application/json` or `application/x-www-form-urlencoded`. |
| **429** | Too Many Requests | You are calling faster than the global throttle allows, *or* you hit the per-IP rate limit | Slow down. Honour the `Retry-After` header. See [2.7](#27-the-one-request-per-second-rule) and [7.7](#77-rate-limit-and-throttle-rejections). |
| **500** | Internal Server Error | The script itself failed — exited non-zero or threw an exception | Read the `error` field. The problem is in the script. See [7.8](#78-endpoints-return-500). |
| **503** | Service Unavailable | All `MaxConcurrent` worker slots are busy | Retry shortly. If constant, raise `MaxConcurrent` ([5.4](#54-common-configuration-patterns)). |
| **504** | Gateway Timeout | The script ran longer than `ScriptTimeoutSec` and was killed | The script is too slow or hung. See [7.9](#79-endpoints-time-out). |

**The ones you will see most:**

- **401** — almost always a missing or stale API key.
- **404** — almost always a typo in the path or a script that was moved/deleted.
- **429** — almost always calling in a tight loop with no delay (see the next section).
- **500** — the script ran but failed. This is a bug in the *endpoint*, not the server.

> **Try it now.** Call `errors.ps1` with each mode and watch the status change:
> `?Mode=ok` → 200, `?Mode=fail` → 500, `?Mode=throw` → 500, `?Mode=timeout` → 504 (after a
> wait). Use `-SkipHttpErrorCheck` so you can see the envelope each time.

## 2.6 The built-in endpoints

A handful of URLs are served by the server itself, not by files in `webroot\`. They are for
discovery and monitoring.

### `GET /` — the endpoint index

Lists every script the server can route to. By default (`IndexShowMetadata = $true`) each
entry is an enriched object with the script's synopsis and parameters, parsed from its
comment-based help:

```powershell
Invoke-RestMethod -Uri 'http://localhost/' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

```json
[
  {
    "path": "/hello.ps1",
    "methods": ["GET"],
    "synopsis": "Minimal GET endpoint — greets the caller by name.",
    "parameters": [ { "name": "Name", "type": "string" }, ... ]
  },
  ...
]
```

This is the quickest way to discover what a server can do. It requires the API key.

### `GET /health` — liveness probe

Uptime and total request count. **No API key required** — this is the endpoint your
monitoring system polls.

```json
{ "status": "ok", "uptime": "3h 12m 45s", "requestsTotal": 1840 }
```

### `GET /metrics` — counters (JSON)

Operational counters for humans: total requests, rate-limited requests, authentication
failures, script timeouts, in-flight and peak concurrency, log drops, and more. **No API key
required** — it is on the auth-exempt list so monitoring tools can read it freely.

### `GET /metrics-prom` — counters (Prometheus format)

The same counters in Prometheus text exposition format, for a Prometheus scraper to ingest.
**No API key required** (configurable). Covered in [6.3](#63-monitoring-health-and-uptime).

### `GET /openapi.json` — the API specification

An OpenAPI 3.1 specification, auto-generated from every webroot script's comment-based help
and `param()` block. **No API key required.** Import it into Swagger UI, Postman, or an API
gateway to get a browsable, typed catalog of every endpoint. Covered in
[10.6](#106-openapi-spec-generation).

> **Note.** All four auth-exempt paths (`/health`, `/metrics`, `/metrics-prom`,
> `/openapi.json`) are also exempt from rate limiting and the global throttle, so a monitoring
> system polling them every few seconds never trips a limit. The exemption lists are
> configurable; see [Part 11](#part-11-complete-configuration-reference).

## 2.7 The one request per second rule

posh is built for automation traffic, and it enforces a deliberate speed limit. There are two
separate mechanisms, and confusing them is a common source of frustration.

**The global throttle (`MinRequestIntervalSec`, default 1 second).** Before the server even
hands a request to a worker, it enforces a minimum gap between *dispatched* requests, server-wide.
With the default of 1 second, if you fire requests back-to-back, the second one is rejected
with **429** because it arrived less than a second after the first. This is a blunt,
whole-server floor.

**The per-IP rate limit (`RateLimitRequests` per `RateLimitWindowSec`, default 100 per 10
minutes).** Separately, each client IP gets a budget of requests per time window. Exhaust it
and you get **429** — and, after the *first* 429, a flat penalty period (`RateLimitPenaltySec`,
default 5 minutes) during which every request is rejected. This catches sustained abuse.

Both return 429. Both set a `Retry-After` header telling you how many seconds to wait.

**The practical rule for callers: leave at least a second between calls.** If you are looping
over a list and calling an endpoint for each item, put a `Start-Sleep` in the loop:

```powershell
foreach ($server in $serverList) {
    Invoke-RestMethod -Uri "http://localhost/subdir/system-info.ps1?ComputerName=$server" `
        -Headers @{ 'X-Api-Key' = 'your-api-key' }
    Start-Sleep -Seconds 1   # respect the global throttle
}
```

**If you do get a 429, honour `Retry-After`:**

```powershell
try {
    Invoke-RestMethod -Uri 'http://localhost/hello.ps1' `
        -Headers @{ 'X-Api-Key' = 'your-api-key' }
} catch {
    if ($_.Exception.Response.StatusCode -eq 429) {
        $wait = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
        Write-Warning "Rate limited. Waiting $wait seconds."
        Start-Sleep -Seconds $wait
    }
}
```

**The exempt paths bypass both.** `/health` and the other monitoring endpoints are exempt, so
a monitoring poll never trips either limit no matter how often it runs.

> **Tip.** If your workload genuinely needs higher throughput, both limits are tunable — see
> [5.4](#54-common-configuration-patterns). But first ask whether the work could be a single
> POST with a batch in the body, or a [background job](#68-running-scripts-on-a-schedule),
> rather than hundreds of fast calls.

## 2.8 Non-PowerShell clients and the bundled scripts

The server speaks plain HTTP. Anything that can make an HTTP request can call it.

**Using `curl`:**

```bash
# GET
curl -H "X-Api-Key: your-api-key" "http://localhost/hello.ps1?Name=Max"

# POST
curl -X POST "http://localhost/post-json.ps1" ^
     -H "X-Api-Key: your-api-key" ^
     -H "Content-Type: application/json" ^
     --data "{\"firstName\":\"Anna\"}"
```

(On Windows `cmd` the line continuation is `^`; in PowerShell it is a backtick `` ` ``; the
header and data flags are the same everywhere.)

**The bundled client scripts.** The folder `examples\clients\` ships a ready-to-run
PowerShell client for every shipped endpoint plus the built-in routes — 13 scripts in all.
They are the fastest way to see correct, working calls.

They read the server URL and key from environment variables, so set those once:

```powershell
$env:POSH_BASE_URL = 'http://localhost'
$env:POSH_API_KEY  = 'your-api-key'
```

Then run any client from the `examples\clients\` directory — for example `Invoke-Hello.ps1`,
`Send-PostJson.ps1`, `Get-SystemInfo.ps1`. Every client dot-sources a shared `_Common.ps1`
that wraps `Invoke-RestMethod`, adds the `X-Api-Key` header, and pretty-prints the envelope.
Copy a helper out of `_Common.ps1` as the starting point for your own production tooling.

**The smoke test.** `Test-AllEndpoints.ps1` calls every endpoint in sequence and reports
pass/fail — run it after an install or an upgrade to confirm the whole server works:

```powershell
$env:POSH_API_KEY = 'your-api-key'
.\Test-AllEndpoints.ps1
```

A full index of the bundled clients is in [Appendix E](#appendix-e-bundled-client-scripts).

---

# Part 3. Writing endpoints

Writing endpoints is the everyday authoring task. An endpoint is just a PowerShell script
that follows a few conventions. This part walks you from a four-line script to a
production-ready one, using the scripts that ship in `webroot\` as worked examples.

## 3.1 Your first endpoint

Create a file `webroot\my-first.ps1` with this content:

```powershell
#Requires -Version 7.0
param(
    [string] $Name = 'World'
)

Write-Output "Hello, $Name!"
```

That is a complete, working endpoint. Save the file and call it immediately — **no restart**:

```powershell
Invoke-RestMethod -Uri 'http://localhost/my-first.ps1?Name=Max' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

```json
{ "exitCode": 0, "output": "Hello, Max!", "error": "" }
```

**Hot reload, explained.** The server resolves the URL to a file on every request. There is
no cached route table for webroot scripts, so the moment the file exists it is callable, and
the moment you edit it the next call runs the new version. This makes developing endpoints
fast: edit, call, repeat. (One nuance: *new subdirectories* at the top level of `webroot\`
are picked up automatically, but if you rely on [path placeholders](#105-path-placeholders),
adding placeholder files deep in the tree may need a restart. Plain `.ps1` files at any depth
are always hot.)

That four-line script works, but it skips conventions that make an endpoint robust and
discoverable. The rest of Part 3 fills them in.

## 3.2 The anatomy of a good endpoint script

Here is the shipped `webroot\hello.ps1` in full. It is the canonical "simplest good
endpoint" — every line earns its place.

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Minimal GET endpoint — greets the caller by name.

.DESCRIPTION
    The simplest possible posh endpoint: declares a few typed parameters,
    writes its output to stdout, and exits with code 0 for a normal
    response. The server wraps the output in the
    `{ exitCode, output, error }` JSON envelope automatically.

    Query string parameters arrive as named arguments. Strings stay
    strings, integers must be cast inside the script (HTTP transports
    everything as text).

.PARAMETER Name
    Display name. Defaults to 'World'.

.PARAMETER Count
    How many times to repeat the greeting (1-10). Defaults to 1.

.PARAMETER Loud
    When 'true', the greeting is uppercased.

.EXAMPLE
    Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Anna' `
        -Headers @{ 'X-Api-Key' = 'your-key' }
#>
param(
    [string] $Name  = 'World',
    [string] $Count = '1',
    [string] $Loud  = 'false'
)

# Dot-source the central config (server names, paths, AES key).
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

# Query-string values arrive as strings — cast Count and convert Loud.
$repeats = [int]$Count
if ($repeats -lt 1)  { $repeats = 1 }
if ($repeats -gt 10) { $repeats = 10 }
$shout = $Loud -eq 'true' -or $Loud -eq '1'

# Server name pulled from globalvars so a deployment rename touches one file.
$greeting = "Hello, $Name! (from $PoshServerFqdn)"
if ($shout) { $greeting = $greeting.ToUpper() }

1..$repeats | ForEach-Object { Write-Output $greeting }
exit 0
```

Walking it part by part:

**`#Requires -Version 7.0`** — the first line. It declares that the script needs PowerShell
7. The server runs on PowerShell 7, so this is mostly documentation, but it makes the
requirement explicit and protects the script if anyone runs it by hand on an older shell.

**The comment-based help block** (`<# .SYNOPSIS ... #>`) — this is not decoration. The server
*parses* it. The `.SYNOPSIS` line appears in the `GET /` index. The whole block — synopsis,
description, every `.PARAMETER` — is turned into the OpenAPI specification at
`/openapi.json`. A script with good help is self-documenting to every caller; a script
without it is a mystery box. Always write the help block.

**The `param()` block** — declares the inputs. Three conventions:

- **Always give every parameter an explicit type.** Use `[string]` for almost everything,
  because query-string values arrive as strings (see [3.3](#33-handling-get-parameters)).
- **Always give a default.** A default means the endpoint still works when a caller omits the
  parameter — `GET /hello.ps1` with no query string returns "Hello, World!".
- The parameter *names* are what callers put in the query string: `?Name=Anna` binds to
  `-Name`.

**Dot-sourcing `globalvars.ps1`** — `. (Join-Path $PSScriptRoot '..\globalvars.ps1')` loads
the deployment's shared configuration into the script: server names, paths, the encryption
key. `$PSScriptRoot` is the folder the script lives in, so `..\globalvars.ps1` is one level
up. Covered fully in [3.7](#37-shared-configuration-with-globalvarsps1).

**The body** — ordinary PowerShell. Cast the strings, do the work.

**`Write-Output`** — everything sent to standard output lands in the envelope's `output`
field. Each `Write-Output` call is one line.

**`exit 0`** — explicitly signals success (HTTP 200). Covered in
[3.5](#35-exit-codes-errors-and-http-status).

## 3.3 Handling GET parameters

The rule worth tattooing on your hand: **every GET parameter arrives as a string.** The query
string `?Count=3&Loud=true` produces the *strings* `'3'` and `'true'`, never the number `3`
or the boolean `$true`. Your script must convert them.

**Declare parameters as `[string]` and cast inside.** Do *not* declare `[int] $Count` in the
`param()` block and hope — if a caller sends `?Count=abc`, PowerShell's parameter binder
throws before your script runs, and the caller gets an unhelpful 500. Declare `[string]` and
convert deliberately, where you can validate and clamp:

```powershell
param(
    [string] $Count = '1'
)

$repeats = [int]$Count           # cast to a number
if ($repeats -lt 1)  { $repeats = 1 }    # clamp to a sane range
if ($repeats -gt 10) { $repeats = 10 }
```

**Convert boolean-ish values by string comparison.** There is no automatic string-to-boolean
conversion you should rely on (`[bool]'false'` is `$true` in PowerShell — a classic trap).
Compare strings explicitly, and accept the common spellings:

```powershell
param(
    [string] $Loud = 'false'
)

$shout = $Loud -eq 'true' -or $Loud -eq '1'
```

`hello.ps1` and `system-info.ps1` both use exactly this pattern for their `Loud` / `Detail`
switches.

**Always provide defaults.** A parameter with a default is optional for the caller. Without a
default, a missing parameter is an empty string, which your script then has to detect and
handle. Defaults keep the common call short.

## 3.4 Handling POST bodies

A POST endpoint receives its input as a file, not as parameters. The server writes the
request body to disk and passes the path as `-JsonFilePath`. The contract for the script is:

1. Declare `param([string] $JsonFilePath = '')`.
2. Validate that the path was supplied and the file exists.
3. Read and parse the file.
4. Access the data defensively — callers send incomplete bodies.

Here is the shipped `webroot\post-json.ps1`, the reference pattern:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    POST endpoint demonstrating the -JsonFilePath contract.
... (help block omitted here for brevity — keep yours) ...
#>
param(
    [string] $JsonFilePath = ''
)

$ErrorActionPreference = 'Stop'

# Central config: post-json log/audit folder + admin mail address come
# from globalvars so multiple POST endpoints can stay consistent.
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
    Write-Error 'JsonFilePath missing. Call this endpoint via HTTP POST.'
    exit 1
}
if (-not (Test-Path -LiteralPath $JsonFilePath -PathType Leaf)) {
    Write-Error "JSON file not found: $JsonFilePath"
    exit 1
}

$data = Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 10

# Defensive accessors — every field is optional so the example also serves
# as a template for real endpoints that need to handle partial payloads.
$firstName = if ($data.PSObject.Properties['firstName']) { $data.firstName } else { '<missing>' }
$lastName  = if ($data.PSObject.Properties['lastName'])  { $data.lastName  } else { '<missing>' }

$deptName       = '<missing>'
$deptCostCenter = '<missing>'
if ($data.PSObject.Properties['department']) {
    $deptName       = $data.department.name
    $deptCostCenter = $data.department.costCenter
}

$roles = if ($data.PSObject.Properties['roles']) { @($data.roles) } else { @() }

$echo = [ordered]@{
    receivedAt = (Get-Date).ToString('o')
    server     = $PoshServerFqdn
    parsed = [ordered]@{
        fullName   = "$firstName $lastName".Trim()
        department = [ordered]@{ name = $deptName; costCenter = $deptCostCenter }
        roleCount  = $roles.Count
        roles      = $roles
    }
}

$echo | ConvertTo-Json -Depth 5
exit 0
```

Three things to copy from this pattern:

**`$ErrorActionPreference = 'Stop'`** — at the top of a POST script. It turns non-terminating
errors into terminating ones so a problem fails loudly (HTTP 500) instead of producing a
half-built response.

**Validate `$JsonFilePath` first.** Check it is not empty and the file exists. If a POST
endpoint is called with a GET, `$JsonFilePath` is empty — fail clearly with `exit 1` rather
than crashing later.

**Read with the right options, parse with enough depth.**
`Get-Content -LiteralPath $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10`.
The `-Depth 10` matters: `ConvertFrom-Json` defaults to a shallow depth and silently
truncates deeply nested objects. If a caller's nested data goes missing, raise the depth.

**Access defensively.** Test for a property before reading it:
`if ($data.PSObject.Properties['firstName']) { ... }`. Callers will send incomplete bodies.
A defensive accessor returns a sensible default; a naive `$data.firstName` on a missing field
returns `$null` and the bug surfaces somewhere confusing later.

**Forms arrive the same way.** A `application/x-www-form-urlencoded` body is parsed by the
server, repeated `key[]=...` fields are collapsed into arrays, and the result is handed to
your script as JSON through the *same* `-JsonFilePath`. The shipped `post-form.ps1` reads it
with `ConvertFrom-Json -Depth 10 -AsHashtable` and inspects the keys. Your script does not
need to know or care whether the original body was JSON or a form.

## 3.5 Exit codes, errors, and HTTP status

The server decides the HTTP status from how your script *ends*. The shipped
`webroot\errors.ps1` exists purely to demonstrate every path — it is the best teaching
example in the repository:

```powershell
param(
    [string] $Mode    = 'ok',
    [string] $Message = 'demo message'
)

. (Join-Path $PSScriptRoot '..\globalvars.ps1')

switch ($Mode.ToLowerInvariant()) {
    'ok' {
        Write-Output "OK: $Message  (contact: $AdminMail on issue)"
        exit 0
    }
    'warn' {
        Write-Output "Output: $Message"
        Write-Error  "Non-fatal warning: $Message"
        # Still exit 0 — the response is HTTP 200 with `error` populated.
        exit 0
    }
    'fail' {
        Write-Output "Partial output before failure: $Message"
        Write-Error  "Operation failed: $Message"
        exit 1
    }
    'throw' {
        throw "Demo exception: $Message"
    }
    'timeout' {
        Write-Output 'Sleeping past ScriptTimeoutSec — the server should kill us with HTTP 504.'
        Start-Sleep -Seconds 600
        exit 0
    }
    default {
        Write-Error "Unknown Mode '$Mode'. Valid values: ok, warn, fail, throw, timeout."
        exit 2
    }
}
```

The contract, mode by mode:

| Mode | What it does | `exitCode` | HTTP |
|---|---|---|---|
| `ok` | `Write-Output`, then `exit 0` | 0 | **200** |
| `warn` | `Write-Output` *and* `Write-Error`, then `exit 0` | 0 | **200**, with `error` populated |
| `fail` | `Write-Output`, `Write-Error`, then `exit 1` | 1 | **500** |
| `throw` | raises an unhandled exception | non-zero | **500**, exception text in `error` |
| `timeout` | sleeps past `ScriptTimeoutSec` | -1 | **504**, killed by the server |

The rules to internalise:

- **`exit 0` (or no `exit` at all) → HTTP 200.** Success.
- **`exit <non-zero>` → HTTP 500.** The number you exit with becomes `exitCode` in the
  envelope, so you can use different codes to signal different failures.
- **`Write-Output` → the `output` field.** Normal results.
- **`Write-Error` → the `error` field.** But on its own it does *not* change the HTTP status —
  see the `warn` mode, which is 200 despite writing an error. To make a request *fail*, you
  must `exit` non-zero.
- **`throw` → HTTP 500.** An unhandled exception terminates the script; the server catches the
  non-zero exit and puts the exception message in `error`.
- **Running past `ScriptTimeoutSec` → HTTP 504.** The server kills the `pwsh.exe` process. Your
  script does not get to clean up, so do not rely on `finally` blocks for anything critical
  in a long-running endpoint.

> **Tip.** Put `$ErrorActionPreference = 'Stop'` near the top of any endpoint that does real
> work. Without it, a failed cmdlet (a missing file, a denied permission) produces a
> non-terminating error: the script keeps running, often produces a broken result, and still
> `exit 0`s — a silent failure that returns HTTP 200. With `Stop`, the same failure
> terminates the script and the caller correctly sees a 500.

## 3.6 Organizing endpoints in subdirectories

Subfolders inside `webroot\` become URL path segments. There is no routing configuration —
the folder structure *is* the URL structure.

```
   webroot\subdir\system-info.ps1   ->   GET /subdir/system-info.ps1
   webroot\ad\Get-LockedAccounts.ps1 ->  GET /ad/Get-LockedAccounts.ps1
   webroot\reports\disk\summary.ps1 ->   GET /reports/disk/summary.ps1
```

Use folders to group endpoints by domain — an `ad\` folder for Active Directory scripts, a
`network\` folder for network checks, and so on. It keeps a large `webroot\` navigable and
keeps URLs self-describing.

**One thing changes with depth: the dot-source path to `globalvars.ps1`.** `globalvars.ps1`
lives in the install root, one level *above* `webroot\`. A script directly in `webroot\` uses
`..\globalvars.ps1`. A script one folder deeper uses `..\..\globalvars.ps1`. The shipped
`webroot\subdir\system-info.ps1` is two levels deep relative to the install root, so it does:

```powershell
# globalvars.ps1 is two directories up because this script lives at webroot/subdir/.
. (Join-Path $PSScriptRoot '..\..\globalvars.ps1')
```

Count the folders between your script and the install root, and use that many `..\` segments.
Get this wrong and the script fails at the dot-source line with a "file not found" error.

## 3.7 Shared configuration with globalvars.ps1

`globalvars.ps1` is the deployment's shared configuration for *endpoint scripts*. It sits in
the install root and every endpoint dot-sources it. Change a hostname, a path, or an LDAP
base DN there once and every endpoint picks it up on the next call.

Here is the shipped `globalvars.ps1`, lightly trimmed:

```powershell
# --- Section 1: Service endpoints and identifiers ---
$DomainController     = 'dc-01.example.local'
$DomainDnsSuffix      = 'example.local'
$SmtpRelay            = 'mail-relay.example.local'
$AdminMail            = 'it-admins@example.local'
$PoshServerFqdn       = 'posh.example.local'
$PoshServerUri        = "https://$PoshServerFqdn"
$LdapUsers            = 'OU=Users,DC=example,DC=local'
$LdapServers          = 'OU=Servers,DC=example,DC=local'
# ... more LDAP base DNs ...
$DefaultTargetHost    = $env:COMPUTERNAME

# --- Section 2: Filesystem paths (derived from this file's location) ---
$PoshBaseDir          = $PSScriptRoot
$PoshWebRoot          = Join-Path $PoshBaseDir 'webroot'
$PoshLogDir           = Join-Path $PoshBaseDir 'logs'
$PoshPostJsonDir      = Join-Path $PoshBaseDir 'postjson'
$PoshEncryptedDir     = Join-Path $PoshBaseDir 'encrypted_pw'

# --- Section 3: AES key for encrypted_pw\encryptedString_*.txt ---
# >>>POSH_KEY_START<<<
$key = @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
# >>>POSH_KEY_END<<<
```

**What lives in it:** identifiers (server names, mail relay, domain), LDAP base DNs,
filesystem paths derived from the install location, and the AES `$key` used to decrypt stored
secrets ([3.8](#38-using-secrets-in-endpoints)).

**Dot-sourcing it** — every endpoint starts with the dot-source line, with the right number
of `..\` for its depth ([3.6](#36-organizing-endpoints-in-subdirectories)). After that line,
all those variables are in scope: `$PoshServerFqdn`, `$AdminMail`, `$LdapUsers`, `$key`, and
the rest.

**Adding your own variables** — just add a line to Section 1. If your endpoints call a Jira
instance, add `$JiraBaseUrl = 'https://jira.example.local'` and every endpoint that
dot-sources `globalvars.ps1` can use `$JiraBaseUrl`. You can also add variables through the
browser editor — see [5.3](#53-editing-configpsd1).

**`globalvars.ps1` vs `config.psd1` — do not confuse them:**

| `globalvars.ps1` | `config.psd1` |
|---|---|
| Read by your **endpoint scripts** | Read by the **server** itself |
| Server names, LDAP DNs, the AES key | Ports, timeouts, auth mode, rate limits |
| Dot-sourced at the top of every endpoint | Loaded once at server startup |
| Edit and it applies on the next request | Edit and you must restart the server |

> **Security.** The `$key` in `globalvars.ps1` is the encryption key for every stored
> credential. A personalised `globalvars.ps1` with a real key must **never** be committed to
> Git. The shipped file has a placeholder of all zeros; [3.8](#38-using-secrets-in-endpoints)
> covers generating a real one.

## 3.8 Using secrets in endpoints

Real endpoints often need a credential — a service account to query Active Directory, an API
token, an SMTP login. posh provides a simple, explicit pattern for this. There is no magic
"get secret" function; you decrypt the secret yourself in three lines.

**The model:**

```
   tools\New-PoshAesKey.ps1   --(once per install)-->  a unique 32-byte $key in globalvars.ps1
   tools\Set-PoshSecret.ps1   --(per secret)-------->  encrypted_pw\encryptedString_<label>.txt
   your endpoint              --(decrypts with $key)-> a PSCredential it can use
```

**Step 1 — generate the key, once per installation.** The shipped `globalvars.ps1` has a
placeholder key of all zeros. Replace it with 32 cryptographically random bytes unique to
this machine:

```powershell
.\tools\New-PoshAesKey.ps1
```

This rewrites the `$key = @(...)` line in `globalvars.ps1` between the `POSH_KEY_START` /
`POSH_KEY_END` markers.

**Step 2 — store a secret.** For each credential, run:

```powershell
.\tools\Set-PoshSecret.ps1 -Label 'ad_adsread'
```

It prompts for the password and writes it, encrypted with `$key`, to
`encrypted_pw\encryptedString_ad_adsread.txt`.

**Step 3 — decrypt it in an endpoint.** Dot-source `globalvars.ps1` (which brings `$key` and
`$PoshEncryptedDir` into scope), then:

```powershell
. (Join-Path $PSScriptRoot '..\globalvars.ps1')

$cipher = (Get-Content -LiteralPath (Join-Path $PoshEncryptedDir 'encryptedString_ad_adsread.txt') -Raw).Trim()
$secStr = ConvertTo-SecureString -String $cipher -Key $key
$cred   = [PSCredential]::new('DOMAIN\svc-adsread', $secStr)

Get-ADUser -Identity $id -SearchBase $LdapUsers -Credential $cred
```

The commented block inside the shipped `webroot\users\[id].ps1` shows this exact pattern in
context. Because the secret is decrypted only with the per-install `$key`, the
`encrypted_pw\` files are useless if copied to another machine — which is the point.

## 3.9 Testing and debugging an endpoint

A short, reliable workflow turns "it 500s and I don't know why" into a two-minute fix.

**1. Run the script standalone first.** Before going through HTTP, run the script directly in
a PowerShell 7 session with the parameters it expects:

```powershell
cd C:\posh\webroot
.\hello.ps1 -Name Test -Count 2
```

Most bugs — a typo, a bad dot-source path, a missing module — show up here, with a full
PowerShell error and line number, before HTTP ever enters the picture.

**2. Lint it.** `PSScriptAnalyzer` catches a large class of mistakes statically:

```powershell
Invoke-ScriptAnalyzer -Path .\webroot\hello.ps1
```

If `PSScriptAnalyzer` is not installed: `Install-Module PSScriptAnalyzer -Scope CurrentUser`.

**3. Syntax-check without any module.** A pure parser check confirms the file at least
*parses*:

```powershell
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\webroot\hello.ps1), [ref]$null, [ref]$errors)
$errors
```

Empty output means the file is syntactically valid.

**4. Call it over HTTP and read the `error` field.** Use `-SkipHttpErrorCheck` so a 500 still
shows you the envelope:

```powershell
$r = Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Test' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } -SkipHttpErrorCheck
$r.error    # the failure reason, if any
```

**5. Trace it through the logs.** Note the `X-Request-Id` from the response headers (use
`Invoke-WebRequest` to see headers), then find that ID in the day's log file. The log line
tells you the status, the timing, and the caller identity. For a POST, the same ID is in the
body filename under `postjson\`, so you can inspect the *exact* JSON the server received:

```powershell
Get-Content C:\posh\postjson\20260514_142233_a1b2c3d4.json
```

This five-step loop — standalone, lint, parse, HTTP, logs — resolves the large majority of
endpoint bugs without guesswork.

## 3.10 Endpoint authoring checklist

A consolidated do/don't list. Tick these before you consider an endpoint done.

**Structure**

- [ ] First line is `#Requires -Version 7.0`.
- [ ] A comment-based help block with `.SYNOPSIS`, `.DESCRIPTION`, a `.PARAMETER` for each
      parameter, and at least one `.EXAMPLE`. (The server publishes this in `/` and
      `/openapi.json`.)
- [ ] A `param()` block with **explicit types** and **defaults** on every parameter.
- [ ] Dot-source `globalvars.ps1` with the correct number of `..\` for the folder depth.

**Behaviour**

- [ ] `$ErrorActionPreference = 'Stop'` for any endpoint that does real work.
- [ ] GET parameters declared `[string]`, cast and validated inside the script.
- [ ] POST endpoints validate `-JsonFilePath`, read with `-Raw -Encoding UTF8`, and
      `ConvertFrom-Json -Depth 10` (or deeper).
- [ ] `exit 0` on success; `exit <non-zero>` on failure.
- [ ] `Write-Output` for results, `Write-Error` for problems.

**Conventions** (consistency with the rest of the codebase)

- [ ] String formatting with the `-f` operator, not `+` concatenation.
- [ ] Suppress unwanted output with `$null = ...`, not `| Out-Null`.
- [ ] Comments explain *why*, in English, not *what* the obvious code does.

**What an endpoint script cannot do**

- It runs in its own `pwsh.exe` process. It **cannot** see the server's `$cfg`, its
  counters, its other requests, or its internal functions. It is an ordinary script that
  happens to be launched by the server.
- It receives input only through its declared parameters (GET) or `-JsonFilePath` (POST), and
  the environment variables the server injects (`POSH_SESSION_ID`, `POSH_COOKIES`). It cannot
  reach into the HTTP request for anything else.

---

# Part 4. Installing and setting up

This part installs posh from scratch on a Windows machine. If you inherited a running server,
you can skip to [Part 5](#part-5-configuring) — but read [4.4](#44-post-install-validation)
anyway, because its validation checklist is also the best "is this server healthy?" check.

The normal install path is one interactive script, `Register-ScheduledTask.ps1`, which sets
up everything: the API key, the configuration file, the optional HTTPS certificate and
binding, the firewall rules, and the auto-starting Windows scheduled task.

## 4.1 Prerequisites checklist

Before you run the installer, confirm all of these.

- [ ] **Windows 10 / Windows Server 2019 or newer.** Older Windows lacks features the server
      relies on.
- [ ] **PowerShell 7 installed.** Not Windows PowerShell 5.1 — PowerShell *7*. Confirm:
      ```powershell
      $PSVersionTable.PSVersion        # Major must be 7 or higher
      $PSVersionTable.PSEdition        # must be 'Core'
      ```
      If it is missing, install it from the Microsoft Store or
      `winget install Microsoft.PowerShell`.
- [ ] **A local administrator account *with a password*.** The scheduled task runs the server
      as this account. It cannot be the built-in `SYSTEM` account and it cannot be a
      password-less account — see the note below.
- [ ] **You can open an elevated (Administrator) PowerShell 7 prompt.** The installer makes
      machine-level changes (environment variables, `netsh` bindings, firewall rules, a
      scheduled task) and must run elevated.
- [ ] **A decision on HTTPS.** Decide *now* whether this server needs HTTPS, and if so what
      certificate it will use (a fresh self-signed one, an existing one already in the
      machine store, or a `.pfx` file you will import). The installer asks during the run.
- [ ] **The ports are free.** The default ports are 80 (HTTP) and 443 (HTTPS). If IIS or
      another service already owns them, pick different ports or stop the other service.

> **Note — why a real admin account, not SYSTEM.** The server runs your endpoint scripts, and
> those scripts often do administrative work (manage AD, restart services, read protected
> files). They run with the privileges of the account the scheduled task uses. A normal local
> administrator account with a known password is required because the task needs stored
> credentials to start at boot and to run scripts that may need network identity. Keep that
> account's password somewhere safe — you need it again to *reinstall*.

## 4.2 Installing with Register-ScheduledTask.ps1

**Step 1 — copy the files to the install directory.** Copy the whole repository to `C:\posh\`
(or your chosen base directory):

```powershell
Copy-Item -Path '.\*' -Destination 'C:\posh\' -Recurse -Force
```

**Step 2 — run the installer, elevated.** Open PowerShell 7 *as Administrator*, change into
the install directory, and run:

```powershell
cd C:\posh
.\Register-ScheduledTask.ps1
```

The installer takes no parameters — it is fully interactive. It walks you through these
prompts, in this order:

| Prompt | What to enter | Notes |
|---|---|---|
| **Username** | The local admin account the task runs as | Defaults to `Administrator`. |
| **Password** | That account's password | Entered masked; held as a `SecureString` and zeroed from memory after use. |
| **API key** | The secret callers will send in `X-Api-Key` | Stored as the `POSH_API_KEY` *machine* environment variable. Choose a long random string. |
| **HTTP port** | The HTTP listen port | Defaults to `80`. |
| **Enable HTTPS?** | Yes / No | If yes, you are asked the HTTPS questions below. |
| **HTTPS port** | The HTTPS listen port | Defaults to `443`. Only asked if HTTPS is enabled. |
| **Certificate source** | New self-signed / existing thumbprint / import a `.pfx` | See [4.3](#43-setting-up-https). Only asked if HTTPS is enabled. |
| **Firewall rules?** | Yes / No | If yes, the installer creates inbound Windows Firewall rules for the chosen port(s). |
| **Disable HTTP?** | Yes / No | Optional HTTPS-only mode — sets the HTTP port to 0. |

**Step 3 — what the installer does behind the scenes.** Once you have answered the prompts,
it performs, in order:

1. **Sets `POSH_API_KEY`** as a machine environment variable.
2. **Creates the certificate and the `netsh` binding** (if HTTPS was enabled) — see
   [4.3](#43-setting-up-https). It also records the thumbprint in the `POSH_CERT_THUMBPRINT`
   machine environment variable for reference.
3. **Generates `config.psd1`** by calling `tools\Initialize-PoshConfig.ps1`, which produces a
   complete, commented runtime configuration file from the server's built-in defaults.
4. **Creates the firewall rules** (if you asked for them).
5. **Registers the scheduled task** named `PowerShell-Webserver`: trigger *At startup*, runs
   as the account you supplied, *Run with highest privileges*, no execution time limit, and
   **automatic restart up to 3 times at 1-minute intervals** if the process exits
   unexpectedly. If a task of that name already exists, it is removed and recreated — so
   re-running the installer is safe.

**Step 4 — start the server.** The task is registered but not running yet. Start it without
rebooting:

```powershell
Start-ScheduledTask -TaskName 'PowerShell-Webserver'
```

**Step 5 — verify.** Confirm it is alive:

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

A JSON `status: ok` response means you are done with the basic install. Now work through the
full validation in [4.4](#44-post-install-validation).

## 4.3 Setting up HTTPS

HTTPS in posh depends on a Windows mechanism called an **`sslcert` binding** — a record,
managed by `netsh`, that ties a certificate to an IP-and-port. **This binding must exist
before the server starts.** At startup, if HTTPS is enabled and no binding is found, the
server writes an error to `startup.log` and exits — it never silently falls back to HTTP.

The installer creates this binding for you. When you choose to enable HTTPS it offers three
**certificate sources**:

| Source | Use when | What the installer does |
|---|---|---|
| **New self-signed certificate** | Internal servers, labs, anything where clients can be told to trust it or use `-SkipCertificateCheck` | Creates a certificate (you choose the validity in years, default 10) with Subject Alternative Names for the hostname, `localhost`, `127.0.0.1`, and the machine's IPv4 addresses, places it in `LocalMachine\My`, and reports the thumbprint. |
| **Existing certificate by thumbprint** | A certificate (e.g. from your internal CA) is already installed in `LocalMachine\My` | Looks up the thumbprint you supply, verifies it is present and not expired, and uses it. |
| **Import a `.pfx` file** | You have a certificate as a `.pfx` file | Prompts for the file path and its password, imports it into `LocalMachine\My`, and uses it. |

Whichever source you pick, the installer then runs the equivalent of:

```powershell
netsh http delete sslcert ipport=0.0.0.0:443        # clear any stale binding
netsh http add sslcert ipport=0.0.0.0:443 certhash=<thumbprint> appid={<posh-app-guid>}
```

**Inspecting the binding** at any time:

```powershell
netsh http show sslcert ipport=0.0.0.0:443
```

**Replacing or renewing the certificate.** The simplest path is to **re-run
`Register-ScheduledTask.ps1`** — it deletes and recreates the binding cleanly. To do it by
hand, see the runbook in [6.5](#65-renewing-or-replacing-the-tls-certificate).

> **Warning.** A self-signed certificate is fine for an internal server, but every client
> that calls it over HTTPS must either trust the certificate (import it into their trusted
> store) or pass `-SkipCertificateCheck`. Plan for this before you switch a server to
> HTTPS-only.

## 4.4 Post-install validation

Do not assume the install worked because no prompt turned red. Walk this checklist — each
item is a command and the result you should see. This same checklist is the best routine
health check for *any* posh server.

**1. The scheduled task exists and is running.**

```powershell
Get-ScheduledTask     -TaskName 'PowerShell-Webserver'
Get-ScheduledTaskInfo -TaskName 'PowerShell-Webserver'
```

`State` should be `Running` and `LastTaskResult` should be `0`.

**2. HTTP responds, no key needed.**

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

Expect `{ "status": "ok", ... }`.

**3. An authenticated call works.**

```powershell
Invoke-RestMethod -Uri 'http://localhost/hello.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }
```

Expect the `hello.ps1` envelope. A 401 here means the API key the server loaded does not
match the one you sent — re-check `POSH_API_KEY`.

**4. HTTPS responds (only if you enabled it).**

```powershell
Invoke-RestMethod -Uri 'https://localhost/health' -SkipCertificateCheck
```

If this fails but step 2 worked, the `sslcert` binding is the prime suspect —
[7.4](#74-https-and-certificate-problems).

**5. The startup log is clean.**

```powershell
Get-Content C:\posh\logs\startup.log -Tail 20
```

The last boot's lines should show a normal start with no `ERROR:` entries.

**6. The firewall rule exists (only if you asked for it).**

```powershell
Get-NetFirewallRule -DisplayName '*PowerShell-Webserver*' -ErrorAction SilentlyContinue
```

**7. The smoke test passes.**

```powershell
cd C:\posh\examples\clients
$env:POSH_API_KEY = 'your-api-key'
.\Test-AllEndpoints.ps1
```

Every endpoint should report a pass.

## 4.5 Running the server manually

The scheduled task is the right way to run posh in production. But for **development** —
testing an endpoint, watching the console output live, trying a config change — you can run
`Start-WebServer.ps1` by hand.

**You must do two things first:**

**1. Set `POSH_API_KEY` for the session.** Running by hand, you usually do not want to touch
the machine-wide variable. Set it for the current session:

```powershell
$env:POSH_API_KEY = 'dev-key-for-testing'
```

(The server reads `POSH_API_KEY` from the environment regardless of scope; a process-scope
value works for a hand-run.)

**2. Make sure `config.psd1` exists.** The server hard-fails at startup without it. If the
installer was never run on this machine, generate it once:

```powershell
.\tools\Initialize-PoshConfig.ps1
```

**Then run the server:**

```powershell
# HTTP only, on a non-privileged port (no admin needed for ports >= 1024)
.\Start-WebServer.ps1 -HttpPort 8080

# HTTP on 80 (needs an elevated prompt)
.\Start-WebServer.ps1

# HTTP on 80 and HTTPS on 443 (needs the netsh binding to exist)
.\Start-WebServer.ps1 -HttpsEnabled -HttpPort 80 -HttpsPort 443

# HTTPS only
.\Start-WebServer.ps1 -HttpsEnabled -HttpPort 0 -HttpsPort 443
```

The server runs in the foreground and logs to the console as well as to `logs\`.

**Stopping it cleanly.** Press `Ctrl+C`. The server stops accepting new requests and waits a
few seconds for in-flight requests to finish before exiting — a graceful shutdown.

> **Tip.** For development, run on a high port (`-HttpPort 8080`) so you do not need an
> elevated prompt and do not collide with anything on port 80.

## 4.6 Removing or reinstalling

**Removing the scheduled task:**

```powershell
Stop-ScheduledTask       -TaskName 'PowerShell-Webserver'
Unregister-ScheduledTask -TaskName 'PowerShell-Webserver' -Confirm:$false
```

That stops the server and removes the auto-start task. It does **not** delete the install
folder, the `POSH_API_KEY` environment variable, the `netsh` binding, or the firewall rules —
remove those by hand if you are fully decommissioning the machine.

**Reinstalling / reconfiguring.** Just re-run `Register-ScheduledTask.ps1`. It is
**idempotent**: it removes any existing `PowerShell-Webserver` task and recreates it, and it
deletes and recreates the `netsh sslcert` binding. Re-run it whenever you need to change the
account, the ports, the certificate, or the firewall rules.

**What survives a reinstall.** Re-running the installer regenerates `config.psd1` *only if
you let `Initialize-PoshConfig.ps1` overwrite it* — by default that tool refuses to
overwrite an existing file. In practice, a reinstall preserves:

- `config.psd1` — your tuned runtime configuration.
- `globalvars.ps1` — your endpoint configuration and AES key.
- `webroot\` — all your endpoints.
- `logs\`, `postjson\`, `encrypted_pw\` — all runtime data and secrets.

So a reinstall re-establishes the *plumbing* (task, binding, firewall, API key) without
disturbing your *content*.

> **Warning.** Before reinstalling, make sure you still have the admin account's password and
> the API key. The installer needs the password again, and if you let it set a *new* API key
> you must update every client.

---

# Part 5. Configuring

Configuration is how you change *server* behaviour — ports, timeouts, authentication, rate
limits, logging, and dozens of other settings. (Changing *endpoint* behaviour is
`globalvars.ps1`, covered in [3.7](#37-shared-configuration-with-globalvarsps1) — do not
confuse the two.)

## 5.1 How configuration works, the two layers

A setting can come from three places. They are resolved in a fixed order of precedence:

```
   Inline $cfg defaults          <---  config.psd1          <---  command-line parameters
   (built into Start-WebServer)        (your runtime file)        (passed to the task / script)
   the schema + fallback               the source of truth        override everything

   lowest precedence  -------------------------------------------->  highest precedence
```

**Layer 1 — the inline `$cfg` defaults.** Inside `Start-WebServer.ps1` there is a large
hashtable, `$cfg`, that defines every setting and its default value. This is the *schema*. You
do not edit it. Its job is to be the fallback: if a setting is missing from your
`config.psd1` — for instance because you are running an older config file against a newer
server — the inline default fills the gap, so upgrades never break an old config.

**Layer 2 — `config.psd1`.** This is the **runtime source of truth** — the file you actually
edit. It lives next to `Start-WebServer.ps1` (at `C:\posh\config.psd1`) and is a PowerShell
data file: a plain `@{ ... }` hashtable, parsed safely with `Import-PowerShellDataFile`, which
*reads data only and never executes code*. It is generated per-installation (so it is
gitignored — it belongs to this machine, not the repository).

**`config.psd1` is mandatory.** The server **refuses to start** if it does not exist. This is
deliberate: every install owns an explicit, reviewable configuration rather than relying on
invisible script defaults. [5.2](#52-generating-and-regenerating-configpsd1) covers
generating it.

**Layer 3 — command-line parameters.** A few settings — `-HttpPort`, `-HttpsPort`,
`-HttpsEnabled` — can be passed on the command line, and they override whatever `config.psd1`
says. The scheduled task uses this: the installer bakes the chosen ports into the task's
command line. [5.6](#56-command-line-parameters) lists them all.

**Inspecting the effective configuration.** To see exactly what the server *will* use, after
all three layers are merged, run:

```powershell
.\Start-WebServer.ps1 -DumpEffectiveConfig
```

It prints the merged configuration as JSON and exits without starting the listener. This is
the definitive answer to "what is this server's setting for X?" and the first tool to reach
for when a config change does not seem to take effect ([7.11](#711-configuration-did-not-take-effect)).
(A related switch, `-DumpConfig`, prints only the layer-1 inline defaults — it is what the
config generator uses internally.)

> **Warning.** A malformed `config.psd1` — a missing brace, a bad quote — makes the server
> fail at startup with a parse error in `startup.log`. The file is data-only so it cannot run
> malicious code, but it must be syntactically valid. Always restart and check `startup.log`
> after a hand edit.

## 5.2 Generating and regenerating config.psd1

`config.psd1` is created by `tools\Initialize-PoshConfig.ps1`. It works by asking
`Start-WebServer.ps1` for its inline `$cfg` defaults and writing them out as a fully
populated, grouped, commented `.psd1` file — so the generated file documents itself.

**First-time generation.** The installer (`Register-ScheduledTask.ps1`) runs this for you. If
you are setting up without the installer, run it once by hand:

```powershell
.\tools\Initialize-PoshConfig.ps1
```

It writes `config.psd1` next to `Start-WebServer.ps1`. It **refuses to overwrite** an
existing file unless you pass `-Force`.

**Regenerating with `-Force`.** If you want a fresh file built from the current server's
defaults — for example after upgrading to a server version with new settings — use:

```powershell
.\tools\Initialize-PoshConfig.ps1 -Force
```

Before overwriting, it backs up the current file as `config.psd1.bak.<timestamp>` (and keeps
the five most recent backups), so a regeneration is always reversible.

**What the generated file looks like.** Keys are grouped under section headers — *HTTP / HTTPS
endpoints*, *Authentication*, *Rate limiting*, *Logging*, and so on — in a fixed order, with
the whole `@{ ... }` aligned for readability:

```powershell
@{

    # -- HTTP / HTTPS endpoints ---------------------------------------------
    HttpsEnabled = $false
    HttpPort     = 80
    HttpsPort    = 443
    Prefixes     = @()

    # -- Authentication ----------------------------------------------------
    ApiKeys      = @{}
    AuthMode     = 'ApiKey'
    # ... every other key, grouped ...
}
```

The full list of groups and every key in them is in [Part 11](#part-11-complete-configuration-reference).

## 5.3 Editing config.psd1

There are two ways to change a setting. **Either way, the server must be restarted for the
change to take effect** — `config.psd1` is read once, at startup.

### Editing the file directly

Open `C:\posh\config.psd1` in any text editor, change the value, save. Because the file is a
PowerShell data file, the syntax is simple — strings in single quotes, `$true`/`$false`,
numbers bare, arrays as `@('a', 'b')`, nested tables as `@{ ... }`:

```powershell
    # -- Script execution --------------------------------------------------
    ScriptTimeoutSec = 600          # was 300; give long jobs more headroom
    MaxConcurrent    = 20           # was 10; allow more parallelism
```

A broken edit is safe in the sense that the data file cannot execute code, but it *will* stop
the server from starting — so after every hand edit, restart and check `startup.log`.

### The browser-based editor

`Edit-PoshSettings.ps1` is a small local web application for editing configuration through a
form, with validation, a diff preview before you save, and automatic backups. It is the
recommended path for a junior admin because it is hard to produce a broken file with it.

```powershell
.\Edit-PoshSettings.ps1
```

It starts a tiny web server **bound to loopback only** (it is not reachable from the network),
protected by a random one-time token in the URL it opens, and it shuts itself down after a
period of inactivity. It can edit both `config.psd1` and `globalvars.ps1`.

**What the editor will not touch.** A few settings are too structured for a simple form — the
`BackgroundJobs` array, the `MimeTypeMap` table, the `ApiKeys` map, and the AES `$key` in
`globalvars.ps1`. For those, edit the file directly. The editor also cannot create or change
the `netsh` certificate binding — that is `Register-ScheduledTask.ps1`'s job.

### Always restart after editing

Whichever method you used:

```powershell
Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
Start-ScheduledTask -TaskName 'PowerShell-Webserver'
```

Then confirm: `Invoke-RestMethod -Uri 'http://localhost/health'` and, if you want certainty,
`.\Start-WebServer.ps1 -DumpEffectiveConfig` to see the merged result.

## 5.4 Common configuration patterns

A cookbook. Each recipe is a goal, the key(s) to change in `config.psd1`, and an example.
**Every recipe ends with the same step: restart the task** ([6.1](#61-starting-stopping-and-restarting)).

**Change the HTTP or HTTPS port.** These are usually set on the task command line by the
installer; the cleanest way to change them is to re-run `Register-ScheduledTask.ps1`. To set
them in `config.psd1` instead:

```powershell
HttpPort  = 8080
HttpsPort = 8443
```

**Run HTTPS-only (no plain HTTP).** Set the HTTP port to 0 and enable HTTPS:

```powershell
HttpPort     = 0
HttpsEnabled = $true
HttpsPort    = 443
```

**Give scripts more time to run.** The default kill-after time is 300 seconds. For endpoints
that legitimately take longer:

```powershell
ScriptTimeoutSec = 900          # 15 minutes
```

**Accept bigger POST bodies.** The default cap is 20 MB (`20971520` bytes):

```powershell
MaxRequestBodyBytes = 52428800  # 50 MB
```

**Handle more requests at once.** The default concurrency cap is 10:

```powershell
MaxConcurrent = 25
```

**Loosen the call-rate limits.** The global throttle forces a gap between requests; the rate
limiter caps requests per IP per window. To allow faster automation:

```powershell
MinRequestIntervalSec = 0       # disable the global throttle entirely
RateLimitRequests     = 1000    # raise the per-IP budget (per RateLimitWindowSec)
```

To *tighten* instead, lower `RateLimitRequests` or raise `MinRequestIntervalSec`.

**Restrict which clients can connect.** `AllowedIPs` is an allowlist (when non-empty, *only*
listed clients pass); `BlockedIPs` is a blocklist. Both accept exact IPs, CIDR ranges, and
`~`-prefixed regular expressions:

```powershell
AllowedIPs = @('10.20.0.0/16', '192.168.1.50')
BlockedIPs = @('203.0.113.7')
```

**Give a specific client its own API key.** The `ApiKeys` map holds labelled keys. Each
label appears in the logs and audit trail, so you can tell *which* client made a call:

```powershell
ApiKeys = @{
    'ci'         = 'long-random-key-for-the-build-pipeline'
    'monitoring' = 'long-random-key-for-the-monitoring-system'
}
```

(The single `POSH_API_KEY` environment variable still works alongside this — it is merged in
under the label `default`.)

**Make an endpoint reachable without a key.** Add its path to `AuthExemptPaths`. Use this
sparingly — an exempt endpoint is open to anyone who can reach the server:

```powershell
AuthExemptPaths = @('/health', '/metrics', '/metrics-prom', '/openapi.json', '/public-status.ps1')
```

**Keep logs longer, or rotate hourly.** Default retention is 180 days, one file per day:

```powershell
LogRetentionDays = 365
LogSchedule      = 'Hourly'     # 'Daily' (default) or 'Hourly'
```

**Turn on the security audit log.** Off by default. When on, authentication failures, IP
blocks, and rate-limit events are written as one JSON line each to `logs\audit.log`:

```powershell
AuditLogEnabled = $true
```

**Serve static files (HTML, CSS, images).** Off by default — posh is script-only out of the
box. To also serve plain files from `webroot\`:

```powershell
StaticServingEnabled = $true
```

See [10.1](#101-static-file-serving) for the full static-serving picture.

**Allow a browser-based app to call the server.** Browsers enforce CORS; by default CORS is
disabled. To let a web app on a specific origin call posh:

```powershell
CorsAllowedOrigins = @('https://app.example.local')
```

See [10.2](#102-cors-and-browser-clients) for the details.

## 5.5 Environment variables

A few settings live in **machine-scope environment variables** rather than `config.psd1`,
because they are secrets or machine-specific and must not end up in a file that could be
copied or committed.

| Variable | Required? | What it is | Set by |
|---|---|---|---|
| `POSH_API_KEY` | **Yes** | The API key callers send in `X-Api-Key`. The server will not start without it. | The installer, or by hand. |
| `POSH_BASIC_USER` | Only for Basic auth | Username for HTTP Basic authentication, used when `AuthMode` is `Basic` or `Both`. | By hand. |
| `POSH_BASIC_PASS` | Only for Basic auth | Password for HTTP Basic authentication. Kept in process memory only. | By hand. |
| `POSH_CERT_THUMBPRINT` | No | The HTTPS certificate thumbprint. Recorded for reference / diagnostics; the server does not require it (the `netsh` binding is what matters). | The installer. |

**Setting one by hand** (in an elevated prompt — machine scope requires admin):

```powershell
[Environment]::SetEnvironmentVariable('POSH_API_KEY', 'a-long-random-key', 'Machine')
```

**Reading one back:**

```powershell
[Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')
```

> **Warning.** A change to a machine environment variable is **not** picked up by a
> already-running process. After changing `POSH_API_KEY`, you must restart the scheduled task
> for the server to see the new value.

## 5.6 Command-line parameters

`Start-WebServer.ps1` accepts a small set of parameters. They override `config.psd1`. The
scheduled task created by the installer passes the port and HTTPS parameters automatically;
you mostly meet these when running the server by hand ([4.5](#45-running-the-server-manually)).

| Parameter | Type | Default | Effect |
|---|---|---|---|
| `-HttpsEnabled` | switch | off | Enable the HTTPS listener. Requires a `netsh sslcert` binding to exist. |
| `-HttpPort` | int (0–65535) | `80` | HTTP listen port. `0` disables HTTP (use with `-HttpsEnabled` for HTTPS-only). |
| `-HttpsPort` | int (1–65535) | `443` | HTTPS listen port. Only used when `-HttpsEnabled` is present. |
| `-BaseDir` | string | `C:\posh` | Base directory for all runtime artefacts — `config.psd1`, `webroot\`, `logs\`, `postjson\`. Change it to run a second instance from a different folder. |
| `-ConfigFile` | string | `<BaseDir>\config.psd1` | Explicit path to the runtime config file. Use it to point at a config outside the base directory. |
| `-DumpConfig` | switch | off | Print the inline `$cfg` defaults as JSON and exit. Used internally by the config generator. |
| `-DumpEffectiveConfig` | switch | off | Print the *merged* configuration (defaults + `config.psd1` + CLI overrides) as JSON and exit. The definitive "what setting is actually in effect" check. |

**How the scheduled task passes them.** The installer bakes the chosen ports into the task's
action, so the task effectively runs something like:

```
pwsh.exe -File C:\posh\Start-WebServer.ps1 -HttpPort 80 -HttpsEnabled -HttpsPort 443
```

That is why changing a port purely in `config.psd1` may appear to do nothing — the
command-line value wins. To change ports cleanly, re-run the installer (or edit the task's
action). This trap is covered in [7.11](#711-configuration-did-not-take-effect).

---

# Part 6. Day-2 operations

"Day 2" is everything after the install: the routine tasks of keeping a posh server running,
healthy, and current. This part is runbooks — step-by-step procedures for the things you do
on a schedule or on demand. (When something is *broken*, go to
[Part 7](#part-7-troubleshooting-and-diagnostics) instead.)

## 6.1 Starting, stopping, and restarting

The server runs as the Windows scheduled task `PowerShell-Webserver`. You control it with the
standard scheduled-task cmdlets.

```powershell
# Start
Start-ScheduledTask -TaskName 'PowerShell-Webserver'

# Stop (waits for in-flight requests to finish, up to a few seconds)
Stop-ScheduledTask -TaskName 'PowerShell-Webserver'

# Restart — the two-step you run after ANY configuration change
Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
Start-ScheduledTask -TaskName 'PowerShell-Webserver'
```

**The restart rule.** `config.psd1` and the `POSH_API_KEY` environment variable are read
**once, at startup**. Any change to either is invisible until you restart the task. Make the
restart-then-verify pair a reflex:

```powershell
Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
Start-ScheduledTask -TaskName 'PowerShell-Webserver'
Invoke-RestMethod   -Uri 'http://localhost/health'
```

(Endpoint scripts in `webroot\` and `globalvars.ps1` are the exception — they are read on
every request, so editing *those* needs no restart.)

**Checking the task's state:**

```powershell
Get-ScheduledTask     -TaskName 'PowerShell-Webserver' | Select-Object State
Get-ScheduledTaskInfo -TaskName 'PowerShell-Webserver' |
    Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns
```

`State` should be `Running`; `LastTaskResult` should be `0`.

**Automatic restart behaviour.** The task is registered with an *At startup* trigger, so it
comes back after a reboot, and with **automatic restart up to 3 times at 1-minute intervals**
if the process exits unexpectedly. That means a server that *crashes on startup* will be seen
trying and failing every minute — three times — and then stop. If you see that pattern,
something is wrong at startup: go straight to [7.2](#72-the-server-will-not-start).

## 6.2 Reading and understanding the logs

All logs live in `C:\posh\logs\`. You will spend real troubleshooting time here, so learn
what each file is.

| File | What it holds | Always present? |
|---|---|---|
| `startup.log` | What happened the last few times the server booted — and *why it exited* if it failed to start | Yes |
| `2026-05-14.log` | One **request log** per day (or per hour if `LogSchedule = 'Hourly'`) — a line for every request | Yes |
| `audit.log` | Security events (auth failures, IP blocks, rate-limit hits) as one JSON object per line | Only if `AuditLogEnabled` |
| `slow.log` | A line for every request slower than `SlowRequestThresholdMs` | Only if that threshold is > 0 |
| `jobs.log` | Output from background jobs | Only if you configured `BackgroundJobs` |

### Anatomy of a request log line

In the default **Native** format, each request is one pipe-delimited line:

```
2026-05-14 14:23:45 | 192.168.1.100   | GET /hello.ps1?Name=Max  | EXIT:0    | OK            | default          | 142ms    | a1b2c3d4
        |                   |                    |                     |          |                |                  |            |
   timestamp           client IP            request line       exit code   status text      identity         elapsed     request ID
```

| Column | Meaning |
|---|---|
| **timestamp** | When the request completed (`yyyy-MM-dd HH:mm:ss`). |
| **client IP** | The caller's IP address. |
| **request line** | The HTTP method and the path with query string. |
| **exit code** | `EXIT:0` for success, `EXIT:1` (or other) for a script failure, `EXIT:-1` for a timeout. |
| **status text** | A short word for the outcome — see the table below. |
| **identity** | Who called: the API-key label (`default`, `ci`, …), `basic:<user>` for Basic auth, `anonymous` for an exempt path, or `-`. |
| **elapsed** | How long the request took, e.g. `142ms`, or `-` if not measured. |
| **request ID** | The 8-character ID that also went out in the `X-Request-Id` header. |

### Status values you will see

| Status text | Means |
|---|---|
| `OK` | The script ran and exited 0. |
| `ERROR` | The script failed (non-zero exit or exception) → HTTP 500. |
| `TIMEOUT` | The script ran past `ScriptTimeoutSec` and was killed → HTTP 504. |
| `UNAUTHORIZED` | Missing or wrong API key → HTTP 401. |
| `NOT FOUND` | No matching script → HTTP 404. |
| `FORBIDDEN` / `IP BLOCKED` / `IP NOT ALLOWED` | Rejected by the IP filter → HTTP 403. |
| `RATE LIMITED` / `GLOBAL THROTTLED` | Hit the per-IP rate limit or the global throttle → HTTP 429. |
| `OVERLOAD` | Server at its concurrency cap → HTTP 503. |
| `METHOD NOT ALLOWED` | Not GET/POST/OPTIONS → HTTP 405. |
| `BAD REQUEST` | Malformed request → HTTP 400. |
| `INDEX` / `HEALTH` / `METRICS` / `METRICS-PROM` / `OPENAPI` | A built-in endpoint was served. |

### startup.log

`startup.log` is the **first file to read when the server will not start**. The early
startup checks (PowerShell version, the API key, the config file, the HTTPS binding) all
write here before anything else exists. A failed start leaves a clear `ERROR:` line, for
example:

```
2026-05-14 09:00:01 | STARTUP | ERROR: Environment variable POSH_API_KEY is not set. Server will not start.
2026-05-14 09:05:12 | STARTUP | ERROR: config.psd1 not found at 'C:\posh\config.psd1'. Run tools\Initialize-PoshConfig.ps1 first.
```

```powershell
Get-Content C:\posh\logs\startup.log -Tail 30
```

### The optional logs

- **`audit.log`** — turn it on with `AuditLogEnabled = $true`. Each line is a JSON object
  describing one security event. See [6.7](#67-reviewing-the-audit-log).
- **`slow.log`** — turn it on by setting `SlowRequestThresholdMs` above 0 (e.g. `2000` for
  "log anything over 2 seconds"). Useful for finding the endpoints that drag.
- **`jobs.log`** — appears only when you use `BackgroundJobs`. See
  [6.8](#68-running-scripts-on-a-schedule).

> **Note.** The request log can be switched to **IIS-W3C** format (`LogFormat = 'IIS-W3C'`)
> for ingestion by log analysers that expect W3C Extended Log Format. The columns are similar
> but space-delimited with a `#Fields` header. Native is the default and is easier to read by
> eye.

## 6.3 Monitoring health and uptime

posh exposes three endpoints designed for monitoring systems.

**`/health` — is it alive?** Authentication-exempt, cheap, returns liveness plus a request
counter. Point your monitoring system's HTTP check at it:

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
# { "status": "ok", "uptime": "3h 12m 45s", "requestsTotal": 1840 }
```

A failed or timed-out `/health` means the server is down or unreachable.

**`/metrics` — operational counters (JSON).** Authentication-exempt, like `/health`. It
returns counters worth watching over time:

| Counter | Watch for |
|---|---|
| `requestsTotal` | Overall traffic volume. |
| `rateLimitedTotal` | A rising number means clients are hitting limits — investigate or tune. |
| `authFailuresTotal` | A spike can mean a misconfigured client — or an attack. |
| `scriptTimeoutsTotal` | Endpoints regularly hitting `ScriptTimeoutSec`. |
| in-flight / peak concurrency | How close you run to `MaxConcurrent`. Peak near the cap means 503s are likely. |
| log drops | The log mutex timed out and lines were dropped — raise `LogMutexTimeoutMs` if non-zero. |

**`/metrics-prom` — the same counters in Prometheus format.** Authentication-exempt, in
Prometheus text exposition format. Point a Prometheus scraper at it:

```
posh_requests_total 1840
posh_rate_limited_total 12
posh_script_timeouts_total 0
posh_uptime_seconds 11565
...
```

> **Tip.** A simple home-grown monitor: a scheduled task on another machine that calls
> `/health` every few minutes and alerts if it fails. Because `/health` is auth-exempt and
> rate-limit-exempt, you can poll it as often as you like.

## 6.4 Rotating the API key

Rotate the API key on a schedule, and immediately if it may have leaked. There are two ways:
a simple swap (brief downtime for clients) and a zero-downtime cutover.

### Simple rotation (single key)

1. Generate a new strong key (any long random string).
2. Set it as the machine environment variable, in an elevated prompt:
   ```powershell
   [Environment]::SetEnvironmentVariable('POSH_API_KEY', 'the-new-key', 'Machine')
   ```
3. Restart the task:
   ```powershell
   Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
   Start-ScheduledTask -TaskName 'PowerShell-Webserver'
   ```
4. Update every client to send the new key.

Between steps 3 and 4, clients still sending the old key get 401. For a handful of clients
under your control that is fine; for many, use the next method.

### Zero-downtime rotation (the ApiKeys map)

The `ApiKeys` map lets several keys be valid at once, so you can introduce the new key,
migrate clients, then retire the old one — with no window where calls fail.

1. In `config.psd1`, add the new key alongside the old, each with a label:
   ```powershell
   ApiKeys = @{
       'old' = 'the-current-key'
       'new' = 'the-replacement-key'
   }
   ```
2. Restart the task. **Both keys now work.**
3. Migrate each client to the new key, at your pace.
4. Confirm nothing still uses the old key — grep the request log for the `old` label:
   ```powershell
   Select-String -Path C:\posh\logs\*.log -Pattern '\| old\s'
   ```
   When that returns nothing for long enough, you are safe to proceed.
5. Remove the `'old'` entry from `ApiKeys`, restart the task.

> **Security.** Because each `ApiKeys` entry has a label and that label is written into every
> log line and audit record, the `ApiKeys` map is also good practice *generally*, not just
> during rotation — it tells you which client did what. See
> [8.2](#82-authentication-hardening).

## 6.5 Renewing or replacing the TLS certificate

The HTTPS certificate eventually expires, or you may need to swap a self-signed one for a
proper CA-issued one. The certificate is tied to the server by a `netsh sslcert` binding
([4.3](#43-setting-up-https)), and that binding must point at a valid certificate.

### The easy way: re-run the installer

`Register-ScheduledTask.ps1` deletes and recreates the `netsh` binding cleanly. Re-run it,
choose your certificate source, let it rebind, and restart the task. This is the recommended
path.

### The manual way

1. Inspect the current binding:
   ```powershell
   netsh http show sslcert ipport=0.0.0.0:443
   ```
2. Get the new certificate into `LocalMachine\My` — import a `.pfx`, or create a self-signed
   one:
   ```powershell
   $cert = New-SelfSignedCertificate -DnsName 'posh.example.local' `
       -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(5)
   $cert.Thumbprint
   ```
3. Replace the binding with the new thumbprint:
   ```powershell
   netsh http delete sslcert ipport=0.0.0.0:443
   netsh http add sslcert ipport=0.0.0.0:443 certhash=<new-thumbprint> appid='{a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d}'
   ```
   (The `appid` is the posh application GUID; using the same one keeps the binding tidy.)
4. Verify the binding shows the new thumbprint, then restart the task.

> **Warning.** Do the rebind *before* restarting the server. If the server starts with HTTPS
> enabled and the binding is missing or broken, it exits immediately —
> [7.4](#74-https-and-certificate-problems).

## 6.6 Managing log and POST-body disk usage

posh cleans up after itself at startup, but you should understand what it does and watch the
folders that can grow.

**Automatic cleanup at startup.** When the server starts, it:

- Deletes dated request logs (`YYYY-MM-DD.log` / `YYYY-MM-DDTHH.log`) older than
  `LogRetentionDays` (default 180; `0` disables).
- Deletes POST body files in `postjson\` older than `PostJsonRetentionDays` (default 30; `0`
  disables).
- Rotates the single-file logs (`audit.log`, `slow.log`, `jobs.log`) if they have grown past
  their size caps (`AuditLogMaxBytes`, `SlowLogMaxBytes`, `JobsLogMaxBytes`).

Because cleanup runs *at startup*, a server that runs for months without a restart will
accumulate files until the next restart. A monthly restart is a reasonable hygiene habit.

**Archiving logs manually.** To keep older logs off the server but not lose them, compress
and move them:

```powershell
# Archive last month's request logs
$old = Get-ChildItem C:\posh\logs\2026-04-*.log
Compress-Archive -Path $old -DestinationPath 'D:\archive\posh-logs-2026-04.zip'
Remove-Item $old
```

**Watch `postjson\`.** Every POST request leaves a body file there. A server taking many
large POSTs can fill the folder between restarts. If disk space is tight, lower
`PostJsonRetentionDays` and restart more often, or add your own scheduled cleanup.

**Integrity hashes (optional).** Setting `LogIntegrityHash = $true` makes the server write a
`.md5` file next to every *completed* log file at startup. That gives you a tamper-evidence
check for logs at rest — useful where logs are an audit requirement.

## 6.7 Reviewing the audit log

The audit log is a focused, machine-readable security trail. It is **off by default**; turn
it on with `AuditLogEnabled = $true` and restart.

**What gets recorded.** Three event types, written to `logs\audit.log` as **NDJSON** — one
JSON object per line:

- `AUTH_FAIL` — a request with a missing or wrong credential.
- `IP_BLOCKED` — a request rejected by the IP filter.
- `RATE_LIMITED` — a request rejected by the rate limiter.

Each line carries a timestamp, the event type, the client IP, the path, the identity (where
known), and a detail field. Secrets are never written — an `AUTH_FAIL` records *that* a key
was wrong, never the key itself.

**Reviewing it.** Because each line is JSON, PowerShell parses it directly:

```powershell
# All authentication failures today
Get-Content C:\posh\logs\audit.log |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.event -eq 'AUTH_FAIL' } |
    Format-Table ts, ip, path

# Count events by type
Get-Content C:\posh\logs\audit.log |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Group-Object event | Select-Object Name, Count
```

The NDJSON format also ingests cleanly into a SIEM. A burst of `AUTH_FAIL` from one IP, or
`IP_BLOCKED` events you did not expect, is worth a look.

## 6.8 Running scripts on a schedule

Sometimes you want a script to run *on a timer* inside the server — a periodic cleanup, a
cache refresh, a health roll-up — rather than in response to an HTTP request. That is what
**background jobs** are for.

**Configuring one.** In `config.psd1`, the `BackgroundJobs` key is an array of small tables,
each with a script path and an interval in seconds:

```powershell
BackgroundJobs = @(
    @{ Path = 'C:\posh\jobs\refresh-cache.ps1'; IntervalSec = 300 }
    @{ Path = 'C:\posh\jobs\nightly-report.ps1'; IntervalSec = 86400 }
)
```

Restart the task and each job starts running on its interval.

**Where the output goes.** Background jobs do not return anything to a caller — they have no
caller. Their output is written to `logs\jobs.log`. Check that file to confirm a job is
running and to see what it produced.

**When to use a background job vs a Windows scheduled task.** A background job is convenient
because it lives with the server and uses the same configuration. But a separate Windows
scheduled task is independent — it survives a posh restart, runs even if posh is stopped, and
shows up in Task Scheduler where other admins expect to find scheduled work. Use background
jobs for things tightly coupled to the server; use a Windows task for everything else.

The internals — isolation, shutdown behaviour — are in [10.7](#107-background-jobs).

---

# Part 7. Troubleshooting and diagnostics

When something is wrong, work *with* the design rather than guessing. The server's gate
sequence ([1.3](#13-how-a-request-is-handled)) and its log files turn most problems into a
short, mechanical diagnosis. This part is organised by symptom: find yours, follow the
causes top to bottom (they are ordered most-likely first), confirm, fix.

## 7.1 The general diagnostic method

Before diving into a specific symptom, run this triage. It tells you *which class* of problem
you have, which is half the battle.

**Step 1 — is the process even running?**

```powershell
Get-ScheduledTask -TaskName 'PowerShell-Webserver' | Select-Object State
```

If `State` is not `Running` → the server is down. Go to [7.2](#72-the-server-will-not-start)
and [7.3](#73-the-scheduled-task-will-not-run).

**Step 2 — does `/health` answer?**

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

- No response / connection refused → the listener is not up, or you cannot reach it. Go to
  [7.5](#75-the-server-is-unreachable-from-another-machine).
- Responds → the server is alive and listening. Your problem is with a *specific request*,
  not the server. Continue.

**Step 3 — is it an HTTP-level rejection or a script error?** Look at the status code your
request got back:

- **401 / 403 / 404 / 405 / 413 / 415 / 429 / 503** — the request was rejected by a *gate*
  before any script ran. The server is fine; the request or the configuration is the issue.
  Each code has a section below.
- **500** — a script *ran and failed*. The problem is in the endpoint. Go to
  [7.8](#78-endpoints-return-500).
- **504** — a script ran too long and was killed. Go to [7.9](#79-endpoints-time-out).

**The three places to look:**

| Place | Tells you |
|---|---|
| `logs\startup.log` | Why the server failed to *start*. |
| `logs\YYYY-MM-DD.log` (the request log) | What happened to a specific *request* — status, identity, timing. |
| Task Scheduler history / `Get-ScheduledTaskInfo` | Whether the *task* ran, and its last result. |

**Use the request ID.** If a caller can give you the `X-Request-Id` from their failed
response, that one string finds the exact log line (and, for a POST, the exact body file).
It is the fastest way from "a request failed" to "here is precisely what happened".

## 7.2 The server will not start

The task shows `Ready` not `Running`, or it flaps (starts, dies, restarts — three times, then
stops; see [6.1](#61-starting-stopping-and-restarting)). **Always read `startup.log` first** —
the startup checks fail loudly and in order, and the last `ERROR:` line names the cause.

```powershell
Get-Content C:\posh\logs\startup.log -Tail 30
```

The startup checks run in this order; the first one to fail stops the server.

**Cause 1 — `POSH_API_KEY` is not set (or empty).** The most common cause on a fresh box.

> `STARTUP | ERROR: Environment variable POSH_API_KEY is not set. Server will not start.`

The server refuses to run without a key. Confirm and fix:

```powershell
[Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')   # is it there?
[Environment]::SetEnvironmentVariable('POSH_API_KEY', 'your-key', 'Machine')   # set it (elevated)
```

Then restart the task. Note the variable must be **Machine** scope — a User-scope value the
task's account cannot see counts as "not set".

**Cause 2 — `config.psd1` is missing.**

> `STARTUP | ERROR: config.psd1 not found at 'C:\posh\config.psd1'. Run tools\Initialize-PoshConfig.ps1 first.`

Generate it:

```powershell
cd C:\posh
.\tools\Initialize-PoshConfig.ps1
```

**Cause 3 — `config.psd1` is malformed.** A hand edit left a bad brace or quote. `startup.log`
shows a parse error naming the file. Fix the syntax (or restore a `config.psd1.bak.*` backup,
or regenerate with `Initialize-PoshConfig.ps1 -Force`), then restart.

**Cause 4 — PowerShell 7 is not what is running the task.**

> `STARTUP | PowerShell 7 required. Running version: 5.1.x (Desktop)`

The task is launching Windows PowerShell, not PowerShell 7. Re-run the installer, or fix the
task's action to point at `pwsh.exe`.

**Cause 5 — a port is out of range or already in use.** A bad port number in `config.psd1`,
or another service (often IIS) already owns port 80/443. `startup.log` shows a listener bind
failure. Pick free ports or stop the conflicting service:

```powershell
Get-NetTCPConnection -LocalPort 80 -ErrorAction SilentlyContinue   # who owns port 80?
```

**Cause 6 — HTTPS is enabled but the `netsh sslcert` binding is missing.** Covered in
[7.4](#74-https-and-certificate-problems).

**Cause 7 — Basic auth is configured but its credentials are not set.** If `AuthMode` is
`Basic` or `Both`, the server needs `POSH_BASIC_USER` and `POSH_BASIC_PASS` set as machine
environment variables. `startup.log` says which is missing. Set them, or switch `AuthMode`
back to `ApiKey`.

## 7.3 The scheduled task will not run

The task exists but does not start, exits immediately, or keeps restarting — and `startup.log`
is *empty or stale* (if `startup.log` has a fresh `ERROR:`, it is really a [7.2](#72-the-server-will-not-start)
problem; the process started and then chose to exit).

**Check the task's last result:**

```powershell
Get-ScheduledTaskInfo -TaskName 'PowerShell-Webserver' |
    Select-Object LastRunTime, LastTaskResult
```

A non-zero `LastTaskResult` is the clue.

**Cause 1 — wrong account or password.** The task is registered to run as a specific account.
If that account's password changed, or the account is wrong, the task cannot start at all —
nothing is even launched, so `startup.log` stays stale. Re-run `Register-ScheduledTask.ps1`
and supply the correct account and current password.

**Cause 2 — the account cannot log on as a batch job.** The task's account needs the "Log on
as a batch job" right. Domain policy sometimes strips it. Grant it (Local Security Policy →
*Log on as a batch job*) or pick an account that has it.

**Cause 3 — the task is not set to run with highest privileges.** posh binds to ports and
needs elevation. The installer sets *Run with highest privileges*; if the task was edited by
hand and lost it, the listener bind fails. Re-run the installer.

**Cause 4 — the process starts then exits immediately.** If something *does* land in
`startup.log` each time the task fires, the task itself is fine — the *server* is exiting on
a startup check. That is a [7.2](#72-the-server-will-not-start) problem.

**Reading task history.** Open Task Scheduler, select the `PowerShell-Webserver` task, and
look at the **History** tab for the launch/exit events and their codes. (History may need to
be enabled at the Task Scheduler level first.)

## 7.4 HTTPS and certificate problems

**Symptom: the server exits at startup whenever HTTPS is enabled.** HTTPS depends on a
`netsh sslcert` binding existing *before* the server starts. If it is missing, stale, or on
the wrong port, the server logs an HTTPS error to `startup.log` and exits — it never falls
back to plain HTTP.

**Confirm the binding:**

```powershell
netsh http show sslcert ipport=0.0.0.0:443
```

- *No binding shown* → the binding was never created or was deleted. Re-run
  `Register-ScheduledTask.ps1`, or create it by hand ([6.5](#65-renewing-or-replacing-the-tls-certificate)).
- *Binding shown, but on a different port than `HttpsPort`* → bind on the right port.
- *Binding shows a thumbprint* → check that certificate exists and is valid:
  ```powershell
  Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq '<thumbprint>' |
      Select-Object Subject, NotAfter
  ```
  If `NotAfter` is in the past, the certificate is **expired** — renew it
  ([6.5](#65-renewing-or-replacing-the-tls-certificate)).

**Symptom: `netsh add sslcert` failed during install.** Sometimes the install-time bind fails
(a stale binding, a thumbprint with stray characters). The installer prints the failure but
may still register the task — so you get a task that cannot start. Re-run the installer; if
it fails again, do the `netsh delete` / `netsh add` by hand
([6.5](#65-renewing-or-replacing-the-tls-certificate)) and watch for the error.

**Symptom: clients get a certificate trust error.** The server is fine — the *client* does
not trust the certificate. For a self-signed certificate, either import it into the client's
trusted store or call with `-SkipCertificateCheck`. This is expected behaviour, not a server
fault.

## 7.5 The server is unreachable from another machine

It works when you call `localhost` *on the server*, but a call from another machine times out
or is refused. Work outward, layer by layer.

**Confirm the split first.** On the server itself:

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
```

If that fails too, it is not a network problem — go to [7.2](#72-the-server-will-not-start).
If it works locally but not remotely, continue.

**Cause 1 — the Windows Firewall is blocking the port.** The installer's firewall step is
*optional*, so it is often skipped. From the remote machine:

```powershell
Test-NetConnection -ComputerName posh.example.local -Port 80
```

`TcpTestSucceeded : False` points at the firewall (or a network device in between). On the
server, check for a rule:

```powershell
Get-NetFirewallRule -DisplayName '*PowerShell-Webserver*' -ErrorAction SilentlyContinue
```

If there is none, add one (or re-run the installer and accept the firewall step):

```powershell
New-NetFirewallRule -DisplayName 'PowerShell-Webserver HTTP' -Direction Inbound `
    -Protocol TCP -LocalPort 80 -Action Allow
```

**Cause 2 — the IP filter excludes the caller.** If `AllowedIPs` is non-empty, *only* listed
clients pass; if the caller's IP is in `BlockedIPs`, it is rejected. The request log shows
`IP NOT ALLOWED` or `IP BLOCKED` and the response is 403. Check `config.psd1`:

```powershell
.\Start-WebServer.ps1 -DumpEffectiveConfig | ConvertFrom-Json |
    Select-Object AllowedIPs, BlockedIPs
```

Add the caller's IP (or its CIDR range) to `AllowedIPs`, or remove it from `BlockedIPs`,
and restart.

**Cause 3 — wrong port or protocol.** The caller is using `http://` when the server is
HTTPS-only, or the wrong port. Confirm what the server actually listens on with
`-DumpEffectiveConfig` (`HttpPort`, `HttpsPort`, `HttpsEnabled`).

**Cause 4 — a hostname-bound prefix.** If `Prefixes` is set to specific hostnames rather than
the default `+` wildcard, the server only answers requests to *those* hostnames. A caller
using the IP address, or a different DNS name, gets nothing. Check `Prefixes` in the config.

## 7.6 Authentication failures

The request gets **401 Unauthorized**; the request log shows `UNAUTHORIZED`. The script never
ran — this is gate 6.

**Cause 1 — the header is missing or misspelled.** The header must be exactly `X-Api-Key`.

```powershell
Invoke-RestMethod -Uri 'http://localhost/hello.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' }      # exact name, exact key
```

**Cause 2 — the key value is wrong.** The comparison is **case-sensitive and exact** — every
character must match, including case. Compare what you are sending against what the server
loaded:

```powershell
[Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')   # on the server
```

**Cause 3 — the key was rotated and this client was missed.** After a rotation
([6.4](#64-rotating-the-api-key)), any client still on the old key gets 401. Update the
client, or (if you used the `ApiKeys` map) confirm the old key is still listed during the
migration window.

**Cause 4 — wrong auth mode.** If `AuthMode` is `Basic`, an `X-Api-Key` header is ignored —
the server wants `Authorization: Basic`. If it is `Both`, either works. Check `AuthMode` with
`-DumpEffectiveConfig`.

**Cause 5 — the environment variable is the wrong scope, or the server has not been
restarted.** `POSH_API_KEY` must be **Machine** scope, and the server only reads it at
startup. If you set it after the server started, restart the task.

> **Tip.** Turn on `AuditLogEnabled` ([6.7](#67-reviewing-the-audit-log)) and every
> `AUTH_FAIL` is logged with the client IP and path — invaluable when several clients call
> the same server and you need to know *which one* is failing.

## 7.7 Rate-limit and throttle rejections

The request gets **429 Too Many Requests**. There are *two* mechanisms that return 429, and
telling them apart decides the fix.

**The global throttle** (`MinRequestIntervalSec`, default 1 second). A whole-server minimum
gap between dispatched requests. It is *not* counted in `/metrics` and the request log shows
`GLOBAL THROTTLED`. You hit this by firing requests back-to-back with no delay.

**The per-IP rate limit** (`RateLimitRequests` per `RateLimitWindowSec`, default 100 per 10
minutes). A per-client budget. It *is* counted in `/metrics` (`rateLimitedTotal`) and the
request log shows `RATE LIMITED`. After the *first* time you exceed it, a flat penalty period
(`RateLimitPenaltySec`, default 5 minutes) begins during which **every** request from you is
rejected — so a short burst can lock you out for minutes.

**Tell them apart** by the log status: `GLOBAL THROTTLED` vs `RATE LIMITED`.

**Fixes:**

- **For the throttle:** put a `Start-Sleep -Seconds 1` between calls
  ([2.7](#27-the-one-request-per-second-rule)). If your workload genuinely needs more
  throughput, lower or disable `MinRequestIntervalSec` ([5.4](#54-common-configuration-patterns)).
- **For the rate limit:** wait out the penalty (honour the `Retry-After` header), then call
  more slowly. If the limit is too tight for legitimate traffic, raise `RateLimitRequests` or
  shorten `RateLimitPenaltySec`.
- **Shared NAT / proxy:** if many clients reach the server from one IP, they share one
  budget. Set `RateLimitPerIdentity = $true` so the budget is keyed by API-key label instead
  of IP — give each client its own labelled key in `ApiKeys`.

## 7.8 Endpoints return 500

**500 means the script ran and failed.** The server is healthy; the bug is in the endpoint.
The request log shows `ERROR`.

**Read the `error` field first.** Re-make the call with `-SkipHttpErrorCheck` and look at
`error` — it holds the script's `Write-Error` output and the text of any unhandled exception:

```powershell
$r = Invoke-RestMethod -Uri 'http://localhost/your-endpoint.ps1' `
    -Headers @{ 'X-Api-Key' = 'your-api-key' } -SkipHttpErrorCheck
$r.error
```

**Reproduce it standalone.** Run the script directly on the server with the same parameters
([3.9](#39-testing-and-debugging-an-endpoint)). A standalone run gives you a full PowerShell
error with a line number.

**Common script bugs behind a 500:**

| Bug | Symptom |
|---|---|
| Uncaught exception | The exception text is in `error`. |
| Explicit `exit 1` | `exitCode` is `1` (or whatever the script chose). |
| GET parameter declared `[int]`/`[bool]` instead of `[string]` | Binder error before the script body runs ([3.3](#33-handling-get-parameters)). |
| POST script not handling a missing `-JsonFilePath` | Called via GET, or the body was empty ([3.4](#34-handling-post-bodies)). |
| `ConvertFrom-Json` depth too shallow | Nested fields silently `$null` — raise `-Depth`. |
| Wrong `..\` count in the `globalvars.ps1` dot-source | "file not found" at the dot-source line ([3.6](#36-organizing-endpoints-in-subdirectories)). |
| A module the script needs is not installed for the task's account | "term not recognized". |

**Trace it.** Note the `X-Request-Id`, find the line in the request log, and — for a POST —
open the matching `postjson\` body file to see exactly what the caller sent.

## 7.9 Endpoints time out

**504 means the script ran longer than `ScriptTimeoutSec` (default 300 s) and the server
killed it.** The request log shows `TIMEOUT` and `EXIT:-1`.

**Decide: legitimate long job, or a hang?**

- If the script genuinely needs more than 5 minutes (a big report, a slow remote query),
  raise `ScriptTimeoutSec` ([5.4](#54-common-configuration-patterns)) — but be aware that a
  worker slot is occupied the whole time, so a few slow endpoints can starve `MaxConcurrent`.
- If the script *should* be fast, it is hung — waiting on a prompt, a dead network share, a
  remote call with no timeout of its own. Reproduce it standalone ([3.9](#39-testing-and-debugging-an-endpoint))
  and find the blocking line. Add timeouts to the script's own external calls.

**Better alternatives to a long synchronous call:**

- Make the endpoint *start* the work and return immediately, and let a
  [background job](#68-running-scripts-on-a-schedule) or a separate process do the slow part.
- If it is a batch, accept the whole batch in one POST body rather than one slow call per
  item.

> **Note.** The PHP-CGI handler has its own timeout, `PhpCgiTimeoutSec` (default 60 s), for
> `.php` requests — see [10.4](#104-the-php-cgi-handler).

## 7.10 Capacity and request errors

The remaining status codes, with the quick diagnosis for each.

**503 Service Unavailable — the server is at capacity.** All `MaxConcurrent` worker slots
(default 10) are busy. The request log shows `OVERLOAD`. An occasional 503 under a burst is
normal — the caller should retry. *Constant* 503s mean you are genuinely over capacity: raise
`MaxConcurrent`, or find the slow endpoints holding slots ([7.9](#79-endpoints-time-out)) and
speed them up. Watch peak concurrency in `/metrics`.

**404 Not Found — no matching script.** The status is `NOT FOUND`. Causes, in order: a typo
in the path; the wrong subdirectory; the file really does not exist; or you are relying on a
[path placeholder](#105-path-placeholders) but `PathPlaceholders` is `$false`. List what the
server can actually route with `GET /`.

**405 Method Not Allowed — wrong HTTP method.** Only GET, POST, and OPTIONS are accepted.
Anything else (PUT, DELETE, …) gets 405. Use GET or POST.

**400 Bad Request.** A malformed request: the path is not a recognised script type, the JSON
body is invalid, or — a common one — a **query string was put on a POST**. POST parameters go
in the body, not the URL ([2.3](#23-calling-an-endpoint-with-post)).

**413 Payload Too Large.** The POST body exceeds `MaxRequestBodyBytes` (default 20 MB). Send
less, or raise the limit ([5.4](#54-common-configuration-patterns)).

**415 Unsupported Media Type.** The POST `Content-Type` is not in `AcceptedContentTypes`
(default: `application/json` and `application/x-www-form-urlencoded`). Set the right
`Content-Type` on the request.

## 7.11 Configuration did not take effect

You changed a setting and the server is behaving as if you did not. This is common enough to
have its own section. Work through these in order.

**1. Did you restart the task?** `config.psd1` is read once, at startup. This is the answer
nine times out of ten.

```powershell
Stop-ScheduledTask  -TaskName 'PowerShell-Webserver'
Start-ScheduledTask -TaskName 'PowerShell-Webserver'
```

**2. Did you edit the right file?** The runtime configuration is `config.psd1`. The inline
`$cfg` block inside `Start-WebServer.ps1` is only the *schema/fallback* — editing it is not
how you configure the server. And `globalvars.ps1` is for *endpoints*, not the server.

**3. Is a command-line parameter overriding you?** `-HttpPort`, `-HttpsPort`, and
`-HttpsEnabled` on the scheduled task's action **override `config.psd1`**. If you changed a
port in `config.psd1` but the task passes `-HttpPort` explicitly, the task wins. Change ports
by re-running the installer, or by editing the task's action.

**4. Are you editing the config the server actually loads?** If the task uses `-ConfigFile`
or `-BaseDir`, the active `config.psd1` may not be the one at `C:\posh\config.psd1`.

**Settle it with `-DumpEffectiveConfig`.** This prints the fully-merged configuration the
server *would* use — defaults, plus `config.psd1`, plus CLI overrides:

```powershell
.\Start-WebServer.ps1 -DumpEffectiveConfig | ConvertFrom-Json | Select-Object HttpPort, MaxConcurrent
```

If the value here is wrong, the problem is your edit or the precedence. If it is right but
the *running* server still misbehaves, the running server has not been restarted since the
change.

## 7.12 Diagnostic command reference

A toolbox. Each command answers one question.

| Command | Answers |
|---|---|
| `Get-ScheduledTask -TaskName 'PowerShell-Webserver'` | Is the task registered, and what state is it in? |
| `Get-ScheduledTaskInfo -TaskName 'PowerShell-Webserver'` | When did it last run, and with what result? |
| `Invoke-RestMethod -Uri 'http://localhost/health'` | Is the server alive and listening? |
| `Get-Content C:\posh\logs\startup.log -Tail 30` | Why did the server fail to start? |
| `Get-Content C:\posh\logs\<date>.log -Tail 50` | What happened to recent requests? |
| `.\Start-WebServer.ps1 -DumpEffectiveConfig` | What configuration is actually in effect? |
| `netsh http show sslcert ipport=0.0.0.0:443` | Is the HTTPS certificate binding present and correct? |
| `netsh http show urlacl` | What URL reservations exist? |
| `Test-NetConnection -ComputerName <host> -Port <port>` | Can this machine reach the server's port? |
| `Get-NetFirewallRule -DisplayName '*PowerShell-Webserver*'` | Is the firewall rule present? |
| `Get-NetTCPConnection -LocalPort 80` | What process owns port 80? |
| `[Environment]::GetEnvironmentVariable('POSH_API_KEY','Machine')` | What API key did the server load? |
| `Invoke-ScriptAnalyzer -Path .\webroot\<script>.ps1` | Does an endpoint have static-analysis problems? |
| `$PSVersionTable.PSVersion` | Is this PowerShell 7? |

---

# Part 8. Security hardening

posh is built to be reached over a network, and it authenticates and rate-limits every
request — but it is not, out of the box, a hardened internet-facing service. This part is the
deliberate set of choices that take it from "works" to "appropriately locked down for where
it runs". Several topics here were introduced earlier; this part pulls them together with the
security reasoning attached.

## 8.1 The threat model in plain terms

Be honest about what posh is. It runs your scripts, and those scripts do administrative work,
so the server process runs as a **privileged account**. That makes the server a high-value
target: anyone who can make it run an arbitrary script, or an unintended one, effectively has
those privileges.

**What posh defends against by design:**

- **Unauthenticated callers** — every endpoint requires the API key (or Basic credentials);
  the server will not even start without a key configured.
- **Abusive call rates** — the global throttle and the per-IP rate limiter blunt floods and
  runaway clients.
- **Path traversal** — requests with `..\` or that resolve outside `webroot\`, and symlink /
  junction escapes, are rejected with 403. This cannot be turned off.
- **Oversized requests** — bodies over `MaxRequestBodyBytes` are rejected before they are
  read.
- **Unwanted source IPs** — the optional IP allow/block lists.

**What posh does *not* do for you:**

- It is **not** hardened for the public internet. Keep it on a trusted, segmented network.
- It runs as a **real privileged account**, by necessity — there is no "low-privilege mode".
  Treat the host like any other privileged box.
- It does not vet *what your endpoint scripts do*. A careless endpoint that runs caller input
  as a command is a vulnerability posh cannot catch — that is on the script author
  ([8.6](#86-secret-management-for-endpoints) and the authoring rules in
  [Part 3](#part-3-writing-endpoints)).

**Why the settings editor is a separate, loopback-only tool.** `Edit-PoshSettings.ps1`
deliberately does *not* run inside the main server. It is its own process, bound only to
loopback, token-protected, and self-terminating — because editing configuration is a
higher-trust action than calling an endpoint, and it should not be reachable over the network
at all. That separation is intentional; do not try to expose the editor.

## 8.2 Authentication hardening

**Keep `POSH_API_KEY` only in the machine environment variable.** It is read from there by
design so it never lands in `config.psd1`, the repository, or a backup of either. Do not
"helpfully" copy it into a file.

**Use the `ApiKeys` map — one labelled key per client.** Instead of every caller sharing one
key, give each its own:

```powershell
ApiKeys = @{
    'ci-pipeline'      = 'long-random-key-1'
    'monitoring'       = 'long-random-key-2'
    'helpdesk-tool'    = 'long-random-key-3'
}
```

The benefits compound:

- The matched **label is written into every log line and audit record** — you can see which
  client did what.
- With `RateLimitPerIdentity = $true`, each client gets its *own* rate-limit budget.
- You can **revoke one client** by removing its entry, without disrupting the others.
- Rotation becomes per-client and zero-downtime ([6.4](#64-rotating-the-api-key)).

**Choose `AuthMode` deliberately.** `ApiKey` (the default) is right for machine-to-machine
automation. `Basic` suits a human with a browser. `Both` is convenient but widens the
surface — only use it if you genuinely need both.

**Keep `AuthExemptPaths` minimal.** Every path on that list is reachable with no
authentication at all. The defaults (`/health`, `/metrics`, `/metrics-prom`, `/openapi.json`)
exist so monitoring works; think hard before adding anything else, and never add an endpoint
that *does* something.

## 8.3 Network-level controls

Authentication decides *who* may call. Network controls decide *who may even reach the
server* — a layer in front of authentication.

**IP allow/block lists.** `AllowedIPs`, when non-empty, makes the server answer *only* listed
clients. `BlockedIPs` rejects listed clients outright. Both accept three entry forms:

```powershell
AllowedIPs = @(
    '10.20.0.0/16',          # a CIDR range
    '192.168.1.50',          # a single exact IP
    '~^172\.16\.'            # a regular expression (the leading ~)
)
BlockedIPs = @('203.0.113.7')
```

For a server with a known, small set of legitimate callers, an `AllowedIPs` allowlist is one
of the highest-value hardening steps you can take.

**Open only the firewall ports you actually use.** If the server is HTTPS-only, do not leave
an inbound rule for port 80. If the firewall step was skipped at install, add a *narrow* rule
— specific port, inbound, and ideally scoped to the source subnet.

**Bind to specific hostnames where it makes sense.** By default the server binds with the
`+` wildcard, answering on any hostname or IP that resolves to the box. Setting `Prefixes` to
explicit hostnames makes it answer *only* those — a small reduction in surface for a
multi-homed host.

## 8.4 Transport security

**Prefer HTTPS, and consider HTTPS-only.** Plain HTTP sends the API key in clear text on the
wire. If the network is not fully trusted, enable HTTPS ([4.3](#43-setting-up-https)) and set
`HttpPort = 0` so there is no plain-HTTP listener at all.

**HSTS — turn it on only after HTTPS is proven.** `HstsEnabled = $true` makes the server send
a `Strict-Transport-Security` header, after which browsers *refuse* plain HTTP to that host
for `HstsMaxAgeSec` (default one year):

```powershell
HstsEnabled           = $true
HstsMaxAgeSec         = 31536000        # 1 year
HstsIncludeSubdomains = $false          # only $true if EVERY subdomain is HTTPS
```

> **Warning.** HSTS is sticky. Once a client has cached the policy it will not talk plain
> HTTP to the host until the max-age expires — you cannot quickly "turn HTTPS back off". Only
> enable HSTS once HTTPS is verified working for every client.

**Certificate hygiene.** Track the expiry date and renew ahead of it
([6.5](#65-renewing-or-replacing-the-tls-certificate)). A self-signed certificate is
acceptable internally, but every client must trust it or use `-SkipCertificateCheck` — decide
which, deliberately, rather than leaving callers to discover the trust error.

## 8.5 Rate limiting and abuse protection

The rate limiter and the concurrency cap are also DoS guards. Tune them to your real traffic
rather than leaving the defaults blindly.

- **`RateLimitRequests` / `RateLimitWindowSec` / `RateLimitPenaltySec`** — size the budget to
  what a legitimate client actually needs, then a bit of headroom. A tighter budget catches
  abuse sooner; too tight and you generate false 429s.
- **`RateLimitMode`** — `reject` fails fast; `queue` makes a caller wait out a brief overage
  instead of failing. `reject` is the safer default under attack.
- **`RateLimitPerIdentity = $true`** — essential when clients share a source IP (NAT, a
  proxy); otherwise one noisy client exhausts the budget for all of them.
- **`MaxRequestBodyBytes`** — keep it only as large as your biggest legitimate POST. A small
  cap means a flood of huge bodies is rejected cheaply.
- **`MaxConcurrent`** — the ceiling on simultaneous work. It protects the host from being
  overwhelmed; raising it spends host resources, so raise it from evidence (peak concurrency
  in `/metrics`), not by guessing.

## 8.6 Secret management for endpoints

Endpoints often need credentials. The pattern from
[3.8](#38-using-secrets-in-endpoints) — done with security discipline:

**Generate a unique per-install AES key.** Run `tools\New-PoshAesKey.ps1` once on each
installation. The shipped `globalvars.ps1` has an all-zero placeholder key; a real deployment
must replace it. Two installs must never share a key.

**Never commit a personalised `globalvars.ps1`.** Once `globalvars.ps1` contains a real
`$key`, it is a secret. It is gitignored for exactly this reason — keep it that way. The same
goes for the `encrypted_pw\` folder.

**Store secrets with `Set-PoshSecret.ps1`, decrypt explicitly in the endpoint.** There is no
ambient "secrets are just available" magic — the endpoint decrypts what it needs, when it
needs it, with the in-scope `$key`. Because the ciphertext is only decryptable with that
machine's key, copying the `encrypted_pw\` files elsewhere yields nothing.

**Rotating the encryption key.** If the key may be compromised: generate a new one
(`New-PoshAesKey.ps1`), then re-store every secret (`Set-PoshSecret.ps1` for each label) so
they are re-encrypted under the new key. The old ciphertext files become useless once the key
changes.

**Endpoints must not echo secrets.** A decrypted credential, a token, a connection string —
none of it should appear in `Write-Output`, because `output` goes straight into the response
and the logs.

## 8.7 Auditing and log integrity

**Turn on the audit log.** `AuditLogEnabled = $true` gives you a focused, machine-readable
trail of `AUTH_FAIL`, `IP_BLOCKED`, and `RATE_LIMITED` events ([6.7](#67-reviewing-the-audit-log)).
On any server that matters, this should be on. Review it — or feed the NDJSON into a SIEM.

**Enable log integrity hashes where logs are evidence.** `LogIntegrityHash = $true` writes an
`.md5` companion next to each completed log file at startup, giving tamper-evidence for logs
at rest.

**Use IIS-W3C format for SIEM ingestion.** If a log analyser expects W3C Extended Log Format,
`LogFormat = 'IIS-W3C'` produces it with the `#Fields` header those tools need.

**Watch the slow log.** `SlowRequestThresholdMs` above 0 surfaces unusually slow requests in
`slow.log` — useful operationally, and occasionally the first sign of something abnormal.

## 8.8 Security hardening checklist

Run down this list when you commission a server, and review it periodically.

**Authentication**

- [ ] `POSH_API_KEY` is a long random string, set only as a machine environment variable.
- [ ] Each distinct client has its own labelled key in the `ApiKeys` map.
- [ ] `AuthMode` is the narrowest mode that works (`ApiKey` unless you truly need otherwise).
- [ ] `AuthExemptPaths` contains only monitoring endpoints — nothing that performs an action.
- [ ] An API-key rotation procedure is written down and has been rehearsed.

**Network**

- [ ] The server is on a trusted, segmented network — not reachable from the public internet.
- [ ] `AllowedIPs` is set to the known set of legitimate callers (where that set is knowable).
- [ ] Firewall rules open *only* the port(s) actually in use, scoped as tightly as practical.

**Transport**

- [ ] HTTPS is enabled; `HttpPort = 0` if plain HTTP is not needed.
- [ ] The certificate's expiry is tracked and a renewal procedure exists.
- [ ] HSTS is enabled *only* after HTTPS is confirmed working everywhere.

**Abuse protection**

- [ ] Rate limits are sized to real traffic, not left at blind defaults.
- [ ] `RateLimitPerIdentity = $true` if clients share a source IP.
- [ ] `MaxRequestBodyBytes` is no larger than the biggest legitimate POST.

**Secrets**

- [ ] A unique per-install AES key was generated with `New-PoshAesKey.ps1`.
- [ ] `globalvars.ps1` (with a real key) and `encrypted_pw\` are gitignored and never committed.
- [ ] No endpoint writes a secret into its output.

**Auditing**

- [ ] `AuditLogEnabled = $true`, and the audit log is actually reviewed (or shipped to a SIEM).
- [ ] `LogIntegrityHash = $true` where logs are an audit requirement.

**Host**

- [ ] The account the scheduled task runs as is dedicated, with a strong password and minimum
      necessary rights.
- [ ] The host is patched and monitored like any other privileged server.

---

# Part 9. Full feature catalog

This is the exhaustive list of what the server can do. Each entry says what the feature is,
the `config.psd1` key that controls it, its default, when you would use it, and — where the
feature has more to it — a pointer to the deep-dive in [Part 10](#part-10-advanced-feature-deep-dives).
For the precise type and description of every key, see [Part 11](#part-11-complete-configuration-reference).

## 9.1 Core

The features that make posh what it is. Most are always on.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| URL-to-script routing | *(none — always on)* | — | Maps every `.ps1` in `webroot\` to a URL path. Subfolders become path segments. The foundation of the whole tool ([1.1](#11-the-core-idea-a-file-is-an-endpoint)). |
| GET parameter passing | *(always on)* | — | Query-string `?name=value` pairs become named string arguments to the script ([3.3](#33-handling-get-parameters)). |
| POST body passthrough | `PostJsonDir`, `PostJsonRetentionDays` | `…\postjson`, `30` days | The POST body is written to a file; the script receives the path via `-JsonFilePath` ([2.3](#23-calling-an-endpoint-with-post), [3.4](#34-handling-post-bodies)). |
| JSON response envelope | *(always on for `.ps1`)* | — | `.ps1` output is wrapped as `{ exitCode, output, error }` ([1.4](#14-the-json-envelope-and-request-ids)). |
| Concurrent request handling | `MaxConcurrent`, `RunspacePoolOverprovision`, `RunspacePoolMinSize` | `10`, `2`, `1` | Several requests run in parallel via a RunspacePool; request `MaxConcurrent + 1` gets HTTP 503. |
| Script timeout enforcement | `ScriptTimeoutSec` | `300` | A script running longer than this is killed; the caller gets HTTP 504. |
| Execution mode | `ExecutionMode`, `InjectContextVars` | `Subprocess`, `$false` | `Subprocess` (default) runs each request in a fresh `pwsh.exe` for reliable exit codes and hard timeouts; `InProcess` is faster but gives up isolation → [10.8](#108-execution-modes). |
| Hot reload | *(always on)* | — | New, edited, or deleted webroot scripts take effect on the next request — no restart ([3.1](#31-your-first-endpoint)). |
| Request tracing | *(always on)* | — | Every response carries an `X-Request-Id` that matches the log line and the POST-body filename ([1.4](#14-the-json-envelope-and-request-ids)). |
| Graceful shutdown | *(always on)* | — | On stop, the server stops accepting requests and waits briefly for in-flight ones to finish. |

## 9.2 Authentication and access control

The layers that decide who may reach the server and who may call it. See
[Part 8](#part-8-security-hardening) for how to tune them as a set.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| API-key authentication | `ApiKey` (env: `POSH_API_KEY`) | required | Every request must carry a matching `X-Api-Key` header. The server will not start without a key ([1.5](#15-the-security-model-in-one-page)). |
| Multiple labelled API keys | `ApiKeys` | `@{}` | A label→key map; several keys valid at once, each label flowing into logs and per-key rate limiting ([8.2](#82-authentication-hardening)). |
| HTTP Basic authentication | `AuthMode`, `BasicAuthUser`/`Pass`/`Realm` (env: `POSH_BASIC_USER`/`PASS`) | `AuthMode = 'ApiKey'` | `Basic` or `Both` accept an `Authorization: Basic` header instead of / as well as the API key. |
| Auth-exempt paths | `AuthExemptPaths` | `/health`, `/metrics`, `/metrics-prom`, `/openapi.json` | Paths that skip authentication; their identity is logged as `anonymous`. |
| IP filtering | `AllowedIPs`, `BlockedIPs`, `IpFilterExemptPaths` | `@()`, `@()`, `/health` | Allowlist / blocklist of client IPs — exact, CIDR, or `~regex` ([8.3](#83-network-level-controls)). |
| Per-IP rate limiting | `RateLimitRequests`, `RateLimitWindowSec`, `RateLimitPenaltySec`, `RateLimitMode`, `RateLimitPerIdentity`, `RateLimitExemptPaths`, and more | `100` / `600` s / `300` s / `reject` | A per-client request budget with a flat penalty after the first breach ([2.7](#27-the-one-request-per-second-rule), [7.7](#77-rate-limit-and-throttle-rejections)). |
| Global throttle | `MinRequestIntervalSec`, `GlobalThrottleExemptPaths` | `1` s | A whole-server minimum gap between dispatched requests. |
| Path-traversal protection | *(always on)* | — | Requests resolving outside `webroot\`, including via symlinks/junctions, get HTTP 403. Cannot be disabled. |

## 9.3 Request and response handling

How the server processes bodies and shapes responses.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| Form-urlencoded POST bodies | `AcceptedContentTypes` | includes `application/x-www-form-urlencoded` | Form bodies are parsed, `key[]=` repeats collapsed to arrays, and handed to the script as JSON via `-JsonFilePath` ([3.4](#34-handling-post-bodies)). |
| Body-size cap | `MaxRequestBodyBytes` | `20 MB` | POST bodies larger than this are rejected with HTTP 413 before being read. |
| Content-type gating | `AcceptedContentTypes` | `application/json`, `application/x-www-form-urlencoded` | A POST whose `Content-Type` is not accepted gets HTTP 415. |
| GZIP + Brotli compression | `GzipEnabled`, `BrotliEnabled`, `GzipMinBytes`, `GzipMaxBytes`, `GzipMimeTypes` | both `$true`, `1024`, `10 MB`, text types | Compresses eligible text responses when the client supports it; Brotli is preferred over GZIP. |
| Cookies and sessions | `SessionEnabled`, `SessionCookieName` | `$false`, `POSH-Session-Id` | When on, mints an HttpOnly session cookie and exposes its value to scripts via `POSH_SESSION_ID` → [10.3](#103-sessions-and-cookies). |
| CORS | `CorsAllowedOrigins`, `CorsAllowedMethods`, `CorsAllowedHeaders`, `CorsAllowCredentials`, `CorsMaxAgeSec` | CORS off (`@()`) | Lets a browser app on an allowed origin call the server, including the `OPTIONS` preflight → [10.2](#102-cors-and-browser-clients). |
| Custom HTML error pages | `CustomErrorPages`, `ErrorPagesRoot` | `$false`, `…\webroot\_error` | When the client accepts `text/html`, 4xx/5xx responses serve `<code>.html` instead of the JSON envelope. |
| HSTS | `HstsEnabled`, `HstsMaxAgeSec`, `HstsIncludeSubdomains` | `$false`, `31536000`, `$false` | Sends `Strict-Transport-Security` on HTTPS responses ([8.4](#84-transport-security)). |

## 9.4 Routing and content

Beyond the basic "a `.ps1` file is a URL", these features extend what can be served and how
URLs map to files.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| Alternate script extensions | `ScriptExtensionMap` | `.ps1`, `.psxml`, `.posh`, `.psapi` | `.psxml`/`.posh`/`.psapi` scripts skip the JSON envelope — their stdout is passed through as XML/HTML → [10.10](#1010-alternate-script-extensions). |
| Path placeholders | `PathPlaceholders` | `$false` | Next.js-style `[id].ps1` matches `/users/<anything>`; the captured value arrives as a named argument → [10.5](#105-path-placeholders). |
| Static file serving | `StaticServingEnabled`, `StaticRoot`, `StaticCacheHeaders`, `StaticCacheMaxAgeSec`, `BlockedMimeTypes`, `MimeTypeMap` | `$false` | Serves plain files (HTML/CSS/JS/images) with conditional GET and byte-range support → [10.1](#101-static-file-serving). |
| Directory browsing | `DirectoryBrowsing`, `DirectoryBrowsingHidden` | `$false` | Renders an HTML index when a static directory has no default document. Requires static serving. |
| Default documents | `DefaultDocuments` | `index.html`, `index.htm` | Files served for a directory request when static serving handles it. |
| PHP-CGI handler | `PhpCgiEnabled`, `PhpCgiPath`, `PhpCgiTimeoutSec` | `$false`, `''`, `60` | Routes `.php` files through an external `php-cgi.exe` → [10.4](#104-the-php-cgi-handler). |
| Multi-host prefixes | `Prefixes` | `@()` (= `+` wildcard) | Explicit `HttpListener` prefixes for hostname-bound listeners instead of the wildcard → [10.9](#109-multi-host-and-prefix-binding). |

## 9.5 Discovery and monitoring

Built-in endpoints that describe and report on the server. All are served by the server
itself, not from `webroot\`.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| Endpoint index | `IndexShowMetadata` | `$true` | `GET /` lists every routable script; with metadata on, each entry includes the synopsis and parameters parsed from the script's help ([2.6](#26-the-built-in-endpoints)). |
| Health endpoint | *(always on)* | — | `GET /health` — auth-exempt liveness probe with uptime and request count. |
| JSON metrics | *(always on)* | — | `GET /metrics` — operational counters as JSON; auth-exempt like `/health`. |
| Prometheus metrics | `PromMetricsEnabled` | `$true` | `GET /metrics-prom` — the same counters in Prometheus text format, auth-exempt. |
| OpenAPI specification | `OpenApiEnabled`, `OpenApiTitle`, `OpenApiVersion` | `$true`, `posh`, `1.0.0` | `GET /openapi.json` — an OpenAPI 3.1 spec auto-generated from webroot script metadata → [10.6](#106-openapi-spec-generation). |

## 9.6 Logging and operations

Everything about what the server records and the lifecycle around it.

| Feature | Key(s) | Default | What it does |
|---|---|---|---|
| Request log + rotation | `LogDir`, `LogRetentionDays`, `LogSchedule` | `…\logs`, `180` days, `Daily` | One line per request to a dated file; old files deleted at startup ([6.2](#62-reading-and-understanding-the-logs)). |
| Log format | `LogFormat` | `Native` | `Native` (pipe-delimited, human-readable) or `IIS-W3C` (W3C Extended Log Format for analysers). |
| Log integrity hashes | `LogIntegrityHash` | `$false` | Writes a `.md5` companion next to each completed log file — tamper-evidence for logs at rest. |
| NDJSON audit log | `AuditLogEnabled`, `AuditLogFile`, `AuditLogMaxBytes` | `$false`, `…\audit.log`, `100 MB` | Security events (`AUTH_FAIL`, `IP_BLOCKED`, `RATE_LIMITED`) as one JSON object per line ([6.7](#67-reviewing-the-audit-log)). |
| Slow-request log | `SlowRequestThresholdMs`, `SlowLogFile`, `SlowLogMaxBytes` | `0` (off), `…\slow.log`, `50 MB` | Requests slower than the threshold get an extra line in `slow.log`. |
| Log-mutex tuning | `LogMutexTimeoutMs` | `500` | How long a log write waits for the file lock before dropping the line (and ticking a drop counter). |
| POST-body retention | `PostJsonRetentionDays` | `30` | POST body files in `postjson\` older than this are deleted at startup ([6.6](#66-managing-log-and-post-body-disk-usage)). |
| Background jobs | `BackgroundJobs`, `JobsLogFile`, `JobsLogMaxBytes` | `@()`, `…\jobs.log`, `50 MB` | Scripts run on a recurring interval inside the server, logged to `jobs.log` → [10.7](#107-background-jobs). |
| Scheduled-task lifecycle | *(installer)* | — | `Register-ScheduledTask.ps1` registers an auto-starting Windows task with automatic restart ([4.2](#42-installing-with-register-scheduledtaskps1)). |

---

# Part 10. Advanced feature deep-dives

Part 9 listed every feature briefly. This part takes the ones with real depth and explains
how they work, how to configure them fully, and the gotchas. Read a section here when you are
about to actually use that feature.

## 10.1 Static file serving

By default posh serves *only* scripts — a request for `style.css` gets 400. Turn on
`StaticServingEnabled = $true` and it will also serve plain files (HTML, CSS, JavaScript,
images, fonts, and ~50 other types) from `StaticRoot` (which defaults to `WebRoot`).

**The pipeline for a static request:**

1. The path is resolved within `StaticRoot` — the same path-traversal protection as scripts.
2. If it is a directory, the server looks for a `DefaultDocuments` match (`index.html`,
   `index.htm`); failing that, it renders a directory listing *if* `DirectoryBrowsing` is on,
   otherwise 404.
3. The content type comes from `MimeTypeMap` (extension → MIME type). An extension not in the
   map, or a type matching `BlockedMimeTypes`, gets 403.
4. **Conditional GET**: with `StaticCacheHeaders = $true` the response carries an `ETag` and
   `Last-Modified`. A client that sends `If-None-Match` / `If-Modified-Since` for an unchanged
   file gets a fast **304 Not Modified** with no body.
5. **Cache-Control**: if `StaticCacheMaxAgeSec > 0`, the response also carries
   `Cache-Control: max-age=N` so browsers and CDNs cache the file for that long.
6. **Range requests**: the server honours RFC-7233 byte ranges (including the suffix form
   `bytes=-N`), so large files can be fetched in parts or resumed.
7. **Compression**: eligible text responses are GZIP/Brotli-compressed under the same rules
   as script responses.

**Static files are GET-only** — a POST to a static path gets 405.

```powershell
# config.psd1 — serve a small static site alongside the script endpoints
StaticServingEnabled = $true
StaticCacheHeaders   = $true
StaticCacheMaxAgeSec = 3600          # tell clients to cache assets for an hour
DirectoryBrowsing    = $false        # do not expose folder listings
```

```powershell
# A conditional GET — the second call returns 304 if the file is unchanged
$r1 = Invoke-WebRequest -Uri 'http://localhost/docs/guide.html' -Headers @{ 'X-Api-Key' = 'k' }
Invoke-WebRequest -Uri 'http://localhost/docs/guide.html' -Headers @{
    'X-Api-Key'     = 'k'
    'If-None-Match' = $r1.Headers.ETag
}
```

> **Security.** Turning on static serving makes everything under `StaticRoot` reachable.
> Keep secrets, backups, and `.bak` files out of that tree, set `BlockedMimeTypes` for
> anything you never want served, and leave `DirectoryBrowsing` off unless you specifically
> want folder listings.

## 10.2 CORS and browser clients

Browsers block a web page from calling an API on a different origin unless the API opts in
with **CORS** headers. By default posh sends no CORS headers, so browser apps cannot call it.
To allow a specific web app:

```powershell
CorsAllowedOrigins   = @('https://app.example.local')
CorsAllowedMethods   = 'GET, POST, OPTIONS'
CorsAllowedHeaders   = 'X-Api-Key, Content-Type, Authorization'
CorsAllowCredentials = $false
CorsMaxAgeSec        = 600
```

**The preflight handshake.** For anything beyond a simple request, the browser first sends an
`OPTIONS` request — the *preflight* — asking "may I?". posh answers the preflight directly:
it is handled early, **before** authentication and rate limiting (gate 4 in
[1.3](#13-how-a-request-is-handled) is the method gate, and `OPTIONS` is allowed through to a
CORS responder). The browser then sends the real request, which goes through the normal
gates.

```
   Browser                          posh
   OPTIONS /endpoint  ----------->   "yes: these origins, methods, headers"  (no auth, no script)
   GET /endpoint  + X-Api-Key  -->   normal request — auth, rate limit, script
```

**Origins, methods, headers.** `CorsAllowedOrigins` is the list of web origins allowed to
call the server, or `@('*')` for any origin. `CorsAllowedMethods` and `CorsAllowedHeaders`
populate the matching `Access-Control-Allow-*` response headers.

**Credentials and the wildcard.** Setting `CorsAllowCredentials = $true` lets the browser
send credentials — but the CORS specification forbids combining credentials with the `*`
wildcard. When credentials are on, list explicit origins, not `*`.

## 10.3 Sessions and cookies

posh is **stateless** — it keeps no per-user memory between requests. The session feature is
a thin convenience on top of that, not a stateful session store.

With `SessionEnabled = $true`, when a request arrives *without* a session cookie the server
mints one — an HttpOnly cookie named by `SessionCookieName` (default `POSH-Session-Id`),
marked `Secure` on HTTPS. On every request, the server passes the cookie data to the script
through environment variables:

| Variable | Contents |
|---|---|
| `POSH_SESSION_ID` | The value of the session cookie. |
| `POSH_COOKIES` | The raw `Cookie:` header from the request. |

The shipped `webroot\session.ps1` exists purely to demonstrate this — it reflects both
variables back. A two-call round-trip with `Invoke-RestMethod`'s session support proves the
cookie persists:

```powershell
# First call mints the cookie; -SessionVariable captures it
Invoke-RestMethod -Uri 'http://localhost/session.ps1' `
    -Headers @{ 'X-Api-Key' = 'k' } -SessionVariable s
# Second call sends the same cookie back via -WebSession
Invoke-RestMethod -Uri 'http://localhost/session.ps1' `
    -Headers @{ 'X-Api-Key' = 'k' } -WebSession $s
```

Both responses show the same `sessionId`. **The server itself stores nothing** — if your
endpoints need real server-side session state (a shopping cart, a wizard's progress), they
must persist it themselves, keyed by the session id, in a file or database. posh just keeps
the id flowing.

## 10.4 The PHP-CGI handler

posh can serve `.php` files by handing them to an external PHP CGI binary. It is off by
default and needs two settings:

```powershell
PhpCgiEnabled    = $true
PhpCgiPath       = 'C:\php\php-cgi.exe'   # must exist — the server checks at startup
PhpCgiTimeoutSec = 60                     # a PHP process running longer is killed → 504
```

**How it works.** For a request to a `.php` file, the server builds a CGI/1.1 environment
(the standard `REQUEST_METHOD`, `QUERY_STRING`, `CONTENT_TYPE`, and so on), streams the
request body to the PHP process's standard input, runs `php-cgi.exe`, and parses the
`Status`, `Content-Type`, and `Location` headers out of PHP's output to build the HTTP
response. The PHP output is sent to the client as-is — there is no JSON envelope.

**Security restrictions.** The handler refuses to serve a `.php` file from inside the
`\Windows\` directory tree. If `php-cgi.exe` disappears or fails to launch, the request gets
a structured 502 rather than a confusing hang.

**Validation.** When `PhpCgiEnabled = $true`, the server checks at startup that `PhpCgiPath`
points at a real file and exits if it does not — so a misconfigured PHP path is a startup
failure, not a per-request surprise.

> **Note.** PHP support exists for compatibility with mixed script estates. If you only have
> PowerShell endpoints, leave it off — it is one less moving part and one less external
> binary to keep patched.

## 10.5 Path placeholders

By default, routing is exact: `/users/123` needs a literal file `webroot\users\123.ps1`.
**Path placeholders** add REST-style parameterised routes — turn them on with
`PathPlaceholders = $true`.

A filename segment in square brackets is a placeholder. The shipped
`webroot\users\[id].ps1` matches any single segment under `/users/`:

```
   GET /users/123         ->  runs [id].ps1 with  -id '123'
   GET /users/anna.smith  ->  runs [id].ps1 with  -id 'anna.smith'
```

The captured value arrives as a named argument, exactly as if it had been a query-string
parameter. A route can have **several** placeholders — `webroot\api\[version]\users\[id].ps1`
matches `/api/v2/users/42` with `-version 'v2' -id '42'`.

**Routing priority.** When more than one route could match, the server picks the most
specific:

```
   1. an exact filename match          (webroot\users\admin.ps1  ->  /users/admin)
   2. a placeholder match              (webroot\users\[id].ps1   ->  /users/<anything else>)
   3. a directory listing              (if DirectoryBrowsing is on)
   4. 404
```

The shipped `webroot\users\admin.ps1` exists to demonstrate rule 1: `/users/admin` is served
by the *exact* file, while `/users/42` falls through to the `[id].ps1` placeholder. This lets
you give well-known cases a dedicated handler while a generic parameterised route covers the
rest. When several placeholder routes could match, the one with **fewer** placeholders (more
literal segments) wins.

**A placeholder endpoint must validate its input.** The captured segment is whatever the URL
contained. The shipped `[id].ps1` shows the discipline — it rejects anything outside a tight
character set before using the value:

```powershell
if ($id -notmatch '^[A-Za-z0-9._-]{1,64}$') {
    Write-Error "Invalid user id format: '$id'"
    exit 1
}
```

> **Note.** The route table for placeholders is cached. Adding or removing a top-level
> subdirectory under `webroot\` is picked up automatically, but adding placeholder files
> deeper in the tree may need a server restart to be seen.

## 10.6 OpenAPI spec generation

`GET /openapi.json` returns a complete **OpenAPI 3.1** specification, generated on the fly
from your webroot scripts — no hand-written spec to maintain. It is on by default
(`OpenApiEnabled = $true`) and auth-exempt.

**What gets generated.** For every routable script, the server reads the comment-based help
block and the `param()` block and produces:

- A path entry (placeholder routes become OpenAPI `{name}` path parameters).
- The `.SYNOPSIS` and `.DESCRIPTION` as the operation summary and description.
- Each `param()` parameter, with its name and a type mapped from the PowerShell type.
- The `{ exitCode, output, error }` envelope as the response schema.

`OpenApiTitle` and `OpenApiVersion` set the spec's `info.title` and `info.version`.

```powershell
# List every path the server documents
(Invoke-RestMethod -Uri 'http://localhost/openapi.json').paths.PSObject.Properties.Name
```

Import the spec URL into Swagger UI, Postman, Insomnia, or an API gateway and you get a
browsable, typed catalog of the whole server — which is the concrete payoff for writing good
comment-based help in every endpoint ([3.2](#32-the-anatomy-of-a-good-endpoint-script)).

## 10.7 Background jobs

Background jobs run scripts on a timer *inside* the server, with no HTTP request involved.
Configure them as an array in `config.psd1`:

```powershell
BackgroundJobs = @(
    @{ Path = 'C:\posh\jobs\refresh-cache.ps1';  IntervalSec = 300 }
    @{ Path = 'C:\posh\jobs\nightly-report.ps1'; IntervalSec = 86400 }
)
JobsLogFile    = ''          # empty = <LogDir>\jobs.log
JobsLogMaxBytes = 52428800   # rotate jobs.log past 50 MB at startup
```

**Isolation and logging.** Each job runs in its own background runspace and (under the
default `Subprocess` execution mode) its own `pwsh.exe` child process — the same isolation as
a request-handling script. A job cannot interfere with request handling or with another job.
All job output goes to `JobsLogFile` (default `logs\jobs.log`), since there is no caller to
return it to.

**Shutdown behaviour.** When the server shuts down gracefully, its background jobs are stopped
with it. A job is not guaranteed to finish its current run on shutdown, so write jobs to be
safe if interrupted.

**Background job vs Windows scheduled task — choosing.** A background job is convenient: it
lives with the server, shares its configuration, and needs no separate registration. But a
separate Windows scheduled task is *independent* — it survives a posh restart, runs even when
posh is stopped, and is visible in Task Scheduler where other admins look for scheduled work.
Use a background job for work tightly coupled to the server (refreshing something the
endpoints use); use a Windows task for anything that should run regardless of posh.

## 10.8 Execution modes

`ExecutionMode` decides *how* the server runs your endpoint scripts. It has two values, and
the default is the right choice for almost everyone.

**`Subprocess` (default).** Every request runs in a brand-new `pwsh.exe` child process.

- **Reliable exit codes** — the child process's real exit code becomes the envelope's
  `exitCode`, so the 200-vs-500 decision is always correct.
- **Hard timeouts** — the server can `Kill()` the process when it exceeds `ScriptTimeoutSec`.
- **Full isolation** — one request cannot leak variables, modules, or state into another.
- **Cost** — a few hundred milliseconds of process-startup time per request.

**`InProcess`.** Requests run inside the server's own runspaces, with no child process.

- **Faster** — it saves the process-startup overhead.
- **Best-effort exit codes only** — without a real process, the exit code can be inferred
  only from exceptions; a script that `exit 1`s without throwing may not be seen as failed.
- **Weaker timeouts** — stopping a runspace does not reliably interrupt a script blocked in a
  native call.
- **State can leak** — modules and variables can carry between requests.
- When `InjectContextVars = $true`, InProcess mode also exposes `$PoSHQuery`, `$PoSHPost`,
  `$PoSHCookies`, and `$PoSHHeaders` to scripts, for compatibility with the older PoSH Server
  project's conventions.

**Why `Subprocess` stays the default.** For automation traffic, reliable exit codes and hard
timeouts matter far more than shaving a few hundred milliseconds. Only switch to `InProcess`
if you have measured a real latency problem *and* you understand that you are trading away
isolation and exit-code reliability to fix it.

> **Note.** The shipped `webroot\api-status.psxml` handles both modes — it checks whether the
> server-injected `ConvertTo-PoshApiXml` helper exists (it does only in `InProcess` mode) and
> falls back to building the XML by hand under `Subprocess`. It is a good model for an
> endpoint that must work either way.

## 10.9 Multi-host and prefix binding

By default the server builds its listener prefixes from `HttpPort` / `HttpsPort` using the
`+` **wildcard** — it answers on any hostname or IP that resolves to the machine, on those
ports.

`Prefixes` overrides that with an explicit list of `HttpListener` URL prefixes:

```powershell
Prefixes = @(
    'https://api.example.local:443/'
    'http://api.example.local:80/'
    'http://localhost:80/'
)
```

With explicit prefixes the server answers **only** requests whose host and port match an
entry — useful on a multi-homed host, or when you want the server reachable by one DNS name
only.

**The rules for a prefix:** each entry must start with `http://` or `https://`, must end with
a trailing `/`, and the list must contain no duplicates. The server validates this at startup
and exits with a clear error if a prefix is malformed.

> **Note.** Explicit hostname-bound prefixes can require a matching URL ACL reservation on
> the host (`netsh http show urlacl`). The `+` wildcard avoids that — which is why it is the
> default — at the cost of being less specific.

## 10.10 Alternate script extensions

Most endpoints are `.ps1` and get the JSON envelope. Three other extensions are recognised,
and they behave differently: their script's standard output is sent back **verbatim**, with a
content type, and **no envelope**. The mapping lives in `ScriptExtensionMap`:

| Extension | Content type | Use for |
|---|---|---|
| `.ps1` | *(envelope)* | Normal endpoints — `{ exitCode, output, error }`. |
| `.psxml` | `text/xml; charset=utf-8` | An endpoint that must return raw XML. |
| `.posh` | `text/html; charset=utf-8` | An endpoint that must return raw HTML. |
| `.psapi` | `application/xml; charset=utf-8` | Legacy "API" XML endpoints (PoSH Server compatibility). |

A `.psxml`/`.posh`/`.psapi` script is still an ordinary PowerShell script with comment-based
help and a `param()` block — it still appears in `GET /` and `/openapi.json` — it just owns
its entire response body. Whatever it writes to stdout *is* the HTTP body.

The shipped `webroot\api-status.psxml` is the worked example: it builds an XML document and
writes it to stdout, and the client receives that XML directly with a `text/xml` content
type.

```powershell
$resp = Invoke-WebRequest -Uri 'http://localhost/api-status.psxml' `
    -Headers @{ 'X-Api-Key' = 'k' }
[xml] $doc = $resp.Content          # the body IS XML, not an envelope
$doc.Result.Items.Item
```

You can add your own extension to `ScriptExtensionMap` with a content type — for example a
`.psjson` that returns raw JSON without the envelope — though for most needs the four built-in
extensions are enough.

---

# Part 11. Complete configuration reference

Every command-line parameter and every `config.psd1` key, with type, default, and a full
description. This is the lookup section — for the *why* and the *how to use*, follow the
cross-references back into Parts 5–10.

## 11.1 Command-line parameters

Parameters of `Start-WebServer.ps1`. They override `config.psd1`. The scheduled task passes
the port/HTTPS parameters automatically.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-HttpsEnabled` | switch | off | Enable the HTTPS listener. Requires a `netsh sslcert` binding for `HttpsPort` to exist before startup, or the server exits. |
| `-HttpPort` | int (0–65535) | `80` | HTTP listen port. `0` disables the HTTP listener entirely (use with `-HttpsEnabled` for HTTPS-only). |
| `-HttpsPort` | int (1–65535) | `443` | HTTPS listen port. Only evaluated when `-HttpsEnabled` is present. |
| `-BaseDir` | string | `C:\posh` | Base directory for all runtime artefacts. `WebRoot`, `LogDir`, `PostJsonDir` default to subfolders of it. Override for multi-instance or non-default installs. |
| `-ConfigFile` | string | `<BaseDir>\config.psd1` | Explicit path to the runtime `config.psd1`. The file is mandatory — the server exits if it does not exist. |
| `-DumpConfig` | switch | off | Print the inline `$cfg` defaults (after derived-field fallbacks), as JSON, and exit. Secrets are redacted. Used internally by `Initialize-PoshConfig.ps1`. Skips the API-key and config-file checks. |
| `-DumpEffectiveConfig` | switch | off | Print the *effective* configuration — inline defaults merged with `config.psd1` and CLI overrides — as JSON, and exit. The definitive "what is in effect" check. Still requires `config.psd1`. |

## 11.2 config.psd1 keys

Every key, grouped in the same order `tools\Initialize-PoshConfig.ps1` writes them. Sizes
written `20MB` are shown as PowerShell understands them; in `config.psd1` they appear as the
byte number (`20MB` = `20971520`).

> **Note.** Three keys — `ApiKey`, `BasicAuthUser`, `BasicAuthPass` — are *not* written into
> `config.psd1` by the generator. They come from environment variables (`POSH_API_KEY`,
> `POSH_BASIC_USER`, `POSH_BASIC_PASS`). `PwshExe` is also omitted — it is auto-derived from
> the running process at startup. They are listed here because they are part of the
> configuration model, but you set them as environment variables ([5.5](#55-environment-variables)),
> not in the file.

### HTTP / HTTPS endpoints

| Key | Type | Default | Description |
|---|---|---|---|
| `HttpsEnabled` | bool | `$false` | Whether the HTTPS listener is active. |
| `HttpPort` | int | `80` | HTTP listen port; `0` = HTTP disabled. |
| `HttpsPort` | int | `443` | HTTPS listen port; only relevant when `HttpsEnabled`. |
| `Prefixes` | string[] | `@()` | Explicit `HttpListener` prefixes (e.g. `'http://api.example.com:80/'`). Empty = build from the ports with the `+` wildcard. Each must start with `http(s)://` and end with `/`. See [10.9](#109-multi-host-and-prefix-binding). |

### Filesystem paths

| Key | Type | Default | Description |
|---|---|---|---|
| `WebRoot` | string | `<BaseDir>\webroot` | Directory holding the `.ps1` endpoint scripts. |
| `LogDir` | string | `<BaseDir>\logs` | Directory for all log files. |
| `PwshExe` | string | *(auto-derived)* | Absolute path to `pwsh.exe`. Auto-derived from the running process; not written to `config.psd1`. |
| `PostJsonDir` | string | `<BaseDir>\postjson` | Directory where POST request bodies are stored as files. |
| `PostJsonRetentionDays` | int | `30` | POST body files older than this are deleted at startup; `0` = disabled. |

### Authentication

| Key | Type | Default | Description |
|---|---|---|---|
| `ApiKey` | string | *(env `POSH_API_KEY`)* | The legacy single API key, read from the environment. Auto-merged into `ApiKeys` under the label `default` when `ApiKeys` is empty. Not written to `config.psd1`. |
| `ApiKeys` | hashtable | `@{}` | Multi-key map of label → key. Populate in `config.psd1`: `@{ 'ci' = 'k1'; 'mon' = 'k2' }`. The matched label flows into logs and per-key rate limiting. |
| `AuthMode` | string | `'ApiKey'` | `'ApiKey'`, `'Basic'`, or `'Both'`. `'Both'` accepts the `X-Api-Key` header *or* a valid `Authorization: Basic` header. |
| `BasicAuthUser` | string | *(env `POSH_BASIC_USER`)* | Username for Basic auth. Validated at startup only when `AuthMode` requires Basic. Not written to `config.psd1`. |
| `BasicAuthPass` | string | *(env `POSH_BASIC_PASS`)* | Password for Basic auth. Kept in process memory only. Not written to `config.psd1`. |
| `BasicAuthRealm` | string | `'posh'` | The `realm` value in the `WWW-Authenticate` header on 401 responses. |

### Script execution

| Key | Type | Default | Description |
|---|---|---|---|
| `ExecutionMode` | string | `'Subprocess'` | `'Subprocess'` (default — a fresh `pwsh.exe` per request, reliable exit codes and timeouts) or `'InProcess'` (faster, no isolation). See [10.8](#108-execution-modes). |
| `InjectContextVars` | bool | `$false` | In `InProcess` mode, expose `$PoSHQuery` / `$PoSHPost` / `$PoSHCookies` / `$PoSHHeaders` to scripts (legacy PoSH Server compatibility). |
| `ScriptTimeoutSec` | int | `300` | Seconds a script may run before it is terminated and the caller gets HTTP 504. |
| `MaxConcurrent` | int | `10` | Maximum parallel requests; excess requests get HTTP 503. |
| `RunspacePoolOverprovision` | int | `2` | Multiplier for the RunspacePool's max size relative to `MaxConcurrent`. Absorbs the gap between releasing a slot and disposing the runspace. Recommended 2–4. |
| `MaxRequestBodyBytes` | int | `20MB` | Maximum POST body size in bytes; larger requests get HTTP 413. |
| `AcceptedContentTypes` | string[] | `@('application/json', 'application/x-www-form-urlencoded')` | POST body content types that pass the body-parsing gate; anything else gets HTTP 415. An empty list accepts all parsed types. |
| `ScriptExtensionMap` | hashtable | `.ps1`=`''`, `.psxml`=`text/xml; charset=utf-8`, `.posh`=`text/html; charset=utf-8`, `.psapi`=`application/xml; charset=utf-8` | Recognised webroot extensions and their response content type. An empty value (`.ps1`) means "use the JSON envelope". See [10.10](#1010-alternate-script-extensions). |

### Rate limiting

| Key | Type | Default | Description |
|---|---|---|---|
| `RateLimitRequests` | int | `100` | Maximum requests per IP per window; excess gets HTTP 429. `0` = rate limiting disabled. |
| `RateLimitWindowSec` | int | `600` | Fixed window size in seconds (10 minutes). |
| `RateLimitPenaltySec` | int | `300` | Penalty duration in seconds after the first 429 in a window (5 minutes) — every request during the penalty is rejected. |
| `RateLimitMode` | string | `'reject'` | `'reject'` = immediate HTTP 429; `'queue'` = wait up to `RateLimitQueueTimeoutSec` for the limit to clear. |
| `RateLimitPerIdentity` | bool | `$false` | Key the rate-limit table by API-key label (when authenticated) instead of by client IP. Anonymous/exempt requests stay keyed by IP. |
| `RateLimitQueueTimeoutSec` | int | `10` | `queue` mode only: seconds to wait before returning HTTP 429. |
| `RateLimitQueuePollMs` | int | `200` | `queue` mode only: re-check interval while waiting. |
| `RateLimitExemptPaths` | string[] | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | Paths excluded from rate limiting. |
| `RateLimitSweepIntervalSec` | int | `60` | How often the main loop sweeps stale entries from the rate-limit table; `0` = disabled (the table grows unbounded). |
| `RateLimitTableSizeWarnThreshold` | int | `100000` | Log a WARN when the rate-limit table grows past this size; `0` = disabled. |
| `MinRequestIntervalSec` | int | `1` | The global throttle — minimum seconds between dispatched requests, server-wide; `0` = disabled. See [2.7](#27-the-one-request-per-second-rule). |

### IP filtering

| Key | Type | Default | Description |
|---|---|---|---|
| `AllowedIPs` | string[] | `@()` | IP allowlist. Empty = all IPs allowed; non-empty = only listed IPs pass. Entries may be exact IPs, CIDR ranges, or `~`-prefixed regular expressions. |
| `BlockedIPs` | string[] | `@()` | IP blocklist — listed IPs are rejected with HTTP 403, before the `AllowedIPs` check. Same entry forms as `AllowedIPs`. |

### Logging

| Key | Type | Default | Description |
|---|---|---|---|
| `LogRetentionDays` | int | `180` | Dated request logs older than this are deleted at startup; `0` = disabled. Single-file logs (audit/slow/jobs/startup) are exempt — they rotate by size. |
| `LogIntegrityHash` | bool | `$false` | Write a `<logfile>.md5` next to every completed log file at startup. The current day's file is left alone. |
| `LogSchedule` | string | `'Daily'` | `'Daily'` = one `YYYY-MM-DD.log` per day; `'Hourly'` = one `YYYY-MM-DDTHH.log` per hour. |
| `LogFormat` | string | `'Native'` | `'Native'` = pipe-delimited; `'IIS-W3C'` = W3C Extended Log Format with a `#Fields` header. |
| `LogMutexTimeoutMs` | int | `500` | Max milliseconds a log write waits for the file lock; on timeout the line is dropped and a drop counter ticks. |
| `AuditLogEnabled` | bool | `$false` | Write security events (`AUTH_FAIL`, `IP_BLOCKED`, `RATE_LIMITED`) as NDJSON to `AuditLogFile`. See [6.7](#67-reviewing-the-audit-log). |
| `AuditLogFile` | string | `<LogDir>\audit.log` | Absolute path to the audit log. Empty = the default under `LogDir`. |
| `AuditLogMaxBytes` | int | `100MB` | At startup, an `audit.log` larger than this is rotated; `0` = disabled. |
| `SlowRequestThresholdMs` | int | `0` | Requests at least this many milliseconds long get an extra line in `SlowLogFile`. `0` = the slow log is disabled. |
| `SlowLogFile` | string | `<LogDir>\slow.log` | Absolute path to the slow-request log. Empty = the default under `LogDir`. |
| `SlowLogMaxBytes` | int | `50MB` | At startup, a `slow.log` larger than this is rotated; `0` = disabled. |

### Compression

| Key | Type | Default | Description |
|---|---|---|---|
| `GzipEnabled` | bool | `$true` | GZIP response compression, when the client sent `Accept-Encoding: gzip`, the body is at least `GzipMinBytes`, and the content type matches `GzipMimeTypes`. |
| `BrotliEnabled` | bool | `$true` | Brotli compression — preferred over GZIP when the client supports both. Uses the same eligibility gates. |
| `GzipMinBytes` | int | `1024` | Responses smaller than this are never compressed (the overhead would exceed the saving). |
| `GzipMaxBytes` | int | `10MB` | Responses larger than this are streamed uncompressed rather than buffered for compression — guards against memory spikes. |
| `GzipMimeTypes` | string[] | `application/json`, `application/xml`, `application/javascript`, `text/html`, `text/plain`, `text/css`, `text/javascript`, `text/xml` | Response content types eligible for compression (matched by prefix). |

### Static serving

| Key | Type | Default | Description |
|---|---|---|---|
| `StaticServingEnabled` | bool | `$false` | Serve non-`.ps1` files (HTML, CSS, JS, images, …) from `StaticRoot`. Off by default — posh is script-only out of the box. See [10.1](#101-static-file-serving). |
| `StaticRoot` | string | *(= `WebRoot`)* | Root directory for static files. Empty = use `WebRoot`. |
| `DefaultDocuments` | string[] | `@('index.html', 'index.htm')` | Files served for a directory request when static serving handles it. |
| `StaticCacheHeaders` | bool | `$true` | Emit `ETag` + `Last-Modified` on static responses and honour `If-None-Match` / `If-Modified-Since` with HTTP 304. |
| `StaticCacheMaxAgeSec` | int | `0` | When `> 0`, also emit `Cache-Control: max-age=N` on static responses. `0` = no `Cache-Control`. |
| `BlockedMimeTypes` | string[] | `@()` | MIME-type blacklist for static responses (matched by prefix); a match gets HTTP 403. |
| `MimeTypeMap` | hashtable | ~50 entries | Extension → content type for static files. Extensions are lowercased with a leading dot; comparison is case-insensitive. |

### Sessions and cookies

| Key | Type | Default | Description |
|---|---|---|---|
| `SessionEnabled` | bool | `$false` | Mint an HttpOnly session cookie when a request arrives without one; the value is passed to scripts via the `POSH_SESSION_ID` environment variable. See [10.3](#103-sessions-and-cookies). |
| `SessionCookieName` | string | `'POSH-Session-Id'` | The name of the session cookie. |

### CORS

| Key | Type | Default | Description |
|---|---|---|---|
| `CorsAllowedOrigins` | string[] | `@()` | Allowed `Origin` values, or `@('*')` for any origin. Empty = CORS disabled. See [10.2](#102-cors-and-browser-clients). |
| `CorsAllowedMethods` | string | `'GET, POST, OPTIONS'` | The `Access-Control-Allow-Methods` header value. |
| `CorsAllowedHeaders` | string | `'X-Api-Key, Content-Type, Authorization'` | The `Access-Control-Allow-Headers` header value. |
| `CorsAllowCredentials` | bool | `$false` | Send `Access-Control-Allow-Credentials: true` for an allowed origin. Incompatible with the `*` wildcard per the CORS spec. |
| `CorsMaxAgeSec` | int | `600` | The `Access-Control-Max-Age` value on preflight responses — how long a browser may cache the preflight result. |

### PHP CGI

| Key | Type | Default | Description |
|---|---|---|---|
| `PhpCgiEnabled` | bool | `$false` | Serve `.php` files via an external PHP CGI binary. See [10.4](#104-the-php-cgi-handler). |
| `PhpCgiPath` | string | `''` | Absolute path to `php-cgi.exe`. Required (and checked at startup) when `PhpCgiEnabled` is `$true`. |
| `PhpCgiTimeoutSec` | int | `60` | Max seconds a PHP-CGI process may run before it is killed and HTTP 504 is returned. |

### Custom error pages

| Key | Type | Default | Description |
|---|---|---|---|
| `CustomErrorPages` | bool | `$false` | Render `<ErrorPagesRoot>\<code>.html` instead of the JSON envelope for 4xx/5xx — only when the client accepts `text/html`. |
| `ErrorPagesRoot` | string | *(= `<WebRoot>\_error`)* | Directory containing `401.html`, `403.html`, `404.html`, etc. Empty = the default under `WebRoot`. |

### Background jobs

| Key | Type | Default | Description |
|---|---|---|---|
| `BackgroundJobs` | hashtable[] | `@()` | Array of `@{ Path = '<absolute>'; IntervalSec = 300 }` — each runs on its interval in its own background runspace. See [10.7](#107-background-jobs). |
| `JobsLogFile` | string | `<LogDir>\jobs.log` | Absolute path to the background-jobs log. Empty = the default under `LogDir`. |
| `JobsLogMaxBytes` | int | `50MB` | At startup, a `jobs.log` larger than this is rotated; `0` = disabled. |

### Directory browsing

| Key | Type | Default | Description |
|---|---|---|---|
| `DirectoryBrowsing` | bool | `$false` | Render an HTML index listing when a static directory has no `DefaultDocuments` match. Requires `StaticServingEnabled`. |
| `DirectoryBrowsingHidden` | string[] | `@('_error', '.git', '.gitignore')` | File/folder names hidden from the directory listing (case-insensitive match). |

### Discovery and metadata

| Key | Type | Default | Description |
|---|---|---|---|
| `IndexShowMetadata` | bool | `$true` | `GET /` returns enriched objects with synopsis and parameters parsed from each script's help. `$false` = a flat path list. |
| `PromMetricsEnabled` | bool | `$true` | Expose `GET /metrics-prom` in Prometheus text format, with the same auth-exempt treatment as `/metrics`. |
| `PathPlaceholders` | bool | `$false` | Match `webroot/users/[id].ps1` against `/users/<anything>`; captured values arrive as named arguments. See [10.5](#105-path-placeholders). |
| `OpenApiEnabled` | bool | `$true` | Expose `GET /openapi.json` with an auto-generated OpenAPI 3.1 spec. See [10.6](#106-openapi-spec-generation). |
| `OpenApiTitle` | string | `'posh'` | The `info.title` field in the OpenAPI spec. |
| `OpenApiVersion` | string | `'1.0.0'` | The `info.version` field in the OpenAPI spec. |

### Other keys

These keys are not placed in a named group by the config generator — they appear under an
"Other" section at the end of `config.psd1`.

| Key | Type | Default | Description |
|---|---|---|---|
| `RunspacePoolMinSize` | int | `1` | Minimum pre-warmed runspaces. `1` accepts a ~150 ms cold-start for the first requests; raise toward `MaxConcurrent` when first-request latency matters more than idle memory. |
| `AuthExemptPaths` | string[] | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | Paths that skip authentication entirely; their identity is logged as `anonymous`. |
| `GlobalThrottleExemptPaths` | string[] | `@('/health', '/metrics', '/metrics-prom', '/openapi.json')` | Paths exempt from the `MinRequestIntervalSec` global throttle. |
| `IpFilterExemptPaths` | string[] | `@('/health')` | Paths that bypass the `BlockedIPs` / `AllowedIPs` checks — keeps `/health` reachable from external monitoring. |
| `StaticCacheMaxAgeSec` | int | `0` | Duplicate listing for completeness — see *Static serving* above. |
| `HstsEnabled` | bool | `$false` | Emit `Strict-Transport-Security` on HTTPS responses. Only enable once HTTPS is verified — see [8.4](#84-transport-security). |
| `HstsMaxAgeSec` | int | `31536000` | The HSTS `max-age` in seconds — 1 year, the recommended baseline. |
| `HstsIncludeSubdomains` | bool | `$false` | Add the `includeSubDomains` directive. Only enable when *every* subdomain serves HTTPS. |

## 11.3 An annotated example config.psd1

A realistic non-default `config.psd1` for an internal automation server — HTTPS-only,
locked to a subnet, with per-client keys and the audit log on. Comments explain the
non-obvious choices.

```powershell
@{
    # -- HTTP / HTTPS endpoints --------------------------------------------
    HttpsEnabled = $true
    HttpPort     = 0            # HTTPS-only — no plain-HTTP listener at all
    HttpsPort    = 443
    Prefixes     = @()          # default + wildcard binding

    # -- Authentication ---------------------------------------------------
    ApiKeys  = @{               # one labelled key per client — labels show in the logs
        'ci'         = 'REPLACE-with-a-long-random-key'
        'monitoring' = 'REPLACE-with-a-long-random-key'
    }
    AuthMode = 'ApiKey'

    # -- Script execution -------------------------------------------------
    ScriptTimeoutSec = 600      # some reports legitimately take >5 min
    MaxConcurrent    = 15

    # -- Rate limiting ----------------------------------------------------
    RateLimitRequests    = 300  # higher budget — the CI pipeline is chatty
    RateLimitPerIdentity = $true # clients share a NAT IP — bill per key, not per IP
    MinRequestIntervalSec = 1

    # -- IP filtering -----------------------------------------------------
    AllowedIPs = @('10.20.0.0/16')   # only the automation subnet may connect

    # -- Logging ----------------------------------------------------------
    LogRetentionDays = 365
    AuditLogEnabled  = $true    # security event trail on
    LogIntegrityHash = $true

    # -- HSTS (Other) -----------------------------------------------------
    HstsEnabled = $true         # safe: this server has been HTTPS-only and verified
}
```

Any key not listed falls back to its inline default — you only need to put the keys you are
*changing* in `config.psd1`, though the generator writes them all out for visibility.

## 11.4 Register-ScheduledTask.ps1 hardcoded values

A few values inside `Register-ScheduledTask.ps1` are fixed, not prompted. Knowing them helps
when you inspect the task or the `netsh` binding by hand.

| Value | Setting |
|---|---|
| Scheduled task name | `PowerShell-Webserver` |
| Server script | `<BaseDir>\Start-WebServer.ps1` |
| Working directory | `<BaseDir>` (default `C:\posh`) |
| Application GUID (`appid` of the `netsh sslcert` binding) | `a3b2c1d0-4e5f-6a7b-8c9d-0e1f2a3b4c5d` |
| Automatic restart count | `3` |
| Automatic restart interval | `PT1M` (1 minute) |
| Trigger | At system startup |
| Run level | Highest (elevated) |

The task name `PowerShell-Webserver` is what you pass to every `*-ScheduledTask` cmdlet
throughout this handbook.

---

# Appendix A. Glossary

| Term | Definition |
|---|---|
| **alternate extension** | A webroot script ending in `.psxml`, `.posh`, or `.psapi` instead of `.ps1`. Its output is returned raw (as XML/HTML) instead of in the JSON envelope. See [10.10](#1010-alternate-script-extensions). |
| **API key** | The secret a caller sends in the `X-Api-Key` header to authenticate. Stored in the `POSH_API_KEY` environment variable on the server. |
| **`ApiKeys` map** | A `config.psd1` table of label → key, allowing several valid keys at once, each labelled in the logs. |
| **audit log** | An optional NDJSON file (`logs\audit.log`) recording security events — auth failures, IP blocks, rate-limit hits. |
| **Basic auth** | HTTP Basic authentication — username and password in an `Authorization` header. An alternative to the API key, selected with `AuthMode`. |
| **`BaseDir`** | The install root, `C:\posh` by default. All runtime folders are derived from it. |
| **CGI** | Common Gateway Interface — the contract posh uses to run `.php` files through an external `php-cgi.exe`. |
| **CIDR** | A notation for an IP range, e.g. `10.20.0.0/16`. Accepted in `AllowedIPs` / `BlockedIPs`. |
| **comment-based help** | The `<# .SYNOPSIS ... #>` block at the top of a script. posh parses it to build the `GET /` index and the OpenAPI spec. |
| **`config.psd1`** | The runtime configuration file — the source of truth for server settings. Mandatory; the server will not start without it. |
| **endpoint** | A webroot script reachable as a URL. "Endpoint" and "webroot script" mean the same thing. |
| **envelope** | The `{ exitCode, output, error }` JSON object that wraps a `.ps1` endpoint's result. |
| **exempt path** | A URL path that skips a check — `AuthExemptPaths` skip authentication, `RateLimitExemptPaths` skip rate limiting, and so on. |
| **exit code** | The numeric result of a script (`exit 0`, `exit 1`). `0` → HTTP 200; non-zero → HTTP 500. |
| **gate** | One of the ordered checks every request passes through (IP filter, throttle, concurrency, method, rate limit, auth, routing). See [1.3](#13-how-a-request-is-handled). |
| **global throttle** | The server-wide minimum interval between dispatched requests, set by `MinRequestIntervalSec`. |
| **`globalvars.ps1`** | The shared configuration file that *endpoint scripts* dot-source — server names, paths, the AES key. Distinct from `config.psd1`. |
| **hot reload** | The fact that adding, editing, or deleting a webroot script takes effect on the next request, with no restart. |
| **HSTS** | HTTP Strict Transport Security — a response header that makes browsers refuse plain HTTP to the host. |
| **inline `$cfg`** | The hashtable of default settings built into `Start-WebServer.ps1`. It is the schema and the fallback behind `config.psd1`. |
| **`-JsonFilePath`** | The parameter through which a POST endpoint receives the path to the file holding the request body. |
| **`MaxConcurrent`** | The cap on simultaneous requests. Request number `MaxConcurrent + 1` gets HTTP 503. |
| **NDJSON** | Newline-delimited JSON — one JSON object per line. The format of the audit log. |
| **`netsh sslcert` binding** | A Windows record tying a TLS certificate to an IP-and-port. Must exist before the server starts with HTTPS enabled. |
| **OpenAPI** | A standard API description format. posh auto-generates an OpenAPI 3.1 spec at `/openapi.json`. |
| **path placeholder** | A webroot filename segment in brackets, like `[id].ps1`, that matches any URL segment (when `PathPlaceholders` is on). |
| **penalty period** | After the first rate-limit breach, a flat window (`RateLimitPenaltySec`) during which every request from that client is rejected. |
| **`POSH_API_KEY`** | The machine environment variable holding the server's API key. The server will not start without it. |
| **posh** | The codename for PowerShell Webserver — used in the folder name, config keys, and log files. |
| **prefix** | An `HttpListener` URL the server binds to. By default built from the ports with a `+` wildcard; can be set explicitly via `Prefixes`. |
| **rate limit** | The per-client request budget (`RateLimitRequests` per `RateLimitWindowSec`). Distinct from the global throttle. |
| **request ID** | An 8-character hex ID on every response (`X-Request-Id`), matching the log line and the POST-body filename. |
| **RunspacePool** | The pool of PowerShell worker threads (runspaces) the server uses to handle requests in parallel. |
| **scheduled task** | The Windows task `PowerShell-Webserver` that runs the server and starts it at boot. |
| **slow log** | An optional file (`logs\slow.log`) recording requests slower than `SlowRequestThresholdMs`. |
| **subprocess execution** | The default mode: each request runs in a fresh `pwsh.exe` process for isolation and reliable exit codes. |
| **webroot** | The folder (`C:\posh\webroot\`) whose `.ps1` files are automatically HTTP endpoints. |

# Appendix B. HTTP status code reference

Every status code the server returns, its trigger, and the administrator action.

| Code | Trigger | Action |
|---|---|---|
| **200** OK | A `.ps1` script ran and exited 0; or a built-in endpoint succeeded. | None — success. |
| **304** Not Modified | A static file is unchanged since the client's cached copy (`If-None-Match` / `If-Modified-Since` matched). | None — the client uses its cache. |
| **400** Bad Request | The path is not a recognised script type; a JSON body is malformed; or a query string was sent on a POST. | Fix the request — method, URL, body. |
| **401** Unauthorized | The `X-Api-Key` header (or Basic credentials) is missing or wrong. | Send the correct credential. See [7.6](#76-authentication-failures). |
| **403** Forbidden | A path-traversal attempt; the client IP is in `BlockedIPs`; or `AllowedIPs` is non-empty and the client is not listed; or a blocked static MIME type. | Check the URL and the IP filter. See [7.5](#75-the-server-is-unreachable-from-another-machine). |
| **404** Not Found | No file matches the path in `webroot\`; or a placeholder route is needed but `PathPlaceholders` is off. | Check spelling, subfolder, and whether the file exists. |
| **405** Method Not Allowed | An HTTP method other than GET, POST, or OPTIONS. | Use GET or POST. |
| **413** Payload Too Large | The POST body exceeds `MaxRequestBodyBytes` (default 20 MB). | Send less, or raise the limit. |
| **415** Unsupported Media Type | The POST `Content-Type` is not in `AcceptedContentTypes`. | Use `application/json` or `application/x-www-form-urlencoded`. |
| **429** Too Many Requests | The global throttle (`MinRequestIntervalSec`) or the per-IP rate limit was exceeded. A `Retry-After` header says how long to wait. | Slow down; honour `Retry-After`. See [7.7](#77-rate-limit-and-throttle-rejections). |
| **500** Internal Server Error | A script ran and failed — non-zero exit or unhandled exception. | Read the `error` field; the bug is in the endpoint. See [7.8](#78-endpoints-return-500). |
| **502** Bad Gateway | The PHP-CGI binary failed to launch. | Check `PhpCgiPath` and that `php-cgi.exe` exists. |
| **503** Service Unavailable | All `MaxConcurrent` worker slots are busy. | Retry; if constant, raise `MaxConcurrent`. |
| **504** Gateway Timeout | A script ran past `ScriptTimeoutSec` (or `PhpCgiTimeoutSec`) and was killed. | Speed up the script, raise the timeout, or move the work to a background job. See [7.9](#79-endpoints-time-out). |

# Appendix C. Environment variable reference

| Variable | Scope | Required? | Purpose |
|---|---|---|---|
| `POSH_API_KEY` | Machine | **Yes** | The API key callers send in `X-Api-Key`. The server will not start without it. Set by the installer or by hand. |
| `POSH_BASIC_USER` | Machine | Only if `AuthMode` is `Basic`/`Both` | Username for HTTP Basic authentication. |
| `POSH_BASIC_PASS` | Machine | Only if `AuthMode` is `Basic`/`Both` | Password for HTTP Basic authentication. Held in process memory only. |
| `POSH_CERT_THUMBPRINT` | Machine | No | The HTTPS certificate thumbprint. Recorded by the installer for diagnostics; the server relies on the `netsh` binding, not this variable. |
| `POSH_SESSION_ID` | *(injected)* | — | Set *by the server* into each endpoint's environment when `SessionEnabled` is on — the session cookie value. Not something you configure. |
| `POSH_COOKIES` | *(injected)* | — | Set *by the server* into each endpoint's environment — the raw `Cookie:` header. Not something you configure. |

Set a machine variable (elevated): `[Environment]::SetEnvironmentVariable('NAME', 'value', 'Machine')`.
Read one: `[Environment]::GetEnvironmentVariable('NAME', 'Machine')`. A change requires a
task restart to be seen.

# Appendix D. File and directory map

The layout of a deployment at `C:\posh\` (or your `-BaseDir`).

| Path | Purpose |
|---|---|
| `Start-WebServer.ps1` | The server. Run by the scheduled task; rarely edited directly. |
| `Register-ScheduledTask.ps1` | The interactive installer ([Part 4](#part-4-installing-and-setting-up)). |
| `Edit-PoshSettings.ps1` | The loopback-only browser configuration editor ([5.3](#53-editing-configpsd1)). |
| `globalvars.ps1` | Shared configuration for *endpoint scripts* ([3.7](#37-shared-configuration-with-globalvarsps1)). Gitignored once personalised. |
| `config.psd1` | The *server's* runtime configuration ([Part 5](#part-5-configuring)). Generated per install; gitignored. |
| `webroot\` | Endpoint scripts. Every `.ps1` here is a URL. |
| `webroot\_error\` | Custom HTML error pages, when `CustomErrorPages` is on. |
| `logs\` | All logs. |
| `logs\startup.log` | Why the server last started — or failed to. |
| `logs\YYYY-MM-DD.log` | The daily (or hourly) request log. |
| `logs\audit.log` | Security events, when `AuditLogEnabled` is on. |
| `logs\slow.log` | Slow requests, when `SlowRequestThresholdMs` is set. |
| `logs\jobs.log` | Background-job output, when `BackgroundJobs` is configured. |
| `postjson\` | POST request bodies, saved as `YYYYMMDD_HHmmss_<requestId>.json`. |
| `encrypted_pw\` | Encrypted credentials, as `encryptedString_<label>.txt` ([3.8](#38-using-secrets-in-endpoints)). |
| `tools\` | Setup helpers. |
| `tools\Initialize-PoshConfig.ps1` | Generates `config.psd1`. |
| `tools\New-PoshAesKey.ps1` | Generates the per-install AES encryption key. |
| `tools\Set-PoshSecret.ps1` | Stores an encrypted credential. |
| `tools\editor\` | Runtime files for `Edit-PoshSettings.ps1`. |
| `examples\clients\` | Ready-to-run client scripts — one per endpoint ([Appendix E](#appendix-e-bundled-client-scripts)). |
| `docs\` | The original per-topic documentation that this handbook consolidates. |

# Appendix E. Bundled client scripts

`examples\clients\` ships a working PowerShell client for every endpoint. They read
`POSH_BASE_URL` and `POSH_API_KEY` from the environment. Run them from the
`examples\clients\` directory.

| Client script | Calls | Demonstrates |
|---|---|---|
| `_Common.ps1` | *(shared helper)* | `Invoke-Posh`, `Write-Envelope`, and base-URL/key accessors that the other clients dot-source. |
| `Invoke-Hello.ps1` | `hello.ps1` | A simple GET with query parameters and the JSON envelope. |
| `Get-SystemInfo.ps1` | `subdir/system-info.ps1` | Subdirectory routing and nested-JSON parsing. |
| `Send-PostJson.ps1` | `post-json.ps1` | A POST with a structured JSON body. |
| `Send-PostForm.ps1` | `post-form.ps1` | A POST with a `application/x-www-form-urlencoded` body. |
| `Get-User.ps1` | `users/[id].ps1` + `users/admin.ps1` | Path placeholders and exact-filename priority. |
| `Test-Session.ps1` | `session.ps1` | The session-cookie round-trip via `-WebSession`. |
| `Get-ApiStatus.ps1` | `api-status.psxml` | An alternate-extension endpoint returning raw XML. |
| `Test-Errors.ps1` | `errors.ps1` | Exit codes and their mapping to HTTP status. |
| `Get-Health.ps1` | `/health` | The auth-exempt liveness probe. |
| `Get-Metrics.ps1` | `/metrics`, `/metrics-prom` | The JSON and Prometheus metrics endpoints. |
| `Get-OpenApiSpec.ps1` | `/openapi.json` | The auto-generated OpenAPI 3.1 spec. |
| `Test-AllEndpoints.ps1` | *(all of the above)* | A full end-to-end smoke test — run it after an install or upgrade. |

# Appendix F. Shipped webroot examples

`webroot\` ships nine example endpoints. They double as teaching material — the handbook
uses them as its running examples throughout.

| Endpoint | Type | What it teaches | Used in |
|---|---|---|---|
| `hello.ps1` | GET | The simplest good endpoint — typed params, defaults, `Write-Output`, `exit 0`. | [3.2](#32-the-anatomy-of-a-good-endpoint-script) |
| `errors.ps1` | GET | How exit codes, `Write-Error`, `throw`, and timeouts map to HTTP status. | [3.5](#35-exit-codes-errors-and-http-status) |
| `post-json.ps1` | POST | The `-JsonFilePath` contract — validating, reading, and defensively accessing a JSON body. | [3.4](#34-handling-post-bodies) |
| `post-form.ps1` | POST | That form-urlencoded bodies arrive through the same `-JsonFilePath` mechanism. | [3.4](#34-handling-post-bodies) |
| `session.ps1` | GET | Reading the session cookie via `POSH_SESSION_ID` / `POSH_COOKIES`. | [10.3](#103-sessions-and-cookies) |
| `api-status.psxml` | GET | An alternate-extension endpoint that returns raw XML, no envelope. | [10.10](#1010-alternate-script-extensions) |
| `subdir/system-info.ps1` | GET | Subdirectory routing and the deeper `..\..\globalvars.ps1` dot-source. | [3.6](#36-organizing-endpoints-in-subdirectories) |
| `users/[id].ps1` | GET | A path-placeholder route and input validation of the captured segment. | [10.5](#105-path-placeholders) |
| `users/admin.ps1` | GET | Exact-filename priority — `/users/admin` beats the `[id]` placeholder. | [10.5](#105-path-placeholders) |

# Appendix G. Version history digest

posh grew in waves. This digest tells you, roughly, which capabilities belong to which era,
so you can gauge what a given server's version supports. The authoritative, dated history is
`docs/changelog.md`.

**Foundation.** The core: webroot-to-URL routing, GET query parameters, the JSON envelope,
per-request `pwsh.exe` subprocess execution, a daily request log, and the Windows
scheduled-task installer.

**Hardening wave.** API-key authentication (`POSH_API_KEY`); HTTP 405 / 413 / 415 / 503 /
504 responses; the script execution timeout; log rotation; HTTPS support with the
`netsh sslcert` binding and the interactive certificate flow in the installer.

**Concurrency rework.** The concurrency engine moved to a `RunspacePool` with
`BeginInvoke()`, replacing earlier `Start-ThreadJob`-based approaches that crashed under
load. This is the model described in [1.3](#13-how-a-request-is-handled).

**POST-as-file wave.** POST bodies moved from flat parameters to the `-JsonFilePath`
file-passthrough model ([2.3](#23-calling-an-endpoint-with-post)); `PostJsonDir` and its
retention; the per-IP rate limiter, the global throttle, the IP filter, the `X-Request-Id`
header, and `GET /metrics`.

**Static and content wave.** Opt-in static file serving with MIME mapping, conditional GET,
byte ranges, and a MIME blacklist; GZIP and then Brotli compression; the
`application/x-www-form-urlencoded` POST path; cookies/sessions; CORS with `OPTIONS`
preflight; the PHP-CGI handler; alternate script extensions; in-process execution mode;
Basic auth; custom HTML error pages; multi-host `Prefixes`; CIDR/regex in the IP filter;
directory browsing; background jobs.

**Discovery and operations wave (most recent).** The external `config.psd1`; multiple
labelled API keys; per-API-key rate limiting; the NDJSON audit log; the slow-request log;
per-script metadata in `GET /`; the Prometheus endpoint `/metrics-prom`; Next.js-style path
placeholders; and the auto-generated OpenAPI spec at `/openapi.json`. A review pass in this
era also fixed a notable bug — the API-key comparison was case-*insensitive* and is now
byte-exact, so a server from before that fix accepts keys with the wrong case.

> **Tip.** To see exactly what a running server supports, call `GET /` and `GET /metrics` and
> check `config.psd1` — the keys present in the generated file tell you which features that
> server's version knows about.

# Appendix H. Quick command reference

Every operational command in one place. Replace `your-api-key` and paths as appropriate.

**Lifecycle**

```powershell
Start-ScheduledTask       -TaskName 'PowerShell-Webserver'
Stop-ScheduledTask        -TaskName 'PowerShell-Webserver'
Get-ScheduledTask         -TaskName 'PowerShell-Webserver' | Select-Object State
Get-ScheduledTaskInfo     -TaskName 'PowerShell-Webserver'
Unregister-ScheduledTask  -TaskName 'PowerShell-Webserver' -Confirm:$false
```

**Install and configure**

```powershell
.\Register-ScheduledTask.ps1                       # interactive install / reinstall
.\tools\Initialize-PoshConfig.ps1                  # generate config.psd1
.\tools\Initialize-PoshConfig.ps1 -Force           # regenerate (backs up the old file)
.\Edit-PoshSettings.ps1                            # browser-based config editor
.\Start-WebServer.ps1 -DumpEffectiveConfig         # show the configuration actually in effect
```

**Secrets**

```powershell
.\tools\New-PoshAesKey.ps1                         # generate the per-install AES key (once)
.\tools\Set-PoshSecret.ps1 -Label 'ad_adsread'     # store an encrypted credential
[Environment]::SetEnvironmentVariable('POSH_API_KEY', 'key', 'Machine')   # set the API key
[Environment]::GetEnvironmentVariable('POSH_API_KEY', 'Machine')          # read it back
```

**Run manually (development)**

```powershell
$env:POSH_API_KEY = 'dev-key'
.\Start-WebServer.ps1 -HttpPort 8080               # high port — no elevation needed
```

**Verify and call**

```powershell
Invoke-RestMethod -Uri 'http://localhost/health'
Invoke-RestMethod -Uri 'http://localhost/hello.ps1?Name=Max' -Headers @{ 'X-Api-Key' = 'your-api-key' }
cd .\examples\clients; .\Test-AllEndpoints.ps1     # full smoke test
```

**Diagnose**

```powershell
Get-Content C:\posh\logs\startup.log -Tail 30
Get-Content C:\posh\logs\2026-05-14.log -Tail 50
netsh http show sslcert ipport=0.0.0.0:443
Test-NetConnection -ComputerName posh.example.local -Port 80   # use your server's host
Get-NetFirewallRule -DisplayName '*PowerShell-Webserver*'
Invoke-ScriptAnalyzer -Path .\webroot\hello.ps1                # use your endpoint's path
```

**Lint and syntax-check an endpoint**

```powershell
Invoke-ScriptAnalyzer -Path .\webroot\hello.ps1

$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\webroot\hello.ps1), [ref]$null, [ref]$errors)
$errors
```
