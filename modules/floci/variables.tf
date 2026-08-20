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
