# posh

A Windows HTTP server that maps URL paths directly to PowerShell scripts and returns their output as JSON.

```
GET /restart-comfyui-graceful.ps1
→ { "exitCode": 0, "output": "ComfyUI ist bereit...", "error": "" }
```

## Documentation

- [Overview](./docs/overview.md) — What posh is and the problem it solves
- [Setup](./docs/setup.md) — Installation and prerequisites
- [Usage](./docs/usage.md) — How to call endpoints and interpret responses
- [Architecture](./docs/architecture.md) — System design and key components
- [Configuration](./docs/configuration.md) — All configuration options
- [Contributing](./docs/contributing.md) — Development workflow, conventions, and adding new endpoints
- [Changelog](./docs/changelog.md) — Version history
