# NOTE: aws_region is a placeholder — confirm the target region with the user
# before running `terraform apply` against real AWS (see plan Risk #2).
aws_region = "us-east-1"
# Single-entry map, not the 4-cluster split -- Jenkins/ArgoCD/observability
# aren't installed via Terraform on real AWS yet (every install resource in
# main.tf is gated on var.manage_floci), so app_services is the only
# cluster prod actually needs right now. See variables.tf's "clusters".
clusters = {
  app_services = { cluster_name = "ai-notification" }
}
k8s_version = "1.31"

# Matches the deleted platform-gitops/k8s/environments/prod/values-backing-services.yaml
# now that Postgres/RabbitMQ/Redis are Terraform-direct instead of a GitOps
# chart (main.tf's postgres_install/rabbitmq_install/redis_install) -- real
# AWS uses the gp3 EBS StorageClass instead of local-path. Currently inert
# either way: those resources are still gated on manage_floci, same as
# ArgoCD/Jenkins/observability, so nothing changes for prod until that gate
# is deliberately lifted.
backing_services_storage_class = "gp3"

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

# No local port config needed here at all -- every UI (web, api-gateway,
# Jenkins, ArgoCD, Grafana, Prometheus, Jaeger) is reached at its own ALB's
# real DNS name on real AWS (outputs.*_url), same mechanism, no
# Floci-only localhost port publishing involved.

tags = {
  Project     = "ai-notification-system"
  Environment = "prod"
  ManagedBy   = "terraform"
}
