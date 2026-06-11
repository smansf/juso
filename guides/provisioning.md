# Provisioning

A workload is a dedicated Linux user account running its own OpenClaw gateway instance on its own port. This guide covers creating a workload with `provision-workload.sh` and adding an agent to it with `add-agent.sh`.

Run everything in this guide on the VM as `juso-admin-vm`.

---

## Prerequisites

- OpenClaw setup complete (see openclaw-setup.md)
- Ollama running and reachable at `192.168.64.1:11434`

---

## Part 1: Provision a workload

`provision-workload.sh` creates the Linux user, sets up the OpenClaw config and directory structure, and installs the per-workload gateway service.

Run from the repo root:

```bash
sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>
```

The workload name is used directly as the Linux username. Naming rules: lowercase letters, digits, and hyphens only; must start with a letter; 31 characters maximum.

`--model-id` and `--context-tokens` are required. They specify the Ollama model and context window size for all agents in the workload. The right values depend on which model you have pulled in Ollama and your hardware. Example:

```bash
sudo ~/juso/scripts/provision-workload.sh --internet=open --model-id qwen3:30b --context-tokens 32768 research
```

The script assigns a port automatically, starting at 18789 and incrementing for each additional workload. The assigned port is stored in the workload's `openclaw.json` and read at runtime by `juso-workload-list` — the helper that `juso-list`, `juso-dashboard`, and the status functions all use.

By default, workloads have no internet access (`--internet=none`). Workloads that need to fetch web content or call external APIs should be provisioned with `--internet=open`, which adds a per-UID iptables rule allowing all outbound traffic for that workload's Linux user. The internet setting is fixed at provision time — to change it, destroy and re-provision. Example:

```bash
sudo ~/juso/scripts/provision-workload.sh --internet=open --model-id qwen3:30b --context-tokens 32768 research
```

If the script fails partway through, re-running it is safe. Each step checks whether it has already been completed and skips if so.

### What the script creates

| Item | Location |
|------|----------|
| Linux user | `<workload>` |
| OpenClaw config | `/home/<workload>/.openclaw/openclaw.json` (owned `root:<workload>` mode `640`) |
| Gateway service | `/home/<workload>/.config/systemd/user/openclaw-gateway.service` |
| `scripts/` skeleton | `/home/<workload>/scripts/{agent,ops,lib}/` with kernel ACL (see [operations.md](operations.md#scriptsagentopslib-kernel-acl)) |
| `audit.sh` | `/usr/local/bin/audit.sh` (overwritten each provision) |

`juso-ctl`, `juso-workload-list`, `juso-config-set`, `juso-rsync-scripts`, `juso-ops-exec`, `audit-acl.sh`, and the sudoers rules are installed by `install-vm-infrastructure.sh`, which is run as part of macbook-setup.md Part 8.

### Verify

```bash
# Workload appears in list
sudo juso-workload-list

# User exists
id <workload>

# Config is present and port is correct
cat /home/<workload>/.openclaw/openclaw.json | grep port

# Service file installed
ls /home/<workload>/.config/systemd/user/openclaw-gateway.service

# Linger enabled
loginctl show-user <workload> | grep Linger
```

The gateway service is installed but not started. An empty gateway (no agents) is harmless but pointless — add at least one agent before starting.

**Web search credentials (if needed)**

If the workload will use `web_search`, write the Brave Search API key before starting the gateway. OpenClaw auto-detects it from `~/.openclaw/.env`:

```bash
juso-write-secret <workload> BRAVE_API_KEY
```

Obtain a Brave Search API key at `brave.com/search/api/` (free tier: $5/month credit, ~1,000 queries/month). Set a usage cap in the Brave dashboard.

---

## Part 2: Add an agent

An agent is a persona with its own workspace, prompt files, tool policy, and bindings. A workload can have multiple agents, each handling different tasks or channels. Agents are added with `add-agent.sh`.

```bash
sudo ~/juso/scripts/add-agent.sh <workload-name> <agent-name>
```

**Naming convention:** agent IDs use the role name only — no workload prefix. The workload context is already provided by the gateway, the Linux user account, and the workload argument in all juso commands. The role name is a noun describing what the agent does (e.g. `-or`/`-er` suffix: `collector`, `auditor`, `tracker`). Examples: `collector`, `auditor`, `tracker`.

**The `main` agent** is OpenClaw's reserved default agent. It is configured automatically at provision time with its workspace at `~/.openclaw/workspace/main/`. Do not add it manually via `add-agent.sh` — doing so will error. Deploy its workspace files with `juso-push-agent <workload> main`. If agent files are organised under a subdirectory (e.g. `agents/`), pass `--agents-dir <subdir>`: `juso-push-agent <workload> main --agents-dir agents`.

Note: the `validation-auditor` agent was created under the previous `<workload>-<role>` convention and has not been renamed.

This scaffolds the agent's workspace directory, seeds the bootstrap prompt files, and adds the agent entry to the workload's `openclaw.json`.

See the agent's workspace files after creation:

```bash
ls /home/<workload>/.openclaw/workspace/<agent-name>/
# SOUL.md    AGENTS.md    USER.md    MEMORY.md    BOOTSTRAP.md
```

These files define who the agent is and how it behaves. Edit them before starting the gateway — they are loaded at session start and injected into the system prompt.

---

## Part 2b: Configure Telegram (optional)

If the workload uses Telegram as a channel, configure it after adding agents and before starting the gateway.

**Write the token first.** `juso-configure-telegram` requires `TELEGRAM_BOT_TOKEN` to already be
set — it enforces this as a precondition and fails fast before writing anything to `openclaw.json`.
Set the token with:

```bash
juso-write-secret <workload> TELEGRAM_BOT_TOKEN
```

This prevents the gateway from starting in a broken state: OpenClaw 2026.4.8+ hard-fails at startup
if a Telegram SecretRef is configured but the token is absent from `~/.openclaw/.env`.

```bash
juso-configure-telegram <workload> \
  --allowlist "<space-separated Telegram user IDs>" \
  --groups "<space-separated group IDs>" \
  [--ack-reaction <emoji>]
```

Example:

```bash
juso-configure-telegram research \
  --allowlist "123456789 987654321" \
  --groups "-1001234567890" \
  --ack-reaction "👀"
```

`--ack-reaction` is optional but recommended: the bot reacts to messages to confirm receipt while processing.

After running the command, restart the gateway for the change to take effect:

```bash
juso-stop-workload <workload>
juso-start-workload <workload>
```

---

## Part 3: Start the gateway

Once at least one agent is configured, start the gateway service:

```bash
sudo juso-ctl <workload> start
```

Verify it is running:

```bash
sudo juso-ctl <workload> status
```

From the MacBook, open the dashboard:

```bash
juso-dashboard <workload>
```

`juso-dashboard` handles everything in one command: opens the SSH tunnel, retrieves the dashboard token URL from the VM, and opens the browser with the full token URL. The token travels over the encrypted SSH tunnel and is never stored on the MacBook. After first login the token is stored locally by the browser — subsequent visits only need `http://localhost:<port>`.

---

## Quick reference

| Task | Command |
|------|---------|
| Provision workload | `sudo ~/juso/scripts/provision-workload.sh [--internet=none\|open] --model-id <model> --context-tokens <n> <workload>` |
| Destroy workload | `sudo ~/juso/scripts/destroy-workload.sh <workload>` |
| Add agent | `sudo ~/juso/scripts/add-agent.sh <workload> <agent>` |
| Remove agent | `sudo ~/juso/scripts/remove-agent.sh <workload> <agent>` |
| Start gateway | `sudo juso-ctl <workload> start` |
| Stop gateway | `sudo juso-ctl <workload> stop` |
| Restart gateway | `sudo juso-ctl <workload> restart` |
| Check status | `sudo juso-ctl <workload> status` |
| List workloads | `juso-list` (from MacBook) |
| Open dashboard | `juso-dashboard <workload>` (from MacBook) |

Proceed to the validation guide to verify the platform before trusting it with real workloads.
