#!/usr/bin/env bash
set -euo pipefail

# Per-boot startup: Docker daemon, local kind cluster, and RPM test pod.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURSOR_DIR="${ROOT_DIR}/.cursor"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-rpm-test}"
KUBECONFIG_PATH="${CURSOR_DIR}/kind-kubeconfig"
TEST_IMAGE="${RPM_TEST_IMAGE:-quay.io/centos/centos:stream9}"
export KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER="${KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER:-fuse-overlayfs}"

log() { printf '[start] %s\n' "$*"; }

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

kind_cmd() {
  if docker info >/dev/null 2>&1; then
    kind "$@"
  else
    sudo -E kind "$@"
  fi
}

kubectl_cmd() {
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl "$@"
}

wait_for_docker() {
  if docker_cmd info >/dev/null 2>&1; then
    log "Docker daemon is running"
    return 0
  fi

  log "Starting Docker daemon"
  if [[ "${EUID}" -ne 0 ]]; then
    sudo mkdir -p /etc/docker
    if [[ ! -f /etc/docker/daemon.json ]]; then
      sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "storage-driver": "fuse-overlayfs",
  "iptables": false
}
EOF
    fi
    sudo dockerd >/tmp/dockerd.log 2>&1 &
  else
    dockerd >/tmp/dockerd.log 2>&1 &
  fi

  for _ in $(seq 1 60); do
    if docker_cmd info >/dev/null 2>&1; then
      log "Docker daemon is ready"
      return 0
    fi
    sleep 2
  done

  echo "Docker daemon failed to start; see /tmp/dockerd.log" >&2
  tail -20 /tmp/dockerd.log >&2 || true
  exit 1
}

ensure_kind_cluster() {
  if kind_cmd get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "kind cluster '${CLUSTER_NAME}' already exists"
  else
    log "Creating kind cluster '${CLUSTER_NAME}'"
    kind_cmd create cluster --name "${CLUSTER_NAME}" --wait 5m
  fi

  kind_cmd get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
  chmod 600 "${KUBECONFIG_PATH}"
  kubectl_cmd cluster-info >/dev/null
  log "kubectl context: $(kubectl_cmd config current-context)"
}

preload_test_image() {
  log "Ensuring test image is available locally: ${TEST_IMAGE}"
  if ! docker_cmd image inspect "${TEST_IMAGE}" >/dev/null 2>&1; then
    docker_cmd pull "${TEST_IMAGE}"
  fi
  kind_cmd load docker-image "${TEST_IMAGE}" --name "${CLUSTER_NAME}" >/dev/null
}

deploy_test_pod() {
  log "Deploying RPM test pod"
  kubectl_cmd apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: rpm-target
  namespace: default
  labels:
    app: rpm-target
spec:
  containers:
    - name: app
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF

  kubectl_cmd wait --for=condition=Ready "pod/rpm-target" --timeout=180s >/dev/null

  # Prefer the rpm install path in offline/nested environments where dnf repo sync is slow.
  kubectl_cmd exec rpm-target -- sh -c '
    for bin in dnf dnf-3 yum yum-4; do
      if [ -x "/usr/bin/$bin" ]; then mv "/usr/bin/$bin" "/tmp/${bin}.bak"; fi
    done
    command -v rpm >/dev/null
  ' >/dev/null

  log "Test pod 'rpm-target' is ready"
}

main() {
  wait_for_docker
  ensure_kind_cluster
  preload_test_image
  deploy_test_pod
  log "Startup complete (KUBECONFIG=${KUBECONFIG_PATH})"
}

main "$@"
