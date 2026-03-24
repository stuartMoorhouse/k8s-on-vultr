terraform {
  required_version = ">= 1.5"
  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.46"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.0"
    }
  }
}

provider "ovh" {
  endpoint = "ovh-eu"
}

provider "openstack" {
  auth_url = "https://auth.cloud.ovh.net/v3"
}
