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

# Managed node groups use this shared cluster security group by default (no
# security_groups override on aws_eks_node_group.default above) -- the
# loadbalancer module opens the NodePort range on it for real AWS so the ALB
# can actually reach the nodes.
output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# The ASG backing this node group, for the loadbalancer module's
# aws_autoscaling_attachment (real AWS only -- Floci's CreateNodegroup is
# metadata-only, so resources[0].autoscaling_groups is empty there; try()
# keeps this output from failing the Floci pass instead of gating it on a
# separate variable).
output "node_group_asg_name" {
  value = try(aws_eks_node_group.default.resources[0].autoscaling_groups[0].name, null)
}
