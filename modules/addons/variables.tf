variable "enable_irsa_addons" {
  description = "Gate for OIDC/IRSA-backed addons — Floci doesn't expose a resolvable OIDC issuer"
  type        = bool
  default     = false
}

variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
