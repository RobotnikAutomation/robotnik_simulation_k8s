#!/usr/bin/env bash
# Sets up a single-node Kubernetes cluster using kubeadm + WeaveNet CNI.
# Must be run as root (sudo ./setup-cluster.sh).
#
# After this script completes run (as normal user):
#   mkdir -p $HOME/.kube
#   sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
#   sudo chown $(id -u):$(id -g) $HOME/.kube/config

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this script as root: sudo $0"
  exit 1
fi

echo "==> [1/8] Loading required kernel modules"
modprobe overlay
modprobe br_netfilter

# Persist across reboots
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

echo "==> [2/8] Setting required sysctl parameters"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "==> [3/8] Disabling swap (required by kubeadm)"
swapoff -a
# Comment out swap entries in /etc/fstab to survive reboot
sed -i '/\bswap\b/s/^/#/' /etc/fstab

echo "==> [4/8] Configuring Docker daemon cgroup driver to systemd"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
systemctl restart docker

echo "==> [5/8] Configuring containerd cgroup driver to systemd"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

echo "==> [6/8] Initialising Kubernetes control-plane (this may take a few minutes)"
kubeadm init \
  --pod-network-cidr=10.32.0.0/12 \
  --cri-socket unix:///var/run/containerd/containerd.sock

echo "==> [7/8] Allowing workloads on the control-plane node (single-node setup)"
# Remove the taint so pods can be scheduled on this node
KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo "==> [8/8] Installing WeaveNet CNI (recommended for ROS2 DDS multicast)"
KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml

echo ""
echo "================================================================"
echo "Cluster is ready. Now run the following as your NORMAL user:"
echo ""
echo "  mkdir -p \$HOME/.kube"
echo "  sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo ""
echo "Then verify:"
echo "  kubectl get nodes"
echo "================================================================"
