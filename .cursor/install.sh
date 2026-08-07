#!/usr/bin/env bash
set -euo pipefail

# Idempotent Cloud Agent install: kubectl tooling, local Kubernetes, and test fixtures.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_DIR="${ROOT_DIR}/test-data"
KIND_VERSION="${KIND_VERSION:-0.27.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -sfL https://dl.k8s.io/release/stable.txt)}"

log() { printf '[install] %s\n' "$*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

install_apt_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    fuse-overlayfs \
    iptables \
    shellcheck \
    rpm
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return 0
  fi

  log "Installing Docker CE"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "fuse-overlayfs",
  "iptables": false
}
EOF
  fi
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1 && kubectl version --client 2>/dev/null | grep -q '+k3s'; then
    log "Replacing k3s kubectl shim with standalone kubectl"
    rm -f /usr/local/bin/kubectl
  elif command -v kubectl >/dev/null 2>&1; then
    log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    return 0
  fi

  log "Installing kubectl ${KUBECTL_VERSION}"
  local tmp_kubectl
  tmp_kubectl="$(mktemp)"
  curl -sfL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o "${tmp_kubectl}"
  install -m 0755 "${tmp_kubectl}" /usr/local/bin/kubectl
  rm -f "${tmp_kubectl}"
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then
    log "kind already installed: $(kind version)"
    return 0
  fi

  log "Installing kind ${KIND_VERSION}"
  curl -sfLo /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64"
  chmod +x /usr/local/bin/kind
}

ensure_docker_group() {
  local target_user="${SUDO_USER:-ubuntu}"
  if id -nG "${target_user}" | grep -qw docker; then
    return 0
  fi
  log "Adding ${target_user} to docker group"
  usermod -aG docker "${target_user}"
}

download_test_rpm() {
  mkdir -p "${TEST_DATA_DIR}"
  local rpm_path="${TEST_DATA_DIR}/tree.rpm"
  if [[ -f "${rpm_path}" ]] && file "${rpm_path}" | grep -q 'RPM'; then
    log "Test RPM already present: ${rpm_path}"
    return 0
  fi

  log "Downloading test RPM"
  curl -sfL -o "${rpm_path}" \
    "https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/tree-1.8.0-10.el9.x86_64.rpm"
  file "${rpm_path}" | grep -q 'RPM' || {
    rm -f "${rpm_path}"
    echo "Downloaded file is not a valid RPM: ${rpm_path}" >&2
    exit 1
  }
}

main() {
  require_root "$@"
  install_apt_packages
  install_docker
  install_kubectl
  install_kind
  ensure_docker_group
  download_test_rpm
  log "Install complete"
}

main "$@"
