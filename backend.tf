terraform {
  # Local backend for both environments (Floci and real AWS) so the .tf
  # source stays identical across targets — only the state-file path differs,
  # via -backend-config at `terraform init` time (see envs/*.backend.hcl).
  backend "local" {}
}
