output "ready" {
  description = "Reference this in depends_on wherever the aws provider needs Floci to already be reachable"
  value       = terraform_data.wait_for_floci.id
}
