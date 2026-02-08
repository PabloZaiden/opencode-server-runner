#!/usr/bin/env bash
#
# Automated tests for opencode-server-runner
# Runs tests in a fresh devcontainer-like Docker environment
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="opencode-test-$$"
TEST_PORT=5099
PASSED=0
FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cleanup() {
  echo ""
  echo -e "${YELLOW}Cleaning up...${NC}"
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

pass() {
  echo -e "${GREEN}PASS${NC}: $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}FAIL${NC}: $1"
  FAILED=$((FAILED + 1))
}

echo "========================================"
echo "OpenCode Server Runner - Test Suite"
echo "========================================"
echo ""

echo -e "${YELLOW}Starting test container...${NC}"
docker run --rm -d --name "$CONTAINER_NAME" \
  -v "$REPO_DIR:/workspace:ro" \
  mcr.microsoft.com/devcontainers/base:ubuntu sleep 3600
echo ""

# ------------------------------------------------------------------------------
echo "=== Test 1: Script installs OpenCode and Caddy ==="
OUTPUT=$(docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$TEST_PORT bash /workspace/opencode-server.sh --skip-auth 2>&1")
if echo "$OUTPUT" | grep -q "OpenCode server started"; then
  pass "Script runs and starts server"
else
  fail "Script did not start server"
  echo "$OUTPUT"
fi

# ------------------------------------------------------------------------------
echo "=== Test 2: OpenCode CLI is installed ==="
if docker exec "$CONTAINER_NAME" bash -c \
  'export PATH="$HOME/.opencode/bin:$PATH" && opencode --version' >/dev/null 2>&1; then
  pass "OpenCode CLI is installed"
else
  fail "OpenCode CLI not found"
fi

# ------------------------------------------------------------------------------
echo "=== Test 3: Caddy is installed ==="
if docker exec "$CONTAINER_NAME" bash -c 'caddy version' >/dev/null 2>&1; then
  pass "Caddy is installed"
else
  fail "Caddy not found"
fi

# ------------------------------------------------------------------------------
echo "=== Test 4: Server responds on HTTPS port ==="
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:$TEST_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server responds with 401 (auth required) on port $TEST_PORT"
else
  fail "Expected HTTP 401, got: $HTTP_CODE"
fi

# ------------------------------------------------------------------------------
echo "=== Test 5: Password is generated and persisted ==="
PASSWORD1=$(docker exec "$CONTAINER_NAME" bash -c 'cat ~/.config/opencode-server-local' 2>/dev/null)
if [ -n "$PASSWORD1" ]; then
  pass "Password was generated: ${PASSWORD1:0:8}..."
else
  fail "Password file not found or empty"
fi

# ------------------------------------------------------------------------------
echo "=== Test 6: Running again shows 'already running' ==="
OUTPUT=$(docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$TEST_PORT bash /workspace/opencode-server.sh --skip-auth 2>&1")
if echo "$OUTPUT" | grep -q "already running"; then
  pass "Detects already running server"
else
  fail "Did not detect already running server"
  echo "$OUTPUT"
fi

# ------------------------------------------------------------------------------
echo "=== Test 7: Stop command works (port no longer listening) ==="
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
sleep 2
LISTENING=$(docker exec "$CONTAINER_NAME" bash -c "ss -tlnp | grep $TEST_PORT || echo 'not listening'" 2>&1)
if [[ "$LISTENING" == *"not listening"* ]]; then
  pass "Port $TEST_PORT is no longer listening"
else
  fail "Server still listening after stop"
  echo "$LISTENING"
fi

# ------------------------------------------------------------------------------
echo "=== Test 7b: Stop command kills processes (no zombies) ==="
PROCS=$(docker exec "$CONTAINER_NAME" bash -c 'ps aux | grep -E "(opencode serve|caddy run)" | grep -v grep || echo "no processes"' 2>&1)
if [[ "$PROCS" == *"no processes"* ]]; then
  pass "OpenCode and Caddy processes are terminated"
else
  # Check if they're zombies
  if echo "$PROCS" | grep -q "defunct"; then
    fail "Processes are zombies (defunct)"
    echo "$PROCS"
  else
    fail "Processes still running"
    echo "$PROCS"
  fi
fi

# ------------------------------------------------------------------------------
echo "=== Test 7c: Watchdog restarts killed OpenCode process ==="
# Start server fresh
docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$TEST_PORT bash /workspace/opencode-server.sh --skip-auth" >/dev/null 2>&1
# Kill only the opencode process (not via --stop)
docker exec "$CONTAINER_NAME" bash -c \
  'OPENCODE_PID=$(cut -d" " -f1 ~/.config/opencode-server.pid); kill "$OPENCODE_PID" 2>/dev/null'
# Wait for watchdog to detect and restart (watchdog checks every 5 seconds)
sleep 8
# Verify server is responding again
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:$TEST_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server auto-restarted after OpenCode process was killed"
else
  fail "Server did not auto-restart after kill (got: $HTTP_CODE)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 7d: Watchdog restarts killed Caddy process ==="
# Kill only the caddy process (not via --stop)
docker exec "$CONTAINER_NAME" bash -c \
  'CADDY_PID=$(cut -d" " -f2 ~/.config/opencode-server.pid); kill "$CADDY_PID" 2>/dev/null'
# Wait for watchdog to detect and restart
sleep 8
# Verify server is responding again
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:$TEST_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server auto-restarted after Caddy process was killed"
else
  fail "Server did not auto-restart after Caddy kill (got: $HTTP_CODE)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 7e: Stop command permanently stops server (no restart) ==="
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
# Wait longer than the watchdog interval to confirm it stays down
sleep 8
LISTENING=$(docker exec "$CONTAINER_NAME" bash -c "ss -tlnp | grep $TEST_PORT || echo 'not listening'" 2>&1)
if [[ "$LISTENING" == *"not listening"* ]]; then
  pass "Server stays stopped after --stop (watchdog does not restart)"
else
  fail "Server restarted after --stop (watchdog should not restart)"
  echo "$LISTENING"
fi

# ------------------------------------------------------------------------------
echo "=== Test 8: Password persists after restart ==="
docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$TEST_PORT bash /workspace/opencode-server.sh --skip-auth" >/dev/null 2>&1
PASSWORD2=$(docker exec "$CONTAINER_NAME" bash -c 'cat ~/.config/opencode-server-local' 2>/dev/null)
if [ "$PASSWORD1" = "$PASSWORD2" ]; then
  pass "Password persisted across restart"
else
  fail "Password changed after restart"
fi

# ------------------------------------------------------------------------------
echo "=== Test 9: Different port works ==="
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
sleep 1
ALTERNATE_PORT=5088
docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$ALTERNATE_PORT bash /workspace/opencode-server.sh --skip-auth" >/dev/null 2>&1
sleep 2
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:$ALTERNATE_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server responds on alternate port $ALTERNATE_PORT"
else
  fail "Server did not respond on alternate port (got: $HTTP_CODE)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 10: Connection info is displayed ==="
OUTPUT=$(docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$ALTERNATE_PORT bash /workspace/opencode-server.sh --skip-auth 2>&1")
if echo "$OUTPUT" | grep -q "Connect via:" && echo "$OUTPUT" | grep -q "Password:"; then
  pass "Connection info is displayed"
else
  fail "Connection info not displayed properly"
fi

# ------------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Test Results: $PASSED passed, $FAILED failed"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

echo ""
echo -e "${GREEN}ALL TESTS PASSED${NC}"
