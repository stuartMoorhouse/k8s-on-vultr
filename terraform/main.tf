# =============================================================================
# SSH Key
# =============================================================================

resource "openstack_compute_keypair_v2" "ssh" {
  name       = "${var.prefix}-key"
  region     = var.region
  public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
}

# =============================================================================
# Network
# =============================================================================

data "openstack_networking_network_v2" "public" {
  name     = "Ext-Net"
  region   = var.region
  external = true
}

resource "openstack_networking_network_v2" "cluster" {
  name           = "${var.prefix}-network"
  region         = var.region
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "cluster" {
  name            = "${var.prefix}-subnet"
  region          = var.region
  network_id      = openstack_networking_network_v2.cluster.id
  cidr            = "10.0.0.0/24"
  ip_version      = 4
  dns_nameservers = ["213.186.33.99", "1.1.1.1"]
}

resource "openstack_networking_router_v2" "cluster" {
  name                = "${var.prefix}-router"
  region              = var.region
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "cluster" {
  region    = var.region
  router_id = openstack_networking_router_v2.cluster.id
  subnet_id = openstack_networking_subnet_v2.cluster.id
}

# =============================================================================
# Security Group
# =============================================================================

resource "openstack_networking_secgroup_v2" "cluster" {
  name        = "${var.prefix}-secgroup"
  region      = var.region
  description = "Security group for ${var.prefix} Kubernetes cluster"
}

# SSH
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
}

# Kubernetes API
resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "0.0.0.0/0"
}

# etcd
resource "openstack_networking_secgroup_rule_v2" "etcd" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2379
  port_range_max    = 2380
  remote_ip_prefix  = "10.0.0.0/24"
}

# kubelet
resource "openstack_networking_secgroup_rule_v2" "kubelet" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 10250
  port_range_max    = 10252
  remote_ip_prefix  = "10.0.0.0/24"
}

# NodePort range
resource "openstack_networking_secgroup_rule_v2" "nodeports" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = "0.0.0.0/0"
}

# All TCP within private subnet (inter-node)
resource "openstack_networking_secgroup_rule_v2" "internal_tcp" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 1
  port_range_max    = 65535
  remote_ip_prefix  = "10.0.0.0/24"
}

# All UDP within private subnet (inter-node)
resource "openstack_networking_secgroup_rule_v2" "internal_udp" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 1
  port_range_max    = 65535
  remote_ip_prefix  = "10.0.0.0/24"
}

# Calico BGP
resource "openstack_networking_secgroup_rule_v2" "calico_bgp" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 179
  port_range_max    = 179
  remote_ip_prefix  = "10.0.0.0/24"
}

# Calico VXLAN
resource "openstack_networking_secgroup_rule_v2" "calico_vxlan" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 4789
  port_range_max    = 4789
  remote_ip_prefix  = "10.0.0.0/24"
}

# ICMP
resource "openstack_networking_secgroup_rule_v2" "icmp" {
  region            = var.region
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
}

# =============================================================================
# Compute Instances
# =============================================================================

resource "openstack_compute_instance_v2" "control_plane" {
  name            = "${var.prefix}-control-plane"
  region          = var.region
  flavor_name     = var.control_plane_flavor
  image_name      = var.image_name
  key_pair        = openstack_compute_keypair_v2.ssh.name
  security_groups = [openstack_networking_secgroup_v2.cluster.name]

  network {
    name = data.openstack_networking_network_v2.public.name
  }

  network {
    name = openstack_networking_network_v2.cluster.name
  }

  depends_on = [
    openstack_networking_router_interface_v2.cluster,
  ]
}

resource "openstack_compute_instance_v2" "worker" {
  count           = var.worker_count
  name            = "${var.prefix}-worker-${count.index + 1}"
  region          = var.region
  flavor_name     = var.worker_flavor
  image_name      = var.image_name
  key_pair        = openstack_compute_keypair_v2.ssh.name
  security_groups = [openstack_networking_secgroup_v2.cluster.name]

  network {
    name = data.openstack_networking_network_v2.public.name
  }

  network {
    name = openstack_networking_network_v2.cluster.name
  }

  depends_on = [
    openstack_networking_router_interface_v2.cluster,
  ]
}
