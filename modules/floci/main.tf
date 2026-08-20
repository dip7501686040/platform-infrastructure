# Manages the Floci emulator container itself, not just the resources
# inside it — so a fresh `terraform apply` after `docker rm`-ing everything
# (including this container) pulls the image if it's missing and starts it,
# with no manual `docker run` step. Everything else in the AWS-provider
# graph depends_on this module so it isn't reachable via localhost:4566
# before Floci is actually listening.

resource "docker_image" "floci" {
  name         = var.image
  keep_locally = true # don't re-pull on every destroy/apply cycle
}

resource "docker_container" "floci" {
  name  = var.container_name
  image = docker_image.floci.image_id

  ports {
    internal = 4566
    external = var.port
  }

  # Without this, FLOCI_STORAGE_MODE defaults to "memory" — every AWS
  # resource Floci has ever emulated (VPC, ECR repos, the EKS cluster, the
  # EC2/Jenkins instance) is forgotten the instant this container restarts,
  # which includes every Mac reboot. Confirmed the hard way: with this unset,
  # a `terraform apply` after a simple `docker start` of the stopped
  # floci-eks-*/floci-ec2-* containers still planned to destroy and recreate
  # all 60 resources, because Floci itself had no memory of them even though
  # the underlying containers/volumes were untouched on disk. "persistent"
  # (sync flush on every write) over "hybrid"/"wal" — this is a single local
  # dev cluster, the write volume is trivial, and a clean reboot shouldn't
  # ever lose anything to an async flush window.
  env = ["FLOCI_STORAGE_MODE=persistent"]

  # Floci shells out to the host Docker daemon to emulate EC2/ECR/EKS as
  # real containers — same requirement as the manual `docker run ... -v
  # /var/run/docker.sock:/var/run/docker.sock` invocation.
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  # Named, not the image's implicit anonymous VOLUME /app/data — an
  # anonymous volume only survives a stop/start of this exact container;
  # this survives even a future forced replace (e.g. an image version bump)
  # too, so the persistence above can't be silently undone by something
  # unrelated to a deliberate `docker volume rm`.
  volumes {
    volume_name    = "floci-data"
    container_path = "/app/data"
  }

  # Not --rm: this container is now Terraform-managed state, meant to
  # survive between applies (and restart with the host/Docker daemon).
  restart  = "unless-stopped"
  must_run = true
}

# docker_container reports "running" as soon as the process starts, not once
# the API is actually accepting connections — a real gap on first boot.
# Block here so every dependent module's first API call doesn't race it.
resource "terraform_data" "wait_for_floci" {
  depends_on = [docker_container.floci]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      for i in $(seq 1 30); do
        if (exec 3<>/dev/tcp/127.0.0.1/${var.port}) 2>/dev/null; then
          exec 3<&- 3>&-
          echo "floci is accepting connections on port ${var.port}"
          exit 0
        fi
        sleep 2
      done
      echo "floci did not open port ${var.port} within 60s" >&2
      exit 1
    EOT
  }
}
