# cluster_name is intentionally left as "ai-notification-floci" rather than
# renamed to match this file — EKS cluster names are immutable in AWS
# (rename = destroy/recreate), and this pass already has a live cluster in
# envs/state/local.tfstate. Only the file/tag naming moved to local/prod;
# renaming provisioned resources is a separate, deliberate decision.
aws_region   = "us-east-1"
cluster_name = "ai-notification-floci"
k8s_version  = "1.31"

# Terraform starts (and, if missing, pulls) the floci/floci container itself
# via module.floci — no manual `docker run` needed before `terraform apply`.
manage_floci = true

vpc_cidr           = "10.0.0.0/16"
az_count           = 2
single_nat_gateway = true

node_instance_types = ["t3.medium"]
node_desired_size   = 1
node_min_size       = 1
node_max_size       = 1

# Floci's EKS control-plane emulation doesn't provide a resolvable OIDC
# issuer, so the IRSA trust chain (aws_iam_openid_connect_provider's TLS
# cert lookup) can't be validated locally — keep addons off for this pass.
enable_irsa_addons = false

# Jenkins runs as a Kubernetes workload (see terraform_data.jenkins_install
# in main.tf), not a dedicated EC2 instance — no jenkins_mode/instance_type/
# admin_cidr needed anymore.

# Browser access via a Terraform-managed kubectl port-forward — see
# jenkins_tunnel in main.tf. http://localhost:8091 once applied.
jenkins_local_tunnel_port = 8091

# Same pattern for the ArgoCD UI (argocd_tunnel) — https://localhost:8090
# once applied. web/api-gateway aren't tunneled anymore -- they're reached
# through the ALB instead (alb_web_local_port/alb_api_gateway_local_port,
# defaults 8080/8000 -- see modules/loadbalancer and modules/floci's
# extra_ports).
argocd_local_tunnel_port = 8090

# Observability platform (main.tf) -- Grafana/Prometheus/Jaeger UIs.
grafana_local_tunnel_port    = 8092
prometheus_local_tunnel_port = 8093
jaeger_local_tunnel_port     = 8094

tags = {
  Project     = "ai-notification-system"
  Environment = "local"
  ManagedBy   = "terraform"
}
