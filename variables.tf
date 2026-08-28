variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "manage_floci" {
  description = "Run the Floci AWS-emulator container via the docker provider (module.floci) and make every AWS-provider resource wait on it. true for the local/Floci pass, false for real AWS."
  type        = bool
  default     = false
}

variable "platform_gitops_path" {
  description = "Path to a local checkout of platform-gitops (the k8s charts/ArgoCD manifests repo), relative to this repo's root. Default assumes the standard sibling-checkout layout (ai-notification-system, platform-gitops, platform-infrastructure all under the same parent directory) — override for a different layout (e.g. a CI box)."
  type        = string
  default     = "../platform-gitops"
}

variable "clusters" {
  description = <<-EOT
    Independent Floci-emulated EKS clusters, keyed by role. The Floci/local
    pass defines 4 (jenkins/argocd/observability/app_services) so each
    workload class gets its own failure domain instead of cold-starting
    together in one shared k3s node; real AWS (envs/prod.tfvars) only ever
    defines "app_services" -- Jenkins/ArgoCD/observability aren't installed
    via Terraform there yet regardless (every install resource below is
    gated on var.manage_floci), so a single-entry map is a no-op change
    for prod, not a partial migration of it.
  EOT
  type = map(object({
    cluster_name = string
  }))
}

variable "k8s_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cost-saving) instead of one per AZ"
  type        = bool
  default     = true
}

variable "node_instance_types" {
  description = "EC2 instance types for the default EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of nodes in the default node group"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes in the default node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the default node group"
  type        = number
  default     = 3
}

variable "enable_irsa_addons" {
  description = <<-EOT
    Enable IRSA-backed EKS addons (EBS CSI driver, AWS Load Balancer Controller
    IAM role). Floci's EKS emulation doesn't expose a resolvable OIDC issuer,
    so this stays false for the Floci pass and true for real AWS.
  EOT
  type        = bool
  default     = false
}

# Floci only -- real AWS reaches each ALB at its actual DNS name, no local
# port publishing involved. Every human-facing UI in this stack (web,
# api-gateway, Jenkins, ArgoCD, Grafana, Prometheus, Jaeger) is reached
# exclusively through its cluster's own ALB now -- no kubectl port-forward
# tunnels anywhere (the old *_local_tunnel_port variables and their
# terraform_data.*_tunnel resources are gone; each of these clusters gets
# its own module.loadbalancer instance in main.tf instead, same pattern
# app_services' web/api-gateway ALB already used).
variable "alb_web_local_port" {
  description = "Local Mac port the app_services ALB's web listener is published on."
  type        = number
  default     = 8080
}

variable "alb_api_gateway_local_port" {
  description = "Local Mac port the app_services ALB's api-gateway listener is published on. Defaults to 8000 to match NEXT_PUBLIC_API_URL's own default -- no web-side config change needed."
  type        = number
  default     = 8000
}

variable "alb_jenkins_local_port" {
  description = "Local Mac port the jenkins cluster's ALB listener is published on."
  type        = number
  default     = 8091
}

variable "alb_argocd_local_port" {
  description = "Local Mac port the argocd cluster's ALB listener is published on. Served plain HTTP (server.extraArgs: [\"--insecure\"] in values-core.yaml) -- an HTTP-only ALB target group can't front an HTTPS backend."
  type        = number
  default     = 8092
}

variable "alb_grafana_local_port" {
  description = "Local Mac port the observability cluster ALB's Grafana listener is published on."
  type        = number
  default     = 8093
}

variable "alb_prometheus_local_port" {
  description = "Local Mac port the observability cluster ALB's Prometheus listener is published on."
  type        = number
  default     = 8094
}

variable "alb_jaeger_local_port" {
  description = "Local Mac port the observability cluster ALB's Jaeger listener is published on."
  type        = number
  default     = 8095
}

variable "lb_services" {
  description = <<-EOT
    Public-facing services fronted by the ALB (modules/loadbalancer).
    node_port must match the fixed NodePort set on that service's k8s
    Service (platform-gitops k8s/environments/<env>/values-<service>.yaml)
    -- both environments use the same node_port values, so this default
    doesn't need to differ per env.
  EOT
  type = map(object({
    listener_port     = number
    node_port         = number
    health_check_path = string
  }))
  default = {
    web = {
      listener_port     = 80
      node_port         = 30080
      health_check_path = "/login"
    }
    api-gateway = {
      listener_port     = 8000
      node_port         = 30081
      health_check_path = "/health"
    }
  }
}

variable "ecr_repository_names" {
  description = "Names of the application images to create ECR repositories for"
  type        = list(string)
  default = [
    "api-gateway",
    "identity-service",
    "tenant-service",
    "event-service",
    "ai-service",
    "rule-engine-service",
    "notification-service",
    "channel-service",
    "template-service",
    "analytics-service",
    "audit-service",
    "web",
    "prediction-service",
  ]
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Sensitive values. These aren't consumed by any Terraform resource — cluster
# infra is provisioned here, application secrets are handed to Kubernetes
# separately via `kubectl create secret` (see k8s/README). Declaring
# them here keeps one secrets.<env>.tfvars file as the single source of truth
# instead of duplicating values across a second file format.
# ---------------------------------------------------------------------------

variable "jwt_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "postgres_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "rabbitmq_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "openai_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "smtp_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "stripe_secret_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "stripe_webhook_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "google_client_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "github_push_username" {
  description = "GitHub username Jenkins pushes tag-bump commits as"
  type        = string
  default     = ""
}

variable "github_push_token" {
  description = "GitHub PAT Jenkins uses to push tag-bump commits — seeded into the Jenkins credential store at boot"
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Backing services (Postgres/RabbitMQ/Redis) -- Terraform-direct now, not a
# GitOps chart (see main.tf's postgres_install/rabbitmq_install/redis_install
# and templates/backing-services/*.tftpl). "" for storage_class uses the
# cluster's default StorageClass (Floci's k3s ships local-path out of the
# box); real AWS would set this to "gp3" once that StorageClass exists.
# ---------------------------------------------------------------------------

variable "backing_services_storage_class" {
  description = "StorageClass for Postgres/RabbitMQ's PVCs. \"\" uses the cluster default."
  type        = string
  default     = ""
}

variable "backing_services_postgres_image" {
  type    = string
  default = "postgres:16-alpine"
}

variable "backing_services_postgres_storage_size" {
  type    = string
  default = "2Gi"
}

variable "backing_services_rabbitmq_image" {
  type    = string
  default = "rabbitmq:3-management-alpine"
}

variable "backing_services_rabbitmq_storage_size" {
  type    = string
  default = "1Gi"
}

variable "backing_services_redis_image" {
  type    = string
  default = "redis:7-alpine"
}
