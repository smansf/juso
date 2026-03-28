#!/usr/bin/env bash
# =============================================================================
# juso VM setup script
#
# Run once on the VM after Ubuntu installation, as juso-admin-vm.
# Idempotent — safe to re-run if interrupted.
#
# What this script does:
#   - Updates system packages
#   - Installs essential packages
#   - Sets hostname and timezone
#   - Enables NTP time sync (required for gateway JWT auth)
#   - Configures UFW firewall (LAN isolation with Ollama and NTP exceptions)
#   - Disables unnecessary services
#   - Enables automatic security updates
#
# What this script does NOT do:
#   - VPN setup (optional — see mini-vm-setup.md)
#   - SSH key configuration (covered in MacBook Pro setup guide)
#   - OpenClaw installation (covered in OpenClaw setup guide)
#   - Workload provisioning (covered by provision-workload.sh)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — review before running
# -----------------------------------------------------------------------------
HOSTNAME="juso-vm"
TIMEZONE="UTC"
# Ollama host address (Mac mini host on UTM's virtual network — do not change)
OLLAMA_HOST="192.168.64.1"
OLLAMA_PORT="11434"
# -----------------------------------------------------------------------------

echo ""
echo "==> juso VM setup"
echo ""

# -----------------------------------------------------------------------------
# Hostname
# -----------------------------------------------------------------------------
echo "--> Setting hostname to ${HOSTNAME}"
sudo hostnamectl set-hostname "${HOSTNAME}"

# Add hostname to /etc/hosts if not already present
if ! grep -q "127.0.1.1.*${HOSTNAME}" /etc/hosts; then
  echo "127.0.1.1 ${HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
fi

# -----------------------------------------------------------------------------
# Timezone
# -----------------------------------------------------------------------------
echo "--> Setting timezone to ${TIMEZONE}"
sudo timedatectl set-timezone "${TIMEZONE}"

echo "--> Enabling NTP time sync"
sudo timedatectl set-ntp true

# -----------------------------------------------------------------------------
# System packages
# -----------------------------------------------------------------------------
echo "--> Updating system packages"
sudo apt-get update -q
sudo apt-get upgrade -y -q
sudo apt-get autoremove -y -q

echo "--> Installing essential packages"
sudo apt-get install -y -q \
  ca-certificates \
  curl \
  wget \
  git \
  vim \
  htop \
  net-tools \
  jq \
  unzip \
  ufw \
  python3

# Make 'python' an alias for python3 — avoids "command not found" when scripts
# use 'python' instead of 'python3'. A symlink is simpler than the
# python-is-python3 package and has no network dependency.
echo "--> Symlinking python -> python3"
sudo ln -sf /usr/bin/python3 /usr/bin/python

# -----------------------------------------------------------------------------
# Automatic security updates
# -----------------------------------------------------------------------------
echo "--> Enabling automatic security updates"
sudo apt-get install -y -q unattended-upgrades
sudo systemctl enable --now unattended-upgrades

# -----------------------------------------------------------------------------
# UFW firewall
#
# Default policy: deny all outbound except explicitly allowed, deny all inbound.
#
# Outbound allow list:
#   ALLOW  192.168.64.1:11434  — Ollama on the Mac mini host (AVF virtual network)
#   ALLOW  1.1.1.1:53          — Cloudflare DNS (UDP+TCP)
#   ALLOW  8.8.8.8:53          — Google DNS (UDP+TCP)
#   ALLOW  0.0.0.0/0:123/udp   — NTP time sync (any public NTP server)
#
# Outbound deny list (explicit, for rule-ordering auditability):
#   DENY   10.0.0.0/8          — LAN range
#   DENY   172.16.0.0/12       — LAN range
#   DENY   192.168.0.0/16      — LAN range (includes 192.168.64.x)
#   DENY   169.254.169.254     — cloud instance metadata endpoint
#
# Public internet is blocked by the default deny outgoing policy,
# except DNS to the two named resolvers above and NTP (any destination).
#
# NTP NOTE: NTP pool servers use rotating public IPs — a destination-specific
# allow is impractical. Without NTP, the VM clock drifts and gateway JWTs
# appear expired, causing "device signature expired" auth failures.
#
# IMPORTANT: The Ollama allow rule must be inserted before the
# 192.168.0.0/16 deny rule. 192.168.64.1 falls inside that range —
# a later allow cannot override an earlier deny in UFW.
#
# DNS is resolved via public servers (1.1.1.1, 8.8.8.8) configured
# in systemd-resolved below — independent of VPN or host DNS state.
# -----------------------------------------------------------------------------
echo "--> Configuring UFW"

# Reset to clean state (idempotent)
sudo ufw --force reset

# Default policies
sudo ufw default deny incoming
sudo ufw default deny outgoing

# Inbound: allow SSH
sudo ufw allow 22/tcp

# Outbound: allow Ollama BEFORE the broad LAN deny that covers its range
sudo ufw allow out to "${OLLAMA_HOST}" port "${OLLAMA_PORT}" proto tcp

# Outbound: allow DNS to public resolvers (independent of host/VPN state)
sudo ufw allow out to 1.1.1.1 port 53 proto udp
sudo ufw allow out to 1.1.1.1 port 53 proto tcp
sudo ufw allow out to 8.8.8.8 port 53 proto udp
sudo ufw allow out to 8.8.8.8 port 53 proto tcp

# Outbound: allow NTP (time sync — clock skew breaks gateway JWT auth)
sudo ufw allow out 123/udp

# Outbound: block all private IP ranges (LAN isolation)
sudo ufw deny out to 10.0.0.0/8
sudo ufw deny out to 172.16.0.0/12
sudo ufw deny out to 192.168.0.0/16

# Outbound: block cloud instance metadata endpoint
sudo ufw deny out to 169.254.169.254

# Enable
sudo ufw --force enable

# -----------------------------------------------------------------------------
# DNS — hardcoded public resolvers
#
# The UTM virtual network sets 192.168.64.1 (Mac mini host) as the VM's DNS
# server, but the host only listens on port 53 when certain VPN software is
# running. Configuring systemd-resolved to use public resolvers directly makes
# DNS reliable and independent of host/VPN state.
# -----------------------------------------------------------------------------
echo "--> Configuring DNS (systemd-resolved)"
sudo mkdir -p /etc/systemd/resolved.conf.d
cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/dns.conf > /dev/null
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
EOF
sudo systemctl restart systemd-resolved

# -----------------------------------------------------------------------------
# Disable unnecessary services
# -----------------------------------------------------------------------------
echo "--> Disabling unnecessary services"
sudo systemctl disable --now apport  2>/dev/null || true
sudo systemctl disable --now whoopsie 2>/dev/null || true

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "--> Ensuring workload registry is accessible"
# The registry file lives in juso-admin-vm's home directory. Workload users
# (e.g. the validation-auditor agent) need to read it. The directory must be
# traversable (o+x) and the file readable (o+r) by other users. The file
# permission is also enforced by provision-workload.sh on each write.
chmod o+x /home/juso-admin-vm

echo ""
echo "==> VM setup complete."
echo ""
echo "    Hostname : ${HOSTNAME}"
echo "    Timezone : ${TIMEZONE}"
echo ""
echo "    UFW status:"
sudo ufw status numbered
echo ""
echo "Next steps (see vm-setup.md):"
echo "  1. Run verification checks"
echo "  2. Take baseline snapshot in UTM"
