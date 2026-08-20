output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "oidc_provider_arn" {
  value = var.enable_irsa_addons ? aws_iam_openid_connect_provider.this[0].arn : null
}

output "oidc_provider_url" {
  value = var.enable_irsa_addons ? aws_iam_openid_connect_provider.this[0].url : null
}
