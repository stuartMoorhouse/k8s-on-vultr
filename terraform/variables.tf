variable "region" {
  description = "Vultr region"
  type        = string
  default     = "ams"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "k8s"
}

variable "plan" {
  description = "Vultr plan for all instances (vc2-2c-4gb = 2 vCPU, 4GB RAM)"
  type        = string
  default     = "vc2-2c-4gb"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "os_id" {
  description = "Vultr OS ID (2284 = Ubuntu 22.04 LTS)"
  type        = number
  default     = 2284
}
