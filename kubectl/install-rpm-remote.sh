#!/usr/bin/env bash
#
# Install an RPM package on a remote machine via kubectl.
#
# Copies the RPM into a target pod, or onto a node via a privileged helper
# pod with the host root mounted, then installs with dnf/yum/rpm.
#
# Usage:
#   ./install-rpm-remote.sh -f <package.rpm> -p <pod> [-n <namespace>]
#   ./install-rpm-remote.sh -f <package.rpm> --node <node-name>
#
# Examples:
#   ./install-rpm-remote.sh -f mypkg-1.0.0.rpm -p worker-pod -n default
#   ./install-rpm-remote.sh -f mypkg-1.0.0.rpm --node node-1
#   ./install-rpm-remote.sh -f mypkg-1.0.0.rpm -p app -c sidecar --upgrade

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REMOTE_TMP="/tmp"
NAMESPACE="default"
CONTAINER=""
POD=""
NODE=""
RPM_FILE=""
UPGRADE=0
DRY_RUN=0
FORCE=0
KUBECTL="${KUBECTL:-kubectl}"
HELPER_IMAGE="${HELPER_IMAGE:-registry.k8s.io/e2e-test-images/busybox:1.29-4}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} -f <package.rpm> (-p <pod> | --node <node>) [options]

Install an RPM package on a remote machine using kubectl.

Required:
  -f, --file <path>       Local path to the .rpm package
  -p, --pod <name>        Target pod name
      --node <name>       Target node name (privileged helper + host mount)

Optional:
  -n, --namespace <ns>    Kubernetes namespace (default: default)
  -c, --container <name>  Container name when the pod has multiple containers
      --upgrade           Upgrade if the package is already present (rpm -Uvh)
      --force             Pass --force to rpm (use with care)
      --dry-run           Print actions without executing them
  -h, --help              Show this help

Environment:
  KUBECTL                 kubectl binary to use (default: kubectl)
  HELPER_IMAGE            Image for node helper pod (default: busybox e2e image)
EOF
}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { err "$*"; exit 1; }

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  log "+ $*"
  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)       RPM_FILE="${2:-}"; shift 2 ;;
    -p|--pod)        POD="${2:-}"; shift 2 ;;
    --node)          NODE="${2:-}"; shift 2 ;;
    -n|--namespace)  NAMESPACE="${2:-}"; shift 2 ;;
    -c|--container)  CONTAINER="${2:-}"; shift 2 ;;
    --upgrade)       UPGRADE=1; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "${RPM_FILE}" ]] || { usage >&2; die "Missing required -f/--file"; }
[[ -n "${POD}" || -n "${NODE}" ]] || { usage >&2; die "Provide either -p/--pod or --node"; }
[[ -n "${POD}" && -n "${NODE}" ]] && die "Use either -p/--pod or --node, not both"
[[ -f "${RPM_FILE}" ]] || die "RPM file not found: ${RPM_FILE}"
[[ "${RPM_FILE}" == *.rpm ]] || die "File must have a .rpm extension: ${RPM_FILE}"

if [[ "${DRY_RUN}" -eq 0 ]]; then
  require_cmd "${KUBECTL}"
fi

RPM_BASENAME="$(basename "${RPM_FILE}")"
REMOTE_RPM="${REMOTE_TMP}/${RPM_BASENAME}"

rpm_flags() {
  local flags="-ivh"
  [[ "${UPGRADE}" -eq 1 ]] && flags="-Uvh"
  [[ "${FORCE}" -eq 1 ]] && flags="${flags} --force"
  printf '%s' "${flags}"
}

# Prefer dnf, then yum, then rpm on the remote side.
install_script() {
  local rpm_path="$1"
  local chroot_prefix="${2:-}"
  local flags
  flags="$(rpm_flags)"
  cat <<EOF
set -euo pipefail
run_cmd() {
  if [ -n '${chroot_prefix}' ]; then
    chroot '${chroot_prefix}' "\$@"
  else
    "\$@"
  fi
}
if run_cmd command -v dnf >/dev/null 2>&1; then
  run_cmd dnf install -y '${rpm_path}'
elif run_cmd command -v yum >/dev/null 2>&1; then
  run_cmd yum localinstall -y '${rpm_path}'
elif run_cmd command -v rpm >/dev/null 2>&1; then
  run_cmd rpm ${flags} '${rpm_path}'
else
  echo "ERROR: neither dnf, yum, nor rpm found on remote" >&2
  exit 1
fi
EOF
}

kubectl_exec() {
  local target_pod="$1"
  shift
  local args=("${KUBECTL}" exec -n "${NAMESPACE}" "${target_pod}")
  [[ -n "${CONTAINER}" ]] && args+=(-c "${CONTAINER}")
  args+=(-- "$@")
  run "${args[@]}"
}

kubectl_cp() {
  local src="$1"
  local dest="$2"
  local args=("${KUBECTL}" cp -n "${NAMESPACE}")
  [[ -n "${CONTAINER}" ]] && args+=(-c "${CONTAINER}")
  args+=("${src}" "${dest}")
  run "${args[@]}"
}

install_on_pod() {
  local target_pod="$1"

  log "Checking pod '${target_pod}' in namespace '${NAMESPACE}'"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "${KUBECTL}" get pod -n "${NAMESPACE}" "${target_pod}" >/dev/null \
      || die "Pod not found: ${NAMESPACE}/${target_pod}"
  fi

  log "Copying '${RPM_FILE}' -> ${NAMESPACE}/${target_pod}:${REMOTE_RPM}"
  kubectl_cp "${RPM_FILE}" "${NAMESPACE}/${target_pod}:${REMOTE_RPM}"

  log "Installing RPM on pod '${target_pod}'"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: kubectl exec ... -- sh -c '<install ${REMOTE_RPM}>'"
  else
    kubectl_exec "${target_pod}" sh -c "$(install_script "${REMOTE_RPM}")"
  fi

  log "Cleaning up remote RPM"
  kubectl_exec "${target_pod}" rm -f "${REMOTE_RPM}" || true
  log "Done. Installed '${RPM_BASENAME}' on pod '${target_pod}'"
}

install_on_node() {
  local target_node="$1"
  local helper_pod
  helper_pod="rpm-install-$(echo "${target_node}" | tr '[:upper:].' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40)-$$"
  helper_pod="${helper_pod:0:63}"
  local host_rpm="/host${REMOTE_RPM}"
  local saved_container="${CONTAINER}"

  log "Checking node '${target_node}'"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "${KUBECTL}" get node "${target_node}" >/dev/null \
      || die "Node not found: ${target_node}"
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: create privileged helper pod on node '${target_node}'"
    log "DRY-RUN: copy RPM to host path ${REMOTE_RPM} and install via chroot /host"
    return 0
  fi

  local cleanup_done=0
  cleanup_helper() {
    if [[ "${cleanup_done}" -eq 0 ]]; then
      cleanup_done=1
      CONTAINER="${saved_container}"
      log "Removing helper pod '${helper_pod}'"
      "${KUBECTL}" delete pod -n "${NAMESPACE}" "${helper_pod}" \
        --wait=false --ignore-not-found >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_helper EXIT

  log "Creating privileged helper pod '${helper_pod}' on node '${target_node}'"
  cat <<YAML | run "${KUBECTL}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${helper_pod}
  namespace: ${NAMESPACE}
  labels:
    app: rpm-install-helper
spec:
  hostNetwork: true
  hostPID: true
  nodeName: ${target_node}
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: helper
      image: ${HELPER_IMAGE}
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-root
          mountPath: /host
  volumes:
    - name: host-root
      hostPath:
        path: /
        type: Directory
YAML

  log "Waiting for helper pod to be Ready"
  run "${KUBECTL}" wait -n "${NAMESPACE}" --for=condition=Ready "pod/${helper_pod}" --timeout=120s

  # Helper pod has a single container named "helper"
  CONTAINER="helper"

  log "Copying '${RPM_FILE}' onto node host at ${REMOTE_RPM}"
  kubectl_cp "${RPM_FILE}" "${NAMESPACE}/${helper_pod}:/tmp/${RPM_BASENAME}"
  kubectl_exec "${helper_pod}" sh -c "cp /tmp/${RPM_BASENAME} '${host_rpm}' && chmod 644 '${host_rpm}'"

  log "Installing RPM on node '${target_node}' (chroot /host)"
  kubectl_exec "${helper_pod}" sh -c "$(install_script "${REMOTE_RPM}" "/host")"
  kubectl_exec "${helper_pod}" sh -c "rm -f '${host_rpm}' /tmp/${RPM_BASENAME}" || true

  cleanup_helper
  trap - EXIT
  log "Done. Installed '${RPM_BASENAME}' on node '${target_node}'"
}

main() {
  log "RPM: ${RPM_FILE}"
  if [[ -n "${POD}" ]]; then
    install_on_pod "${POD}"
  else
    install_on_node "${NODE}"
  fi
}

main
