variable "cluster_name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

# Pinned, not discovered via a data "aws_availability_zones" lookup -- see
# main.tf's own comment on why that data source is actively unsafe to use
# here (module-level depends_on chains + this project's always-recreating
# terraform_data steps make it resolve as "unknown" on every plan, forcing
# needless subnet replacement). Both envs/local.tfvars and envs/prod.tfvars
# use aws_region = "us-east-1" today, hence this default; if either ever
# targets a different region, override this explicitly (both callers
# already pass every other network variable explicitly, so adding this one
# follows the same pattern).
variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
