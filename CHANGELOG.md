# Changelog

## v0.2.0 — 2026-06-10

v0.1.0 was built for a human operator running setup guides and provisioning commands by hand. Dogfooding juso on a real workload made that model feel like the wrong fit. v0.2.0 ships a complete set of commands designed for an AI agent operator — provisioning workloads, pushing scripts, patching config, tailing logs, managing secrets — without a human involved at each step. The operator agent runs on the personal machine and has no workload-level access inside the VM.

v0.1.0 isolated workloads from each other and from the network, but within a workload an agent had too much reach: it could read privileged scripts, overwrite its own config, and see what the operator was doing. v0.2.0 closes that. Privileged scripts are now owned by root and invisible to the agent process. The agent's config file is read-only to the agent. A new gateway is the only way to run privileged operations, and it checks on every call that the request is legitimate. Both boundaries are verified two ways: a static ownership check, and a live check that proves them from inside the workload by attempting the blocked operations and confirming they fail.

### Breaking

- **Workload username prefix removed.** Workload Linux accounts no longer use the `juso-` prefix — the workload name is the Linux username directly (e.g. `research`, not `juso-research`). Existing accounts must be renamed or destroyed and re-provisioned before upgrading. The `neighbor` and `validation` workloads used by the validation setup are affected: rename `juso-neighbor` → `neighbor` and `juso-validation` → `validation` (or destroy and re-provision both).
- **`juso-push-shared` removed.** `shared/` is VM-canonical — agents write there during runs; pushing from the repo would overwrite live work. Use `juso-pull-shared` to back up the directory from the VM. For emergency restore, rsync manually with explicit path targeting.

### Added

- **`audit-acl.sh`** — static ownership and mode check for the kernel-ACL script tiers (`agent/`, `ops/`, `lib/`) and `openclaw.json`. Run by the operator via `sudo`; JSON output, same shape as `audit.sh`.
- **`acl-behavioural` layer in `audit.sh`** — three negative checks run as the workload user: `ops/` must be unreadable, `agent/` must be unwritable, `openclaw.json` must be unwritable. Proves the ACL boundary holds from inside the workload, not just from file metadata.
- **`juso-ops-exec`** — sole privileged gateway for running ops-tier scripts after the kernel-ACL flip. Enforces three checks on every call: caller is a `juso-workloads` member, target script is in the caller's own `~/scripts/ops/` (no path traversal), and the target file is owned `root:root`.
- **`juso-rsync-scripts` / `juso-push-scripts`** — staged script push that materialises the `agent/ops/lib` ownership matrix on the VM. Scripts in `ops/` are set `root:root 750`; `agent/` and `lib/` are `root:root 755`.
- **`vm-exec`** — run any command on the VM as the workload user from the MacBook without an interactive shell session.
- **`juso-write-secret` / `juso-check-secret`** — write and verify workload secrets in `~/.openclaw/.env` without echoing values to the terminal.
- **`juso-configure-telegram`** — configure Telegram channels with token precondition enforcement (`TELEGRAM_BOT_TOKEN` must be written before any config is applied).
- **`juso-config-set`** — patch `openclaw.json` as root while preserving `root:<workload> 640` ownership.
- **`juso-logs`** — tail the workload gateway log from the MacBook.
- **`juso-wipe-agent`** — wipe an agent's workspace files; `--reset-memory` also clears `MEMORY.md`.
- **`juso-clear-sessions`** — clear stored sessions for a workload.
- **`juso-pair-cli-device`** — pair a CLI device using least-privilege scopes.
- **`--agents-dir <subdir>`** flag on `juso-push-agent` — for workload repos that organise agent files under a subdirectory.
- **`--force`** and **`--non-interactive`** flags on relevant provisioning commands.

### Changed

- **Workload identity is now group-based.** All juso primitives gate on `juso-workloads` group membership (`getent group juso-workloads`) instead of `/home/juso-*/` path globbing. A home directory without group membership is invisible to listing, audit, config-set, and rsync.
- **Provisioning creates the kernel-ACL scripts skeleton.** `provision-workload.sh` creates `~/scripts/{agent,ops,lib}/` with the correct ownership matrix (`agent/` 755, `ops/` 750, `lib/` 755, all `root:root`) and sets `openclaw.json` to `root:<workload> 640` — readable by the workload process, not writable.
- **Provisioning baseline expanded.** `thinkingDefault=off` (prevents Qwen3 thinking-mode loop crash) and `idleTimeoutSeconds=1800` (30 min, for local model KV-cache load time) are now set. `tools.profile` defaults to `minimal` rather than `default`.
- **`juso-push-agent` preserves `MEMORY.md`.** If `MEMORY.md` already exists on the VM, it is excluded from the push rather than overwritten.
- **`juso-run-agent` dispatches through the gateway API.** No `--local` flag, no 30-minute ceiling; runs use isolated sessions.
- **Telegram tokens via `SecretRef`.** Tokens are read from `~/.openclaw/.env` at runtime rather than stored inline in `openclaw.json`.

### Fixed

- `tools.profile` now applied correctly during provisioning (was silently ignored).
- `idleTimeoutSeconds` now written to the correct config path (was written to a path OpenClaw ignored).
- `thinkingDefault` now applied correctly during provisioning.
- `juso-status` probes Ollama at the VM bridge IP (`192.168.64.1`) — was using an incorrect address and always reporting unreachable.

### Compatibility

Tested against OpenClaw 2026.4.8. Note: 2026.4.8 hardcodes `idleTimeoutSeconds` to 60s on embedded runs, silently overriding the provisioned 1800s value. Run the `main` agent on `qwen3:30b` as a workaround — this is a known upstream issue in 2026.4.8.

---

## v0.1.0 — 2026-04-02

Initial release. juso provides defense-in-depth isolation for OpenClaw agents running on personal hardware — a layered architecture so that a compromised agent faces a chain of distinct barriers rather than a single point of failure.

Four independently-enforced isolation layers: UFW outbound firewall blocking LAN access at the kernel level (Ollama at `192.168.64.1:11434` the sole permitted outbound exception), Linux VM via UTM/Apple Virtualization Framework, per-workload Linux user accounts with kernel-enforced filesystem and process boundaries, and OpenClaw tool policy as a complementary layer. Workloads are provisioned with explicit internet access (`--internet=open`) or none (`--internet=none`). VPN is an optional additional layer for internet-enabled workloads.

Includes a validation agent that actively probes the isolation layers — attempting LAN connections, cross-workload file reads, and metadata endpoint requests — and produces a binary CERTIFIED / NOT CERTIFIED result per check. Designed to be re-run after any configuration change, not just at initial setup.

---
