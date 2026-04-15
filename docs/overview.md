# posh

## What is it?

posh is a Windows HTTP/HTTPS server that maps URL paths directly to PowerShell scripts and returns their output as JSON.

## Problem Statement

Windows automation tasks — restarting services, querying system state, triggering maintenance jobs — are typically triggered manually or via brittle scheduled tasks with no external interface. There is no standard way to invoke a local PowerShell script over HTTP from another machine, a monitoring system, or a workflow orchestrator without installing a full application framework or exposing a remote management surface.

## Key Features

- **URL-to-script routing** — every `.ps1` file placed in the `webroot\` directory is immediately reachable as an HTTP endpoint, with no registration or configuration required.
- **GET and POST support** — URL query parameters (GET) and flat JSON body keys (POST) are passed directly as named PowerShell arguments to the target script. Body keys take precedence when names collide.
- **JSON response envelope** — all responses follow a uniform `{ "exitCode", "output", "error" }` structure, making results predictable for any HTTP client.
- **HTTPS support** — optional TLS on a configurable port. A certificate is created and bound to the port automatically by `Register-ScheduledTask.ps1`. Self-signed and imported PFX certificates are supported.
- **API key authentication** — all endpoints except `GET /health` require an `X-Api-Key` header, configured via the `POSH_API_KEY` system environment variable.
- **Concurrent request handling** — up to 10 requests are processed simultaneously; requests beyond the limit receive an immediate HTTP 503 instead of queuing indefinitely.
- **Low-frequency design** — posh is built for infrequent, manually-triggered or scheduled automation calls, not high-frequency polling. A global throttle (default: 1 request per second) enforces this limit — requests arriving faster receive HTTP 429 with a `Retry-After` header.
- **Script timeout enforcement** — scripts that run longer than the configured threshold are terminated and the caller receives HTTP 504, preventing indefinite hangs.

## Who is it for?

- Windows system administrators who need to trigger local PowerShell scripts remotely from other machines or monitoring tools.
- Self-hosted workflow operators who want to expose machine-local automation (e.g. restarting GPU workloads, querying system state) as HTTP endpoints without deploying a full web application.

For setup instructions, see [Setup](./setup.md).
