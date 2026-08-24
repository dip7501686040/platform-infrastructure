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

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
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

variable "jenkins_local_tunnel_port" {
  description = "Local Mac port for a Terraform-managed kubectl port-forward to the Jenkins Service's port 8080. 0 disables it (default) — leave disabled on any box that isn't a human's dev machine."
  type        = number
  default     = 0
}

# Floci only -- real AWS reaches the ALB at its actual DNS name, no local
# port publishing involved. web/api-gateway are reached exclusively through
# the ALB now (no kubectl-port-forward tunnel anymore -- see git history for
# the removed web_tunnel resource).
variable "alb_web_local_port" {
  description = "Local Mac port the ALB's web listener (inside the floci container's own netns) is published on."
  type        = number
  default     = 8080
}

variable "alb_api_gateway_local_port" {
  description = "Local Mac port the ALB's api-gateway listener is published on. Defaults to 8000 to match NEXT_PUBLIC_API_URL's own default -- no web-side config change needed."
  type        = number
  default     = 8000
}

variable "argocd_local_tunnel_port" {
  description = "Local Mac port for a Terraform-managed kubectl port-forward to the ArgoCD server Service's port 443 (TLS, self-signed — expect a browser warning). 0 disables it (default) — leave disabled on any box that isn't a human's dev machine."
  type        = number
  default     = 0
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
