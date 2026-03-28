# Architecture: juso

## Overview

This document describes the implementation behind juso's security layers — the specific technologies, configurations, and design decisions that make each guarantee hold. requirements.md specifies what the platform does; this document explains how.

The architecture has four layers, each independently enforced:

1. **Network isolation** — LAN segmentation enforced by UFW (Uncomplicated Firewall); optional VPN for internet-enabled workloads
2. **VM isolation** — Linux VM managed by UTM/Apple Virtualization Framework
3. **Workload isolation** — per-workload Linux user accounts inside the VM
4. **Runtime capability restriction** — OpenClaw tool policy per agent

Layers 1–3 are enforced by hardware and OS primitives. Layer 4 is enforced by OpenClaw's tool configuration. The hard security guarantees come from layers 1–3; layer 4 is a complementary control. Each layer is described in its own section below — the key property is that they're independent, so no single failure bypasses more than one.

---

## Hardware

The architecture starts with physical separation. Agents run on a dedicated machine that holds no personal data and serves no purpose other than hosting the VM where OpenClaw runs, and running model inference.

**Mac mini (dedicated agent machine)**: All agent workloads run on a dedicated Mac mini with an M-series Apple Silicon chip. The machine holds no personal data. Its only resident workload is running the Linux VM and hosting Ollama for model inference. This physical separation ensures that even a complete host compromise reaches only the Mac mini — not the operator's personal machine or its data.

**MacBook (operator machine — root of trust)**: The operator's personal MacBook is the single point of trust the architecture depends on. The MacBook accesses the Mac mini for management only (SSH, screen sharing). It does not run agent processes.

---

## Layer 1: Network Isolation

Layer 1 controls what agent workloads can reach on the network. It's enforced by UFW at the kernel level, independently of OpenClaw, so it holds regardless of agent configuration or whether OpenClaw is functioning correctly.

### LAN segmentation and VPN

UFW blocks all outbound connections to private LAN address ranges, enforced at the kernel level independently of OpenClaw. This is the primary LAN isolation control — it applies to all workloads regardless of VPN status.

VPN is an optional additional layer, recommended for deployments with `--internet=open` workloads. When configured on the VM, it routes agent internet traffic through a tunnel, providing a kill switch if connectivity drops and preventing direct internet exposure. Without it, `--internet=open` workloads have unencrypted direct internet access; LAN access remains blocked by UFW. The `vpn_status` audit check flags this configuration.

Any WireGuard-compatible VPN with a kill switch and local network passthrough works. See the VM setup guide for a Mullvad-based example. If configured, allow WireGuard outbound in UFW: `ufw allow out to any port 51820 proto udp`.

### Mac mini host hardening

The host macOS installation is minimal: UTM, Ollama, SSH, and screen sharing only. FileVault disk encryption is enabled. No hypervisor shared folders, clipboard sharing, bluetooth, or drag-and-drop between host and VM are configured. The host is a stable inference appliance that changes infrequently.

---

## Layer 2: VM Isolation

Layer 2 is the primary isolation boundary between agent workloads and the Mac mini host. The Linux VM provides a separate kernel and hardware-enforced memory boundaries — breaking out of the VM requires a fundamentally different class of attack than breaking out of a workload.

### Hypervisor: UTM/Apple Virtualization Framework (AVF)

The Linux VM runs inside UTM using Apple Virtualization Framework — hardware-assisted native ARM64 virtualization. AVF provides full OS-level isolation with a separate kernel and hardware-enforced memory boundaries — the VM and the host are separated at the hypervisor level.

Side note: Containers were considered but not used here — they share the kernel with the host, which means a container escape reaches the host directly. AVF is built into macOS, adds no software dependencies, and provides hardware-enforced isolation with a separate kernel.

The VM is configured with no hypervisor-level shared folders (no UTM shared directories, clipboard sharing, or drag-and-drop). The VM filesystem is entirely independent of the host filesystem.

### Linux VM

The VM runs Ubuntu 24 LTS (ARM64). The distribution choice is driven by familiarity and tooling quality; any modern Linux distribution is acceptable. The VM is configured as a semi-disposable workload environment: all provisioning is scripted, and the VM can be destroyed and rebuilt from scripts without requiring manual decisions.

A single clean snapshot is taken after initial provisioning and before any agent workloads run. This snapshot provides a recovery baseline for rollback. A snapshot restore is treated the same as a rebuild — the full validation run should pass before resuming agent workloads.

### VM networking

The VM has two network interfaces:

**Internet access (NAT)**: UTM shared network in NAT (Network Address Translation) mode provides internet connectivity. The VM is not visible as a peer device on the local LAN; it appears to the LAN as the Mac mini's own traffic. This limits the VM's surface from a network scanning perspective.

**Ollama access (AVF virtual network)**: The Apple Virtualization Framework creates a virtual network where the host is reachable at `192.168.64.1`. The VM is assigned an address in `192.168.64.0/24`. Ollama listens on the host at `192.168.64.1:11434` — reachable from the VM, not reachable from the LAN.

UFW enforces the following at the OS level:

- Default outbound policy is deny. All outbound traffic is denied by default for all users.
- Outbound to private IP ranges `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` is blocked.
- Single permitted exception: outbound TCP to `192.168.64.1:11434` (Ollama).
- Cloud instance metadata endpoints (e.g., `169.254.169.254`) are blocked.
- Per-workload internet access is opt-in at provision time via `--internet=open`. This adds a per-UID iptables `--uid-owner` ACCEPT rule in `/etc/ufw/before.rules`, allowing all outbound traffic for that workload's Linux user. Workloads provisioned with `--internet=none` (the default) inherit the global deny-all baseline. The internet setting is fixed at provision time — to change it, destroy and re-provision the workload.

These are hard OS-level guarantees, enforced by the kernel regardless of what OpenClaw does.

### Ollama: on the host, not in the VM

Model inference runs on the Mac mini host, not inside the VM. The VM reaches Ollama over the AVF virtual network. This design choice serves two purposes: first, it keeps model weights and inference capability outside the agent's execution environment, limiting what a compromised VM can directly access or manipulate. Second, it allows the Apple Silicon GPU (Metal) to accelerate inference, which would not be possible from inside the VM.

Ollama must be configured to bind only to the VM-facing interface (`192.168.64.1:11434`), not to all interfaces (`0.0.0.0`). Binding to all interfaces would expose Ollama to any device on the local network — a significant unnecessary exposure. The host-setup guide covers the configuration and verification steps.

---

## Layer 3: Per-Workload Linux User Accounts

Layer 3 isolates workloads from each other within the VM. Each workload runs as a dedicated Linux user, and the kernel enforces filesystem and process boundaries between users — a hard OS guarantee that holds independently of OpenClaw.

### Rationale

OpenClaw's own documentation is explicit on this point: *"tool-level config (tools.allow/tools.deny) is necessary but not sufficient to enforce user-to-user isolation within a single OpenClaw instance."* The recommended approach is one OS user per agent (or per group of cooperating agents).

juso implements this with standard Linux user accounts. Each workload runs under a dedicated Linux user with its own home directory. The Linux kernel enforces filesystem and process boundaries between users — a hard OS-level guarantee that OpenClaw's tool policy cannot override.

A compromised workload cannot read or modify another workload's workspace, session history, or credentials. Agents within the same workload share a Linux user by design — that is how OpenClaw's native multi-agent collaboration works. OpenClaw supports sub-agent delegation (`sessions_spawn`) and direct agent-to-agent messaging (`sessions_send`) within a single gateway; these work naturally because agents in the same workload share a user account. The isolation boundary is workload-to-workload, not agent-to-agent.

**Privilege escalation**: Workload users have no sudo access. A compromised workload cannot escalate privileges within the VM through sudo. The VM admin account (`juso-admin-vm`) has sudo, but scoped to specific infrastructure scripts only — not blanket root access. This is enforced via `/etc/sudoers.d/juso-infrastructure`.

### Per-workload OpenClaw gateway instances

A critical implementation detail: each Linux user runs its own **full default OpenClaw gateway instance**, not a profile gateway.

OpenClaw supports running secondary instances with `--profile <name>`, but profile gateways share the same OS user. That would mean multiple workloads sharing a Linux user, collapsing the isolation Layer 3 depends on. Since each juso workload has its own Linux user, each runs a standard default gateway instead. (Profile gateways also have a known heartbeat bug, GitHub #26846, but the shared OS user is the architectural reason to avoid them.)

Running multiple gateways on the same machine requires each to have a unique port and state directory. OpenClaw doesn't handle this automatically but the juso provisioning scripts do. The scripts assign both the port and state directory at provision time.

### Systemd user services

Each workload's OpenClaw gateway runs as a systemd user service under its Linux user account. Systemd provides:

- Auto-restart on crash
- Boot persistence (`loginctl enable-linger <agent-user>` allows services to persist after logout)
- Log aggregation via `journalctl`
- Resource controls via cgroup (`MemoryMax`, `CPUQuota`)

### Provisioning a new workload

`provision-workload.sh` creates: a dedicated Linux user, installs the OpenClaw gateway service via `openclaw gateway install`, writes an initial `openclaw.json` (gateway config, port assignment, model endpoint — no agent definitions), and assigns a unique port and `OPENCLAW_STATE_DIR`. Agents are added separately with `add-agent.sh`. The workload is ready to receive agents after provisioning.

The provisioning sequence uses `set -e` — any failed command halts immediately without attempting automated rollback. Partial state is left visible for debugging. `destroy-workload.sh` handles deprovisioning. Each workload also gets a `~/shared/` directory for work product files written by agents and synced by the operator.

### Adding an agent to an existing workload

`add-agent.sh` adds a new agent to an already-provisioned workload. It creates a new workspace directory with the agent's markdown files and adds a new entry to the workload's `openclaw.json` under `agents.list`. The gateway is restarted to pick up the change. No new Linux user, port, or systemd service is involved.

This is the path for building multi-agent workloads — a research pipeline, for example, might start with a Collector agent and later have an Analyst and Reporter added to the same workload.

### Agent capability configuration

Each agent's `openclaw.json` specifies exactly which tools it can use. A read-only web research agent should not have shell execution or email access. A validation agent needs shell execution to attempt OS-level violations. Tool configuration is set at provisioning time and is not modifiable by the agent process itself — the `openclaw.json` file is owned by the operator account, not the workload's Linux user.

The known delivery bug ([GitHub Issue #27299](https://github.com/openclaw/openclaw/issues/27299)) — where the `exec` tool is sometimes not delivered to the agent despite being in the allow list — must be verified on the actual running setup before building validation logic around it.

---

## Layer 4: OpenClaw Tool Policy

Layer 4 restricts what individual agents can do within their workload. Unlike layers 1–3, enforcement here comes from OpenClaw rather than the OS — it's a complementary control that reduces blast radius but is not a hard guarantee.

Each agent's capabilities are restricted to what that agent's purpose requires. This is configured in `openclaw.json` under `agents.list[].tools`:

- **Validation agent**: needs `exec` (shell execution) to attempt OS-level violation probes.
- **Web research agents**: need `web_fetch` and file I/O only.

This is enforced by OpenClaw's tool allow/deny system. As stated in requirements.md, this is a soft constraint — a sufficiently sophisticated prompt injection could potentially work around it. The hard isolation comes from layers 1–3. Layer 4 reduces the blast radius of a successful injection against a well-configured agent.

**Gateway bind address**: Each workload's gateway must bind to `127.0.0.1` only, not `0.0.0.0`. This prevents the gateway's WebSocket interface from being reachable from the VM's network interfaces. The ClawJacked attack class exploits browsers opening WebSocket connections to localhost; binding to loopback with a long random auth token raises the brute-force bar.

**OpenClaw version**: The installed version is documented in the setup guide. Updates are evaluated deliberately rather than applied automatically — OpenClaw's CVE history is accumulating rapidly, and new versions can introduce new attack surfaces alongside patches.

---

## The Validation Agent

juso ships a validation agent that actively probes the isolation layers and produces a certifiable audit result. It's the primary agent artifact in this repo — the mechanism by which the platform's guarantees are verified under live conditions rather than inferred from configuration.

The validation agent is a complete OpenClaw agent definition with its own workspace files, tool configuration, and audit script.

**Design**: The validation agent uses the `exec` tool to attempt operations that the security architecture is supposed to block — LAN probing, cross-workload workspace reads, metadata endpoint probes — alongside positive checks that confirm normal operation works. The agent runs each check, interprets the result, and issues a binary verdict: CERTIFIED (all checks pass) or NOT CERTIFIED (one or more failures). The full report is written to the workspace; a summary is printed to the session. The agent does not offer remediation and does not wait for follow-up input.

**Neighbor workload**: Cross-workload isolation tests require a second workload to probe against. A minimal neighbor workload — a provisioned Linux user with a workspace directory — is set up alongside the validation workload as part of the juso reference installation. It does not need a running gateway; its home directory just needs to exist on disk so that access attempts are meaningful.

**Positive scenarios**: The validation agent also confirms that a correctly provisioned agent *can* do what it is supposed to — fetch internet content, write to its workspace, reach Ollama for inference. Isolation tests only have meaning if normal operation is confirmed to work.

**Agent files**: The validation agent is defined by the standard OpenClaw workspace files:

| File            | Content                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------- |
| `SOUL.md`     | Validation agent persona: methodical, security-focused, precise about what each test exercises |
| `AGENTS.md`   | Operating rules: how to run tests, what to record, how to handle inconclusive results          |
| `IDENTITY.md` | Agent name and identifier                                                                      |
| `USER.md`     | Who is running the validation and what they need from it                                       |
| `MEMORY.md`   | Accumulates longitudinal history of validation runs: what passed, what failed, when            |

**Audit execution**: Validation probes are executed by a shell script running as the unprivileged validation workload user. The script performs the behavioral checks, evaluates pass/fail deterministically, and returns structured data. The validation agent writes the report from that data and exits.

**Layer attribution**: Each validation test must explicitly identify which layer it exercises. A test that verifies OpenClaw's tool policy is not a test of OS-level enforcement. Both types of tests are valid; conflating them produces misleading results.

---

## Operator Access

The operator accesses all workloads from their personal machine via SSH tunnel. Agents have no inbound connectivity to the operator machine — the management relationship is strictly one-directional.

The operator accesses the system exclusively via SSH tunnel to the Linux VM. The OpenClaw Control UI (browser-based WebSocket client) is accessed through the tunnel:

```
MacBook → SSH tunnel → Linux VM → OpenClaw Control UI (port 18789)
```

No agent has inbound connectivity. The operator reaches the agents; agents do not reach the operator.

Each workload's gateway has its own port and its own Control UI. A multi-agent workload has one port — all of its agents are visible within a single Control UI session. Each port is accessed via a separate SSH tunnel from the MacBook; the operational guides cover the specifics.

Standard Linux tooling (`journalctl`, `systemctl status`) provides fallback observability when the Control UI is unreachable.

---

## Limitations

These are the known gaps in the current architecture — places where enforcement is soft, relies on OpenClaw rather than the OS, or where coverage hasn't been built yet.

**HTTP method restriction is soft**: GET/HEAD-only enforcement is configured in OpenClaw's tool policy, not the OS firewall. An agent that circumvents OpenClaw's tool policy could make POST requests. This is an accepted residual risk stated in requirements.md.

**Silent OS denials**: When the kernel blocks a cross-workload access attempt or a LAN connection, no log entry is produced. Containment holds; detectability does not. auditd or eBPF monitoring would address this but are not part of the current platform.

**No automated validation gate**: The platform does not enforce a validation run before resuming agent operation after a configuration change. This is the operator's responsibility.

**No ingress filtering**: Web content fetched by agents reaches the model without a classifier layer. OpenClaw natively wraps fetched content in trust boundary markers (`<<<END_EXTERNAL_UNTRUSTED_CONTENT id="...">`), which provides structural separation but not injection detection.

**Prompt injection through authorized channels**: An agent that legitimately fetches a malicious web page can be injected through that content. Infrastructure isolation reduces the blast radius (exfiltration paths are limited; LAN is unreachable; cross-workload contamination requires OS-level escape), but does not prevent the injection itself.

---

## Compromise Sequence

To understand the architecture's overall posture, it helps to trace what a real attack would require — step by step, from initial agent compromise to reaching the operator's personal systems.

To reach sensitive systems from a compromised agent, an attacker must execute these steps in sequence:

1. **Compromise the agent process** — prompt injection, skill supply chain attack, or other agent-level compromise
2. **Escape Linux user isolation** — break OS user/filesystem boundaries within the VM (requires exploiting a kernel vulnerability or misconfiguration)
3. **Escape the VM** — requires a kernel exploit or an Apple Virtualization Framework vulnerability
4. **Compromise the Mac mini host** — pivot from VM escape to host-level access
5. **Break network isolation** — reach the operator's personal machine or LAN devices despite network controls

Getting past one layer doesn't help with the next — each one requires a different kind of attack.
