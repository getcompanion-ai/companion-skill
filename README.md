# Companion Offload Skill

A [skills.sh](https://skills.sh) skill for Claude Code that offloads tasks to a Companion sandbox in the cloud.

## What it does

When you invoke this skill, Claude will:

1. Use `companion ssh` to connect to your sandbox
2. Sync your entire project, environment variables, and Claude session history
3. Install Claude Code on the sandbox if needed
4. Start a Claude Code session with `--dangerously-skip-permissions` so it runs autonomously

The remote session picks up right where you left off - full context, full environment.

## Install

```bash
npx skills add getcompanion-ai/companion-skill
```

## Usage

Inside a Claude Code session, tell Claude to offload:

- "offload this task to my companion"
- "continue this in the cloud"
- "run this on my sandbox"

Or use the standalone script:

```bash
./companion-offload/scripts/offload.sh "finish implementing the API"
```

## Prerequisites

- `companion` CLI installed: `npm install -g @getcompanion/cli`
- Logged in: `companion login`
- A running sandbox: `companion create <handle>`
- `rsync` available locally

## Remote workspace

Files are synced to whichever path exists on the sandbox:

- `/home/node/.openclaw/workspace`
- `/home/node/.pi/workspace`

## Reconnecting

After offloading, reconnect to the remote session:

```bash
companion ssh
cd /home/node/.openclaw/workspace
claude --continue
```

## License

MIT
