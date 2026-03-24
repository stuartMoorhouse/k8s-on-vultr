output "control_plane_ip" {
  description = "Public IP address of the control plane node"
  value       = openstack_compute_instance_v2.control_plane.access_ip_v4
}

output "worker_ips" {
  description = "Public IP addresses of worker nodes"
  value       = openstack_compute_instance_v2.worker[*].access_ip_v4
}

output "private_network_id" {
  description = "ID of the private cluster network"
  value       = openstack_networking_network_v2.cluster.id
}

output "ssh_command" {
  description = "SSH command to connect to the control plane"
  value       = "ssh ubuntu@${openstack_compute_instance_v2.control_plane.access_ip_v4}"
}
