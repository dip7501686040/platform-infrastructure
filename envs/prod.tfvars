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

# Jenkins runs as a Kubernetes workload — no jenkins_mode/instance_type/
# admin_cidr needed anymore. Real-AWS browser/network exposure for it (an
# Ingress + AWS Load Balancer Controller, most likely) is separate,
# unbuilt, deferred prod work — see platform-infrastructure's own plan notes.

# 0 (default) — disabled. Whoever needs browser access sets this to a real
# port on *their own* machine; it should never be baked into a shared/CI
# apply of the prod env. Same reasoning for argocd — and both tunnels are
# gated on manage_floci anyway (main.tf), so these are inert on prod
# regardless. web/api-gateway need no local port at all here -- prod reaches
# them at the ALB's real DNS name (outputs.web_url/api_gateway_url).
jenkins_local_tunnel_port = 0
argocd_local_tunnel_port  = 0

tags = {
  Project     = "ai-notification-system"
  Environment = "prod"
  ManagedBy   = "terraform"
}
