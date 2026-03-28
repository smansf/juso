# OpenClaw setup

This guide installs OpenClaw on the Linux VM at the system level. It covers the binary install and verification only. Per-workload configuration — the `openclaw.json` config, gateway service, and agents — is handled by `provision-workload.sh` when a workload is created.

Run everything in this guide on the VM as `juso-admin-vm`.

---

## Prerequisites

- VM setup complete (see mini-vm-setup.md)
- Ollama running on the Mac mini and reachable at `192.168.64.1:11434`

---

## Part 1: Install Node.js

OpenClaw requires Node.js ≥ 22. Install the current LTS release via NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
```

Verify:

```bash
node --version
npm --version
```

---

## Part 2: Install OpenClaw

Install the OpenClaw CLI globally so that all workload user accounts created later by `provision-workload.sh` can access the binary:

```bash
sudo npm install -g openclaw
```

Do not run `openclaw onboard`. The onboarding wizard installs a gateway service under whichever user runs it — here, `juso-admin-vm`. That is the wrong account. Each workload needs its own gateway running under its own dedicated Linux user, which is what `provision-workload.sh` handles. Running onboard first would create a rogue gateway under the admin account with a default catch-all agent and no workload isolation.

Verify:

```bash
openclaw --version
```

juso was built and tested on **v2026.3.13**. Later releases were not stable enough at time of publication.

---

## Part 3: Run doctor

`openclaw doctor` checks the binary environment. Run it as `juso-admin-vm`:

```bash
openclaw doctor
```

At this stage — before any workload is provisioned — several warnings are expected and ignorable:

| Warning | Status |
|---------|--------|
| `NODE_COMPILE_CACHE is not set` | Ignore — minor startup optimisation, not needed |
| `OPENCLAW_NO_RESPAWN is not set` | Ignore — startup overhead hint for low-power hosts, not needed |
| `X skills missing requirements` | Ignore — skills whose required binaries are absent simply do not load |
| `gateway.mode is unset` | Expected — `juso-admin-vm` has no `~/.openclaw`; mode is set correctly in the workload config template |
| `Gateway auth is off or missing a token` | Expected — auth is configured per workload when the gateway first starts |
| `CRITICAL: state directory missing` | Expected — consequence of declining to create `~/.openclaw` for the admin account |
| `Gateway service not installed` | Expected — installed per workload by `provision-workload.sh`, not here |

Doctor prompts for several interactive choices. Answer **No** to all of them: do not generate a token, do not create `~/.openclaw`, do not install the gateway service. Answering Yes to any of these would configure OpenClaw under the admin account, which is the wrong place.

Any warning not in this table should be investigated before proceeding.

---

## Part 4: Verify Ollama reachability

Confirm the VM can reach Ollama on the Mac mini before any workload relies on it:

```bash
curl -s http://192.168.64.1:11434/api/version
# Should return a JSON response with the Ollama version

curl -s http://192.168.64.1:11434/api/tags | jq '.models[].name'
# Should list qwen3:30b and nomic-embed-text
```

If either check fails, resolve it before continuing. OpenClaw will start but all inference and memory search requests will fail silently.

---

## Base configuration template

`~/juso/scripts/openclaw.json.template` on the VM (copied from `scripts/vm/openclaw.json.template` in the repo) is the base configuration that `provision-workload.sh` copies into each new workload user's `~/.openclaw/openclaw.json`. It is not used directly by `juso-admin-vm`.

Key decisions embedded in the template:

- **Ollama at `192.168.64.1:11434`** — the AVF virtual network address. The VM reaches the Mac mini host here; LAN and internet addresses are blocked by UFW.
- **`api: "ollama"`** — OpenClaw's native Ollama API mode. Tool calling is only reliable via the native API; the OpenAI-compatible `/v1` endpoint breaks tool calls with Ollama.
- **`provider: "openai"` for memory search** — despite using Ollama, the config validator rejects `"ollama"` as a provider value. The memory search `baseUrl` retains `/v1/` — correct for the embeddings endpoint only, which is not affected by the tool-calling issue.
- **`skills.allowBundled: []`** — disables the five bundled OpenClaw skills (healthcheck, node-connect, tmux, weather, skill-creator) which are irrelevant for juso workloads and consume ~700 context tokens per session. Individual workloads can override this if a bundled skill is genuinely needed.
- **`bind: "loopback"`** — the gateway only listens on `localhost`. It is never exposed on the VM's network interface.
- **`port: __PORT__`** — placeholder substituted by `provision-workload.sh` with the workload's assigned port.
- **`agents.list: []`** — no agents defined at provision time. Agents are added by `add-agent.sh` after the workload is running.

Web search credentials (`BRAVE_API_KEY` or equivalent) are not part of the template — they are configured per-workload after provisioning. See the provisioning guide for details.

---

## What comes next

OpenClaw is now installed system-wide. Nothing runs yet. The next step is workload provisioning — see the provisioning guide — which creates a Linux user, copies and customises the config template, and installs the per-workload gateway service.

Proceed to the provisioning guide.
