# NOTE: aws_region is a placeholder — confirm the target region with the user
# before running `terraform apply` against real AWS (see plan Risk #2).
aws_region   = "us-east-1"
cluster_name = "ai-notification"
k8s_version  = "1.31"

vpc_cidr           = "10.0.0.0/16"
az_count           = 2
single_nat_gateway = true

node_instance_types = ["t3.medium"]
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 3

enable_irsa_addons = true

# Real AWS — nothing to emulate.
manage_floci = false

jenkins_mode          = "ec2"
jenkins_instance_type = "t3.medium"
# NOTE: placeholder — must be set to your actual IP/CIDR before applying to
# real AWS. 0.0.0.0/0 exposes SSH/Jenkins UI to the entire internet.
jenkins_admin_cidr = "0.0.0.0/0"

# 0 (default) — disabled. Whoever needs browser access sets this to a real
# port on *their own* machine; it should never be baked into a shared/CI
# apply of the prod env.
jenkins_local_tunnel_port = 0

tags = {
  Project     = "ai-notification-system"
  Environment = "prod"
  ManagedBy   = "terraform"
}
