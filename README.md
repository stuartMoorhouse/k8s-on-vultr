# kubeadm Kubernetes Cluster - OVH VPS

Self-managed K8s cluster built with kubeadm on OVH VPS instances. Full control plane access.

## Components

**Control Plane (1 node):**
- etcd
- kube-apiserver
- kube-controller-manager
- kube-scheduler
- kubelet
- containerd

**Worker Nodes (2+ nodes):**
- kubelet
- kube-proxy
- containerd

**Cluster Addons:**
- **Calico CNI** (network plugin)
- **Longhorn** (storage provisioner - CKA essential)
- **Prometheus** (metrics collection)
- **Kube State Metrics** (K8s object metrics)
- **nginx-ingress** (ingress controller)


## Architecture

```
OVH VPS Instances
├── control-plane-1 (4GB RAM, 2 vCPU)
│   ├── etcd
│   ├── kube-apiserver
│   ├── kube-controller-manager
│   └── kube-scheduler
├── worker-1 (4GB RAM, 2 vCPU)
│   └── kubelet + containerd
└── worker-2 (4GB RAM, 2 vCPU)
    └── kubelet + containerd

Cluster Services
├── Calico (CNI)
├── Longhorn (storage)
├── Prometheus (namespace: monitoring)
├── Kube State Metrics (namespace: monitoring)
└── nginx-ingress (namespace: ingress-nginx)
```

## Prerequisites

- OVH Cloud account with API credentials
- Terraform >= 1.5
- kubectl
- Helm >= 3.0
- SSH key pair for VPS access

## Project Structure

```
.
├── terraform/
│   ├── main.tf                 # VPS instances, networking, firewall
│   ├── cloud-init.yaml         # Initial VPS configuration
│   ├── variables.tf            # Instance sizing, region, SSH keys
│   ├── outputs.tf              # Instance IPs, SSH access
│   └── providers.tf            # OVH provider
├── ansible/                    # Alternative to cloud-init (optional)
│   ├── playbook.yaml          # kubeadm cluster setup
│   └── inventory.yaml         # Generated from Terraform output
├── kubeadm/
│   ├── init-config.yaml       # Control plane initialization
│   ├── join-config.yaml       # Worker node join template
│   └── calico.yaml            # CNI manifest
├── helm/
│   ├── longhorn/
│   │   └── values.yaml        # Storage provisioner values
│   ├── prometheus/
│   │   └── values.yaml        # Prometheus Helm values
│   ├── kube-state-metrics/
│   │   └── values.yaml        # KSM Helm values
│   └── nginx-ingress/
│       └── values.yaml        # Ingress controller values
├── prometheus/
│   ├── prometheus-config-map.yml   # Prometheus scrape configs / remote write
│   ├── prometheus-deployment.yml   # Prometheus deployment manifest
│   └── prometheus-service.yml      # Prometheus service manifest
├── elastic-agent.yml               # Elastic Agent DaemonSet (Fleet-managed)
└── README.md
```

## Deployment

### 1. Provision VPS Instances

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

This creates:
- 3 VPS instances (1 control plane, 2 workers)
- Ubuntu 22.04 LTS
- Private network for pod/cluster communication
- Firewall rules (6443, 2379-2380, 10250-10252, 30000-32767)
- Outputs instance IPs for SSH access

### 2. Install Container Runtime and kubeadm (on all nodes)

SSH to each node and run:

```bash
# Disable swap (required by kubelet)
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

# Load kernel modules
modprobe overlay
modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

# Set sysctl params
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Install containerd
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, kubectl (v1.31)
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings
K8S_VERSION=v1.31
K8S_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o "${K8S_KEYRING}"
echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
```

### 3. Initialize Control Plane

From your local machine, copy the generated init config to the control plane:

```bash
scp -i terraform/id_ed25519 -o StrictHostKeyChecking=no \
  kubeadm/init-config.generated.yaml root@<control-plane-ip>:/root/init-config.yaml
```

Then SSH to the control plane:

```bash
ssh -i terraform/id_ed25519 -o StrictHostKeyChecking=no root@<control-plane-ip>
```

On the control plane node, initialize the cluster. The init config sets
`advertiseAddress` to the private VPC IP so that the `kubernetes` service
endpoint uses the private network (workers must be able to reach 10.96.0.1
which DNATs to this address):

```bash
kubeadm init --config /root/init-config.yaml

# Configure kubectl
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config

# Verify control plane components
kubectl get pods -n kube-system
```

### 4. Install CNI Plugin (Calico)

On the control plane node:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Wait for Calico pods to be ready
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=300s
```

### 5. Allow VPC Traffic (all nodes)

Calico sets the iptables INPUT policy to DROP, which blocks inter-node
communication over the VPC private network. On **all 3 nodes**, run:

```bash
iptables -I INPUT 1 -s 10.0.0.0/24 -j ACCEPT
```

### 6. Join Worker Nodes

On the control plane, get the join command:

```bash
kubeadm token create --print-join-command
```

On each worker node, first configure kubelet to use the node's **private VPC IP**
(without this, the node registers with its public IP and the API server cannot
reach kubelet on port 10250):

```bash
echo "KUBELET_EXTRA_ARGS=--node-ip=<worker-private-ip>" > /etc/default/kubelet
```

Then run the join command from above:

```bash
kubeadm join <control-plane-private-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Verify nodes are ready:

```bash
kubectl get nodes -o wide
# The INTERNAL-IP column should show private VPC IPs (10.0.0.x)
```

### 7. Install Storage Provisioner (Longhorn)

```bash
# Install Longhorn for persistent volumes (CKA essential)
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml

# Wait for Longhorn to be ready
kubectl get pods -n longhorn-system --watch

# Set Longhorn as default storage class
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify storage class
kubectl get sc
```

### 8. Deploy Monitoring Stack

```bash
# Add Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring

# Deploy Prometheus
helm install prometheus prometheus-community/prometheus \
  -n monitoring \
  -f ../helm/prometheus/values.yaml

# Deploy Kube State Metrics
helm install kube-state-metrics prometheus-community/kube-state-metrics \
  -n monitoring \
  -f ../helm/kube-state-metrics/values.yaml
```

### 9. Deploy Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

kubectl create namespace ingress-nginx

helm install nginx-ingress ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f ../helm/nginx-ingress/values.yaml
```

### 10. Deploy Additional Manifests (Prometheus Config, Elastic Agent)

These are applied automatically by `bootstrap.sh` (Phase 7b), but can also be
applied manually:

```bash
kubectl apply -f prometheus/prometheus-config-map.yml
kubectl apply -f prometheus/prometheus-deployment.yml
kubectl apply -f prometheus/prometheus-service.yml
kubectl apply -f elastic-agent.yml
```

The Elastic Agent manifest contains Fleet enrollment credentials. If you are
recreating the cluster, verify that the `FLEET_ENROLLMENT_TOKEN` and `FLEET_URL`
in `elastic-agent.yml` are still valid.

## Accessing the Cluster Locally

The API server listens on the control plane's private VPC IP, which isn't
reachable from your local machine. Use an SSH tunnel to forward port 6443:

```bash
# Start an SSH tunnel (runs in the background)
ssh -i terraform/id_ed25519 -o StrictHostKeyChecking=no \
  -L 6443:10.0.0.4:6443 -N -f root@<control-plane-public-ip>
```

Copy the kubeconfig from the control plane and configure it for local use:

```bash
scp -i terraform/id_ed25519 -o StrictHostKeyChecking=no \
  root@<control-plane-public-ip>:/etc/kubernetes/admin.conf ./kubeconfig

# Rewrite the server URL to use the SSH tunnel
sed -i '' 's|https://10.0.0.4:6443|https://127.0.0.1:6443|' ./kubeconfig
```

Add it to your existing kubeconfig:

```bash
# Option A: Merge into your default kubeconfig
KUBECONFIG=~/.kube/config:./kubeconfig kubectl config view --flatten > /tmp/merged-config
mv /tmp/merged-config ~/.kube/config

# Option B: Use it standalone for this session
export KUBECONFIG=$(pwd)/kubeconfig
```

Switch context and verify:

```bash
kubectl config get-contexts
kubectl config use-context kubernetes-admin@kubernetes
kubectl get nodes
```

To stop the SSH tunnel later:

```bash
# Find and kill the tunnel process
ps aux | grep 'ssh.*6443' | grep -v grep | awk '{print $2}' | xargs kill
```

## Accessing Cluster Components

### Control Plane Components

```bash
# View control plane pods
kubectl get pods -n kube-system

# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# View kubelet logs
sudo journalctl -u kubelet -f

# Check control plane component logs
kubectl logs -n kube-system kube-apiserver-<node-name>
kubectl logs -n kube-system kube-scheduler-<node-name>
kubectl logs -n kube-system kube-controller-manager-<node-name>
```

### Prometheus

Port-forward to access Prometheus UI:

```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Access at http://localhost:9090
```

## Admin Operations

### Backup etcd

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify backup
sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup.db
```

### Restore etcd

```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd-restore

# Update etcd manifest to use new data-dir
sudo vi /etc/kubernetes/manifests/etcd.yaml
# Change --data-dir=/var/lib/etcd to --data-dir=/var/lib/etcd-restore
```

### Upgrade Cluster

```bash
# Upgrade control plane
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.28.x-00
sudo apt-mark hold kubeadm

sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.28.x

sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.28.x-00 kubectl=1.28.x-00
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Upgrade workers (drain first)
kubectl drain <worker-node> --ignore-daemonsets
# SSH to worker and upgrade kubeadm, kubelet, kubectl
kubectl uncordon <worker-node>
```

### Certificate Management

```bash
# Check certificate expiration
sudo kubeadm certs check-expiration

# Renew certificates
sudo kubeadm certs renew all
sudo systemctl restart kubelet
```

## Cleanup

```bash
# On control plane
kubectl drain <node-name> --delete-emptydir-data --force --ignore-daemonsets

# On each node
sudo kubeadm reset
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /etc/cni/net.d/

# Destroy VPS instances
cd terraform/
terraform destroy
```
## Notes

- kubeconfig is located at `/etc/kubernetes/admin.conf` on control plane
- Control plane components run as static pods in `/etc/kubernetes/manifests/`
- kubelet configuration in `/var/lib/kubelet/config.yaml`
- CNI configuration in `/etc/cni/net.d/`
- Container runtime socket: `/run/containerd/containerd.sock`
- All certificates are in `/etc/kubernetes/pki/`

## Troubleshooting

```bash
# Node not ready
kubectl describe node <node-name>
sudo journalctl -u kubelet -f

# Pod not scheduling
kubectl describe pod <pod-name>
kubectl get events --sort-by='.lastTimestamp'

# Network issues
kubectl get pods -n kube-system -l k8s-app=calico-node
sudo crictl ps  # Check containers on node

# Control plane issues
kubectl get cs  # Component status (deprecated but useful)
sudo journalctl -u kubelet -f
kubectl logs -n kube-system <control-plane-pod>
```

## Future Additions

- cert-manager (for Let's Encrypt certificates)
- ELK stack (Elasticsearch, Logstash, Kibana, Filebeat)
- Headlamp dashboard
- MetalLB (bare-metal load balancer)
- External secrets operator