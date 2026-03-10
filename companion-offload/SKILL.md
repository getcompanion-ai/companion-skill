---
name: companion-offload
description: Offload a Claude Code task to a remote Companion sandbox via SSH. Use when the user wants to continue a task in the cloud, run something remotely, or offload work to their Companion sandbox. Triggers on "offload", "run in cloud", "companion run", "remote task", or "send to sandbox".
compatibility: Requires the companion CLI (npm install -g @getcompanion/cli), an active Companion sandbox, and rsync. Designed for Claude Code.
allowed-tools: Bash(companion:*) Bash(rsync:*) Bash(scp:*) Bash(ssh:*) Bash(cat:*) Bash(env:*) Read
---

# Companion Offload

Offload the current Claude Code session to a remote Companion sandbox so it can continue running autonomously in the cloud.

## When to use

- The user says "offload this task" or "run this in the cloud"
- A long-running task needs to continue without tying up the local machine
- The user wants to hand off work to their Companion sandbox

## Prerequisites

- The `companion` CLI must be installed and the user must be logged in (`companion login`)
- An active sandbox must exist and be running (`companion ls` to check)
- `rsync` must be available locally

## Instructions

### Step 1: Verify companion CLI is available and user is logged in

```bash
companion whoami
```

If this fails, tell the user to run `companion login` first.

### Step 2: Check that a sandbox is running

```bash
companion ls
```

If no sandbox exists or it's not running, tell the user to create one with `companion create <handle>`.

### Step 3: Inject SSH key into the sandbox

Use `--inject-only` to set up SSH access without connecting:

```bash
companion ssh --inject-only
```

This outputs the SSH key path and the manual SSH command. Parse the output to extract:
- The key path (e.g. `~/.companion/ssh/id_ed25519_<handle>`)
- The sandbox handle

### Step 4: Build the SSH/rsync connection parameters

The Companion SSH gateway uses a ProxyCommand. Construct the connection parameters:

```bash
HANDLE="<sandbox-handle-from-step-2>"
KEY_PATH="$HOME/.companion/ssh/id_ed25519_$HANDLE"
SSH_GATEWAY="${COMPANION_SSH_GATEWAY:-ssh.os.companion.ai}"
SSH_PORT="2222"
PROXY_CMD="sh -c '( printf \"COMPANION:${HANDLE}\n\"; cat ) | nc ${SSH_GATEWAY} ${SSH_PORT}'"
SSH_OPTS="-i $KEY_PATH -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ProxyCommand=$PROXY_CMD"
```

### Step 5: Determine the remote workspace path

```bash
ssh $SSH_OPTS node@$HANDLE '[ -d /home/node/.openclaw/workspace ] && echo "/home/node/.openclaw/workspace" || ([ -d /home/node/.pi/workspace ] && echo "/home/node/.pi/workspace" || echo "NONE")'
```

If `NONE`, use `/home/node/.openclaw/workspace` and create it:

```bash
ssh $SSH_OPTS node@$HANDLE 'mkdir -p /home/node/.openclaw/workspace'
```

Store the result as `REMOTE_WORKSPACE`.

### Step 6: Install Claude Code on the sandbox if missing

```bash
ssh $SSH_OPTS node@$HANDLE 'command -v claude >/dev/null 2>&1 && echo "installed" || echo "missing"'
```

If missing:

```bash
ssh $SSH_OPTS node@$HANDLE 'curl -fsSL https://claude.ai/install.sh | sh 2>/dev/null || npm install -g @anthropic-ai/claude-code'
```

### Step 7: Sync the repository to the sandbox

Use rsync over the SSH ProxyCommand to transfer the current project:

```bash
rsync -avz --progress \
  --exclude='node_modules' \
  --exclude='.git/objects' \
  --exclude='__pycache__' \
  --exclude='.venv' \
  --exclude='venv' \
  --exclude='.next' \
  --exclude='dist' \
  --exclude='build' \
  -e "ssh $SSH_OPTS" \
  "$(pwd)/" "node@$HANDLE:$REMOTE_WORKSPACE/"
```

### Step 8: Sync the Claude session history

Transfer the local `.claude/` directory (session history, settings, memory) so the remote Claude session has full context:

```bash
rsync -avz --progress \
  -e "ssh $SSH_OPTS" \
  "$(pwd)/.claude/" "node@$HANDLE:$REMOTE_WORKSPACE/.claude/"
```

### Step 9: Transfer environment variables

Capture relevant env vars (especially ANTHROPIC_API_KEY) and send them to the sandbox:

```bash
env | grep -v '^_=' | grep -v '^SHELL=' | grep -v '^TERM_' | grep -v '^SSH_' | \
  grep -v '^DISPLAY=' | grep -v '^HOME=' | grep -v '^USER=' | grep -v '^LOGNAME=' | \
  grep -v '^PATH=' | grep -v '^PWD=' | grep -v '^OLDPWD=' | grep -v '^SHLVL=' \
  > /tmp/companion_env_export.txt
rsync -avz -e "ssh $SSH_OPTS" /tmp/companion_env_export.txt "node@$HANDLE:$REMOTE_WORKSPACE/.companion_env"
rm -f /tmp/companion_env_export.txt
```

### Step 10: Launch Claude Code on the sandbox

If the user provided a specific task/prompt to offload:

```bash
ssh -t $SSH_OPTS node@$HANDLE "cd $REMOTE_WORKSPACE && set -a && source .companion_env 2>/dev/null; set +a && claude --dangerously-skip-permissions --prompt '${TASK_PROMPT}'"
```

Otherwise, continue the session:

```bash
ssh -t $SSH_OPTS node@$HANDLE "cd $REMOTE_WORKSPACE && set -a && source .companion_env 2>/dev/null; set +a && claude --dangerously-skip-permissions --continue"
```

### Step 11: Confirm to the user

After launching, tell the user:
- The session is now running on their Companion sandbox
- They can reconnect with: `companion ssh` then `cd $REMOTE_WORKSPACE && claude --continue`
- To sync results back locally: `rsync -avz -e "ssh $SSH_OPTS" node@$HANDLE:$REMOTE_WORKSPACE/ ./`

## Important notes

- Always exclude `node_modules`, `.git/objects`, and other large directories from rsync
- The `--dangerously-skip-permissions` flag is required so the remote session runs autonomously
- If the sandbox already has `ANTHROPIC_API_KEY` set, the offloaded session will use it. Otherwise ensure Step 9 transfers it.
- Session history in `.claude/` gives the remote Claude full context of the local conversation
- The SSH gateway at `ssh.os.companion.ai:2222` routes connections via the `COMPANION:<handle>` prefix

## Error handling

- If `companion whoami` fails: user needs to `companion login`
- If `companion ls` shows no sandbox: user needs to `companion create <handle>`
- If SSH key injection fails: sandbox may not be running
- If rsync fails: check disk space on sandbox
- If Claude is not installable: ensure Node.js >= 18 is on the sandbox
