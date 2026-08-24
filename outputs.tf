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

output "jenkins_admin_password_path" {
  value = local_sensitive_file.jenkins_admin_password.filename
}

output "jenkins_url" {
  value = var.jenkins_local_tunnel_port > 0 ? "http://localhost:${var.jenkins_local_tunnel_port}" : null
}

output "web_url" {
  value = var.manage_floci ? "http://localhost:${var.alb_web_local_port}" : module.loadbalancer.dns_name
}

output "api_gateway_url" {
  value = var.manage_floci ? "http://localhost:${var.alb_api_gateway_local_port}" : module.loadbalancer.dns_name
}

output "argocd_url" {
  value = var.argocd_local_tunnel_port > 0 ? "https://localhost:${var.argocd_local_tunnel_port}" : null
}
