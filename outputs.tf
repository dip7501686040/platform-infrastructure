output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_issuer_url" {
  value = module.eks.oidc_provider_url
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "ebs_csi_role_arn" {
  value = module.addons.ebs_csi_role_arn
}

output "lb_controller_role_arn" {
  value = module.addons.lb_controller_role_arn
}

output "jenkins_public_ip" {
  value = var.jenkins_mode == "ec2" ? module.jenkins_ec2[0].public_ip : null
}

output "jenkins_ssh_key_path" {
  value = var.jenkins_mode == "ec2" ? module.jenkins_ec2[0].ssh_private_key_path : null
}

output "jenkins_ssh_command" {
  # Floci's emulated instance only has root (no ec2-user — see the
  # jenkins_ssh_tunnel provisioner's comment in main.tf), and its real SSH
  # port is a Docker-published one, not literally 22 — find it with
  # `docker port floci-ec2-<instance-id> 22` and pass `-p <that>`.
  value = var.jenkins_mode == "ec2" ? "ssh -i ${module.jenkins_ec2[0].ssh_private_key_path} ${var.manage_floci ? "root" : "ec2-user"}@${module.jenkins_ec2[0].public_ip}" : null
}

output "jenkins_admin_password_path" {
  value = var.jenkins_mode == "ec2" ? module.jenkins_ec2[0].admin_password_path : null
}

output "jenkins_url" {
  value = var.jenkins_local_tunnel_port > 0 ? "http://localhost:${var.jenkins_local_tunnel_port}" : null
}
