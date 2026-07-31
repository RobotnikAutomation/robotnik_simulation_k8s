#!/usr/bin/env bash
# Creates Kubernetes ConfigMaps from local files.
# Run this once before applying robotnik-simulation.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Creating ConfigMap: robot-env-config"
kubectl create configmap robot-env-config \
  --from-file=robot.env="${REPO_ROOT}/env/robot.env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating ConfigMap: demo-world-config"
kubectl create configmap demo-world-config \
  --from-file=demo.world="${REPO_ROOT}/robotnik_gazebo_ignition/worlds/demo.world" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> ConfigMaps created successfully."
kubectl get configmap robot-env-config demo-world-config
