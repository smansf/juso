# Requirements: juso

This document specifies what juso does — the observable, testable properties of the platform. For how each property is implemented, see `design/architecture.md`. Known limitations are noted where they exist.

---

## My Setup

These requirements are written against my specific stack, but the underlying architecture applies to other hypervisors and Linux distributions.

**Hardware**

- Mac mini M4 Pro — 12-core CPU (8P + 4E), 16-core GPU, 16-core Neural Engine, 64 GB unified memory, 512 GB SSD
- MacBook (operator machine) — personal computer, management access only, root of trust

**Host software**

- macOS
- UTM (Apple Virtualization Framework mode) — manages the Linux VM
- Ollama — model inference server, bound to `192.168.64.1:11434` on the AVF virtual interface
- VPN (optional) — routes agent internet traffic through a tunnel when configured on the VM; recommended for deployments with internet-enabled workloads

**VM**

- Ubuntu 24 LTS ARM64
- Allocation: 16 GB RAM, 6 vCPUs, 128 GB virtual disk
- UFW (Uncomplicated Firewall) for outbound firewall rules
- systemd for service management and resource limits

**Agent runtime**

- OpenClaw — installed at a documented version; updates are evaluated deliberately rather than applied automatically
- One full default gateway instance per workload (Linux user); a workload may contain one or multiple OpenClaw agents

---

## 1. Infrastructure

This section covers the physical and virtual environment juso runs on: the dedicated hardware, where model inference runs, how the network baseline is established, and the requirement that the entire environment be rebuildable from scripts without manual decisions.

**Dedicated hardware**: Agents run inside a Linux VM on the Mac mini, which is physically separate from the operator's personal computer. The VM is managed by UTM using Apple Virtualization Framework.

**Model inference on the host**: Ollama runs on the Mac mini host. The VM reaches it over the AVF virtual network at `192.168.64.1:11434`. Model weights and inference capability live outside the agent execution environment.

**Network isolation**: UFW blocks agent outbound connections to private LAN address ranges at the kernel level. The operator's personal machine can reach the Mac mini for management; agents cannot reach other LAN devices. VPN is an optional additional layer — when configured on the VM, it routes internet-enabled workload traffic through a tunnel rather than directly to the internet.

**Rebuildable environment**: The entire VM environment can be rebuilt from the setup scripts in this repo without requiring prior context or manual decisions beyond what the scripts request. Agent workspace data is the operator's responsibility to back up before a rebuild.

---

## 2. Isolation

These are the security boundaries juso provides. Each is enforced independently — a failure in one doesn't compromise the others, and none of them depend on OpenClaw behaving correctly. The hard guarantees come from the OS and network layers; OpenClaw's tool policies add a complementary layer on top.

**LAN isolation**: Agents can't reach your local network. UFW blocks outbound connections to private IP ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`). The only exception is the Ollama endpoint on the host (`192.168.64.1:11434`). Linux enforces this at the kernel level.

**Internet access**: Internet access is denied by default for all workloads. Workloads that need internet (web research, API calls) are provisioned with `--internet=open`, which adds a per-UID iptables `--uid-owner` ACCEPT rule. Workloads provisioned with `--internet=none` (the default) cannot make any outbound connections beyond Ollama. The internet setting is fixed at provision time — to change it, destroy and re-provision the workload. Per-agent internet control within a workload is not feasible (agents share a Linux user); different internet tiers require different workloads.

**Workload-to-workload isolation**: Each workload gets its own Linux user account. The kernel prevents one workload from accessing another's files, session data, or credentials. Agents within the same workload share a user account by design - that's how OpenClaw's multi-agent collaboration works.

**No runtime capability escalation**: An agent cannot expand its own tool access, network permissions, or filesystem scope at runtime. Capability is fixed at provisioning time in `openclaw.json` and the agent process has no write access to that file.

**Skill immutability during runs**: An agent cannot modify its own skill files during a run. Skill directories are owned by the operator account and are read-only to the agent process.

**Ollama scoped to the VM interface**: The Ollama service on the Mac mini host binds only to `192.168.64.1`, making it reachable from the VM and nowhere else on the local network.

**No hypervisor shared folders**: The VM has no hypervisor-level shared folder mounts — no UTM shared directories, clipboard sharing, or drag-and-drop. The VM filesystem is entirely independent of the host filesystem.

**Known limitation — silent OS denials**: When Linux blocks an access attempt, it doesn't log it. If an agent tries to access another workload's files or write somewhere it shouldn't, the system stops it but you won't see a log entry. The containment works, but you won't know it happened.

---

## 3. Operations

The platform supports a defined set of operations for managing workloads and agents, each backed by a script. These cover the full lifecycle from provisioning through decommissioning, plus day-to-day agent execution, monitoring, and configuration updates.

**Provision new workload**: The operator can provision a new workload by running `provision-workload.sh`. This creates a dedicated Linux user account, installs the OpenClaw gateway service, writes an initial `openclaw.json` (gateway config, port assignment, model endpoint — no agent definitions), and assigns a unique port and `OPENCLAW_STATE_DIR`. Agents are added separately with `add-agent.sh`. The workload is ready to receive agents after provisioning.

**Remove workload**: The operator can fully deprovision a workload by running `destroy-workload.sh`. This stops the gateway, uninstalls the service, deletes the Linux user and all associated data, and removes the registry entry. This operation is irreversible.

**Add agent to existing workload**: The operator can add a new agent to an existing workload by running `add-agent.sh`. This creates a new workspace directory with the agent's markdown files and adds a new entry to the workload's existing `openclaw.json` under `agents.list`. The gateway is restarted to pick up the change. No new Linux user, port, or systemd service is created.

**Remove agent from workload**: The operator can remove a single agent from a workload by running `remove-agent.sh`. This removes the agent's configuration and workspace and restarts the gateway if other agents remain. This operation is irreversible.

**On-demand and scheduled execution**: The operator can trigger an agent run on demand via the OpenClaw Control UI or CLI. Recurring runs can be scheduled via OpenClaw's cron system. A new scheduled run does not start if a run for the same agent is already in progress.

**Monitoring**: The operator can monitor agent activity — task history, tool calls, session logs — via the OpenClaw Control UI over an SSH tunnel from the personal machine, without requiring an interactive shell session in the VM. Standard Linux tooling (`journalctl`, `systemctl status`) provides fallback infrastructure-level observability when the Control UI is unreachable.

**Environment rebuild**: The operator can destroy and rebuild the entire VM environment using the setup scripts and redeploy all agents. The rebuild procedure is fully documented and executable without prior context.

**Agent configuration updates**: The operator can update an agent's workspace files (SOUL.md, HEARTBEAT.md, AGENTS.md, etc.) and `openclaw.json` without reprovisioning the agent from scratch.

**Skill management**: Skills are installed manually by the operator after review. No skills are installed from ClawHub or any community source without the operator reading the skill content first. The operator accepts responsibility for the behavior any installed skill directs the agent to perform.

---

## 4. Validation

The validation framework certifies that the isolation layers are working as expected, not just configured correctly. It's designed to be re-run after any infrastructure change — and to distinguish clearly between a test of OS-level enforcement and a test of OpenClaw's tool policy, since those are different things.

**Active violation probing**: The validation agent tries to break the rules - it attempts LAN access, tries to read other workloads' files, attempts out-of-scope writes, and probes metadata endpoints. The OS and network layers decide what succeeds or fails, and everything gets logged.

**Neighbor workload required for isolation testing**: Cross-workload isolation tests can only run if a second workload exists to probe against. The validation setup must provision a minimal neighbor workload — a Linux user with a workspace directory — alongside the validation workload. The neighbor workload does not need a running gateway; its workspace just needs to exist on disk for the probe attempts to be meaningful.

**Positive scenario coverage**: The validation agent must also verify that a well-configured agent can do what it is supposed to — fetch internet content, write to its workspace, reach Ollama for inference. Containment tests only have meaning alongside confirmation that normal operation works.

**Longitudinal audit trail**: The validation agent's MEMORY.md accumulates a history of validation runs — what was tested, what passed, what failed, and when. This provides a record of the platform's security posture over time and makes regressions visible.

**Deterministic audit execution**: A shell script runs the actual validation tests as the unprivileged validation user. The script determines pass/fail and returns structured data - the validation agent just writes the human-readable report. This keeps the AI out of the pass/fail decisions.

**Intra-workload coordination**: The validation setup must verify that agents within the same workload can share workspace files — confirming that intra-workload collaboration works as expected. This is distinct from isolation testing: it confirms the platform does not accidentally break the sharing that multi-agent workloads depend on.

**Layer attribution**: Each test clearly identifies which security layer it's checking. Testing OpenClaw's tool policy is different from testing OS-level enforcement — both matter, but they're not the same thing.

---

## 5. Scope Limits

These are the things juso explicitly doesn't address. Some have clear paths forward; others are outside juso's scope by design.

- **Real-time violation detection**: OS permission denials are silent. Detecting them requires external monitoring such as auditd or eBPF, which juso doesn't provide.
- **Defense against a compromised operator machine**: the personal machine used to manage juso is the root of trust. A compromise there bypasses the management layer entirely; this is outside juso's scope by design.
- **Perfect prompt injection prevention**: juso limits the damage from prompt injection but can't prevent agents from being compromised through legitimate web content they fetch. Input classifiers such as Llama Guard could be added as a layer between fetched content and the model.
- **Guaranteed HTTP method restriction**: GET/HEAD-only restrictions are set in OpenClaw's configuration, not enforced by the OS. A compromised agent could potentially bypass this. Moving enforcement to iptables would make this a hard OS-level guarantee.
- **Browser automation**: works within juso's existing isolation; no additional juso-level hardening designed yet.
- **Credentialed agent access to external services**: API keys scoped to a workload user are isolated from other workloads by the OS; no credential management facility beyond that is provided.
- **Automated recertification gating**: juso doesn't automatically run validation tests after configuration changes. Running validation after any infrastructure change is the operator's responsibility; a pre-run hook could automate this.
