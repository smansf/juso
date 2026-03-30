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

Do not run `openclaw onboard` as `juso-admin-vm`. Onboarding is performed by `provision-workload.sh`, which runs it as the workload user via `sudo -u`. Running it manually as `juso-admin-vm` would create a gateway under the wrong account with no workload isolation.

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

## Provisioning approach

`provision-workload.sh` uses `openclaw onboard --non-interactive` to generate the base gateway config, then applies juso-specific values via `openclaw config set`. The generated config is always what the installed OpenClaw version produces — only the specific keys juso cares about are layered on top.

See `scripts/vm/provision-workload.sh` for the full set of config values applied at provision time.

## Expected secrets audit findings

Running `openclaw secrets audit` on any provisioned workload will always report 5 plaintext findings. These are not real secrets and do not need to be resolved:

| Finding | Value | Why ignorable |
|---|---|---|
| `agents.defaults.memorySearch.remote.apiKey` | `ollama-local` | Placeholder string; local Ollama requires no auth |
| `gateway.auth.token` | (random hex) | Local-only token; never leaves the VM |
| `models.providers.ollama.apiKey` | `OLLAMA_API_KEY` | Placeholder; local Ollama requires no auth |
| `profiles.ollama:default.key` (main) | (same placeholder) | Ollama auth profile placeholder |
| `profiles.ollama:default.key` (prospector) | (same placeholder) | Ollama auth profile placeholder |

After configuring the Brave Search API key, run the audit to confirm the Brave key is **not** in the findings. If it appears there, it was entered directly into the wizard rather than read from `.env` and needs to be moved to a SecretRef via `openclaw secrets configure`.
