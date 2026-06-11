#!/usr/bin/env bash
# juso-rsync-scripts — Stage-to-destination receiver for juso-push-scripts.
# Reads from /tmp/juso-push-staging-<workload>/ (workload-user-staged) and
# rsyncs to /home/<workload>/scripts/ as root with the kernel-ACL ownership
# matrix. Cleans up the staging dir on success.

set -euo pipefail

usage() { echo "Usage: juso-rsync-scripts <workload>"; }

[[ "${1:-}" == "--help" ]] && {
  usage
  exit 0
}

workload="${1:-}"
if [[ -z "$workload" ]]; then
  usage >&2
  exit 1
fi

if ! getent group juso-workloads | grep -qw "$workload"; then
  echo "juso-rsync-scripts: '$workload' is not a juso-workloads member" >&2
  exit 1
fi

staging="/tmp/juso-push-staging-${workload}"
dest="/home/${workload}/scripts"

if [[ ! -d "$staging" ]]; then
  echo "juso-rsync-scripts: staging dir ${staging} not found" >&2
  exit 1
fi
if [[ ! -d "$dest" ]]; then
  echo "juso-rsync-scripts: destination ${dest} not found (workload not provisioned?)" >&2
  exit 1
fi

rsync -a --delete "${staging}/" "${dest}/"

chown -R root:root "$dest"
find "$dest" -type d -exec chmod 755 {} \;
find "$dest" -type f -exec chmod 755 {} \;
if [[ -d "${dest}/ops" ]]; then
  chmod 750 "${dest}/ops"
  find "${dest}/ops" -type f -exec chmod 750 {} \;
fi

rm -rf "$staging"

echo "juso-rsync-scripts: pushed to ${dest}"
