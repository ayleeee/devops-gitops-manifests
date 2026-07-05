#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-ubuntu}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this script with sudo."
  echo "Example: sudo bash bootstrap-ec2-docker-k3s-helm.sh"
  exit 1
fi

if [[ ! -d "$USER_HOME" ]]; then
  echo "ERROR: Could not find home directory for user: $USER_NAME"
  exit 1
fi

echo "==> Target user: $USER_NAME"
echo "==> User home: $USER_HOME"

echo "==> Updating apt packages"
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  git \
  gnupg \
  htop \
  unzip \
  vim

echo "==> Installing Docker Engine"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
UBUNTU_RELEASE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_RELEASE} stable
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

usermod -aG docker "$USER_NAME"
systemctl enable docker
systemctl restart docker

echo "==> Installing k3s"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -
else
  echo "k3s is already installed. Skipping k3s install."
fi

echo "==> Preparing kubeconfig for $USER_NAME"
mkdir -p "$USER_HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/.kube/config"
chmod 600 "$USER_HOME/.kube/config"

if ! grep -q 'export KUBECONFIG=$HOME/.kube/config' "$USER_HOME/.bashrc"; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "$USER_HOME/.bashrc"
fi

echo "==> Installing Helm"
if ! command -v helm >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed. Skipping Helm install."
fi

echo "==> Verifying installation"
docker --version
k3s --version | head -1
helm version --short
kubectl get nodes

echo
echo "==> Bootstrap completed."
echo "IMPORTANT: Log out and log back in, or reconnect SSH, so the docker group change is applied."
echo "Then verify as the ubuntu user:"
echo "  docker ps"
echo "  kubectl get nodes"
echo "  helm version"
