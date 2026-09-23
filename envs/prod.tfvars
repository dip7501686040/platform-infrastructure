# Mumbai -- matches the OCI side's ap-mumbai-1, confirmed with the user
# 2026-09-23 (changed from an earlier us-east-1 placeholder).
aws_region         = "ap-south-1"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
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

# Burst-session design: this cluster is provisioned for a few hours at a
# time and destroyed right after, so NAT Gateway's cost buys security
# value that doesn't matter here. Nodes go in public subnets instead, same
# /32-scoped security-group discipline as the OCI VCN for actual access
# control.
create_nat_gateway      = false
nodes_in_public_subnets = true

# t3.medium isn't Free-Tier-eligible -- this account is on AWS's "Free
# Plan" (not "Paid Plan"), which hard-blocks launching any non-free-tier
# instance type outright (confirmed live: every t3.medium launch attempt
# failed with "InvalidParameterCombination: not eligible for Free Tier",
# for 27 minutes straight, until this was caught and fixed -- user chose
# to stay on Free Plan and use a free-tier type rather than upgrade).
# m7i-flex.large is the best-specced option in ap-south-1's free-tier
# list (`aws ec2 describe-instance-types --filters
# Name=free-tier-eligible,Values=true`): 2 vCPU/8GB, comparable to the
# OCI node's 2 OCPU/12GB. Also note: the account's default EC2
# "Running On-Demand Standard instances" vCPU quota is 5 -- caps this at
# 2 nodes (4 vCPU) without a separate quota-increase request, hence
# max=2 not 3.
node_instance_types = ["m7i-flex.large"]
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 2

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
