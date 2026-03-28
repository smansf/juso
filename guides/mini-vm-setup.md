# VM setup

This guide provisions the Linux VM that runs juso's agent workloads: creating and configuring the VM in UTM, installing Ubuntu, hardening the OS, and optionally configuring a VPN for agent internet traffic.

---

## Prerequisites

- Mac mini host setup complete (see mini-host-setup.md)
- Ubuntu 24 LTS Server ARM64 ISO downloaded to the Mac mini
- juso repo available on the Mac mini (for transferring scripts to the VM)

---

## About this implementation

This guide describes a specific realization of the juso architecture: Ubuntu 24 LTS ARM64 running inside UTM using Apple Virtualization Framework, with Mullvad as the example VPN client for agent internet traffic. These are the choices made for this reference implementation. The underlying principles — VM isolation, LAN blocking, VPN for agent traffic — apply to other hypervisors and VPN providers. Where a meaningful alternative exists, it is noted inline.

---

## Part 1: Create and configure the VM in UTM

On the Mac mini, open UTM as the `juso` account and create a new VM. Select **Virtualize** (not Emulate) and **Linux**.

Configure the VM with the following settings:

| Setting | Value |
|---------|-------|
| Name | `openclaw-vm` |
| Architecture | ARM64 (aarch64) |
| Memory | 16384 MB |
| CPU cores | 6 |
| Disk | 128 GB |
| Network | Shared Network (NAT) |
| Display | Console only |

Under Sharing: no shared directories. This is a hard requirement — a hypervisor-level shared folder would bridge the VM filesystem to the Mac mini host, bypassing the isolation the VM provides. This applies regardless of which hypervisor you use; the prohibition is on the filesystem bridge, not UTM specifically.

Attach the Ubuntu Server ARM64 ISO as the boot device. Do not start the VM yet.

---

## Part 2: Install Ubuntu Server

Start the VM. The Ubuntu Server installer boots from the ISO.

Make the following choices during installation:

- **Language**: English
- **Installation type**: Ubuntu Server (not Ubuntu Server minimized)
- **Network**: accept DHCP defaults
- **Storage**: Use entire disk. Disable LVM.
- **Profile**:
  - Your name: juso admin
  - Server name: `juso-vm`
  - Username: `juso-admin-vm`
  - Password: strong password — store in your password manager
- **SSH**: install OpenSSH server: **yes**
- **Featured server snaps**: skip all

Wait for installation to complete. When prompted, reboot. After the VM reboots, remove the ISO from the UTM boot device configuration so it does not boot from the ISO again.

---

## Part 3: First-boot setup

After the reboot, find the VM's IP address. It will be in the `192.168.64.0/24` range — typically `192.168.64.2`. Run this in the UTM console to confirm:

```bash
ip addr show
```

From the MacBook, copy the setup script to the VM through the mini and SSH in. Password auth is still enabled at this stage so no SSH config is needed yet:

```bash
scp -J jusoadmin@<mini-ip> scripts/vm/vm-setup.sh juso-admin-vm@192.168.64.2:~/
ssh -J jusoadmin@<mini-ip> juso-admin-vm@192.168.64.2
```

Run the script:

```bash
chmod +x vm-setup.sh
./vm-setup.sh
```

The script updates the system, installs packages, sets hostname and timezone, enables NTP time sync, configures UFW firewall rules (including the outbound NTP allow required for time sync to work), and disables unnecessary services. See `scripts/vm/vm-setup.sh` in the repo for the full contents.

**Why NTP matters**: UFW's `default deny outgoing` blocks NTP (port 123/udp) unless explicitly allowed. Without an active NTP sync, the VM clock drifts. Clock skew of more than a few minutes causes gateway JWTs to appear expired — the dashboard shows "device signature expired" and all gateway connections fail. The script enables both `timedatectl set-ntp true` and `ufw allow out 123/udp` to prevent this.

---

## Part 4: VPN (optional)

VPN for agent internet traffic is recommended but not required. Without it, traffic from `--internet=open` workloads leaves the VM unencrypted and there is no kill switch to block traffic if the connection drops. The UFW rules from Part 3 still provide LAN isolation regardless of whether VPN is configured. If you choose to skip VPN entirely, omit this section.

The following uses Mullvad as an example. Any VPN provider with a Linux CLI, a kill switch, and a local network passthrough option works.

Install Mullvad and add its apt repository:

```bash
sudo curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
  https://repository.mullvad.net/deb/mullvad-keyring.asc

echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$(dpkg --print-architecture)] \
  https://repository.mullvad.net/deb/stable $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/mullvad.list

sudo apt update
sudo apt install -y mullvad-vpn
```

Configure and connect:

```bash
mullvad account login          # prompts for your Mullvad account number
mullvad lan set allow          # allow local network traffic (required for Ollama at 192.168.64.1)
mullvad lockdown-mode set on   # kill switch: block all internet traffic if VPN drops
mullvad auto-connect set on    # connect automatically on boot
mullvad connect
mullvad status                 # should show: Connected
```

`mullvad lan set allow` is required. Without it, Mullvad's tunnel blocks traffic to `192.168.64.1` — the address the VM uses to reach Ollama on the Mac mini host. The lockdown mode and LAN allow setting work together: internet traffic is VPN-only, local network traffic to the host is permitted.

---

## Part 5: Verification

```bash
# UFW rules are in the expected order
sudo ufw status numbered

# Internet is blocked
curl --max-time 5 http://1.1.1.1 2>&1 | grep -qE "timed out|refused|Network" \
  && echo "OK: internet blocked" || echo "FAIL: internet reachable"

# LAN is blocked
curl --max-time 5 http://192.168.1.1 2>&1 | grep -qE "timed out|refused|Network" \
  && echo "OK: LAN blocked" || echo "FAIL: LAN reachable"

# Ollama is reachable on the host
curl -s http://192.168.64.1:11434/api/version && echo "OK: Ollama reachable"

# NTP is synchronized (clock skew breaks gateway JWT auth)
timedatectl show --property=NTPSynchronized --value | grep -q yes \
  && echo "OK: NTP synchronized" || echo "FAIL: NTP not synchronized — gateway auth will fail"
```

All four checks must pass before proceeding.

Note: Part 4 is optional. If VPN is configured, internet checks will still pass
(tunnel traffic is allowed via the WireGuard UFW rule noted in vm-setup.sh).
Add `mullvad status` or equivalent to verify VPN connectivity separately.

---

## Part 6: Baseline snapshot

With setup complete and verification passing, take a baseline snapshot before any workloads are provisioned. This captures the clean hardened OS state. If the VM is ever corrupted or needs to be rebuilt, restoring from this snapshot avoids repeating the installation and setup.

Shut down the VM cleanly:

```bash
sudo shutdown now
```

In UTM on the Mac mini, clone the VM (right-click → Clone). Name the clone `juso-vm-baseline-YYYY-MM-DD`. Do not start or modify the clone — it exists only as a restore point.

---

## Note on SSH password authentication

Password authentication is intentionally left enabled at this stage. SSH key-based authentication has not been set up yet — that is covered in the MacBook Pro setup guide. Disabling password auth before keys are in place would lock you out of the VM. The MacBook Pro guide hardens SSH once keys are established.

---

## Security posture achieved

- Ubuntu 24 LTS, fully patched, automatic security updates enabled
- UFW: internet blocked by default, LAN ranges blocked, Ollama and NTP endpoints allowed, metadata endpoint blocked
- NTP time sync enabled (`timedatectl set-ntp true`) — required for gateway JWT auth
- VPN (if configured): agent internet traffic tunnelled through WireGuard, kill switch active (requires `ufw allow out to any port 51820 proto udp`)
- SSH: password auth enabled (hardened in MacBook Pro guide)
- No hypervisor shared folders
- Baseline snapshot taken

Proceed to the MacBook setup guide.
