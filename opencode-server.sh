#!/usr/bin/env bash

# Detect OS
OS="$(uname -s)"

# Add opencode to PATH if not already there (installer puts it in ~/.opencode/bin)
export PATH="$HOME/.opencode/bin:$PATH"

# Check if opencode is installed, if not install it
if ! command -v opencode &> /dev/null; then
  echo "opencode is not installed. Installing..."
  # Use bash -s to avoid stdin conflicts when this script is itself piped
  curl -fsSL https://opencode.ai/install | bash -s --
  
  # Verify installation succeeded
  if ! command -v opencode &> /dev/null; then
    echo "Failed to install opencode. Please install it manually from https://opencode.ai"
    exit 1
  fi
  echo "opencode installed successfully."
fi

# Handle --skip-auth flag (for automated testing)
SKIP_AUTH=false
for arg in "$@"; do
  if [ "$arg" = "--skip-auth" ]; then
    SKIP_AUTH=true
  fi
done

# Check if authenticated (skip if --skip-auth or --stop)
if [ "$SKIP_AUTH" = "false" ] && [ "$1" != "--stop" ]; then
  AUTH_FILE="$HOME/.local/share/opencode/auth.json"
  if [ ! -f "$AUTH_FILE" ] || [ ! -s "$AUTH_FILE" ]; then
    echo ""
    echo "OpenCode authentication required."
    echo "A browser/device code flow will be initiated..."
    echo ""
    opencode auth login </dev/tty
    
    # Verify auth succeeded
    if [ ! -f "$AUTH_FILE" ] || [ ! -s "$AUTH_FILE" ]; then
      echo "Authentication failed or was cancelled."
      exit 1
    fi
    echo "Authentication successful."
    echo ""
  fi
fi

# Determine data directory: use .opencode-server in the repo root if inside a git
# repo, otherwise fall back to ~/.config
if git rev-parse --show-toplevel &>/dev/null; then
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  DATA_DIR="$GIT_ROOT/.opencode-server"
  mkdir -p "$DATA_DIR"

  # Locally ignore the data directory so it's never committed
  EXCLUDE_FILE="$GIT_ROOT/.git/info/exclude"
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  if ! grep -qxF '.opencode-server' "$EXCLUDE_FILE" 2>/dev/null; then
    echo '.opencode-server' >> "$EXCLUDE_FILE"
  fi
else
  DATA_DIR="$HOME/.config"
fi

# Configuration
PASSWORD_FILE="$DATA_DIR/opencode-server-local"
PID_FILE="$DATA_DIR/opencode-server.pid"
STOP_FLAG="$DATA_DIR/opencode-server.stop"
CERT_DIR="$DATA_DIR/opencode-certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
CADDYFILE="$DATA_DIR/opencode-caddyfile"
LOG_FILE="$DATA_DIR/opencode-server.log"
MONITOR_INTERVAL=${OPENCODE_MONITOR_INTERVAL:-5}

OPENCODE_INTERNAL_PORT="4097"
OPENCODE_HTTPS_PORT=${OPENCODE_PORT-"5000"}

# Get IP address (platform-specific)
if [ "$OS" = "Darwin" ]; then
  IP_ADDRESS=$(ipconfig getifaddr en0)
else
  # Linux: get first non-localhost IP
  IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
  fi
fi

# Check if password file exists
if [ -f "$PASSWORD_FILE" ]; then
  OPENCODE_SERVER_PASSWORD=$(cat "$PASSWORD_FILE")
else
  # Generate new password and save it
  mkdir -p "$(dirname "$PASSWORD_FILE")"
  # Try uuidgen first, fall back to /proc/sys/kernel/random/uuid (Linux), then openssl
  if command -v uuidgen &> /dev/null; then
    OPENCODE_SERVER_PASSWORD=$(uuidgen)
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    OPENCODE_SERVER_PASSWORD=$(cat /proc/sys/kernel/random/uuid)
  else
    OPENCODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  fi
  echo "$OPENCODE_SERVER_PASSWORD" >"$PASSWORD_FILE"
fi
export OPENCODE_SERVER_PASSWORD

# Function to print connection info
print_info() {
  echo "IP Address:"
  echo "$IP_ADDRESS"
  echo
  echo "HTTPS Port:"
  echo "$OPENCODE_HTTPS_PORT"
  echo
  echo "Username:"
  echo "opencode"
  echo
  echo "Password:"
  echo "$OPENCODE_SERVER_PASSWORD"
  echo
  echo "Connect via: https://$IP_ADDRESS:$OPENCODE_HTTPS_PORT"
  echo
}

# Generate self-signed certificate if it doesn't exist
generate_cert() {
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=opencode-server" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$IP_ADDRESS" \
    2>/dev/null
  echo "Generated new self-signed certificate"
}

# Check if server is already running
is_running() {
  if [ -f "$PID_FILE" ]; then
    read OPENCODE_PID CADDY_PID MONITOR_PID < "$PID_FILE"
    if kill -0 "$OPENCODE_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Stop the running server
stop_server() {
  # Set the stop flag so the monitor knows this is intentional
  touch "$STOP_FLAG"
  if [ -f "$PID_FILE" ]; then
    read OPENCODE_PID CADDY_PID MONITOR_PID < "$PID_FILE"
    if [ -n "$MONITOR_PID" ]; then
      echo "Stopping monitor (PID: $MONITOR_PID)..."
      kill "$MONITOR_PID" 2>/dev/null
    fi
    echo "Stopping OpenCode server (PID: $OPENCODE_PID)..."
    kill "$OPENCODE_PID" 2>/dev/null
    echo "Stopping Caddy proxy (PID: $CADDY_PID)..."
    kill "$CADDY_PID" 2>/dev/null
    rm -f "$PID_FILE"
    rm -f "$CADDYFILE"
    echo "Server stopped."
  else
    echo "No running server found."
  fi
}

# Handle --stop flag
if [ "$1" = "--stop" ]; then
  stop_server
  exit 0
fi

# Check if already running
if is_running; then
  echo "OpenCode server is already running."
  echo "OpenCode PID: $OPENCODE_PID"
  echo "Caddy PID: $CADDY_PID"
  echo
  print_info
  exit 0
fi

# Clean up any orphaned processes from a previous run
if [ -f "$PID_FILE" ]; then
  read OLD_OPENCODE_PID OLD_CADDY_PID OLD_MONITOR_PID < "$PID_FILE"
  kill "$OLD_OPENCODE_PID" 2>/dev/null || true
  kill "$OLD_CADDY_PID" 2>/dev/null || true
  [ -n "$OLD_MONITOR_PID" ] && kill "$OLD_MONITOR_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

# Remove stop flag for fresh start
rm -f "$STOP_FLAG"

# Check if caddy is installed, if not install it (Linux only)
if ! command -v caddy &> /dev/null; then
  if [ "$OS" = "Linux" ]; then
    echo "caddy is not installed. Installing via apt..."
    sudo apt update && sudo apt install -y caddy
    if ! command -v caddy &> /dev/null; then
      echo "Failed to install caddy. Please install it manually."
      exit 1
    fi
    echo "caddy installed successfully."
  else
    echo "caddy is not installed. Please install it manually."
    echo "On macOS: brew install caddy"
    exit 1
  fi
fi

# Generate certificate if needed
if [ ! -f "$CERT_FILE" ]; then
  generate_cert
fi

# Create the Caddyfile for HTTPS reverse proxy with manual certs
cat > "$CADDYFILE" <<EOF
{
  auto_https disable_redirects
}

:$OPENCODE_HTTPS_PORT {
  tls $CERT_FILE $KEY_FILE
  reverse_proxy 127.0.0.1:$OPENCODE_INTERNAL_PORT
}
EOF

# Start opencode on localhost only (not exposed to network)
opencode serve --hostname 127.0.0.1 --port $OPENCODE_INTERNAL_PORT >> "$LOG_FILE" 2>&1 &
OPENCODE_PID=$!

# Wait a moment for opencode to start
sleep 1

# Start Caddy natively
caddy run --config "$CADDYFILE" --adapter caddyfile >> "$LOG_FILE" 2>&1 &
CADDY_PID=$!

# Start the process monitor in the background
# The monitor watches both processes and relaunches them if they die unexpectedly.
# It exits if the stop flag file is present (set by --stop).
(
  # Helper: check if a PID is alive and not a zombie
  is_process_alive() {
    local pid=$1
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    # Check for zombie (defunct) state - works on Linux
    if [ -f "/proc/$pid/status" ]; then
      if grep -q "^State:.*Z" "/proc/$pid/status" 2>/dev/null; then
        # Reap the zombie
        wait "$pid" 2>/dev/null
        return 1
      fi
    fi
    return 0
  }

  while true; do
    sleep "$MONITOR_INTERVAL"

    # If the stop flag exists, this is an intentional shutdown - exit monitor
    if [ -f "$STOP_FLAG" ]; then
      exit 0
    fi

    # Read current PIDs from the PID file
    if [ ! -f "$PID_FILE" ]; then
      exit 0
    fi
    read CUR_OPENCODE_PID CUR_CADDY_PID CUR_MONITOR_PID < "$PID_FILE"

    NEED_UPDATE=false

    # Check if opencode is alive
    if ! is_process_alive "$CUR_OPENCODE_PID"; then
      if [ -f "$STOP_FLAG" ]; then exit 0; fi
      echo "$(date): OpenCode process died, relaunching..." >> "$LOG_FILE"
      opencode serve --hostname 127.0.0.1 --port $OPENCODE_INTERNAL_PORT >> "$LOG_FILE" 2>&1 &
      CUR_OPENCODE_PID=$!
      NEED_UPDATE=true
    fi

    # Check if caddy is alive
    if ! is_process_alive "$CUR_CADDY_PID"; then
      if [ -f "$STOP_FLAG" ]; then exit 0; fi
      echo "$(date): Caddy process died, relaunching..." >> "$LOG_FILE"
      caddy run --config "$CADDYFILE" --adapter caddyfile >> "$LOG_FILE" 2>&1 &
      CUR_CADDY_PID=$!
      NEED_UPDATE=true
    fi

    # Update PID file if any process was relaunched
    if [ "$NEED_UPDATE" = true ]; then
      echo "$CUR_OPENCODE_PID $CUR_CADDY_PID $CUR_MONITOR_PID" > "$PID_FILE"
    fi
  done
) >> "$LOG_FILE" 2>&1 &
MONITOR_PID=$!

# Save PIDs to file (opencode, caddy, monitor)
echo "$OPENCODE_PID $CADDY_PID $MONITOR_PID" > "$PID_FILE"

echo "OpenCode server started in background."
echo "OpenCode PID: $OPENCODE_PID"
echo "Caddy PID: $CADDY_PID"
echo "Monitor PID: $MONITOR_PID"
echo "Logs: $LOG_FILE"
echo
print_info
echo "To stop the server, run:"
echo "  curl -fsSL https://raw.githubusercontent.com/PabloZaiden/opencode-server-runner/main/opencode-server.sh | bash -s -- --stop"
