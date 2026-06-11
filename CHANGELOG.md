# Changelog

## v0.1.0 — 2026-04-02

Initial release. juso provides defense-in-depth isolation for OpenClaw agents running on personal hardware — a layered architecture so that a compromised agent faces a chain of distinct barriers rather than a single point of failure.

Four independently-enforced isolation layers: UFW outbound firewall blocking LAN access at the kernel level (Ollama at `192.168.64.1:11434` the sole permitted outbound exception), Linux VM via UTM/Apple Virtualization Framework, per-workload Linux user accounts with kernel-enforced filesystem and process boundaries, and OpenClaw tool policy as a complementary layer. Workloads are provisioned with explicit internet access (`--internet=open`) or none (`--internet=none`). VPN is an optional additional layer for internet-enabled workloads.

Includes a validation agent that actively probes the isolation layers — attempting LAN connections, cross-workload file reads, and metadata endpoint requests — and produces a binary CERTIFIED / NOT CERTIFIED result per check. Designed to be re-run after any configuration change, not just at initial setup.

---
