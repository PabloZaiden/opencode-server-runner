#!/usr/bin/env bash

# Check if password file exists
PASSWORD_FILE="$HOME/.config/opencode-server-local"
if [ -f "$PASSWORD_FILE" ]; then
  OPENCODE_SERVER_PASSWORD=$(cat "$PASSWORD_FILE")
else
  # Generate new password and save it
  mkdir -p "$(dirname "$PASSWORD_FILE")"
  OPENCODE_SERVER_PASSWORD=$(uuidgen)
  echo "$OPENCODE_SERVER_PASSWORD" >"$PASSWORD_FILE"
fi

IP_ADDRESS=$(ipconfig getifaddr en0)
OPENCODE_INTERNAL_PORT="4097"
OPENCODE_HTTPS_PORT=${OPENCODE_PORT-"4096"}
export OPENCODE_SERVER_PASSWORD

# Certificate configuration
CERT_DIR="$HOME/.config/opencode-certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
CADDYFILE="$HOME/.config/opencode-caddyfile"

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

if [ ! -f "$CERT_FILE" ]; then
  generate_cert
fi

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

# Cleanup function to kill background processes on exit
cleanup() {
  echo "Shutting down..."
  kill $OPENCODE_PID 2>/dev/null
  kill $CADDY_PID 2>/dev/null
  rm -f "$CADDYFILE"
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Start opencode on localhost only (not exposed to network)
opencode serve --hostname 127.0.0.1 --port $OPENCODE_INTERNAL_PORT &
OPENCODE_PID=$!

# Wait a moment for opencode to start
sleep 1

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

# Start Caddy natively
caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!

echo "Caddy HTTPS proxy started (PID: $CADDY_PID)"
echo "OpenCode server started (PID: $OPENCODE_PID)"
echo

# Wait for either process to exit
wait $OPENCODE_PID $CADDY_PID
