# Operations

Day-to-day reference for running the juso platform once it is set up. Setup procedures are in the setup guides; validation procedures are in validation.md.

Run everything in this guide from the MacBook unless otherwise noted.

---

## Startup and shutdown

The juso stack has a strict ordering requirement.

**Start bottom-up:**
```
Ollama → VM → workload(s)
```

**Stop top-down:**
```
workload(s) → VM → Ollama
```

Shell functions from `scripts/macbook/juso-ops.sh` (sourced in `~/.zshrc`):

```bash
# Start
juso-start-ollama                  # Start Ollama on the Mac mini
juso-start-vm                      # Start the VM (allow ~15s to boot)
juso-start-workload <workload>     # Start a workload's OpenClaw gateway

# Stop
juso-stop-workload <workload>      # Stop a workload's gateway
juso-stop-vm                       # Stop the VM
juso-stop-ollama                   # Stop Ollama

# Check everything at once
juso-status
```

Run `juso-help` for a full command reference.

Ollama must be running before workloads start. If Ollama goes down while workloads are running, agents will fail their inference calls. Restart Ollama (`juso-start-ollama`), then restart affected workloads.

---

## Status and dashboard

Check all layers:

```bash
juso-status
```

Open the Control UI for a workload:

```bash
juso-dashboard <workload>          # Open SSH tunnel and launch browser
juso-dashboard-stop                # Close all dashboard tunnels
juso-dashboard-stop <workload>     # Close tunnel for one workload
```

`juso-dashboard` opens an SSH tunnel from the MacBook to the VM and opens the browser to the workload's gateway port. The Control UI is the primary interface for agent interaction, session history, and monitoring.

List all provisioned workloads and their ports:

```bash
juso-list
```

---

## Workload and agent management

See [provisioning.md](provisioning.md) for full procedures.

Quick reference (run on the VM as `juso-admin-vm`):

```bash
sudo ~/juso/scripts/provision-workload.sh <workload>     # Create a new workload
sudo ~/juso/scripts/add-agent.sh <workload> <agent>      # Add an agent
sudo ~/juso/scripts/remove-agent.sh <workload> <agent>   # Remove an agent
sudo ~/juso/scripts/destroy-workload.sh <workload>       # Tear down a workload entirely
```

After provisioning, start the workload from the MacBook:

```bash
juso-start-workload <workload>
```

---

## Validation

See [validation.md](validation.md) for full procedures.

Run the audit script directly from the MacBook without opening the dashboard:

```bash
ssh -t vm "sudo -u juso-validation /usr/local/bin/audit.sh | jq ."
```

Trigger the validation-auditor agent for a full formatted report: open the `validation` workload dashboard and send `run the audit`.

Re-validate after any change to the platform: OpenClaw upgrade, UFW rule change, new workload provisioned, script update deployed to the VM.

---

## Maintenance

### Updating Ollama

1. Stop all workloads from the MacBook: `juso-stop-workload <workload>` for each.
2. Connect to the mini via Screen Sharing as `juso`.
3. Click the Ollama menu bar icon → **Restart to Update**. When prompted for admin credentials, enter the `jusoadmin` password. Wait for Ollama to restart and the menu bar icon to reappear.
4. Open a Terminal on the mini as `juso` and run `configure-ollama.sh` to re-register the LaunchAgent with the new binary:
   ```bash
   ~/scripts/configure-ollama.sh
   ```
5. Disable Ollama in App Background Activity if re-enabled by the update (System Settings → General → Login Items & Extensions → App Background Activity).
6. Verify the binding:
   ```bash
   lsof -i :11434   # should show ollama LISTEN on 192.168.64.1:11434
   ```
7. Restart all workloads from the MacBook: `juso-start-workload <workload>` for each.

`configure-ollama.sh` must be re-run after every Ollama update. The update restarts Ollama under its default binding (`127.0.0.1`); `configure-ollama.sh` re-registers the LaunchAgent that overrides this with `192.168.64.1:11434`.

### Updating OpenClaw

OpenClaw updates are applied deliberately, not automatically — new versions can introduce new attack surfaces alongside patches.

1. Review the release notes for breaking changes or new CVEs.
2. Install the update on the VM following the same procedure in `guides/openclaw-setup.md`.
3. Run `openclaw doctor --fix` as `juso-admin-vm` to auto-correct any config schema changes:
   ```bash
   openclaw doctor --fix
   ```
4. Run a full validation audit. Do not resume agent workloads until CERTIFIED.

TODO: The upgrade procedure above should be scripted as `scripts/vm/upgrade-openclaw.sh` before the next upgrade is performed. The script should handle the UFW rule open/close, the `npm install`, and the `doctor --fix` call in sequence, and must close the firewall rules even if an intermediate step fails.

### Deploying script updates to the VM

Scripts live in the MacBook repo and are deployed to the VM. After modifying anything in `scripts/vm/`, re-run the deployment step from `guides/macbook-setup.md` Part 8 to push the changes.

`provision-workload.sh` always overwrites `audit.sh` at `/usr/local/bin/` on each run. For updates between provisions, the audit script can be deployed directly:

```bash
ssh vm "sudo cp ~/juso/scripts/audit.sh /usr/local/bin/audit.sh"
```

### Taking a VM snapshot

Take a new snapshot after any significant change to the VM baseline: OS updates, OpenClaw upgrades, UFW rule changes, or script deployments.

1. Stop all workloads from the MacBook: `juso-stop-workload <workload>` for each.
2. Stop the VM: `juso-stop-vm`.
3. On the Mac mini (screen sharing as `juso`): open UTM, right-click the VM, take snapshot. Name it `juso-vm-YYYY-MM-DD`.
4. Start the VM: `juso-start-vm`. Start each workload: `juso-start-workload <workload>`.

A snapshot restore is treated the same as a rebuild — run a full validation audit before resuming agent workloads.

---

## Troubleshooting

This section covers failures in juso's infrastructure layer: the VM, Ollama, and the systemd gateway services.

For agent-level issues — stuck runs, config drift, tool errors, session problems — use OpenClaw's own tooling: `openclaw doctor`, `openclaw doctor --fix`, `openclaw logs --follow`, and `/stop` in a session to kill a stuck run. See the [OpenClaw troubleshooting docs](https://docs.openclaw.ai/gateway/troubleshooting).

### VM unreachable

`juso-status` shows the VM as stopped or unreachable; `ssh vm` fails.

1. Check if the Mac mini is reachable: `ssh mini "echo ok"`.
2. If the mini responds, check if the VM is running: `ssh mini "utmctl list"`.
   Note: `utmctl list` crashes with an `NSInvalidArgumentException` on some macOS/UTM versions.
   If it crashes, check VM status via Screen Sharing — open UTM on the mini and inspect the VM list directly.
3. Start the VM if needed: `juso-start-vm`. Allow ~15 seconds to boot before retrying.
4. If the VM was listed as running but SSH still fails, the VM may have lost its IP address — see **VM loses IP address** below.

### VM loses IP address (DHCP lease expiry)

**Symptom**: `ssh vm` fails with `channel 0: open failed: connect failed: Operation timed out`. UTM shows the VM as "Started". Pinging 192.168.64.2 from the mini fails. The mini has not rebooted recently.

**Cause**: UTM's internal DHCP server silently fails to renew IPv4 leases on long-running VMs. The VM's network interface stays up but loses its IP address with no visible error. This can happen after days of uptime with no reboot or disruption.

**Diagnosis**: Use the UTM console (via Screen Sharing on the mini) to check the VM's IP:
```bash
ip addr show enp0s1
# If inet 192.168.64.2/24 is absent, the lease has expired
```

**Fix**: Manually restore the IP. Run in the UTM console:
```bash
sudo ip addr add 192.168.64.2/24 dev enp0s1
sudo ip route add default via 192.168.64.1
```

This restores SSH immediately. Note: this assignment does not survive a reboot. A permanent fix (static IP via netplan) is the right long-term solution but has not yet been applied to this installation — it requires understanding the IP allocation across all VMs on the host before baking in a specific address.

### `ssh vm` fails after a network disruption (router reboot, ISP outage)

**Symptom**: `ssh mini` works, but `ssh vm` fails with `channel 0: open failed: connect failed`. The VM is running, its network interface is up (192.168.64.2), and connectivity from the mini is fine (`ping -c 3 -S 192.168.64.1 192.168.64.2` and `nc -zv 192.168.64.2 22` both succeed). SSH is healthy on the VM (`sudo systemctl status ssh` shows active).

**Cause**: A network disruption on the Mac mini (router reboot, ISP outage) can leave the mini's sshd in a stale state where its ProxyJump forwarding (`-W`) no longer works, even though direct TCP connectivity is fine. The shell and sshd use different code paths for connecting to the VM; shell commands like nc work but sshd's internal forwarding does not.

**Fix**: Restart sshd on the mini. Your current SSH session to mini will drop — that's expected.

```bash
ssh -t mini "sudo launchctl kickstart -k system/com.openssh.sshd"
ssh vm "echo ok"
```

### Ollama not responding

`juso-status-ollama` returns an error; the validation audit fails the Ollama reachability check.

1. Check if Ollama is running: `juso-status-ollama`.
2. Start it if needed: `juso-start-ollama`. Allow a few seconds, then re-check.
3. If Ollama starts but agents still can't reach it, the binding may have reset to `0.0.0.0` (this happens after Ollama updates). Re-run `configure-ollama.sh` as `juso` — via `su - juso` from a `jusoadmin` SSH session, or from a Terminal in a screen sharing session to the `juso` account.
4. Verify the binding is correct: `ssh mini "curl -s http://192.168.64.1:11434/api/version"`.

### Gateway service won't start

`juso-start-workload <workload>` reports failure; the service shows as inactive or failed.

`juso-ctl` checks for the workload user's session at startup and prints an explicit fix if it's missing:

```
Error: user session not running for 'juso-<workload>'. Is linger enabled?
  Fix: sudo loginctl enable-linger juso-<workload>
```

If that error appears:

```bash
ssh vm "sudo loginctl enable-linger juso-<workload>"
ssh vm "sudo systemctl start user@\$(id -u juso-<workload>).service"
juso-start-workload <workload>
```

If linger is enabled but the service still fails, check the service logs on the VM:

```bash
ssh vm "sudo juso-ctl <workload> status"
```

For deeper log inspection, SSH into the VM and check as the workload user:

```bash
ssh vm
sudo -u juso-<workload> bash -c "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  journalctl --user -u openclaw-gateway --lines=50
"
```

If the gateway starts but the port doesn't respond, run `openclaw doctor` as the workload user to check for config errors.

### Agent receives gateway setup context instead of running its instructions

**Symptom**: The agent responds with content about Wi-Fi configuration, QR codes, or device pairing instead of following its AGENTS.md instructions. The gateway log shows the model output was the pairing/setup response.

**Cause**: `gateway.bind` is set to `lan` in the workload's openclaw.json. When bound to `lan`, the gateway presents a device-pairing UI on startup. Agents running via `--local` receive this setup context as their first input and respond to it.

**Fix**: Update the live config on the VM and restart the workload:

```bash
ssh vm "sudo jq '.gateway.bind = \"loopback\"' \
  /home/juso-<workload>/.openclaw/openclaw.json \
  > /tmp/oc_fixed.json && \
  sudo mv /tmp/oc_fixed.json /home/juso-<workload>/.openclaw/openclaw.json && \
  sudo chown juso-<workload>:juso-<workload> /home/juso-<workload>/.openclaw/openclaw.json"
juso-stop-workload <workload>
juso-start-workload <workload>
```

**Root cause**: `openclaw gateway install` writes a default config with `bind: lan`, overwriting the template-written config. Fixed in `provision-workload.sh` (provisioning now uses `openclaw onboard --gateway-bind loopback` directly). Workloads provisioned before this fix need the manual correction above.

### "Device signature expired" (gateway auth failure)

**Symptom**: The dashboard shows "device signature expired". The CLI reports a similar failure. Gateway connections are refused or close immediately (close code 4008). Persists across browser data clearing, private windows, and gateway restarts.

**Cause**: VM clock has drifted from real time. Gateway JWTs include timestamps — even a few minutes of skew causes every JWT to appear expired. A `default deny outgoing` UFW policy silently blocks NTP (port 123/udp), which prevents `systemd-timesyncd` from correcting the clock.

**Diagnosis**:
```bash
# Compare VM clock to MacBook
date && ssh vm "date"

# Check NTP sync status on VM
ssh vm "timedatectl show --property=NTPSynchronized --value"  # should be: yes
ssh vm "timedatectl status"
```

**Fix**: Allow NTP outbound and restart timesyncd:
```bash
ssh vm "sudo ufw allow out 123/udp && sudo systemctl restart systemd-timesyncd"
```

Wait 30–60 seconds, then re-check:
```bash
ssh vm "timedatectl show --property=NTPSynchronized --value"  # should return: yes
```

**Root cause fix**: `vm-setup.sh` now includes `timedatectl set-ntp true` and `ufw allow out 123/udp`. VMs provisioned before this update need the two commands above applied manually. Re-run `install-vm-infrastructure.sh` as well to pick up the NOPASSWD fix for `juso-dashboard` token retrieval.
