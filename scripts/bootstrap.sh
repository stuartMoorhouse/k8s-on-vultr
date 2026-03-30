#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# bootstrap.sh — Fully automated kubeadm cluster bootstrap
#
# Reads Terraform outputs, SSHs into each node, installs K8s 1.31 via kubeadm,
# sets up Calico CNI, Longhorn storage, and Helm charts (Prometheus, KSM,
# nginx-ingress).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
KUBEADM_DIR="$PROJECT_DIR/kubeadm"
HELM_DIR="$PROJECT_DIR/helm"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SSH_KEY="$TERRAFORM_DIR/id_ed25519"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

###############################################################################
# Helpers
###############################################################################

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$@"; exit 1; }

run_ssh() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "root@${ip}" "$@"
}

scp_to() {
    local src="$1"
    local ip="$2"
    local dst="$3"
    scp $SSH_OPTS "$src" "root@${ip}:${dst}"
}

wait_for_ssh() {
    local ip="$1"
    local retries=30
    info "Waiting for SSH on $ip..."
    for i in $(seq 1 $retries); do
        if run_ssh "$ip" "true" 2>/dev/null; then
            ok "SSH available on $ip"
            return 0
        fi
        sleep 5
    done
    fatal "SSH not available on $ip after $((retries * 5))s"
}

###############################################################################
# Phase 1: Read Terraform outputs
###############################################################################

phase1_terraform_outputs() {
    info "Phase 1: Reading Terraform outputs..."

    cd "$TERRAFORM_DIR"

    CONTROL_PLANE_IP=$(terraform output -raw control_plane_ip 2>&1) || \
        fatal "Failed to read control_plane_ip from Terraform:\n$CONTROL_PLANE_IP"

    CONTROL_PLANE_PRIVATE_IP=$(terraform output -raw control_plane_private_ip 2>&1) || \
        fatal "Failed to read control_plane_private_ip from Terraform:\n$CONTROL_PLANE_PRIVATE_IP"

    WORKER_IPS_JSON=$(terraform output -json worker_ips 2>&1) || \
        fatal "Failed to read worker_ips from Terraform:\n$WORKER_IPS_JSON"

    # Parse worker IPs from JSON array
    mapfile -t WORKER_IPS < <(echo "$WORKER_IPS_JSON" | python3 -c "import sys,json; [print(ip) for ip in json.load(sys.stdin)]")

    WORKER_PRIVATE_IPS_JSON=$(terraform output -json worker_private_ips 2>&1) || \
        fatal "Failed to read worker_private_ips from Terraform:\n$WORKER_PRIVATE_IPS_JSON"

    mapfile -t WORKER_PRIVATE_IPS < <(echo "$WORKER_PRIVATE_IPS_JSON" | python3 -c "import sys,json; [print(ip) for ip in json.load(sys.stdin)]")

    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        fatal "control_plane_ip is empty"
    fi
    if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
        fatal "worker_ips is empty"
    fi

    ALL_IPS=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")

    ok "Control plane: $CONTROL_PLANE_IP (private: $CONTROL_PLANE_PRIVATE_IP)"
    ok "Workers: ${WORKER_IPS[*]}"
}

###############################################################################
# Phase 2: Common setup on all nodes
###############################################################################

phase2_common_setup() {
    info "Phase 2: Common node setup (all nodes)..."

    for ip in "${ALL_IPS[@]}"; do
        wait_for_ssh "$ip"
        info "Configuring node $ip..."

        run_ssh "$ip" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> Disabling swap..."
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

echo ">>> Loading kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">>> Setting sysctl parameters..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1

echo ">>> Installing containerd..."
apt-get update -qq
apt-get install -y -qq containerd > /dev/null 2>&1
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo ">>> Installing kubeadm, kubelet, kubectl v1.31..."
apt-get install -y -qq apt-transport-https ca-certificates curl gpg > /dev/null 2>&1
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl > /dev/null 2>&1
apt-mark hold kubelet kubeadm kubectl

echo ">>> Node setup complete."
REMOTE_SCRIPT

        ok "Node $ip configured"
    done
}

###############################################################################
# Phase 3: Initialize control plane
###############################################################################

phase3_init_control_plane() {
    info "Phase 3: Initializing control plane on $CONTROL_PLANE_IP..."

    # Copy Terraform-generated init config (IPs already substituted)
    scp_to "$KUBEADM_DIR/init-config.generated.yaml" "$CONTROL_PLANE_IP" "/root/init-config.yaml"

    # Run kubeadm init
    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Reset if previously initialized (idempotency)
if [ -f /etc/kubernetes/admin.conf ]; then
    echo ">>> Cluster already initialized, resetting..."
    kubeadm reset -f > /dev/null 2>&1 || true
fi

echo ">>> Running kubeadm init..."
kubeadm init --config /root/init-config.yaml

echo ">>> Setting up kubectl for root..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

echo ">>> Control plane initialized."
REMOTE_SCRIPT

    # Extract join token and CA cert hash
    info "Extracting join credentials..."
    JOIN_TOKEN=$(run_ssh "$CONTROL_PLANE_IP" "kubeadm token list -o jsonpath='{.token}' 2>/dev/null | head -1")
    if [[ -z "$JOIN_TOKEN" ]]; then
        JOIN_TOKEN=$(run_ssh "$CONTROL_PLANE_IP" "kubeadm token create")
    fi

    CA_CERT_HASH=$(run_ssh "$CONTROL_PLANE_IP" \
        "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")

    if [[ -z "$JOIN_TOKEN" || -z "$CA_CERT_HASH" ]]; then
        fatal "Failed to extract join token or CA cert hash"
    fi

    ok "Join token: $JOIN_TOKEN"
    ok "CA cert hash: sha256:$CA_CERT_HASH"
}

###############################################################################
# Phase 4: Install Calico CNI
###############################################################################

phase4_install_calico() {
    info "Phase 4: Installing Calico CNI..."

    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

echo ">>> Applying Calico manifest..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

echo ">>> Waiting for Calico pods to be ready..."
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=300s

echo ">>> Calico CNI installed."
REMOTE_SCRIPT

    ok "Calico CNI running"

    # Allow VPC traffic on all nodes (Calico sets INPUT policy to DROP)
    info "Adding iptables rules to allow VPC traffic..."
    for ip in "${ALL_IPS[@]}"; do
        run_ssh "$ip" "iptables -I INPUT 1 -s 10.0.0.0/24 -j ACCEPT"
        ok "iptables rule added on $ip"
    done
}

###############################################################################
# Phase 5: Join worker nodes
###############################################################################

phase5_join_workers() {
    info "Phase 5: Joining worker nodes..."

    for i in "${!WORKER_IPS[@]}"; do
        local worker_ip="${WORKER_IPS[$i]}"
        local worker_private_ip="${WORKER_PRIVATE_IPS[$i]}"
        info "Joining worker $worker_ip (private: $worker_private_ip)..."

        # Substitute token, CA hash, and add node-ip into join config
        local tmp_config
        tmp_config=$(mktemp)
        sed -e "s/PLACEHOLDER_TOKEN/${JOIN_TOKEN}/g" \
            -e "s/PLACEHOLDER_HASH/${CA_CERT_HASH}/g" \
            "$KUBEADM_DIR/join-config.generated.yaml" > "$tmp_config"

        # Inject node-ip under nodeRegistration so kubelet registers with the private IP
        local tmp_config2
        tmp_config2=$(mktemp)
        awk -v ip="$worker_private_ip" '/criSocket:/{print; print "  kubeletExtraArgs:"; print "    node-ip: \"" ip "\""; next}1' "$tmp_config" > "$tmp_config2"
        mv "$tmp_config2" "$tmp_config"

        scp_to "$tmp_config" "$worker_ip" "/root/join-config.yaml"
        rm -f "$tmp_config"

        run_ssh "$worker_ip" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Reset if previously joined (idempotency)
if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo ">>> Node already joined, resetting..."
    kubeadm reset -f > /dev/null 2>&1 || true
fi

echo ">>> Running kubeadm join..."
kubeadm join --config /root/join-config.yaml
echo ">>> Worker joined."
REMOTE_SCRIPT

        ok "Worker $worker_ip joined"
    done

    # Wait for all nodes to be Ready
    info "Waiting for all nodes to be Ready..."
    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
for i in $(seq 1 60); do
    NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready " | wc -l || true)
    if [ "$NOT_READY" -eq 0 ]; then
        echo "All nodes Ready"
        exit 0
    fi
    sleep 5
done
echo "WARNING: Not all nodes Ready after 5 minutes"
kubectl get nodes
REMOTE_SCRIPT
}

###############################################################################
# Phase 5b: Harden kubelet configuration
###############################################################################

phase5b_harden_kubelet() {
    info "Phase 5b: Hardening kubelet configuration on all nodes..."

    for ip in "${ALL_IPS[@]}"; do
        run_ssh "$ip" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

# CIS 4.2.9: Set eventRecordQPS to an appropriate level
if ! grep -q 'eventRecordQPS' "$KUBELET_CONFIG"; then
    echo "eventRecordQPS: 5" >> "$KUBELET_CONFIG"
fi

systemctl restart kubelet
REMOTE_SCRIPT
        ok "Kubelet hardened on $ip"
    done
}

###############################################################################
# Phase 6: Install Longhorn
###############################################################################

phase6_install_longhorn() {
    info "Phase 6: Installing Longhorn storage..."

    # Install open-iscsi on all nodes (Longhorn dependency)
    for ip in "${ALL_IPS[@]}"; do
        info "Installing open-iscsi on $ip..."
        run_ssh "$ip" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq open-iscsi > /dev/null 2>&1 && systemctl enable --now iscsid"
    done

    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

LONGHORN_VERSION="v1.6.0"

echo ">>> Applying Longhorn manifest..."
kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"

echo ">>> Waiting for Longhorn pods (this may take a few minutes)..."
kubectl -n longhorn-system wait --for=condition=ready pod --all --timeout=600s 2>/dev/null || {
    echo ">>> Some pods not ready yet, waiting longer..."
    sleep 30
    kubectl -n longhorn-system wait --for=condition=ready pod --all --timeout=300s
}

echo ">>> Setting Longhorn as default StorageClass..."
# Remove default annotation from any existing default StorageClass
for sc in $(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'); do
    if [ "$sc" != "longhorn" ]; then
        kubectl patch sc "$sc" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    fi
done
# Set longhorn as default
kubectl patch sc longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo ">>> Longhorn installed and set as default StorageClass."
REMOTE_SCRIPT

    ok "Longhorn storage installed"
}

###############################################################################
# Phase 7: Install Helm charts
###############################################################################

phase7_install_helm_charts() {
    info "Phase 7: Installing Helm charts..."

    # Copy Helm values files to control plane
    run_ssh "$CONTROL_PLANE_IP" "mkdir -p /root/helm-values"
    scp_to "$HELM_DIR/prometheus/values.yaml" "$CONTROL_PLANE_IP" "/root/helm-values/prometheus.yaml"
    scp_to "$HELM_DIR/kube-state-metrics/values.yaml" "$CONTROL_PLANE_IP" "/root/helm-values/kube-state-metrics.yaml"
    scp_to "$HELM_DIR/nginx-ingress/values.yaml" "$CONTROL_PLANE_IP" "/root/helm-values/nginx-ingress.yaml"

    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

# Install Helm if not present
if ! command -v helm &>/dev/null; then
    echo ">>> Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo ">>> Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

echo ">>> Creating namespaces..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Installing Prometheus..."
helm upgrade --install prometheus prometheus-community/prometheus \
    --namespace monitoring \
    --values /root/helm-values/prometheus.yaml \
    --wait --timeout 5m

echo ">>> Installing Kube State Metrics..."
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
    --namespace monitoring \
    --values /root/helm-values/kube-state-metrics.yaml \
    --wait --timeout 5m

echo ">>> Installing nginx-ingress..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --values /root/helm-values/nginx-ingress.yaml \
    --wait --timeout 5m

echo ">>> Helm charts installed."
REMOTE_SCRIPT

    ok "Helm charts deployed"
}

###############################################################################
# Phase 8: Verify
###############################################################################

phase8_verify() {
    info "Phase 8: Cluster verification..."

    run_ssh "$CONTROL_PLANE_IP" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

echo ""
echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== All Pods ==="
kubectl get pods --all-namespaces

echo ""
echo "=== Storage Classes ==="
kubectl get sc

echo ""
echo "=== Helm Releases ==="
helm list -A
REMOTE_SCRIPT

    echo ""
    ok "========================================="
    ok " Cluster bootstrap complete!"
    ok "========================================="
    echo ""
    info "Access the cluster:"
    info "  scp $SSH_OPTS root@${CONTROL_PLANE_IP}:/etc/kubernetes/admin.conf ./kubeconfig"
    info "  export KUBECONFIG=./kubeconfig"
    info "  kubectl get nodes"
    echo ""
    info "Access Prometheus UI:"
    info "  kubectl port-forward -n monitoring svc/prometheus-server 9090:80"
    info "  Open http://localhost:9090"
    echo ""
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    info "========================================="
    info " kubeadm Cluster Bootstrap"
    info "========================================="
    echo ""

    phase1_terraform_outputs
    phase2_common_setup
    phase3_init_control_plane
    phase4_install_calico
    phase5_join_workers
    phase5b_harden_kubelet
    phase6_install_longhorn
    phase7_install_helm_charts
    phase8_verify
}

main "$@"
