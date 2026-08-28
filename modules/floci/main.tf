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

  dynamic "ports" {
    for_each = var.extra_ports
    content {
      internal = tonumber(ports.key)
      external = ports.value
    }
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

  # kreuzwerker/docker 3.9.0 re-serializes `ports` from Docker's own
  # NetworkSettings.Ports map (unordered in the Docker API) into an ordered
  # list on every refresh -- confirmed live, the exact same 8 port mappings
  # come back in a different list order from one plan to the next with
  # nothing in `var.extra_ports` having changed, so every plan proposes
  # replacing this container purely to "reorder" entries that are already
  # correct. Twice live this actually broke things: bundled into a larger
  # apply alongside other -target resources, the destroy-then-create replace
  # this spurious diff triggers lost its own ordering race against Docker's
  # own container-name uniqueness check ("Conflict: /floci already in use"),
  # aborting the whole apply -- not a one-off, reproduced identically twice.
  # An isolated single-target apply of just this resource *does* complete
  # the replace correctly (named volumes/socket mount reattach fine), so
  # this isn't corrupting anything when it fires -- it's just firing on
  # every apply for no real reason, and unsafe to leave doing so bundled
  # with anything else. `extra_ports` changing (a genuinely new service
  # added to the ALB, a rare event) needs `terraform apply
  # -replace=module.floci[0].docker_container.floci` from here on instead
  # of happening automatically -- an explicit, deliberate step is the right
  # tradeoff against a container that can spontaneously and unsafely
  # recreate itself on any unrelated apply.
  #
  # `cpus` ignored too, for an unrelated reason: this container's actual
  # cap is managed live by scripts/cpu-priority.sh (`docker update --cpus`,
  # outside Terraform entirely -- see that script's own comment) so it
  # always has a real value here that this resource's config never
  # declares. Without ignoring it, every plan sees that as drift ("0.8" ->
  # null) and -- confirmed live -- `cpus` is *also* a forces-replacement
  # attribute for this provider, so it started proposing the exact same
  # unsafe bundled-replace this whole lifecycle block exists to stop, for
  # a completely different reason than the ports one above.
  lifecycle {
    ignore_changes = [ports, cpus]
  }
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
