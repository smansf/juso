# Mac mini host setup

This guide provisions the Mac mini as the juso host machine: a dedicated, hardened appliance that runs the Linux VM and Ollama inference. No personal data lives here. No unnecessary services run here.

---

## About this implementation

This guide describes a specific realization of the juso architecture: a Mac mini M4 Pro running macOS, with UTM as the hypervisor and Ollama for local model inference. The design docs — requirements.md, architecture.md — describe the underlying principles; the tools here are one way to satisfy them. Where a meaningful alternative exists, it is noted inline.

---

## Prerequisites

Before starting, have the following ready:

- Mac mini M4 Pro, fresh macOS installation
- MacBook (operator machine) on the same local network, for SSH verification at the end
- Downloads: [UTM](https://mac.getutm.app), [Ollama](https://ollama.com/download)

Connect a monitor, keyboard, and mouse for initial setup. After SSH access is verified the Mac mini operates headlessly.

---

## Account structure

The Mac mini uses two accounts. Understanding this separation before starting is important — several steps in this guide must be performed from a specific account.

**`jusoadmin`** — the administrator account, created first during macOS Setup Assistant. Used for SSH access, system configuration, and software installation. No auto-login. SSH is restricted to this account — it is the only account reachable over SSH. Most operational tasks (`juso-ctl`, system changes, reboots) require admin access, so this is the right SSH entry point. For tasks that need `juso`'s context (inspecting UTM, checking Ollama, reviewing login items), SSH in as `jusoadmin` and switch: `su - juso`.

**`juso`** — a standard (non-admin) account created in Part 1 below. UTM and Ollama run under this account. Auto-login is enabled so services start on boot without physical interaction. This account is a service identity, not an interactive login — it is operated through `jusoadmin` via `su`, not SSHed into directly.

The separation matters for security: if an attacker escapes the Linux VM to the macOS host, they land as `juso` — a non-admin user with no path to system modification without the `jusoadmin` password. Restricting SSH to `jusoadmin` also means `juso` is not SSH-reachable at all: a VM-escaped attacker cannot use `juso` to establish a persistent SSH backdoor or pivot to other machines on the network. This is why SSH lands on the higher-privilege account rather than the lower one — the lower-privilege account is the expected breach point, and keeping it off the network is the goal. It also means recovery is possible: if an agent ever escaped the VM and landed as `juso`, you could SSH in as `jusoadmin` from the MacBook, inspect and kill `juso`'s processes, and take the VM offline — all from a clean, uncompromised session that the attacker cannot reach or interfere with.

**Important: do not log out of `juso`** once services are running. Logging out terminates UTM and the VM. Use Fast User Switching to move between accounts, or `su juso` from a `jusoadmin` SSH session. The `juso` account is meant to stay logged in permanently.

This guide is split into two parts accordingly: Part 1 runs as `jusoadmin`, Part 2 runs as `juso`.

---

## Part 1: System setup (as jusoadmin)

### macOS initial setup

Run through the Setup Assistant. Connect to Wi-Fi. Do not migrate data from another machine. Create the `jusoadmin` account — this is the administrator account used for SSH and system administration. Skip Apple ID: this is a dedicated appliance, not a personal machine, and Apple ID brings in iCloud sync, Keychain access, and other services that have no place here.

Apply all available macOS updates before proceeding. A fully patched baseline matters before enabling remote access.

### Disable automatic macOS updates

Once the baseline is established, disable automatic updates to prevent unplanned changes from destabilising the system:

System Settings → General → Software Update → turn off **Automatically keep my Mac up to date**.

Leaving **Install Security Responses and system files** on is acceptable — these are narrow targeted patches, not full OS updates.

### Security hardening

These are machine-wide settings — they apply regardless of which account is active.

Enable **FileVault** full disk encryption. Store the recovery key in your password manager. The key must not be stored anywhere accessible from the Mac mini itself — its purpose is to regain access to the machine if the `jusoadmin` password is lost.

Enable the **macOS firewall**. Default configuration is sufficient.

Enable **Remote Login (SSH)** and **Screen Sharing**. Restrict both to `jusoadmin` only. Everything else in Sharing stays off: File Sharing, Printer Sharing, Media Sharing, Remote Management. Screen Sharing can be disabled once the machine is operating headlessly and you are satisfied managing it via SSH alone.

Disable **AirDrop**, **Handoff**, and **Bluetooth**. This is a headless appliance — none of these are needed.

Disable **automatic login** for `jusoadmin`. Password required immediately on wake.

Confirm on your router that no port forwarding rules exist for the Mac mini and that UPnP has not opened ports. The Mac mini should not be publicly reachable from the internet.

### Power settings

The Mac mini runs headlessly and must stay reachable indefinitely:

```bash
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a womp 1
sudo pmset -a autorestart 1
```

This disables sleep, keeps the disk awake, enables wake-on-LAN, and restarts automatically after a power failure.

### Software installs

Install both applications as `jusoadmin`. They land in `/Applications` and are accessible to the `juso` account.

**UTM** — the hypervisor that manages the Linux VM. Install from [mac.getutm.app](https://mac.getutm.app). No VM configuration at this stage — that is covered in the VM setup guide.

After installing, make `utmctl` (UTM's command-line tool) available to SSH sessions. By default, macOS SSH sessions get a minimal PATH that excludes `/usr/local/bin`, so two steps are needed:

```bash
# Symlink the binary into /usr/local/bin
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl

# Add /usr/local/bin to the PATH sshd provides to non-interactive sessions
echo 'SetEnv PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' | sudo tee -a /etc/ssh/sshd_config

# Restart sshd to apply the change (launchd restarts it automatically)
sudo launchctl stop com.openssh.sshd
```

Note: `utmctl` requires a local GUI session and does not work over SSH — this is a hard constraint of the tool. The VM starts and stops automatically via UTM's auto-start configuration (set up in the VM guide). If you ever need to manually start or stop the VM, use Screen Sharing to connect to the Mac mini and control UTM directly. The symlink and PATH steps above are still useful for running `utmctl --help` and similar informational commands over SSH.

**Ollama** — model inference server. Install from [ollama.com/download](https://ollama.com/download). OpenClaw also supports cloud model providers — Anthropic, OpenAI, Google, and others — configured via `openclaw.json`. If using a cloud provider exclusively, Ollama installation and the configuration steps in Part 2 can be skipped.

### Create the juso account

In **System Settings → Users & Groups**, create a new account:

- Full name: `juso`
- Account name: `juso`
- Account type: Standard (not Administrator)

Enable **automatic login** for `juso` in **System Settings → General → Login Options**. This allows UTM and Ollama to start on boot without physical access to the machine. Automatic login for `jusoadmin` must remain disabled.

---

## Part 2: Service configuration (as juso)

Switch to the `juso` account via Fast User Switching — do not log out of `jusoadmin`.

### Configure UTM auto-start

Open UTM. In **System Settings → General → Login Items**, add UTM so it launches automatically when `juso` logs in. The VM itself is configured in the VM setup guide — at this stage, confirming UTM launches on login is sufficient.

### Configure Ollama

Launch Ollama once from `juso` to let it register its components in the correct user context. A menu bar icon will appear.

Ollama binds to `127.0.0.1` by default. The Linux VM needs to reach it at `192.168.64.1:11434`. UTM creates a private virtual network between the Mac mini host and the VM; the host is always reachable from the VM at `192.168.64.1` on this network. Nothing on the local network can reach this address — only the VM can.

Reconfigure Ollama using `configure-ollama.sh`. This script replaces the Ollama GUI auto-start with a LaunchAgent that runs `ollama serve` directly with `OLLAMA_HOST` embedded in the plist — this is more reliable than setting an environment variable and is not affected by Ollama updates. The script is deployed to `~/scripts/` as part of the MacBook setup guide. Run it as `juso`:

```bash
bash ~/scripts/configure-ollama.sh
```

After running, **remove Ollama from Login Items and App Background Activity**:

```
System Settings → General → Login Items & Extensions
  Login Items: remove Ollama from the list
  App Background Activity: disable the toggle for Ollama
```

Both must be disabled. If App Background Activity is left on, macOS starts Ollama at login without `OLLAMA_HOST`, causing it to bind to `127.0.0.1` before the LaunchAgent fires.

**Disable Ollama auto-updates**: click the Ollama menu bar icon → Settings → uncheck automatic updates. Updates should be applied manually and followed immediately by re-running `configure-ollama.sh`.

### Pull base models

```bash
ollama pull qwen3:30b        # chat and reasoning
ollama pull nomic-embed-text  # memory search embeddings
```

Verify both are available:

```bash
ollama list
```

---

## Verification

Switch back to `jusoadmin` for verification.

Confirm Ollama is bound to the correct address — not `0.0.0.0` or `127.0.0.1`:

```bash
lsof -i :11434
# Should show: ollama listening on 192.168.64.1:11434

curl -s http://192.168.64.1:11434/api/version
# Should return a version JSON object
```

Confirm SSH access from the MacBook. Find the Mac mini's LAN IP in Network settings:

```bash
ssh jusoadmin@<mac-mini-ip>
```

Once SSH is confirmed, disconnect the monitor and keyboard. The Mac mini operates headlessly from this point.

---

## Security posture achieved

- Disk encrypted (FileVault)
- OS fully patched, automatic updates disabled
- Firewall on, SSH restricted to `jusoadmin` — no other inbound services exposed
- UTM and Ollama running under the non-admin `juso` account
- No VPN software installed on the mini
- No agent software installed yet

Proceed to the VM setup guide.
