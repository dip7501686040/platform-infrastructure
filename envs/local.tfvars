# app_services keeps the name "ai-notification-floci" rather than being
# renamed to match this file — EKS cluster names are immutable in AWS
# (rename = destroy/recreate), and this pass already has a live cluster in
# envs/state/local.tfstate. Only the file/tag naming moved to local/prod;
# renaming provisioned resources is a separate, deliberate decision. The
# other 3 are new clusters (Phase 1 of the 4-cluster split) with no prior
# state to preserve, so they're free to name plainly.
aws_region = "us-east-1"
clusters = {
  jenkins          = { cluster_name = "floci-jenkins" }
  argocd           = { cluster_name = "floci-argocd" }
  observability    = { cluster_name = "floci-observability" }
  app_services     = { cluster_name = "ai-notification-floci" }
  backing_services = { cluster_name = "floci-backing-services" }
}
k8s_version = "1.31"

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

# Every human-facing UI (web, api-gateway, Jenkins, ArgoCD, Grafana,
# Prometheus, Jaeger) is reached through its own cluster's ALB now -- no
# kubectl port-forward tunnels anywhere. See the alb_*_local_port variables
# in variables.tf for the actual localhost URLs (defaults: web 8080,
# api-gateway 8000, jenkins 8091, argocd 8092, grafana 8093, prometheus
# 8094, jaeger 8095) -- not overridden here since the defaults already fit.

tags = {
  Project     = "ai-notification-system"
  Environment = "local"
  ManagedBy   = "terraform"
}
