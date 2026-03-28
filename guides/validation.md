# Validation

Validation answers two questions: are the juso platform services running correctly, and do the security guarantees actually hold? Both must pass before agents are trusted with real workloads.

Run everything in this guide on the VM as `juso-admin-vm` unless otherwise noted.

---

## Validation architecture

Validation uses two components with a clear division of responsibility.

`audit.sh` runs the checks. It executes every validation probe as the unprivileged `juso-validation` workload user, evaluates PASS/FAIL deterministically, and returns structured JSON.

The validation auditor agent writes the report. It invokes `audit.sh`, receives the JSON results, writes the markdown audit report, replies with the verdict summary, and exits.

This split keeps the approach sound and efficient. Behavioral checks run inside the same containment boundary as a real workload. Deterministic checks stay in shell, where they are fast and unambiguous. The model is used for report writing, not for adjudicating raw check results.

---

## Behavioral validation

The central principle is behavioral over configuration: do not merely check that a firewall rule exists — try the operation the rule is supposed to block, and record what happens. A rule that exists but is ordered incorrectly, applied to the wrong interface, or superseded by a broader rule does nothing. Only a live probe tells you whether the containment actually holds.

This applies equally to positive checks. A gateway service that systemd reports as active but fails to bind its port is broken. Checking the service state is not enough; checking that the port responds is.

Configuration checks are not included. They describe how the system is set up, not whether it behaves correctly. Every check in this audit attempts the guarded operation and records the result.

The prescribed check list defines the minimum set of concerns that must be verified. If the auditor encounters something outside the check list that appears to indicate a failure — an unexpected listener, a novel misconfiguration, a suspicious response — it should report it as a FAIL.

---

## The validation auditor

The validation auditor is an OpenClaw agent running in the `validation` workload. It calls a single shell script (`audit.sh`) that runs all behavioral checks, evaluates pass/fail deterministically, and returns structured JSON. The agent receives that JSON and writes a narrative markdown report. It runs once per invocation, writes the report, and exits.

This split means: the script handles all check execution (under 30 seconds, fully unprivileged, no model involved); the model does one inference pass to write the formatted report. A full audit cycle completes in under 2 minutes.

**Verdict taxonomy:** Binary. Every check is either PASS or FAIL. No warnings. If a result is ambiguous, it is a FAIL. A CERTIFIED verdict requires zero FAILs across all checks.

**Scope boundary:** The audit certifies behavior from the perspective of the `juso-validation` workload user. It verifies what an unprivileged workload can reach, read, execute, or escalate to from inside the containment boundary.

---

## Setup

### Prerequisites

- Two workloads provisioned: `validation` and `neighbor`
- `neighbor` exists as the isolation test target — its home directory (mode 700) is what the isolation check probes

Provision both:

```bash
sudo ~/juso/scripts/provision-workload.sh validation
sudo ~/juso/scripts/provision-workload.sh neighbor
```

### Set up the validation workload

```bash
# Add the auditor agent
sudo ~/juso/scripts/add-agent.sh validation validation-auditor

# Remove the auto-created 'main' agent (created by openclaw gateway install)
sudo ~/juso/scripts/remove-agent.sh validation main

# Deploy workspace files from the repo
sudo cp -r ~/juso/validation/agents/validation-auditor/* \
  /home/juso-validation/.openclaw/workspace/validation-auditor/
sudo chown -R juso-validation:juso-validation \
  /home/juso-validation/.openclaw/workspace/validation-auditor/

# Start the gateway
sudo juso-ctl validation start
```

### Triggering an audit

Connect to the validation gateway via the dashboard. Open a session and prompt it to run. The trigger phrase is:

```
run the audit
```

The auditor writes its full report to `audits/YYYY-MM-DD.md` in its workspace and prints a verdict summary to the session.

---

## Running audit.sh standalone

`audit.sh` can be run directly from the MacBook without starting the agent or opening the dashboard. This is useful for quick health checks and debugging — no model involved, results in under 30 seconds.

```bash
# Full JSON output
ssh -t vm "sudo -u juso-validation /usr/local/bin/audit.sh | jq ."

# Results summary only
ssh -t vm "sudo -u juso-validation /usr/local/bin/audit.sh | jq '[.checks[] | {name, result}]'"

# Failures only
ssh -t vm "sudo -u juso-validation /usr/local/bin/audit.sh | \
  jq '[.checks[] | select(.result == \"FAIL\") | {name, actual, evidence}]'"
```

Run standalone to verify the script is passing before triggering the agent. This keeps model behaviour out of the debugging loop.

---

## Check list

All checks are behavioral. The audit certifies that the system behaves as intended from the perspective of the `juso-validation` workload user — unprivileged, isolated, running on the same containment architecture as any production workload.

### Infrastructure

| Check | Behavioral test | PASS condition |
|---|---|---|
| Ollama reachability | `curl http://192.168.64.1:11434/api/version` | HTTP response with version field |
| Ollama model availability | `curl http://192.168.64.1:11434/api/tags` | qwen3:30b and nomic-embed-text present |
| Internet access blocked | `curl http://1.1.1.1` | Timeout or connection refused |
| LAN access blocked | `curl http://192.168.1.1`, `10.0.0.1`, `172.16.0.1` | Timeout or connection refused for all |
| Cloud metadata blocked | `curl http://169.254.169.254` | Timeout or connection refused |
| DNS resolution blocked | `nslookup google.com` | SERVFAIL, timeout, or no response |
| IPv6 egress blocked | `curl -6 http://ipv6.google.com` | Timeout, refused, or no IPv6 interface |
| VPN status | `ip link show` for WireGuard interface | Tunnel active, or no internet-enabled workloads |
| OpenClaw binary | `openclaw --version` | Binary present, exits zero |
| Clock sync (NTP) | `timedatectl show --property=NTPSynchronized` | NTPSynchronized: yes |
| Unexpected listeners | `ss -tlnp` | No ports listening on non-loopback beyond SSH |

A timeout on any "should be blocked" test is a PASS. The timeout is evidence of blocking.

### Security

| Check | Behavioral test | PASS condition |
|---|---|---|
| Sudo access denied | `sudo -n /bin/true` | Non-zero exit — no passwordless sudo |

### Runtime

| Check | Behavioral test | PASS condition |
|---|---|---|
| Own gateway liveness | `curl http://127.0.0.1:<own-port>` | OpenClaw HTML response |

This single check is the behavioral equivalent of three former config checks: service state, correct port binding, and loopback bind mode. If the gateway responds with OpenClaw HTML, all three are confirmed.

### Isolation

| Check | Behavioral test | PASS condition |
|---|---|---|
| Cross-workload file access | `ls /home/juso-neighbor/` | Permission denied |
| Cross-workload gateway access | `curl http://127.0.0.1:<neighbor-port>` | OpenClaw HTML response (loopback binding confirmed) |
| Process visibility | `ps aux \| grep juso-neighbor` | Informational — never a FAIL |

`juso-neighbor` is a required part of the standard juso setup. If `/home/juso-neighbor/` does not exist, the isolation check is a FAIL — the test environment is incomplete.

---

## Known gaps

**Inbound exposure.** Whether gateway ports are reachable from outside the VM cannot be tested from inside the VM. The architecture relies on `gateway.bind = loopback` and the VM firewall for this guarantee. Verifying it requires a manual probe from the Mac mini host or the MacBook — attempting a direct TCP connection to the VM's IP on each registered gateway port. This test is not automated.

**Cross-workload network access.** Gateway ports are bound to the loopback interface, which is accessible to any process on the VM — including other workload users. The audit verifies that the neighbor gateway responds with OpenClaw HTML on loopback (confirming it is not bound to an external interface). Auth is enforced at the token layer for agent operations — the HTTP dashboard layer returns 200 HTML without a token, which is expected behaviour. Per-workload iptables loopback rules (blocking workloads from reaching each other's loopback ports at the network level) are deferred — gateway token auth is the current mitigation.

**Linger.** Whether the gateway service survives a reboot is not checked per-audit. The behavioral equivalent (reboot and re-probe) is impractical to run on every audit cycle. Deferred.

**Group membership and SSH lockdown.** Verifying that workload users are not in privileged groups and have no authorized SSH keys are configuration reads with no clean behavioral equivalent from within the VM. Deferred.

Proceed to the operations guide for day-to-day management.
