variable "tenancy_ocid" {
  type        = string
  description = "Root tenancy OCID; also used as the compartment for all resources (no dedicated compartment at this scale)."
}

variable "region" {
  type    = string
  default = "ap-mumbai-1"
}

variable "vcn_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your current public IPv4, /32 — scopes who can reach the Kubernetes API endpoint directly. Update this if your ISP assigns you a new IP (`curl -4 ifconfig.me`)."
}

# --- app-secrets values (in a gitignored secrets.oci.tfvars, not here) ---

variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "rabbitmq_password" {
  type      = string
  sensitive = true
}

variable "google_client_secret" {
  type      = string
  sensitive = true
}
