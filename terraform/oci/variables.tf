variable "region" {
  description = "OCI home region where Always Free resources will be created."
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the dedicated finance-control-staging compartment."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain with capacity for VM.Standard.A1.Flex."
  type        = string
}

variable "image_ocid" {
  description = "OCID of an Always Free-eligible Ubuntu 24.04 ARM64 image."
  type        = string
}

variable "ssh_public_key" {
  description = "OpenSSH public key authorized for the deploy user."
  type        = string
  sensitive   = true
}

variable "ssh_allowed_cidr" {
  description = "Single trusted IPv4 CIDR allowed to reach SSH, preferably x.x.x.x/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0)) && var.ssh_allowed_cidr != "0.0.0.0/0"
    error_message = "ssh_allowed_cidr must be a valid restricted CIDR and cannot be 0.0.0.0/0."
  }
}

variable "instance_display_name" {
  description = "Display name of the staging VM."
  type        = string
  default     = "finance-control-staging"
}
