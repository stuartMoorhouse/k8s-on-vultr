# =============================================================================
# SSH Key
# =============================================================================

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/id_ed25519"
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "${path.module}/id_ed25519.pub"
  file_permission = "0644"
}

resource "vultr_ssh_key" "cluster" {
  name    = "${var.prefix}-key"
  ssh_key = tls_private_key.ssh.public_key_openssh
}

# =============================================================================
# VPC (Private Network)
# =============================================================================

resource "vultr_vpc" "cluster" {
  description    = "${var.prefix} cluster network"
  region         = var.region
  v4_subnet      = "10.0.0.0"
  v4_subnet_mask = 24
}

# =============================================================================
# Firewall
# =============================================================================

resource "vultr_firewall_group" "cluster" {
  description = "${var.prefix} cluster firewall"
}

# SSH
resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
}

# Kubernetes API
resource "vultr_firewall_rule" "k8s_api" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "6443"
}

# NodePort range
resource "vultr_firewall_rule" "nodeports" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "30000:32767"
}

# ICMP
resource "vultr_firewall_rule" "icmp" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "icmp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
}

# =============================================================================
# Compute Instances
# =============================================================================

resource "vultr_instance" "control_plane" {
  label             = "${var.prefix}-control-plane"
  hostname          = "${var.prefix}-control-plane"
  region            = var.region
  plan              = var.plan
  os_id             = var.os_id
  ssh_key_ids       = [vultr_ssh_key.cluster.id]
  firewall_group_id = vultr_firewall_group.cluster.id
  vpc_ids           = [vultr_vpc.cluster.id]
}

resource "vultr_instance" "worker" {
  count             = var.worker_count
  label             = "${var.prefix}-worker-${count.index + 1}"
  hostname          = "${var.prefix}-worker-${count.index + 1}"
  region            = var.region
  plan              = var.plan
  os_id             = var.os_id
  ssh_key_ids       = [vultr_ssh_key.cluster.id]
  firewall_group_id = vultr_firewall_group.cluster.id
  vpc_ids           = [vultr_vpc.cluster.id]
}

# =============================================================================
# Generated kubeadm configs (with real IPs substituted)
# =============================================================================

resource "local_file" "init_config" {
  filename = "${path.module}/../kubeadm/init-config.generated.yaml"
  content = templatefile("${path.module}/../kubeadm/init-config.yaml", {
    CONTROL_PLANE_PRIVATE_IP = vultr_instance.control_plane.internal_ip
  })
}

resource "local_file" "join_config" {
  filename = "${path.module}/../kubeadm/join-config.generated.yaml"
  content = templatefile("${path.module}/../kubeadm/join-config.yaml", {
    CONTROL_PLANE_PRIVATE_IP = vultr_instance.control_plane.internal_ip
  })
}
