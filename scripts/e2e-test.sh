#!/usr/bin/env bash
set -euo pipefail

# End-to-end validation for install-rpm-remote.sh against the local kind cluster.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/kubectl/install-rpm-remote.sh"
RPM_FILE="${ROOT_DIR}/test-data/tree.rpm"
export KUBECONFIG="${ROOT_DIR}/.cursor/kind-kubeconfig"

log() { printf '[e2e] %s\n' "$*"; }
die() { printf '[e2e] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "${SCRIPT}" ]] || chmod +x "${SCRIPT}"
[[ -f "${KUBECONFIG}" ]] || die "Missing kubeconfig at ${KUBECONFIG}; run .cursor/start.sh first"
[[ -f "${RPM_FILE}" ]] || die "Missing test RPM at ${RPM_FILE}; run .cursor/install.sh first"

log "Running shellcheck"
shellcheck "${SCRIPT}"

log "Verifying cluster connectivity"
kubectl cluster-info >/dev/null
kubectl get pod rpm-target >/dev/null

log "Dry-run pod install"
"${SCRIPT}" --dry-run -f "${RPM_FILE}" -p rpm-target -n default >/dev/null

log "Dry-run node install"
"${SCRIPT}" --dry-run -f "${RPM_FILE}" --node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" -n default >/dev/null

log "Removing any existing tree package"
kubectl exec rpm-target -- rpm -e tree >/dev/null 2>&1 || true

log "Installing RPM via install-rpm-remote.sh"
"${SCRIPT}" -f "${RPM_FILE}" -p rpm-target -n default

log "Verifying installed package"
kubectl exec rpm-target -- tree --version >/dev/null
kubectl exec rpm-target -- rpm -q tree >/dev/null

log "All checks passed"
