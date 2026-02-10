# opencode-server-runner

A script to run [OpenCode](https://opencode.ai) server with HTTPS support via Caddy reverse proxy. Designed to work seamlessly inside devcontainers.

## Quick Start

Run this one-liner inside your devcontainer terminal:

```bash
# Start the server on port 5001
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | OPENCODE_PORT=5001 bash
```

```bash
# Stop the server
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | bash -s -- --stop
```

VS Code will automatically detect the exposed port and offer to forward it.

## Authentication

On first run, if you're not authenticated, the script will initiate an authentication flow:

1. A URL and device code will be displayed in the terminal
2. Visit the URL in your browser
3. Enter the device code
4. Authorize OpenCode to access your chosen provider
5. The script will continue once authentication is complete

Your authentication persists in `~/.local/share/opencode/auth.json` and will survive container restarts (but not rebuilds).

### Skipping Authentication (for testing)

```bash
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | OPENCODE_PORT=5001 bash -s -- --skip-auth
```

## Requirements

- macOS or Linux (including devcontainers)
- OpenSSL (for certificate generation)

> **Note:** OpenCode CLI and Caddy will be installed automatically if not present.

## Usage

**Using different ports for multiple devcontainers:**

```bash
# Devcontainer 1
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | OPENCODE_PORT=5001 bash

# Devcontainer 2
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | OPENCODE_PORT=5002 bash

# Devcontainer 3
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | OPENCODE_PORT=5003 bash
```

**If you have the script locally:**

```bash
# Start the server (runs in background)
OPENCODE_PORT=5001 ./opencode-server.sh

# Check status / print connection info (if already running)
./opencode-server.sh

# Stop the server
./opencode-server.sh --stop
```

## What it does

1. Installs OpenCode CLI (if not present)
2. Installs Caddy (if not present, Linux only)
3. Authenticates with a provider (if not already authenticated)
4. Generates a persistent password
5. Creates a self-signed SSL certificate
6. Starts OpenCode server on localhost:4097
7. Starts Caddy as an HTTPS reverse proxy on the configured port
8. Prints connection info (IP, port, username, password)

## Data Storage

When run inside a **git repository**, all server data (password, PID file, certificates, logs, Caddyfile) is stored in `.opencode-server/` at the repository root. This directory is automatically added to `.git/info/exclude` so it won't be committed.

When run **outside a git repository**, data is stored in `~/.config/` (the previous default behavior).

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `OPENCODE_PORT` | `5000` | HTTPS port for external connections |

## Files

| File | Description |
|------|-------------|
| `~/.local/share/opencode/auth.json` | Provider authentication |
| `<data-dir>/opencode-server-local` | Persistent password |
| `<data-dir>/opencode-server.pid` | PID file for running instance |
| `<data-dir>/opencode-server.log` | Server logs |
| `<data-dir>/opencode-certs/` | SSL certificates |
| `<data-dir>/opencode-caddyfile` | Generated Caddy configuration |

`<data-dir>` is `.opencode-server/` (in git repos) or `~/.config/` (otherwise).

## Connecting

After starting, connect using the displayed URL:

```
https://<your-ip>:5001
```

- **Username:** `opencode`
- **Password:** (displayed on start, persisted in config)

Note: You'll need to accept the self-signed certificate warning in your browser/client.

## Running Tests

Automated tests are available using Docker:

```bash
./tests/test-devcontainer.sh
```

This will spin up a fresh container, run the script, and verify everything works correctly.
