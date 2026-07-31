#!/usr/bin/env bash
# =============================================================================
# stop-simulation.sh  –  Gracefully stop Robotnik simulation on Kubernetes
#
# Usage:
#   ./stop-simulation.sh [--delete] [--purge-configmaps]
#
# Default behavior:
#   - Scales deployments down in reverse dependency order
#   - Waits for each deployment to fully stop
#   - Keeps manifests and configmaps in cluster
#
# Options:
#   --delete            Delete the simulation manifest after scale-down
#   --purge-configmaps  Delete robot-env-config and demo-world-config
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/robotnik-simulation.yaml"

DO_DELETE=false
DO_PURGE_CONFIGMAPS=false

for arg in "$@"; do
  case "$arg" in
    --delete)
      DO_DELETE=true
      ;;
    --purge-configmaps)
      DO_PURGE_CONFIGMAPS=true
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: ./stop-simulation.sh [--delete] [--purge-configmaps]" >&2
      exit 1
      ;;
  esac
done

log() {
  echo ""
  echo "==> $*"
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl not found in PATH" >&2
    exit 1
  }
}

wait_deleted() {
  local dep="$1"
  # Ignore if deployment does not exist.
  if ! kubectl get deployment "$dep" >/dev/null 2>&1; then
    echo "  - deployment/$dep not found, skipping"
    return 0
  fi

  kubectl wait --for=delete --timeout=180s "pod" -l "app=$dep" >/dev/null 2>&1 || true

  # Ensure replicas are actually zero.
  local replicas
  replicas="$(kubectl get deployment "$dep" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")"
  if [[ -n "$replicas" && "$replicas" != "0" ]]; then
    echo "  - WARNING: deployment/$dep still reports replicas=$replicas"
  else
    echo "  - deployment/$dep stopped"
  fi
}

scale_down() {
  local dep="$1"
  if kubectl get deployment "$dep" >/dev/null 2>&1; then
    echo "  - scaling deployment/$dep -> 0"
    kubectl scale deployment "$dep" --replicas=0 >/dev/null
    wait_deleted "$dep"
  else
    echo "  - deployment/$dep not found, skipping"
  fi
}

require_kubectl

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: Kubernetes cluster is not reachable. Check kubeconfig and kubelet/containerd status." >&2
  exit 1
fi

log "Stopping simulation workloads in reverse dependency order"
scale_down manipulation
scale_down navigation
scale_down localization
scale_down simulation

if [[ "$DO_DELETE" == true ]]; then
  log "Deleting manifest resources"
  kubectl delete -f "$MANIFEST" --ignore-not-found=true
fi

if [[ "$DO_PURGE_CONFIGMAPS" == true ]]; then
  log "Deleting ConfigMaps"
  kubectl delete configmap robot-env-config demo-world-config --ignore-not-found=true
fi

log "Done"
kubectl get deployments 2>/dev/null || true
kubectl get pods -l app.kubernetes.io/part-of=robotnik-simulation 2>/dev/null || true
