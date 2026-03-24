variable "region" {
  description = "OVH region for VPS instances"
  type        = string
  default     = "GRA7"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "k8s"
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair in OVH"
  type        = string
}

variable "control_plane_flavor" {
  description = "Flavor (size) for control plane VPS"
  type        = string
  default     = "b3-8"
}

variable "worker_flavor" {
  description = "Flavor (size) for worker VPS instances"
  type        = string
  default     = "b3-8"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "image_name" {
  description = "OS image for VPS instances"
  type        = string
  default     = "Ubuntu 22.04"
}
