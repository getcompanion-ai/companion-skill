#!/usr/bin/env bash
# Companion Offload Script
# Syncs local Claude Code environment to a Companion sandbox and starts a Claude session there.
#
# Usage: ./offload.sh [task_prompt]
# Example: ./offload.sh "finish implementing the API endpoint"
#
# Prerequisites:
#   - companion CLI installed and logged in (companion login)
#   - A running sandbox (companion ls / companion create <handle>)
#   - rsync available locally

set -euo pipefail

TASK_PROMPT="${1:-}"
LOCAL_DIR="$(pwd)"

# --- Check companion CLI ---
if ! command -v companion >/dev/null 2>&1; then
  echo "[offload] ERROR: companion CLI not found. Install with: npm install -g @getcompanion/cli"
  exit 1
fi

echo "[offload] Checking authentication..."
companion whoami || { echo "[offload] ERROR: Not logged in. Run 'companion login' first."; exit 1; }

# --- Get sandbox info ---
echo "[offload] Checking sandbox status..."
SANDBOX_OUTPUT=$(companion ls 2>&1) || { echo "[offload] ERROR: No sandbox found. Create one with: companion create <handle>"; exit 1; }
echo "$SANDBOX_OUTPUT"

# Extract handle from companion ls output
HANDLE=$(echo "$SANDBOX_OUTPUT" | grep -i "handle:" | head -1 | awk '{print $NF}' | tr -d '[:space:]')
if [ -z "$HANDLE" ]; then
  echo "[offload] ERROR: Could not determine sandbox handle from 'companion ls' output."
  exit 1
fi
echo "[offload] Sandbox handle: $HANDLE"

# --- Inject SSH key ---
echo "[offload] Setting up SSH key..."
companion ssh --inject-only 2>&1 || { echo "[offload] ERROR: Failed to inject SSH key."; exit 1; }

# --- Build SSH connection parameters ---
KEY_PATH="$HOME/.companion/ssh/id_ed25519_$HANDLE"
SSH_GATEWAY="${COMPANION_SSH_GATEWAY:-ssh.os.companion.ai}"
SSH_PORT="2222"
PROXY_CMD="sh -c '( printf \"COMPANION:${HANDLE}\n\"; cat ) | nc ${SSH_GATEWAY} ${SSH_PORT}'"

SSH_CMD="ssh -i $KEY_PATH -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ProxyCommand=${PROXY_CMD}"
RSYNC_SSH="ssh -i $KEY_PATH -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ProxyCommand=${PROXY_CMD}"

# --- Determine remote workspace ---
echo "[offload] Checking remote workspace..."
REMOTE_WORKSPACE=$(eval $SSH_CMD node@$HANDLE '[ -d /home/node/.openclaw/workspace ] && echo "/home/node/.openclaw/workspace" || ([ -d /home/node/.pi/workspace ] && echo "/home/node/.pi/workspace" || echo "")' 2>/dev/null || echo "")

if [ -z "$REMOTE_WORKSPACE" ]; then
  REMOTE_WORKSPACE="/home/node/.openclaw/workspace"
  echo "[offload] Creating workspace at $REMOTE_WORKSPACE"
  eval $SSH_CMD node@$HANDLE "mkdir -p $REMOTE_WORKSPACE"
fi
echo "[offload] Remote workspace: $REMOTE_WORKSPACE"

# --- Install Claude if needed ---
echo "[offload] Checking for Claude Code on sandbox..."
HAS_CLAUDE=$(eval $SSH_CMD node@$HANDLE 'command -v claude >/dev/null 2>&1 && echo "yes" || echo "no"' 2>/dev/null)
if [ "$HAS_CLAUDE" = "no" ]; then
  echo "[offload] Installing Claude Code on sandbox..."
  eval $SSH_CMD node@$HANDLE 'curl -fsSL https://claude.ai/install.sh | sh 2>/dev/null || npm install -g @anthropic-ai/claude-code' || {
    echo "[offload] ERROR: Could not install Claude Code on sandbox."
    exit 1
  }
fi

# --- Sync project ---
echo "[offload] Syncing project to sandbox..."
rsync -avz --progress \
  --exclude='node_modules' \
  --exclude='.git/objects' \
  --exclude='__pycache__' \
  --exclude='.venv' \
  --exclude='venv' \
  --exclude='.next' \
  --exclude='dist' \
  --exclude='build' \
  -e "$RSYNC_SSH" \
  "$LOCAL_DIR/" "node@$HANDLE:$REMOTE_WORKSPACE/"

# --- Sync project-level Claude session ---
if [ -d "$LOCAL_DIR/.claude" ]; then
  echo "[offload] Syncing project Claude session data..."
  rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$LOCAL_DIR/.claude/" "node@$HANDLE:$REMOTE_WORKSPACE/.claude/"
fi

# --- Sync global ~/.claude config (settings, memory, global session history) ---
if [ -d "$HOME/.claude" ]; then
  echo "[offload] Syncing global ~/.claude config..."
  rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$HOME/.claude/" "node@$HANDLE:/home/node/.claude/"
fi

# --- Transfer env vars ---
echo "[offload] Transferring environment variables..."
env | grep -v '^_=' | grep -v '^SHELL=' | grep -v '^TERM_' | grep -v '^SSH_' | \
  grep -v '^DISPLAY=' | grep -v '^HOME=' | grep -v '^USER=' | grep -v '^LOGNAME=' | \
  grep -v '^PATH=' | grep -v '^PWD=' | grep -v '^OLDPWD=' | grep -v '^SHLVL=' \
  > /tmp/companion_env_export.txt 2>/dev/null || true
rsync -avz -e "$RSYNC_SSH" /tmp/companion_env_export.txt "node@$HANDLE:$REMOTE_WORKSPACE/.companion_env" 2>/dev/null
rm -f /tmp/companion_env_export.txt

# --- Launch Claude ---
echo "[offload] Launching Claude Code on sandbox..."
echo ""

if [ -n "$TASK_PROMPT" ]; then
  eval $SSH_CMD -t node@$HANDLE "cd $REMOTE_WORKSPACE && set -a && source .companion_env 2>/dev/null; set +a && claude --dangerously-skip-permissions --prompt '$TASK_PROMPT'"
else
  eval $SSH_CMD -t node@$HANDLE "cd $REMOTE_WORKSPACE && set -a && source .companion_env 2>/dev/null; set +a && claude --dangerously-skip-permissions --continue"
fi
