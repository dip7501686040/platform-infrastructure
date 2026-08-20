provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }

  # The aws provider calls sts:GetCallerIdentity as part of its own
  # configuration step — before Terraform walks the resource graph at all,
  # so no depends_on can defer it. On a fresh `plan`, Floci isn't up yet
  # (module.floci only gets created during apply), so that eager check
  # always fails here. Skip it for the Floci pass only; real AWS still gets
  # full credential/account/metadata validation.
  skip_credentials_validation = var.manage_floci
  skip_requesting_account_id  = var.manage_floci
  skip_metadata_api_check     = var.manage_floci
  skip_region_validation      = var.manage_floci
}

# Only used when var.manage_floci is true (local env) — talks to the host
# Docker daemon to run the Floci emulator container itself. Default
# host/socket, same daemon `docker build`/`docker push` already use.
provider "docker" {}
