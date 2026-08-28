variable "manage_floci" {
  description = "true for the local/Floci pass, false for real AWS -- same convention as the root variable."
  type        = bool
}

variable "name_prefix" {
  description = "Usually var.cluster_name -- kept short, ALB/target-group names have a 32-char AWS limit."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

# Real AWS only (module.eks outputs, null-safe on the Floci pass -- see that
# module's own comments on why).
variable "cluster_security_group_id" {
  type    = string
  default = null
}

variable "node_group_asg_name" {
  type    = string
  default = null
}

# Floci only -- the floci-eks-<cluster_name> container backing the "cluster".
variable "floci_eks_container_name" {
  type    = string
  default = null
}

# Floci only -- fixed IP on the floci-static Docker network (see
# local.static_ips in the root main.tf). Passed straight through instead of
# resolved via `docker inspect` at apply time, since the default bridge
# network doesn't guarantee IP stability across container restarts but
# floci-static does.
variable "static_ip" {
  type    = string
  default = null
}

variable "services" {
  description = <<-EOT
    Public-facing services to front with the ALB. Each gets its own listener
    port + target group. node_port must match the fixed NodePort configured
    on that service's k8s Service (platform-gitops
    k8s/environments/<env>/values-<service>.yaml) -- both environments use
    the same node_port values so this map doesn't need to differ per env.
  EOT
  type = map(object({
    listener_port     = number
    node_port         = number
    health_check_path = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
