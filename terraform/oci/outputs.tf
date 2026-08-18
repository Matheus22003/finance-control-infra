output "instance_id" {
  description = "OCID of the Always Free staging instance."
  value       = oci_core_instance.staging.id
}

output "public_ipv4" {
  description = "Public IPv4 to configure in the free DNS hostname."
  value       = oci_core_instance.staging.public_ip
}

output "ssh_command" {
  description = "SSH command for the dedicated deploy user."
  value       = "ssh deploy@${oci_core_instance.staging.public_ip}"
}
