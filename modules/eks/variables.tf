variable "cluster_name" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "enable_irsa_addons" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
