# MacBook Pro setup

This guide establishes key-based SSH access from the MacBook Pro to both the Mac mini and the Linux VM, hardens SSH on both machines by disabling password authentication, and installs shell functions for workload management and dashboard access.

Run everything in this guide from the MacBook Pro unless a step specifies otherwise.

---

## Prerequisites

- Mac mini host setup complete (see mini-host-setup.md)
- VM setup complete (see mini-vm-setup.md) — VM is running, SSH password auth still enabled
- Mac mini LAN IP known (visible in Network settings on the Mac mini)
- If VPN is running on the MacBook with local network sharing off, disconnect it temporarily — it will block the Mac mini's LAN IP

---

## Placeholders

Two values are specific to your environment. Substitute them throughout this guide:

| Placeholder | Value |
|-------------|-------|
| `<mini-ip>` | The Mac mini's current LAN IP address |

---

## Part 1: Generate SSH key pairs

Generate two key pairs on the MacBook — one for the Mac mini and one for the VM.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_macbook-to-mini -C "macbook->mini"
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_macbook-to-mini-vm -C "macbook->mini-vm"
```

Hit Enter twice on each to skip passphrase.

---

## Part 2: Authorize on Mac mini

Copy the public key to the Mac mini admin account. This prompts for the admin password — the last time a password is used for this connection.

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_macbook-to-mini.pub jusoadmin@<mini-ip>
```

---

## Part 3: Authorize on VM

Copy the VM key to the VM, routing through the Mac mini. The VM is on UTM's internal network and is not directly reachable from the MacBook. This prompts for `juso-admin-vm`'s password on the VM — the last time a password is used for this connection.

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_macbook-to-mini-vm.pub \
  -o "ProxyJump jusoadmin@<mini-ip>" \
  juso-admin-vm@192.168.64.2
```

---

## Part 4: SSH config

Add both hosts to `~/.ssh/config`:

```
Host mini
  HostName <mini-ip>
  User jusoadmin
  IdentityFile ~/.ssh/id_ed25519_macbook-to-mini

Host vm
  HostName 192.168.64.2
  User juso-admin-vm
  ProxyJump mini
  IdentityFile ~/.ssh/id_ed25519_macbook-to-mini-vm
```

`ssh vm` routes silently through the Mac mini in a single command. The VM is unreachable without the Mac mini.

---

## Part 5: Test connections

Confirm both connections work without password prompts:

```bash
ssh mini   # should land in admin account shell on Mac mini
ssh vm     # should land in juso-admin-vm shell on VM, one command
```

---

## Part 6: Harden SSH on Mac mini

With key-based access confirmed, disable password authentication on the Mac mini:

```bash
ssh -t mini "sudo sed -i '' 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
  && sudo launchctl kickstart -k system/com.openssh.sshd"
```

This affects SSH access only — Screen Sharing is unaffected and continues to work normally for both `juso` and `jusoadmin` accounts. Sudo password prompts within an SSH session are also unaffected; this only disables using a password to establish the SSH connection itself.

Verify the key still works, and that password auth is rejected:

```bash
ssh mini "echo '✓ connected'"
ssh -o PasswordAuthentication=no -o PubkeyAuthentication=no mini
# Should produce: Permission denied (publickey)
```

---

## Part 7: Harden SSH on VM

Disable password authentication on the VM:

```bash
ssh -t vm "sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
  && sudo systemctl reload ssh"
```

This disables password-based SSH login to the VM. Sudo password prompts within a session are unaffected. The VM has no GUI — if you ever lose your SSH key, recovery requires opening the VM console directly in UTM (via Screen Sharing to the Mac mini).

Verify the key still works, and that password auth is rejected:

```bash
ssh vm "echo '✓ connected'"
ssh -o PasswordAuthentication=no -o PubkeyAuthentication=no vm
# Should produce: Permission denied (publickey)
```

---

## Part 8: Deploy scripts and install VM infrastructure

Scripts are maintained in the repo on the MacBook. `deploy-scripts.sh` copies them to the VM and mini. `install-vm-infrastructure.sh` then runs on the VM to install system-wide binaries and sudoers rules. Both are safe to re-run after updates.

Run from the repo root:

```bash
./scripts/macbook/deploy-scripts.sh
ssh -t vm "sudo ~/juso/scripts/install-vm-infrastructure.sh"
```

---

## Part 9: Shell functions

Run from the repo root to add the `source` line to `~/.zshrc` with the correct absolute path, then reload:

```bash
echo "source $(pwd)/scripts/macbook/juso-ops.sh" >> ~/.zshrc
source ~/.zshrc
```

`juso-list` and `juso-dashboard` won't be fully operational until workloads are provisioned, but all functions are available immediately.

---

## Verification

```bash
ssh mini "echo '✓ mini'"           # passwordless
ssh vm "echo '✓ vm'"               # passwordless, one command
ssh -t mini "sudo -u juso ls /Users/juso/scripts/"   # mini scripts deployed
ssh vm "ls ~/juso/scripts/"        # VM scripts deployed
ssh vm "sudo juso-workload-list"   # infrastructure ready (empty until workloads provisioned)
juso-list                          # shell function works
```

---

## Reference

Run `juso-help` in your shell for a full list of available commands.

### If the VM IP changes

The VM gets its address from UTM's DHCP. If it changes, update `HostName` under `Host vm` in `~/.ssh/config` and re-run Part 3 with the new address.

Proceed to the OpenClaw setup guide.
