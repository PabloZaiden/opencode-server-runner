# opencode-server-runner

A script to run [OpenCode](https://opencode.ai) server with HTTPS support via Caddy reverse proxy.

## Quick Start

```bash
# Start the server
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | bash

# Stop the server
curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | bash -s -- --stop
```

## Requirements

- macOS (uses `ipconfig` for network detection)
- [Caddy](https://caddyserver.com/) installed
- OpenSSL (for certificate generation)

> **Note:** OpenCode CLI will be installed automatically if not present.

## Usage

If you have the script locally:

```bash
# Start the server (runs in background)
./opencode-server.sh

# Check status / print connection info (if already running)
./opencode-server.sh

# Stop the server
./opencode-server.sh --stop
```

## What it does

1. Generates a persistent password (stored in `~/.config/opencode-server-local`)
2. Creates a self-signed SSL certificate (stored in `~/.config/opencode-certs/`)
3. Starts OpenCode server on localhost:4097
4. Starts Caddy as an HTTPS reverse proxy on port 4096 (or `$OPENCODE_PORT` if set)
5. Prints connection info (IP, port, username, password)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `OPENCODE_PORT` | `4096` | HTTPS port for external connections |

## Files

| Path | Description |
|------|-------------|
| `~/.config/opencode-server-local` | Persistent password |
| `~/.config/opencode-server.pid` | PID file for running instance |
| `~/.config/opencode-server.log` | Server logs |
| `~/.config/opencode-certs/` | SSL certificates |
| `~/.config/opencode-caddyfile` | Generated Caddy configuration |

## Connecting

After starting, connect using the displayed URL:

```
https://<your-ip>:4096
```

- **Username:** `opencode`
- **Password:** (displayed on start, persisted in config)

Note: You'll need to accept the self-signed certificate warning in your browser.
