output "ebs_csi_role_arn" {
  value = var.enable_irsa_addons ? aws_iam_role.ebs_csi[0].arn : null
}

output "lb_controller_role_arn" {
  value = var.enable_irsa_addons ? aws_iam_role.lb_controller[0].arn : null
}
