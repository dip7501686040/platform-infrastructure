output "cluster_name" {
  value = module.eks_app_services.cluster_name
}

output "cluster_endpoint" {
  value = module.eks_app_services.cluster_endpoint
}

output "oidc_issuer_url" {
  value = module.eks_app_services.oidc_provider_url
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks_app_services.cluster_name} --region ${var.aws_region}"
}

output "ebs_csi_role_arn" {
  value = module.addons_app_services.ebs_csi_role_arn
}

output "lb_controller_role_arn" {
  value = module.addons_app_services.lb_controller_role_arn
}

# Every one of these is now reached through its own cluster's ALB -- no
# kubectl port-forward tunnels anywhere in this stack. Floci publishes each
# ALB's listener straight to a fixed Mac port (module.floci's extra_ports);
# real AWS reaches the same ALB at its actual DNS name instead.
output "web_url" {
  value = var.manage_floci ? "http://localhost:${var.alb_web_local_port}" : module.loadbalancer.dns_name
}

output "api_gateway_url" {
  value = var.manage_floci ? "http://localhost:${var.alb_api_gateway_local_port}" : module.loadbalancer.dns_name
}

output "jenkins_admin_password_path" {
  value = local_sensitive_file.jenkins_admin_password.filename
}

output "argocd_admin_password_path" {
  value = local_sensitive_file.argocd_admin_password.filename
}


# jenkins/argocd/grafana/prometheus/jaeger are plain Docker containers now,
# not their own EKS-emulated cluster behind an ALB -- reached directly on
# their own fixed host port (see each docker_container's own `ports`
# block), no var.manage_floci branch needed since there's no real-AWS
# equivalent form of "just a local container" to branch on.
output "jenkins_url" {
  value = "http://localhost:9091"
}

output "argocd_url" {
  value = "http://localhost:9092"
}

output "grafana_url" {
  value = "http://localhost:9093"
}

output "grafana_admin_password_path" {
  value = local_sensitive_file.grafana_admin_password.filename
}

output "prometheus_url" {
  value = "http://localhost:9094"
}

output "jaeger_url" {
  value = "http://localhost:9095"
}
