#!/usr/bin/env bash
# =============================================================================
# run-simulation.sh  –  One-shot script to start the Robotnik simulation on K8s
#
# Usage:
#   ./run-simulation.sh [--reset]
#
# Options:
#   --reset   Wipe and re-initialise the cluster before deploying.
#             Use when admin.conf is missing or kubelet is failing to start.
#
# Prerequisites (do once, manually):
#   - Docker image built: docker build -t robotnik/simulation-gz:jazzy ../docker/
#   - Kubernetes packages installed (kubeadm, kubectl, kubelet, containerd)
#     See: https://github.com/fujitatomoya/ros_k8s/blob/main/docs/Install_Kubernetes_Packages.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="$HOME/.kube/config"
ADMIN_CONF="/etc/kubernetes/admin.conf"
MANIFEST="$SCRIPT_DIR/robotnik-simulation.yaml"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log()  { echo ""; echo "==> $*"; }
die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' not found. Install Kubernetes packages first."
}

wait_for_node_ready() {
    log "Waiting for node to become Ready (up to 120 s)..."
    local deadline=$(( $(date +%s) + 120 ))
    until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
        if [[ $(date +%s) -gt $deadline ]]; then
            die "Node did not become Ready in time. Check: sudo journalctl -u kubelet -n 30"
        fi
        sleep 5
    done
    kubectl get nodes
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────
DO_RESET=false
for arg in "$@"; do
    [[ "$arg" == "--reset" ]] && DO_RESET=true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 0 – Sanity checks
# ─────────────────────────────────────────────────────────────────────────────
require_cmd kubectl
require_cmd kubeadm
require_cmd docker

# Verify simulation image is available locally
if ! docker image inspect robotnik/simulation-gz:jazzy &>/dev/null; then
    die "Docker image 'robotnik/simulation-gz:jazzy' not found locally.\n" \
        "Build it first:\n  docker build -t robotnik/simulation-gz:jazzy ${SCRIPT_DIR}/../docker/"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 – Cluster bootstrap (if needed or --reset requested)
# ─────────────────────────────────────────────────────────────────────────────
CLUSTER_NEEDS_INIT=false

if [[ "$DO_RESET" == true ]]; then
    log "[1/6] --reset: wiping existing cluster state"
    sudo kubeadm reset -f
    sudo rm -rf /etc/cni/net.d /var/lib/etcd "$HOME/.kube"
    CLUSTER_NEEDS_INIT=true
fi

if [[ ! -f "$ADMIN_CONF" ]]; then
    log "[1/6] No cluster found (admin.conf missing) – bootstrapping"
    CLUSTER_NEEDS_INIT=true
fi

if [[ "$CLUSTER_NEEDS_INIT" == true ]]; then
    log "[1/6] Running cluster setup (requires sudo) – this may take a few minutes..."
    sudo "$SCRIPT_DIR/setup-cluster.sh"
else
    log "[1/6] Cluster already initialised, skipping setup"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 – Copy kubeconfig (always ensure it is up to date)
# ─────────────────────────────────────────────────────────────────────────────
log "[2/6] Configuring kubectl credentials"
mkdir -p "$HOME/.kube"
sudo cp "$ADMIN_CONF" "$KUBECONFIG_PATH"
sudo chown "$(id -u):$(id -g)" "$KUBECONFIG_PATH"

# Restart services if kubelet is not yet active
if ! sudo systemctl is-active --quiet kubelet; then
    log "  kubelet not active – starting containerd and kubelet"
    sudo systemctl start containerd
    sudo systemctl start kubelet
fi

wait_for_node_ready

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 – X11 display access
# ─────────────────────────────────────────────────────────────────────────────
log "[3/6] Granting X11 display access (xhost +local:)"
if command -v xhost &>/dev/null; then
    xhost +local: || true
else
    echo "  WARNING: xhost not found – GUI windows may not appear."
    echo "  Run 'xhost +local:' manually in a terminal with DISPLAY set."
fi

# Patch DISPLAY in the manifest if the host value differs from the default ':0'
CURRENT_DISPLAY="${DISPLAY:-:0}"
if [[ "$CURRENT_DISPLAY" != ":0" ]]; then
    log "  Detected DISPLAY=$CURRENT_DISPLAY (not :0) – patching manifest"
    sed -i "s/value: \":0\"/value: \"${CURRENT_DISPLAY}\"/g" "$MANIFEST"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 – Create ConfigMaps from local files
# ─────────────────────────────────────────────────────────────────────────────
log "[4/6] Creating ConfigMaps from local files"
"$SCRIPT_DIR/create-configmaps.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 – Deploy simulation stack
# ─────────────────────────────────────────────────────────────────────────────
log "[5/6] Applying Kubernetes manifests"
kubectl apply -f "$MANIFEST"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 – Watch pod startup
# ─────────────────────────────────────────────────────────────────────────────
log "[6/6] Waiting for simulation pod to start (up to 3 min)..."
kubectl wait --for=condition=available --timeout=180s deployment/simulation

echo ""
echo "================================================================"
echo " Simulation is up. Pod status:"
echo "================================================================"
kubectl get pods -l "app.kubernetes.io/part-of=robotnik-simulation"
echo ""
echo " Pods start in sequence:"
echo "   simulation -> localization -> navigation -> manipulation"
echo " Monitor progress with:  kubectl get pods -w"
echo " View logs with:          kubectl logs deployment/<name> -f"
echo " Stop with:               kubectl delete -f k8s/robotnik-simulation.yaml"
echo "================================================================"
