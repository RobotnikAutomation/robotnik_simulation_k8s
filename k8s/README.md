# Robotnik Simulation – Kubernetes Deployment

Before going through this readme follow first 
**[this](https://github.com/fujitatomoya/ros_k8s/blob/main/docs/Install_Kubernetes_Packages.md)**
 readme to install Kubernetes dependencies.

This directory contains Kubernetes manifests that replicate the exact behaviour of
`docker/docker-compose.yaml` for the Robotnik simulation stack.

## Overview

| Service | Deployment name | Description |
|---|---|---|
| `simulation` | `simulation` | Gazebo Ignition world + robot spawn |
| `localization` | `localization` | nav2 AMCL / localization stack |
| `navigation` | `navigation` | nav2 navigation + RViz |
| `manipulation` | `manipulation` | MoveIt2 + MoveIt RViz |

### docker-compose → Kubernetes mapping

| docker-compose | Kubernetes |
|---|---|
| `network_mode: host` | `hostNetwork: true` |
| `ipc: host` | `hostIPC: true` |
| `privileged: true` | `securityContext.privileged: true` |
| `devices: /dev/dri` | `hostPath` volume |
| `/tmp/.X11-unix` volume | `hostPath` volume |
| `env/robot.env` file mount | `ConfigMap` `robot-env-config` |
| `demo.world` file mount | `ConfigMap` `demo-world-config` |
| `depends_on` | `initContainer` sleep |

---

## Prerequisites

### 1. Kubernetes cluster

A running cluster is required. If you do not have one yet, follow the steps below to bootstrap
a single-node cluster with **kubeadm + WeaveNet CNI** (the recommended setup for ROS2 DDS).
For multi-node setups see the [ros_k8s cluster guide](../../ros_k8s/docs/Setup_Kubernetes_Cluster.md).

> **CNI plugin:** Use **WeaveNet** so that `hostNetwork` pods can discover each other via
> DDS/FastRTPS across nodes. See [ROS2 Deployment Demonstration](../../ros_k8s/docs/ROS2_Deployment_Demonstration.md).

#### 1a. One-time cluster bootstrap (requires `sudo`)

A helper script is provided that handles all prerequisites automatically:

```bash
cd k8s/
sudo ./setup-cluster.sh
```

> **⚠ REQUIRED after the script finishes** — `kubeadm` writes the cluster credentials to
> `/etc/kubernetes/admin.conf` (owned by root). You must copy them to your home directory
> before any `kubectl` command will work. See **step 1b** below.
> Skipping this step causes `dial tcp 127.0.0.1:8080: connection refused`.

The script performs these steps in order:

| Step | What it does |
|---|---|
| 1 | Loads `overlay` and `br_netfilter` kernel modules (required by kubeadm / containerd) |
| 2 | Sets sysctl `bridge-nf-call-iptables`, `bridge-nf-call-ip6tables`, `ip_forward = 1` |
| 3 | Disables swap (`kubeadm` refuses to init with swap on) |
| 4 | Writes `/etc/docker/daemon.json` with `cgroupdriver=systemd` and restarts Docker |
| 5 | Configures containerd `SystemdCgroup = true` in `/etc/containerd/config.toml` and restarts containerd |
| 6 | Runs `kubeadm init --pod-network-cidr=10.32.0.0/12` against the containerd socket |
| 7 | Removes the control-plane taint so pods can schedule on the single node |
| 8 | Installs WeaveNet CNI (pod CIDR `10.32.0.0/12`) |

#### 1b. Configure kubectl — **mandatory, run as your normal user**

**Do this immediately after `setup-cluster.sh` completes, before running any other command.**

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Verify the node is ready (may take up to 60 s for WeaveNet to come up):

```bash
kubectl cluster-info        # must show a running API server, not a connection error
kubectl get nodes
# NAME        STATUS   ROLES           AGE   VERSION
# <hostname>  Ready    control-plane   90s   v1.29.x
```

### 2. Docker image

The image `robotnik/simulation-gz:jazzy` must be available on all nodes that will run the pods.
Build or pull it before deploying:

```bash
# Build from the docker/ directory
cd docker/
docker build -t robotnik/simulation-gz:jazzy .

# Or pull from a registry (if published)
docker pull robotnik/simulation-gz:jazzy
```

### 3. X11 display access

All four deployments render GUI (Gazebo, RViz, MoveIt RViz). The pods must run on a node
with an active X server.

**Allow container access — use `+local:` (not `+local:root`).**
Containers run as user `robot` (UID 1000), not root. `xhost +local:root` only adds
root to the access list and will cause RViz / Qt apps to fail with
`could not connect to display`. Use the form below which allows all local users:

```bash
xhost +local:
```

Verify your current display value and confirm it matches `DISPLAY` in `robotnik-simulation.yaml`
(default `:0`):

```bash
echo $DISPLAY
```

If it is not `:0`, patch the YAML before applying:

```bash
sed -i "s/value: \":0\"/value: \"$DISPLAY\"/g" robotnik-simulation.yaml
```

If you have multiple nodes, label the one with the display:

```bash
kubectl label nodes <NODE_NAME> nodetype=edgeserver
```

Then uncomment the `nodeSelector` block in each Deployment in `robotnik-simulation.yaml`:

```yaml
nodeSelector:
  nodetype: edgeserver
```

---

## Deployment

### Step 1 – Create ConfigMaps

ConfigMaps are loaded from the local source files. Run the helper script **once**
(re-run any time you change `env/robot.env` or `robotnik_gazebo_ignition/worlds/demo.world`):

```bash
cd k8s/
./create-configmaps.sh
```

Expected output:
```
==> Creating ConfigMap: robot-env-config
configmap/robot-env-config configured
==> Creating ConfigMap: demo-world-config
configmap/demo-world-config configured
==> ConfigMaps created successfully.
NAME                DATA   AGE
robot-env-config    1      0s
demo-world-config   1      0s
```

### Step 2 – Apply the manifests

```bash
kubectl apply -f robotnik-simulation.yaml
```

Expected output:
```
configmap/robot-env-config configured
deployment.apps/simulation created
deployment.apps/localization created
deployment.apps/navigation created
deployment.apps/manipulation created
```

### Step 3 – Verify startup

```bash
kubectl get pods -w
```

The pods start in strict sequence controlled by `initContainer` `kubectl wait` calls that
mimic `depends_on` from docker-compose. Each pod waits until the previous Deployment
reports `condition=available` (i.e. its pod is Running and passes its readiness probe)
before starting:

```
simulation  ──ready──▶  localization  ──ready──▶  navigation  ──ready──▶  manipulation
```

| Pod | Waits for | Timeout |
|---|---|---|
| `simulation` | — (starts immediately) | — |
| `localization` | `deployment/simulation` Available | 300 s |
| `navigation` | `deployment/localization` Available | 300 s |
| `manipulation` | `deployment/navigation` Available | 300 s |

Once all pods show `Running`:

```bash
kubectl get pods
NAME                           READY   STATUS    RESTARTS   AGE
simulation-xxx                 1/1     Running   0          2m
localization-xxx               1/1     Running   0          1m30s
navigation-xxx                 1/1     Running   0          60s
manipulation-xxx               1/1     Running   0          20s
```

---

## Configuration

### Robot / world parameters

Edit `env/robot.env` and re-run `./create-configmaps.sh` to apply changes without
rebuilding the image.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `ROBOT` | `rbwatcher` | Robot family |
| `ROBOT_MODEL` | `rbwatcher` | Robot variant |
| `ROBOT_ID` | `robot` | ROS2 namespace / TF prefix |
| `USE_GUI` | `true` | Show Gazebo GUI |
| `USE_RVIZ` | `true` | Show RViz |
| `ARM_TYPE` | `ur10e` | Arm model (for robots with manipulator) |
| `WORLD` | `demo` | Built-in world name |
| `RUN_MOVEIT` | `false` | Launch MoveIt (used by manipulation deployment) |

### Launch arguments

Each deployment exposes environment variables that override the defaults in `robot.env`.
Edit them directly in `robotnik-simulation.yaml`:

| Deployment | Env var | Example |
|---|---|---|
| `simulation` | `ROBOTNIK_LAUNCH_ARGS_WORLD` | `gui:=true world_path:=...` |
| `simulation` | `ROBOTNIK_LAUNCH_ARGS_ROBOT` | `robot:=rbkairos robot_model:=rbkairos_plus ...` |
| `localization` | `ROBOTNIK_LAUNCH_ARGS` | `robot_id:=robot use_sim:=true` |
| `navigation` | `ROBOTNIK_LAUNCH_ARGS` | `robot_id:=robot use_sim:=true` |
| `navigation` | `ROBOTNIK_RVIZ_ARGS` | `robot_id:=robot rviz_name:=rviz_nav` |
| `manipulation` | `ROBOTNIK_LAUNCH_ARGS` | `robot_id:=robot robot:=rbkairos ...` |

### ROS Domain ID

Change `ROS_DOMAIN_ID` in each Deployment (default `30`) to isolate traffic between
different simulation instances on the same network.

### DISPLAY variable

Default is `:0`. Change it if your X server runs on a different display:

```bash
# Find the correct DISPLAY value on the target node
echo $DISPLAY
```

Then edit the `DISPLAY` env var in `robotnik-simulation.yaml` before applying.

### GPU / NVIDIA acceleration

To enable NVIDIA GPU acceleration (equivalent to `docker-compose.gpu.yaml`), add the
following to each container spec:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
env:
- name: NVIDIA_VISIBLE_DEVICES
  value: "all"
- name: NVIDIA_DRIVER_CAPABILITIES
  value: "compute,utility,graphics"
```

This requires the [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin)
to be installed in the cluster.

---

## Teardown

### Remove workloads only (cluster stays running)

```bash
# Remove all deployments, ConfigMaps and RBAC resources
kubectl delete -f robotnik-simulation.yaml
kubectl delete configmap robot-env-config demo-world-config
```

> Deleting a **pod** directly (e.g. `kubectl delete pod <name>`) is not enough — the
> Deployment controller will immediately recreate it. Delete the Deployment instead,
> or use `kubectl delete -f robotnik-simulation.yaml` to remove everything at once.

### Pause the cluster (preserves state, can be restarted)

```bash
sudo systemctl stop kubelet
sudo systemctl stop containerd
```

Restart later with:

```bash
sudo systemctl start containerd
sudo systemctl start kubelet
kubectl get nodes   # wait ~30 s for Ready
```

### Full cluster reset (destructive — removes all state)

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/etcd $HOME/.kube
```

You will need to re-run `sudo ./setup-cluster.sh` and the kubeconfig copy step to use
the cluster again after a full reset.

| Command | Effect |
|---|---|
| `kubectl delete -f robotnik-simulation.yaml` | Removes pods/deployments only, cluster untouched |
| `sudo systemctl stop kubelet containerd` | Pauses cluster, all state preserved |
| `sudo kubeadm reset -f` | Wipes cluster completely, cannot be undone |

---

## Troubleshooting

### RViz / Qt crashes with `could not connect to display`

Pods run as user `robot` (UID 1000). `xhost +local:root` only grants root access and
does **not** help. Run this on the host instead:

```bash
xhost +local:
```

Then restart the affected deployments:

```bash
kubectl rollout restart deployment/navigation deployment/manipulation
```

Also confirm the `DISPLAY` value in the YAML matches your host's `$DISPLAY`:

```bash
echo $DISPLAY   # e.g. :1
# If not :0, patch the YAML:
sed -i "s/value: \":0\"/value: \"$DISPLAY\"/g" robotnik-simulation.yaml
kubectl rollout restart deployment/navigation deployment/manipulation deployment/simulation
```

### Pod stuck in `Init:0/1`

The init container is still sleeping. Wait for the configured delay to elapse, then check:

```bash
kubectl describe pod <POD_NAME>
kubectl logs <POD_NAME> -c wait-for-simulation   # or wait-for-localization / wait-for-navigation
```

### `CrashLoopBackOff` on simulation pod

Check logs:

```bash
kubectl logs deployment/simulation
```

Common causes:
- Image not present on the node → pull or build `robotnik/simulation-gz:jazzy` on that node.
- `/dev/dri` does not exist → the node has no DRI device; run headless by setting `USE_GUI=false` in `robot.env`.
- X11 connection refused → run `xhost +local:root` on the host and verify `DISPLAY` is correct.

### No ROS2 topic communication between pods

- Confirm `hostNetwork: true` is set on all pods.
- Confirm all pods are on the same `ROS_DOMAIN_ID`.
- Use WeaveNet (not Flannel or Calico) as the CNI plugin for reliable DDS multicast.

### `dial tcp 127.0.0.1:8080: connection refused` (no cluster running)

This error means `kubectl` cannot reach any Kubernetes API server. The cluster has not
been initialised yet.

1. Bootstrap the cluster:
   ```bash
   sudo ./setup-cluster.sh
   ```
2. Copy the kubeconfig to your home directory:
   ```bash
   mkdir -p $HOME/.kube
   sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```
3. Confirm connectivity:
   ```bash
   kubectl cluster-info
   ```
4. Re-run `./create-configmaps.sh` and then `kubectl apply -f robotnik-simulation.yaml`.

### ConfigMap not found

Run `./create-configmaps.sh` before `kubectl apply -f robotnik-simulation.yaml`.
