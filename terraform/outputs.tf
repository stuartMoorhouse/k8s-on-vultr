output "control_plane_ip" {
  description = "Public IP address of the control plane node"
  value       = vultr_instance.control_plane.main_ip
}

output "worker_ips" {
  description = "Public IP addresses of worker nodes"
  value       = vultr_instance.worker[*].main_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control plane (VPC2)"
  value       = vultr_instance.control_plane.internal_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes (VPC2)"
  value       = vultr_instance.worker[*].internal_ip
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.ssh_private_key.filename
}

output "ssh_command" {
  description = "SSH command to connect to the control plane"
  value       = "ssh -i ${local_file.ssh_private_key.filename} root@${vultr_instance.control_plane.main_ip}"
}
