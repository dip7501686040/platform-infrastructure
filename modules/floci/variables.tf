variable "image" {
  description = "Floci image (emulates ~75 AWS services on one port)"
  type        = string
  default     = "floci/floci:latest"
}

variable "container_name" {
  type    = string
  default = "floci"
}

variable "port" {
  description = "Host port the emulated AWS API listens on (matches infra/local/aws-config's endpoint_url)"
  type        = number
  default     = 4566
}

variable "extra_ports" {
  description = <<-EOT
    Additional container_port -> host_port mappings to publish on this
    container -- e.g. the ALB's listener ports (see modules/loadbalancer),
    which live inside this container's own network namespace and aren't
    host-reachable otherwise. Keyed by container port as a string (map keys
    must be strings), valued by the host port to publish it on.
  EOT
  type        = map(number)
  default     = {}
}
