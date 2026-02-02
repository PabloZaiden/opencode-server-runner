#!/usr/bin/env bash

# Check if opencode is installed, if not install it
if ! command -v opencode &> /dev/null; then
  echo "opencode is not installed. Installing..."
  curl -fsSL https://opencode.ai/install | bash
  
  # Refresh PATH by sourcing shell config files (the installer may have updated them)
  # Try common shell config files
  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    if [ -f "$rc_file" ]; then
      source "$rc_file" 2>/dev/null || true
    fi
  done
  
  # Verify installation succeeded
  if ! command -v opencode &> /dev/null; then
    echo "Failed to install opencode. Please install it manually from https://opencode.ai"
    exit 1
  fi
  echo "opencode installed successfully."
fi

# Configuration
PASSWORD_FILE="$HOME/.config/opencode-server-local"
PID_FILE="$HOME/.config/opencode-server.pid"
CERT_DIR="$HOME/.config/opencode-certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
CADDYFILE="$HOME/.config/opencode-caddyfile"
LOG_FILE="$HOME/.config/opencode-server.log"

OPENCODE_INTERNAL_PORT="4097"
OPENCODE_HTTPS_PORT=${OPENCODE_PORT-"4096"}

# Get IP address
IP_ADDRESS=$(ipconfig getifaddr en0)

# Check if password file exists
if [ -f "$PASSWORD_FILE" ]; then
  OPENCODE_SERVER_PASSWORD=$(cat "$PASSWORD_FILE")
else
  # Generate new password and save it
  mkdir -p "$(dirname "$PASSWORD_FILE")"
  OPENCODE_SERVER_PASSWORD=$(uuidgen)
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
    read OPENCODE_PID CADDY_PID < "$PID_FILE"
    if kill -0 "$OPENCODE_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Stop the running server
stop_server() {
  if [ -f "$PID_FILE" ]; then
    read OPENCODE_PID CADDY_PID < "$PID_FILE"
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

# Save PIDs to file
echo "$OPENCODE_PID $CADDY_PID" > "$PID_FILE"

echo "OpenCode server started in background."
echo "OpenCode PID: $OPENCODE_PID"
echo "Caddy PID: $CADDY_PID"
echo "Logs: $LOG_FILE"
echo
print_info
echo "Use '$0 --stop' to stop the server."
