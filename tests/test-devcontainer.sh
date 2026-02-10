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
echo "=== Test 7c: Stop command kills monitor process ==="
MONITOR_PROCS=$(docker exec "$CONTAINER_NAME" bash -c 'ps aux | grep "opencode-server" | grep -v grep | grep -v test || echo "no monitor"' 2>&1)
if [[ "$MONITOR_PROCS" == *"no monitor"* ]]; then
  pass "Monitor process is terminated"
else
  fail "Monitor process still running"
  echo "$MONITOR_PROCS"
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
# Stop the server from previous tests and start fresh for relaunch tests
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
sleep 2

echo "=== Test 11: OpenCode process is relaunched after external kill ==="
# Start the server with a fast monitor interval for testing
docker exec "$CONTAINER_NAME" bash -c \
  "OPENCODE_PORT=$TEST_PORT OPENCODE_MONITOR_INTERVAL=2 bash /workspace/opencode-server.sh --skip-auth" >/dev/null 2>&1
sleep 2

# Get the opencode PID and kill it
OPENCODE_PID_BEFORE=$(docker exec "$CONTAINER_NAME" bash -c \
  'read OPID CPID MPID < ~/.config/opencode-server.pid && echo $OPID' 2>/dev/null)
docker exec "$CONTAINER_NAME" bash -c "kill $OPENCODE_PID_BEFORE" 2>/dev/null

# Wait for the monitor to detect and relaunch (monitor interval is 2s)
sleep 5

# Check that a new opencode process exists and has a different PID
OPENCODE_PID_AFTER=$(docker exec "$CONTAINER_NAME" bash -c \
  'read OPID CPID MPID < ~/.config/opencode-server.pid && echo $OPID' 2>/dev/null)
if [ -n "$OPENCODE_PID_AFTER" ] && [ "$OPENCODE_PID_AFTER" != "$OPENCODE_PID_BEFORE" ]; then
  # Verify the new process is actually running
  if docker exec "$CONTAINER_NAME" bash -c "kill -0 $OPENCODE_PID_AFTER" 2>/dev/null; then
    pass "OpenCode process was relaunched (PID $OPENCODE_PID_BEFORE -> $OPENCODE_PID_AFTER)"
  else
    fail "New OpenCode PID exists in file but process is not running"
  fi
else
  fail "OpenCode process was not relaunched (PID before=$OPENCODE_PID_BEFORE, after=$OPENCODE_PID_AFTER)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 12: Caddy process is relaunched after external kill ==="
# Get the caddy PID and kill it
CADDY_PID_BEFORE=$(docker exec "$CONTAINER_NAME" bash -c \
  'read OPID CPID MPID < ~/.config/opencode-server.pid && echo $CPID' 2>/dev/null)
docker exec "$CONTAINER_NAME" bash -c "kill $CADDY_PID_BEFORE" 2>/dev/null

# Wait for the monitor to detect and relaunch
sleep 5

# Check that a new caddy process exists and has a different PID
CADDY_PID_AFTER=$(docker exec "$CONTAINER_NAME" bash -c \
  'read OPID CPID MPID < ~/.config/opencode-server.pid && echo $CPID' 2>/dev/null)
if [ -n "$CADDY_PID_AFTER" ] && [ "$CADDY_PID_AFTER" != "$CADDY_PID_BEFORE" ]; then
  if docker exec "$CONTAINER_NAME" bash -c "kill -0 $CADDY_PID_AFTER" 2>/dev/null; then
    pass "Caddy process was relaunched (PID $CADDY_PID_BEFORE -> $CADDY_PID_AFTER)"
  else
    fail "New Caddy PID exists in file but process is not running"
  fi
else
  fail "Caddy process was not relaunched (PID before=$CADDY_PID_BEFORE, after=$CADDY_PID_AFTER)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 13: Server still responds after process relaunch ==="
# Give the relaunched processes time to fully start
sleep 5
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' --retry 3 --retry-delay 2 https://127.0.0.1:$TEST_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server responds with 401 after relaunch on port $TEST_PORT"
else
  fail "Expected HTTP 401 after relaunch, got: $HTTP_CODE"
fi

# ------------------------------------------------------------------------------
echo "=== Test 14: Processes are NOT relaunched after --stop ==="
# Stop the server using --stop
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
sleep 5

# Verify no opencode or caddy processes are running (monitor should not have relaunched them)
PROCS=$(docker exec "$CONTAINER_NAME" bash -c 'ps aux | grep -E "(opencode serve|caddy run)" | grep -v grep || echo "no processes"' 2>&1)
if [[ "$PROCS" == *"no processes"* ]]; then
  pass "Processes were NOT relaunched after --stop"
else
  fail "Processes were relaunched after --stop (they should not have been)"
  echo "$PROCS"
fi

# ==============================================================================
# GIT REPO DATA DIRECTORY TESTS
# ==============================================================================
echo ""
echo -e "${YELLOW}Setting up git repo tests...${NC}"

# Stop any running server and clean up state from previous tests
docker exec "$CONTAINER_NAME" bash /workspace/opencode-server.sh --stop >/dev/null 2>&1
sleep 2

# Create a git repo inside the container
docker exec "$CONTAINER_NAME" bash -c \
  'mkdir -p /tmp/test-repo && cd /tmp/test-repo && git init && git config user.email "test@test.com" && git config user.name "Test"' >/dev/null 2>&1

# Copy the script into the repo (since /workspace is read-only)
docker exec "$CONTAINER_NAME" bash -c 'cp /workspace/opencode-server.sh /tmp/test-repo/' >/dev/null 2>&1

# ------------------------------------------------------------------------------
echo "=== Test 15: Data is stored in .opencode-server/ inside a git repo ==="
OUTPUT=$(docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp/test-repo && OPENCODE_PORT=$TEST_PORT bash opencode-server.sh --skip-auth 2>&1")
if echo "$OUTPUT" | grep -q "OpenCode server started"; then
  # Check that data dir was created inside the repo
  if docker exec "$CONTAINER_NAME" bash -c 'test -d /tmp/test-repo/.opencode-server'; then
    pass "Data directory .opencode-server/ created inside git repo"
  else
    fail "Data directory .opencode-server/ not found inside git repo"
  fi
else
  fail "Script did not start server from git repo"
  echo "$OUTPUT"
fi

# ------------------------------------------------------------------------------
echo "=== Test 16: .git/info/exclude contains .opencode-server ==="
EXCLUDE_CONTENT=$(docker exec "$CONTAINER_NAME" bash -c 'cat /tmp/test-repo/.git/info/exclude' 2>/dev/null)
if echo "$EXCLUDE_CONTENT" | grep -qxF '.opencode-server'; then
  pass ".opencode-server is in .git/info/exclude"
else
  fail ".opencode-server not found in .git/info/exclude"
  echo "Exclude file contents: $EXCLUDE_CONTENT"
fi

# ------------------------------------------------------------------------------
echo "=== Test 17: Password file is inside .opencode-server/ ==="
GIT_PASSWORD=$(docker exec "$CONTAINER_NAME" bash -c 'cat /tmp/test-repo/.opencode-server/opencode-server-local' 2>/dev/null)
if [ -n "$GIT_PASSWORD" ]; then
  pass "Password file found in .opencode-server/: ${GIT_PASSWORD:0:8}..."
else
  fail "Password file not found in .opencode-server/"
fi

# ------------------------------------------------------------------------------
echo "=== Test 18: PID file is inside .opencode-server/ ==="
if docker exec "$CONTAINER_NAME" bash -c 'test -f /tmp/test-repo/.opencode-server/opencode-server.pid'; then
  pass "PID file found in .opencode-server/"
else
  fail "PID file not found in .opencode-server/"
fi

# ------------------------------------------------------------------------------
echo "=== Test 19: Certs are inside .opencode-server/ ==="
if docker exec "$CONTAINER_NAME" bash -c 'test -f /tmp/test-repo/.opencode-server/opencode-certs/cert.pem'; then
  pass "Certificate found in .opencode-server/opencode-certs/"
else
  fail "Certificate not found in .opencode-server/opencode-certs/"
fi

# ------------------------------------------------------------------------------
echo "=== Test 20: Log file is inside .opencode-server/ ==="
if docker exec "$CONTAINER_NAME" bash -c 'test -f /tmp/test-repo/.opencode-server/opencode-server.log'; then
  pass "Log file found in .opencode-server/"
else
  fail "Log file not found in .opencode-server/"
fi

# ------------------------------------------------------------------------------
echo "=== Test 21: Server responds on HTTPS port (git repo mode) ==="
HTTP_CODE=$(docker exec "$CONTAINER_NAME" bash -c \
  "curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:$TEST_PORT" 2>&1)
if [ "$HTTP_CODE" = "401" ]; then
  pass "Server responds with 401 on port $TEST_PORT (git repo mode)"
else
  fail "Expected HTTP 401, got: $HTTP_CODE (git repo mode)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 22: Stop works in git repo mode ==="
docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp/test-repo && bash opencode-server.sh --stop" >/dev/null 2>&1
sleep 2
LISTENING=$(docker exec "$CONTAINER_NAME" bash -c "ss -tlnp | grep $TEST_PORT || echo 'not listening'" 2>&1)
if [[ "$LISTENING" == *"not listening"* ]]; then
  pass "Server stopped in git repo mode"
else
  fail "Server still listening after stop in git repo mode"
  echo "$LISTENING"
fi

# ------------------------------------------------------------------------------
echo "=== Test 23: Password persists after restart in git repo mode ==="
docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp/test-repo && OPENCODE_PORT=$TEST_PORT bash opencode-server.sh --skip-auth" >/dev/null 2>&1
GIT_PASSWORD2=$(docker exec "$CONTAINER_NAME" bash -c 'cat /tmp/test-repo/.opencode-server/opencode-server-local' 2>/dev/null)
if [ "$GIT_PASSWORD" = "$GIT_PASSWORD2" ]; then
  pass "Password persisted across restart in git repo mode"
else
  fail "Password changed after restart in git repo mode"
fi

# Stop server before next test
docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp/test-repo && bash opencode-server.sh --stop" >/dev/null 2>&1
sleep 2

# ------------------------------------------------------------------------------
echo "=== Test 24: .git/info/exclude entry is not duplicated on repeated runs ==="
EXCLUDE_COUNT=$(docker exec "$CONTAINER_NAME" bash -c \
  'grep -cx ".opencode-server" /tmp/test-repo/.git/info/exclude' 2>/dev/null)
if [ "$EXCLUDE_COUNT" = "1" ]; then
  pass ".opencode-server appears exactly once in .git/info/exclude"
else
  fail ".opencode-server appears $EXCLUDE_COUNT times in .git/info/exclude (expected 1)"
fi

# ------------------------------------------------------------------------------
echo "=== Test 25: Data stored in ~/.config/ when not in a git repo ==="
# Run from /tmp which is not a git repo
OUTPUT=$(docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp && OPENCODE_PORT=$TEST_PORT bash /workspace/opencode-server.sh --skip-auth 2>&1")
if echo "$OUTPUT" | grep -q "OpenCode server started"; then
  if docker exec "$CONTAINER_NAME" bash -c 'test -f ~/.config/opencode-server.pid'; then
    pass "Data stored in ~/.config/ when not in a git repo"
  else
    fail "PID file not found in ~/.config/ when not in a git repo"
  fi
else
  fail "Script did not start server from non-git directory"
  echo "$OUTPUT"
fi

# Stop the non-git-repo server
docker exec "$CONTAINER_NAME" bash -c \
  "cd /tmp && bash /workspace/opencode-server.sh --stop" >/dev/null 2>&1
sleep 2

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
