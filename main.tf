locals {
  app_services_name     = var.clusters["app_services"].cluster_name
  jenkins_name          = var.clusters["jenkins"].cluster_name
  argocd_name           = var.clusters["argocd"].cluster_name
  observability_name    = var.clusters["observability"].cluster_name
  backing_services_name = var.clusters["backing_services"].cluster_name

  # Fixed NodePorts for the two cross-cluster links this architecture needs
  # (otel-collector receiving OTLP from app_services; Prometheus scraping
  # kube-state-metrics-app-services) -- pinned rather than dynamically
  # queried at apply time, same convention this repo already uses for
  # web/api-gateway's ALB target-group NodePorts (see var.lb_services).
  # Avoids a whole class of "helm-assigned port not known until after the
  # install runs" chicken-and-egg problem a rendered values file would
  # otherwise hit.
  otel_otlp_grpc_node_port = 30317
  # NOT 30081 -- confirmed live, that's already var.lb_services'
  # api-gateway NodePort (pre-existing, unrelated to this cross-cluster
  # work), and ArgoCD's sync for api-gateway was failing outright on
  # "provided port is already allocated" as a direct result.
  kube_state_metrics_node_port = 30082

  # Fixed NodePorts for backing_services (Postgres/RabbitMQ/Redis), split
  # out onto its own cluster -- app_services reaches them the exact same
  # way it reaches otel-collector cross-cluster: a NodePort here, addressed
  # by a stub Service+Endpoints on the consuming side (see
  # backing_services_cross_cluster_stub below).
  postgres_node_port      = 30432
  rabbitmq_amqp_node_port = 30672
  redis_node_port         = 30679
  rabbitmq_prometheus_node_port = 30692
  api_gateway_metrics_node_port = 30964

  # Every human-facing UI in this stack is reached through its own
  # cluster's ALB now -- no kubectl port-forward tunnels. listener_port is
  # the port each cluster's ALB answers on *inside the base floci
  # container's network namespace* (see module.floci's extra_ports below,
  # which is what actually makes it host-reachable) -- must be unique
  # across ALL of these clusters' ALBs since they all publish through that
  # SAME single container, unlike node_port (k8s-level, safe to reuse
  # across different clusters/k3s nodes since those are separate
  # containers). web=80/api-gateway=8000 (var.lb_services) already claim
  # those two -- everything here picks distinct ports above 8000.
  jenkins_alb    = { listener_port = 8081, node_port = 30881, health_check_path = "/login" }
  argocd_alb     = { listener_port = 8082, node_port = 30882, health_check_path = "/healthz" }
  grafana_alb    = { listener_port = 8083, node_port = 30883, health_check_path = "/login" }
  prometheus_alb = { listener_port = 8084, node_port = 30884, health_check_path = "/-/healthy" }
  jaeger_alb     = { listener_port = 8085, node_port = 30885, health_check_path = "/" }

  # Fixed IPs on a custom Docker network (floci_static_network below) for
  # every floci-eks-<cluster> container, plus the shared ECR registry
  # container -- confirmed live, repeatedly, that Docker's default "bridge"
  # network does NOT guarantee a container keeps the same internal IP
  # across a `docker stop`/`start` cycle. k3s persists its own node
  # registration (including that IP) to disk and hard-crashes on every boot
  # if it no longer matches an actual interface -- confirmed live via
  # RestartCount climbing every ~2s -- rather than adapting. Pinning a
  # static IP per container eliminates that failure mode at the root
  # instead of recovering from it after the fact (the wipe-and-reinit
  # dance in scripts/kubeconfig.sh's own wait loop, still kept as a
  # fallback for whatever this doesn't cover). Also removes the need for
  # every consumer that used to `docker inspect` a cluster's current IP at
  # apply time (module.loadbalancer's target registration, the three
  # cross-cluster resources below) -- these are now compile-time-known
  # constants, not runtime lookups. The default bridge network can't do
  # this at all (`--ip` is a Docker feature only user-defined networks
  # support), hence the separate network.
  static_ips = {
    app_services     = "172.30.0.10"
    jenkins          = "172.30.0.11"
    argocd           = "172.30.0.12"
    observability    = "172.30.0.13"
    backing_services = "172.30.0.14"
    ecr_registry     = "172.30.0.20"
  }
}

# Floci-only: the custom network the fixed IPs above live on. Idempotent
# (docker network create fails harmlessly if it already exists) and cheap
# enough to just check-and-create on every apply rather than tracking it as
# its own terraform_data with a real skip-check.
resource "terraform_data" "ensure_static_network" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [module.floci]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      docker network inspect floci-static >/dev/null 2>&1 || \
        docker network create --subnet 172.30.0.0/24 floci-static >/dev/null

      # The `floci` container itself (not one of the 4 EKS clusters) is what
      # actually runs the ALB emulation -- confirmed live, every ALB target
      # group registered against a 172.30.0.x static IP reported
      # Target.Timeout until this container was also on floci-static. No
      # route to floci-static, no way for it to ever reach any of the 4
      # clusters it's supposed to be fronting.
      if ! docker inspect floci --format '{{json .NetworkSettings.Networks}}' | grep -q floci-static; then
        docker network connect floci-static floci
      fi
    EOT
  }
}

# Started/pulled before anything else touches the aws provider. count-based
# (not a plain resource block) so real-AWS applies (manage_floci = false)
# never require the docker provider to be reachable at all.
module "floci" {
  count  = var.manage_floci ? 1 : 0
  source = "./modules/floci"

  extra_ports = {
    "${var.lb_services["web"].listener_port}"         = var.alb_web_local_port
    "${var.lb_services["api-gateway"].listener_port}" = var.alb_api_gateway_local_port
    "${local.jenkins_alb.listener_port}"              = var.alb_jenkins_local_port
    "${local.argocd_alb.listener_port}"               = var.alb_argocd_local_port
    "${local.grafana_alb.listener_port}"              = var.alb_grafana_local_port
    "${local.prometheus_alb.listener_port}"           = var.alb_prometheus_local_port
    "${local.jaeger_alb.listener_port}"               = var.alb_jaeger_local_port
  }
}

module "ecr" {
  source     = "./modules/ecr"
  depends_on = [module.floci]

  repository_names = var.ecr_repository_names
  tags             = var.tags
}

# ---------------------------------------------------------------------------
# Serial cluster chain
#
# Each of the 4 clusters used to be one `for_each` instance of
# module.network/module.eks/module.addons, created in whatever order
# Terraform's default parallelism picked -- confirmed live this session,
# all 4 floci-eks-* containers cold-starting at once, real CPU contention on
# a machine that can't absorb it. A real HCL dependency between for_each
# instances of the SAME module was tried and rejected by `terraform
# validate` as a cycle (for_each collapses every instance into one graph
# node, so cross-referencing two keys of the same module closes a loop at
# the whole-module level even though no individual instance pair actually
# cycles) -- "enforced operationally" instead via `-parallelism=1`, a flag
# that's trivial to forget (happened this session).
#
# Un-rolled into 4 explicitly named module instances instead, threaded
# together with real depends_on edges. This isn't a fake dependency -- each
# stage's own kubeconfig.sh call already needs the *previous* cluster to be
# fully up (network -> eks -> addons -> every install step on it), so a
# strict chain is both what CPU-safety requires and what's actually true.
#
# Order: app_services first (nothing else needs anything from ANYONE, and
# both argocd and observability need app_services to already exist so they
# can register/token against it) -> jenkins (fully independent, no reason
# to make it wait past app_services) -> argocd (registers app_services as a
# remote cluster once both exist) -> observability (remote-scrapes
# app_services once both exist). This satisfies "whichever has no unmet
# dependency goes next", not just the literal jenkins/argocd/observability/
# app_services listing that was the original ask -- see the plan file for
# why that literal order doesn't actually work.
# ---------------------------------------------------------------------------

# --- app_services ------------------------------------------------------

module "network_app_services" {
  source     = "./modules/network"
  depends_on = [module.floci]

  cluster_name       = local.app_services_name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = var.tags
}

module "eks_app_services" {
  source     = "./modules/eks"
  depends_on = [module.network_app_services]

  cluster_name        = local.app_services_name
  k8s_version         = var.k8s_version
  private_subnet_ids  = module.network_app_services.private_subnet_ids
  public_subnet_ids   = module.network_app_services.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  enable_irsa_addons  = var.enable_irsa_addons
  tags                = var.tags
}

module "addons_app_services" {
  source     = "./modules/addons"
  depends_on = [module.eks_app_services]

  enable_irsa_addons = var.enable_irsa_addons
  cluster_name       = local.app_services_name
  oidc_provider_arn  = module.eks_app_services.oidc_provider_arn
  oidc_provider_url  = module.eks_app_services.oidc_provider_url
  tags               = var.tags
}

# Fronts web + api-gateway with a real ALB via Floci's ELBv2 emulation
# locally and a real AWS ALB in prod -- unchanged from before, just
# rewired to the un-rolled app_services module names.
module "loadbalancer" {
  source     = "./modules/loadbalancer"
  depends_on = [module.floci, module.eks_app_services, terraform_data.ensure_restart_policies_app_services]

  manage_floci              = var.manage_floci
  name_prefix               = module.eks_app_services.cluster_name
  vpc_id                    = module.network_app_services.vpc_id
  public_subnet_ids         = module.network_app_services.public_subnet_ids
  cluster_security_group_id = module.eks_app_services.cluster_security_group_id
  node_group_asg_name       = module.eks_app_services.node_group_asg_name
  static_ip                 = local.static_ips.app_services
  services                  = var.lb_services
  tags                      = var.tags
}

resource "terraform_data" "ensure_restart_policies_app_services" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [module.eks_app_services, terraform_data.ensure_static_network]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CONTAINER="floci-eks-${module.eks_app_services.cluster_name}"
      DESIRED_IP="${local.static_ips.app_services}"
      docker update --restart=unless-stopped "$CONTAINER" >/dev/null

      # Checks the ACTUAL assigned IP, not just network membership. Confirmed
      # live (first on backing_services, then again here after this cluster
      # got `-replace`d to dodge a Floci host-port collision): a plain
      # membership check (`grep -q floci-static`) sees "already connected"
      # and skips the explicit --ip request the moment Floci's own
      # container-creation step has auto-joined floci-eks-* to every
      # existing custom Docker network before this script ever runs --
      # whether that's this cluster's first-ever creation (if floci-static
      # already existed by then) or any later recreation. Only ever safe to
      # skip when the recorded IP already matches.
      CURRENT_IP=$(docker inspect "$CONTAINER" --format '{{(index .NetworkSettings.Networks "floci-static").IPAddress}}' 2>/dev/null || true)
      NEEDED_FIX=false
      if [ "$CURRENT_IP" != "$DESIRED_IP" ]; then
        NEEDED_FIX=true
        docker network disconnect floci-static "$CONTAINER" 2>/dev/null || true
        docker network connect --ip "$DESIRED_IP" floci-static "$CONTAINER"
      fi

      # k3s only auto-detects its own node-ip at boot -- once floci-static is
      # attached alongside the default bridge (above), that auto-detection
      # becomes ambiguous between the two interfaces. Confirmed live: without
      # an explicit pin this surfaces as `fatal: unable to initialize network
      # policy controller: error getting node subnet: failed to find
      # interface with specified node ip`. Pinning via node-ip/node-external-ip
      # (config.yaml is read automatically by k3s, no CLI flag needed) helps,
      # but confirmed live it's NOT fully deterministic on its own -- this is
      # a boot-order race between floci-static's interface actually coming up
      # and this same network-policy-controller check running, and pinning
      # the IP doesn't guarantee the interface exists yet at that exact
      # instant. disable-network-policy removes the race at the root instead
      # of chasing its timing: these are single-node clusters with no real
      # multi-tenant NetworkPolicy enforcement need, so the controller this
      # bug lives in isn't doing anything for us anyway. docker cp works
      # whether the container is running or stopped, unlike docker exec --
      # same reason ensure_registry_pull_mirror doesn't rely on exec for a
      # stopped container either.
      DESIRED_K3S_CONFIG="node-ip: $DESIRED_IP
node-external-ip: $DESIRED_IP
disable-network-policy: true
"
      CURRENT_K3S_CONFIG=$(docker cp "$CONTAINER:/etc/rancher/k3s/config.yaml" - 2>/dev/null | tar -xO 2>/dev/null || true)
      if [ "$CURRENT_K3S_CONFIG" != "$(printf '%s' "$DESIRED_K3S_CONFIG")" ]; then
        NEEDED_FIX=true
        TMP_K3S_CONFIG=$(mktemp)
        printf '%s' "$DESIRED_K3S_CONFIG" > "$TMP_K3S_CONFIG"
        docker cp "$TMP_K3S_CONFIG" "$CONTAINER:/etc/rancher/k3s/config.yaml"
        rm -f "$TMP_K3S_CONFIG"
      fi

      # If either the network or config.yaml needed correcting, the
      # container may have ALREADY booted once with the wrong IP/config --
      # a plain restart alone does NOT fix this, since k3s persists its own
      # first-ever self-registered node identity and silently keeps it
      # forever after. scripts/kubeconfig.sh's own RestartCount-driven wipe
      # loop (sourced by every step downstream of this one) is the usual
      # safety net for that, but it only fires on an observed crash loop --
      # a wrong-but-stable IP doesn't crash, it just serves wrong, so it
      # needs wiping here too rather than waiting on that loop to notice.
      if [ "$NEEDED_FIX" = "true" ]; then
        ALREADY_BOOTED=$(docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && echo true || echo false)
        if [ "$ALREADY_BOOTED" = "true" ]; then
          echo "container already booted once before this fix landed -- wiping its k3s datastore for a clean re-init on the corrected network..."
          docker stop "$CONTAINER" >/dev/null
          docker run --rm --entrypoint sh -v "$CONTAINER:/data" rancher/k3s:latest -c 'rm -rf /data/*' >/dev/null
          docker start "$CONTAINER" >/dev/null
        else
          docker restart "$CONTAINER" >/dev/null
        fi
        echo "waiting for k3s to come back up..."
        for i in $(seq 1 60); do
          docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
          sleep 2
        done
      fi
    EOT
  }
}

# Floci-only: containerd (inside the k3s node) defaults to HTTPS for any
# registry host it has no explicit config for, but floci-ecr-registry is
# plain unauthenticated HTTP. Only app_services ever pulls images from it
# (Jenkins pushes via kaniko's own HTTP client, not a containerd pull), so
# this stays scoped to app_services alone -- unchanged from before.
resource "terraform_data" "ensure_registry_pull_mirror" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.ensure_restart_policies_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CONTAINER="floci-eks-${module.eks_app_services.cluster_name}"

      if ! docker inspect floci-ecr-registry >/dev/null 2>&1; then
        echo "floci-ecr-registry not found yet -- skipping (nothing to mirror)."
        exit 0
      fi

      # app_services can legitimately be stopped (paused for CPU/stability
      # reasons, mid-restart-loop investigation, etc.) -- docker exec would
      # just hard-fail the whole apply in that case. Nothing to mirror into
      # a container that isn't running anyway; this step re-runs and
      # catches up next apply once it's back up.
      if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        echo "$CONTAINER is not running -- skipping (will patch registries.yaml next apply once it's up)."
        exit 0
      fi

      # Pinned to local.static_ips.ecr_registry, not a `docker inspect`
      # lookup of the default bridge network -- see local.static_ips' own
      # comment for the full reasoning (Docker's default bridge doesn't
      # guarantee IP stability across restarts). This is what actually
      # makes the patch below a one-time fix instead of something that
      # recurs on every single registry container restart.
      if ! docker inspect floci-ecr-registry --format '{{json .NetworkSettings.Networks}}' | grep -q floci-static; then
        docker network connect --ip "${local.static_ips.ecr_registry}" floci-static floci-ecr-registry
      fi
      REGISTRY_IP="${local.static_ips.ecr_registry}"

      # Anchored to exactly 2 leading spaces -- a plain substring grep
      # (the previous check) also matches a MALFORMED entry sitting at
      # column 0 (not actually nested under `mirrors:` at all, so
      # containerd never sees it as a real override) as if it were a
      # working one, permanently skipping the real fix forever after.
      # Confirmed live: exactly this happened -- a stale unindented entry
      # from an earlier session sat there silently "passing" this check on
      # every apply since, while every real image pull kept failing with
      # "server gave HTTP response to HTTPS client" the whole time.
      if docker exec "$CONTAINER" grep -qE "^  \"$REGISTRY_IP:5000\":[[:space:]]*\$" /etc/rancher/k3s/registries.yaml 2>/dev/null; then
        echo "registries.yaml already has a correctly-formed mirror for $REGISTRY_IP:5000 -- nothing to do."
        exit 0
      fi

      MALFORMED_LINE=$(docker exec "$CONTAINER" grep -n "\"$REGISTRY_IP:5000\":" /etc/rancher/k3s/registries.yaml 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$MALFORMED_LINE" ]; then
        echo "registries.yaml has a malformed (incorrectly indented) mirror entry for $REGISTRY_IP:5000 at line $MALFORMED_LINE -- fixing it in place..."
        NEXT1=$((MALFORMED_LINE + 1))
        NEXT2=$((MALFORMED_LINE + 2))
        docker exec "$CONTAINER" sh -c "
          sed -i '$${MALFORMED_LINE}s/.*/  \"$REGISTRY_IP:5000\":/' /etc/rancher/k3s/registries.yaml
          sed -i '$${NEXT1}s/.*/    endpoint:/' /etc/rancher/k3s/registries.yaml
          sed -i '$${NEXT2}s#.*#      - \"http://$REGISTRY_IP:5000\"#' /etc/rancher/k3s/registries.yaml
        "
      else
        echo "registries.yaml is missing a mirror for the current registry IP ($REGISTRY_IP) -- patching and restarting k3s to pick it up..."
        docker exec "$CONTAINER" sh -c "sed -i '1a\\
  \"$REGISTRY_IP:5000\":\\
    endpoint:\\
      - \"http://$REGISTRY_IP:5000\"' /etc/rancher/k3s/registries.yaml"
      fi
      docker restart "$CONTAINER" >/dev/null

      echo "waiting for k3s to come back up..."
      for i in $(seq 1 60); do
        docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
        sleep 2
      done
    EOT
  }
}

resource "terraform_data" "k8s_reconcile_app_services" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.ensure_registry_pull_mirror]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      echo "cleaning up stale Terminating/Unknown pods..."
      kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating" || $4=="Unknown"{print $2, $1}' | \
        while read -r ns name; do
          kubectl delete pod "$name" -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
        done

      echo "removing NotReady nodes..."
      LIVE_NODES=""
      for node in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
        status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$status" = "True" ]; then
          LIVE_NODES="$LIVE_NODES $node"
        else
          kubectl delete node "$node" >/dev/null 2>&1 || true
        fi
      done

      echo "reconciling PVCs pinned to now-deleted nodes..."
      kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1, $2}' | \
        while read -r ns name; do
          pv=$(kubectl get pvc "$name" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
          [ -z "$pv" ] && continue
          pinned=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)
          [ -z "$pinned" ] && continue
          case " $LIVE_NODES " in
            *" $pinned "*) ;;
            *)
              echo "  $ns/$name is pinned to dead node $pinned -- deleting so it recreates fresh"
              kubectl delete pvc "$name" -n "$ns" >/dev/null 2>&1 || true
              ;;
          esac
        done

      echo "k8s reconcile complete."
    EOT
  }
}

# app-secrets is read by postgres/rabbitmq's own credentials, and every
# nest-service chart (DATABASE_URL/RABBITMQ_URL composition). Never wired
# up for prod: real secrets there stay a deliberate manual step.
resource "terraform_data" "app_secrets" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.k8s_reconcile_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace ai-notification --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      kubectl create secret generic app-secrets -n ai-notification \
        --from-literal=JWT_SECRET='${var.jwt_secret}' \
        --from-literal=POSTGRES_PASSWORD='${var.postgres_password}' \
        --from-literal=RABBITMQ_PASSWORD='${var.rabbitmq_password}' \
        --from-literal=RABBITMQ_URL='amqp://notification:${var.rabbitmq_password}@rabbitmq.ai-notification.svc.cluster.local:5672' \
        --from-literal=ANTHROPIC_API_KEY='${var.anthropic_api_key}' \
        --from-literal=OPENAI_API_KEY='${var.openai_api_key}' \
        --from-literal=SMTP_PASSWORD='${var.smtp_password}' \
        --from-literal=STRIPE_SECRET_KEY='${var.stripe_secret_key}' \
        --from-literal=STRIPE_WEBHOOK_SECRET='${var.stripe_webhook_secret}' \
        --from-literal=GOOGLE_CLIENT_SECRET='${var.google_client_secret}' \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      echo "app-secrets applied."
    EOT
  }
}

# ---------------------------------------------------------------------------
# Backing services (Postgres/RabbitMQ/Redis) -- their own cluster
# (backing_services), not app_services. Originally landed directly in
# app_services (moved there from a GitOps chart) -- split out per the user's
# explicit decision to reverse that call, so a CPU storm from the 13 app
# workloads cold-starting can't take Postgres/RabbitMQ down with it. Reached
# from app_services via backing_services_cross_cluster_stub below, same
# pattern as otel-collector's own cross-cluster link.
#
# Each gets the same idempotency shape as every other install step here:
# check a live object first, skip the real work if it's already there and
# healthy.
# ---------------------------------------------------------------------------

resource "terraform_data" "postgres_install" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.backing_services_secrets]

  triggers_replace = {
    always_run    = timestamp()
    manifest_hash = "${filesha256("${path.module}/templates/backing-services/postgres.yaml.tftpl")}-${filesha256("${path.module}/templates/backing-services/files/postgres-init.sql")}"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      DEPLOYED_HASH=$(kubectl get statefulset postgres -n backing-services -o jsonpath='{.metadata.annotations.manifest-hash}' 2>/dev/null || true)
      READY=$(kubectl get statefulset postgres -n backing-services -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${self.triggers_replace.manifest_hash}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "postgres already deployed and healthy with unchanged manifest -- skipping."
        exit 0
      fi

      cat <<'MANIFEST' | kubectl apply -f -
${templatefile("${path.module}/templates/backing-services/postgres.yaml.tftpl", {
    namespace          = "backing-services"
    postgres_image     = var.backing_services_postgres_image
    storage_class_name = var.backing_services_storage_class
    storage_size       = var.backing_services_postgres_storage_size
    postgres_init_sql  = file("${path.module}/templates/backing-services/files/postgres-init.sql")
})}
MANIFEST

      kubectl rollout status statefulset/postgres -n backing-services --timeout=5m
      kubectl annotate statefulset postgres -n backing-services manifest-hash="${self.triggers_replace.manifest_hash}" --overwrite
    EOT
}
}

resource "terraform_data" "rabbitmq_install" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.postgres_install]

  triggers_replace = {
    always_run    = timestamp()
    manifest_hash = filesha256("${path.module}/templates/backing-services/rabbitmq.yaml.tftpl")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      DEPLOYED_HASH=$(kubectl get statefulset rabbitmq -n backing-services -o jsonpath='{.metadata.annotations.manifest-hash}' 2>/dev/null || true)
      READY=$(kubectl get statefulset rabbitmq -n backing-services -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${self.triggers_replace.manifest_hash}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "rabbitmq already deployed and healthy with unchanged manifest -- skipping."
        exit 0
      fi

      cat <<'MANIFEST' | kubectl apply -f -
${templatefile("${path.module}/templates/backing-services/rabbitmq.yaml.tftpl", {
    namespace          = "backing-services"
    rabbitmq_image     = var.backing_services_rabbitmq_image
    storage_class_name = var.backing_services_storage_class
    storage_size       = var.backing_services_rabbitmq_storage_size
})}
MANIFEST

      kubectl rollout status statefulset/rabbitmq -n backing-services --timeout=5m
      kubectl annotate statefulset rabbitmq -n backing-services manifest-hash="${self.triggers_replace.manifest_hash}" --overwrite
    EOT
}
}

resource "terraform_data" "redis_install" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.rabbitmq_install]

  triggers_replace = {
    always_run    = timestamp()
    manifest_hash = filesha256("${path.module}/templates/backing-services/redis.yaml.tftpl")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      DEPLOYED_HASH=$(kubectl get deployment redis -n backing-services -o jsonpath='{.metadata.annotations.manifest-hash}' 2>/dev/null || true)
      READY=$(kubectl get deployment redis -n backing-services -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${self.triggers_replace.manifest_hash}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "redis already deployed and healthy with unchanged manifest -- skipping."
        exit 0
      fi

      cat <<'MANIFEST' | kubectl apply -f -
${templatefile("${path.module}/templates/backing-services/redis.yaml.tftpl", {
    namespace   = "backing-services"
    redis_image = var.backing_services_redis_image
})}
MANIFEST

      kubectl rollout status deployment/redis -n backing-services --timeout=5m
      kubectl annotate deployment redis -n backing-services manifest-hash="${self.triggers_replace.manifest_hash}" --overwrite
    EOT
}
}

# NodePort exposure for cross-cluster reach from app_services -- clusterIP:
# None (headless, needed for StatefulSet DNS) can't also be NodePort on the
# same Service object, so these are separate Service objects layered on top,
# same pattern as grafana_nodeport_service/prometheus_nodeport_service.
resource "terraform_data" "backing_services_nodeports" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.redis_install]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      cat <<SVCEOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres-nodeport
  namespace: backing-services
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: postgres }
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: ${local.postgres_node_port}
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq-nodeport
  namespace: backing-services
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: rabbitmq }
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
      nodePort: ${local.rabbitmq_amqp_node_port}
    - name: prometheus
      port: 15692
      targetPort: 15692
      nodePort: ${local.rabbitmq_prometheus_node_port}
---
apiVersion: v1
kind: Service
metadata:
  name: redis-nodeport
  namespace: backing-services
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: redis }
  ports:
    - port: 6379
      targetPort: 6379
      nodePort: ${local.redis_node_port}
SVCEOF
    EOT
  }
}

# The other half of the link: a stub Service+Endpoints on app_services with
# the EXACT names (postgres/rabbitmq/redis) and namespace (ai-notification)
# nest-service's chart already expects (postgresHost: postgres,
# rabbitmqHost: rabbitmq, both bare short names resolved same-namespace) --
# zero chart/values changes across any environment. Same pattern as
# otel_cross_cluster_stub.
resource "terraform_data" "backing_services_cross_cluster_stub" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.backing_services_nodeports, terraform_data.k8s_reconcile_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      BACKING_IP="${local.static_ips.backing_services}"

      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace ai-notification --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      # clusterIP is immutable -- if postgres/rabbitmq/redis previously
      # existed as StatefulSet-backed headless Services (clusterIP: None,
      # required for stable per-pod DNS) on THIS cluster, kubectl apply
      # can't turn them into normal ClusterIP Services no matter what this
      # manifest says; it just silently keeps clusterIP: None forever.
      # Confirmed live: that's fatal here specifically, since a headless
      # Service has no kube-proxy virtual IP to translate ports through --
      # clients resolving "rabbitmq:5672" get $BACKING_IP straight from
      # DNS and connect to port 5672 directly, but only
      # ${local.rabbitmq_amqp_node_port} is actually listening there,
      # wedging every consumer in an init-container retry loop with no
      # error, just a silent connection timeout. Deleting first (cheap,
      # these are always immediately recreated below) guarantees a real
      # ClusterIP every time instead of inheriting stale headless state.
      for svc in postgres rabbitmq redis; do
        if [ "$(kubectl get svc "$svc" -n ai-notification -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" = "None" ]; then
          kubectl delete svc "$svc" -n ai-notification >/dev/null
        fi
      done

      cat <<STUBEOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ai-notification
spec:
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres
  namespace: ai-notification
subsets:
  - addresses:
      - ip: $BACKING_IP
    ports:
      - port: ${local.postgres_node_port}
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: ai-notification
spec:
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
---
apiVersion: v1
kind: Endpoints
metadata:
  name: rabbitmq
  namespace: ai-notification
subsets:
  - addresses:
      - ip: $BACKING_IP
    ports:
      - name: amqp
        port: ${local.rabbitmq_amqp_node_port}
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ai-notification
spec:
  ports:
    - port: 6379
      targetPort: 6379
---
apiVersion: v1
kind: Endpoints
metadata:
  name: redis
  namespace: ai-notification
subsets:
  - addresses:
      - ip: $BACKING_IP
    ports:
      - port: ${local.redis_node_port}
STUBEOF

      echo "postgres/rabbitmq/redis reachable from app_services via $BACKING_IP."
    EOT
  }
}

resource "terraform_data" "api_gateway_metrics_nodeport" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.k8s_reconcile_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl apply -f - <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  name: api-gateway-metrics-nodeport
  namespace: ai-notification
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: api-gateway }
  ports:
    - port: 9464
      targetPort: 9464
      nodePort: ${local.api_gateway_metrics_node_port}
SVCEOF
    EOT
  }
}


# k3s sometimes ships metrics-server as a built-in addon already -- checked
# first so this doesn't fight or duplicate it. Lives here (app_services),
# not with the rest of the observability stack: this is what KEDA actually
# needs to be co-located with -- see the plan file for why moving KEDA next
# to observability instead doesn't work (no cross-cluster HPA).
resource "terraform_data" "metrics_server_install_app_services" {
  count = var.manage_floci ? 1 : 0
  # Not backing_services_cross_cluster_stub -- metrics-server itself needs
  # nothing from Postgres/RabbitMQ/Redis, and coupling this to a different
  # cluster's install chain would just make app_services' own bootstrap
  # wait on backing_services' for no functional reason.
  depends_on = [terraform_data.app_secrets]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      FOUND=false
      for i in $(seq 1 15); do
        if kubectl get serviceaccount metrics-server -n kube-system >/dev/null 2>&1; then
          FOUND=true
          break
        fi
        sleep 2
      done

      if [ "$FOUND" = "true" ]; then
        echo "metrics-server already present (k3s built-in or a prior apply) -- waiting for it to be ready..."
        kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || true
        exit 0
      fi

      helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
      helm repo update metrics-server >/dev/null 2>&1

      helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --set args="{--kubelet-insecure-tls}" \
        --set resources.requests.cpu=25m \
        --set resources.requests.memory=64Mi \
        --set resources.limits.cpu=150m \
        --set resources.limits.memory=128Mi \
        --wait --timeout 5m
    EOT
  }
}

# KEDA operator only -- inert until an HPA/ScaledObject references it. Stays
# in app_services (not observability): it manipulates replica counts on
# Deployments via its own cluster's API server, and those Deployments (the
# 13 app services) live here.
resource "terraform_data" "keda_install" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.metrics_server_install_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      READY=$(kubectl get deployment keda-operator -n keda -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$${READY:-0}" -ge 1 ]; then
        echo "KEDA already installed and healthy -- skipping."
        exit 0
      fi

      helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
      helm repo update kedacore >/dev/null 2>&1

      helm upgrade --install keda kedacore/keda \
        --namespace keda --create-namespace \
        --set resources.operator.requests.cpu=25m \
        --set resources.operator.requests.memory=64Mi \
        --set resources.operator.limits.cpu=150m \
        --set resources.operator.limits.memory=256Mi \
        --set resources.metricServer.requests.cpu=25m \
        --set resources.metricServer.requests.memory=64Mi \
        --set resources.metricServer.limits.cpu=150m \
        --set resources.metricServer.limits.memory=256Mi \
        --set resources.webhooks.requests.cpu=10m \
        --set resources.webhooks.requests.memory=32Mi \
        --set resources.webhooks.limits.cpu=100m \
        --set resources.webhooks.limits.memory=128Mi \
        --wait --timeout 5m
    EOT
  }
}

# ---------------------------------------------------------------------------
# Remote-cluster-access token -- minted once on app_services, consumed
# later by both argocd (to register app_services as a remote managed
# cluster) and observability (to remote-scrape it). A ServiceAccount-bound
# Secret (the legacy kubernetes.io/service-account-token style), not
# `kubectl create token` -- that command mints a brand-new signed JWT on
# every single call, which would make every downstream consumer's hash
# change on every apply even when nothing real changed, defeating the whole
# idempotency goal. This Secret's token is stable for the SA's lifetime.
# cluster-admin is pragmatic and local-only, matching how this repo already
# handles credentials elsewhere for the Floci pass specifically (never
# wired up for real AWS).
# ---------------------------------------------------------------------------

resource "terraform_data" "remote_access_token" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.keda_install]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create serviceaccount remote-cluster-reader -n kube-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      kubectl create clusterrolebinding remote-cluster-reader --clusterrole=cluster-admin \
        --serviceaccount=kube-system:remote-cluster-reader --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      kubectl apply -f - <<'SAEOF'
apiVersion: v1
kind: Secret
metadata:
  name: remote-cluster-reader-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: remote-cluster-reader
type: kubernetes.io/service-account-token
SAEOF

      TOKEN=""
      for i in $(seq 1 30); do
        TOKEN=$(kubectl get secret remote-cluster-reader-token -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
        [ -n "$TOKEN" ] && break
        sleep 2
      done
      if [ -z "$TOKEN" ]; then
        echo "remote-cluster-reader-token never populated" >&2
        exit 1
      fi

      mkdir -p "${path.module}/envs/state"
      printf '%s' "$TOKEN" > "${path.module}/envs/state/remote-access-token-app-services.txt"
      chmod 600 "${path.module}/envs/state/remote-access-token-app-services.txt"
      echo "remote-access token minted for app_services."
    EOT
  }
}

# --- backing_services ----------------------------------------------------
# Postgres/RabbitMQ/Redis's own failure domain, separate from app_services --
# confirmed with the user this is a deliberate reversal of the earlier
# "keep them in app_services, simplest option" call (see the plan file):
# app_services reaches them the same way it already reaches otel-collector
# cross-cluster -- a NodePort here, a stub Service+Endpoints with the exact
# same in-cluster DNS name on the app_services side (see
# backing_services_cross_cluster_stub below) -- so nest-service's chart
# (postgresHost: postgres / rabbitmqHost: rabbitmq, both bare short names)
# needs zero changes across any of the 20+ environment values files.
# KEDA stays in app_services regardless (see keda_install's own comment --
# no cross-cluster HPA in Kubernetes), so this split doesn't touch it.

module "network_backing_services" {
  source     = "./modules/network"
  depends_on = [module.floci]

  cluster_name       = local.backing_services_name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = var.tags
}

module "eks_backing_services" {
  source     = "./modules/eks"
  depends_on = [module.network_backing_services]

  cluster_name        = local.backing_services_name
  k8s_version         = var.k8s_version
  private_subnet_ids  = module.network_backing_services.private_subnet_ids
  public_subnet_ids   = module.network_backing_services.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  enable_irsa_addons  = var.enable_irsa_addons
  tags                = var.tags
}

module "addons_backing_services" {
  source     = "./modules/addons"
  depends_on = [module.eks_backing_services]

  enable_irsa_addons = var.enable_irsa_addons
  cluster_name       = local.backing_services_name
  oidc_provider_arn  = module.eks_backing_services.oidc_provider_arn
  oidc_provider_url  = module.eks_backing_services.oidc_provider_url
  tags               = var.tags
}

# No module.loadbalancer for this cluster -- Postgres/RabbitMQ/Redis are
# infra, not user-facing, nothing here needs a public URL.

resource "terraform_data" "ensure_restart_policies_backing_services" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [module.eks_backing_services, terraform_data.ensure_static_network]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CONTAINER="floci-eks-${module.eks_backing_services.cluster_name}"
      DESIRED_IP="${local.static_ips.backing_services}"
      docker update --restart=unless-stopped "$CONTAINER" >/dev/null

      # Checks the ACTUAL assigned IP, not just network membership.
      # Confirmed live: backing_services is the first cluster ever created
      # AFTER floci-static already existed -- Floci's own container-creation
      # step auto-joins new floci-eks-* containers to every existing custom
      # Docker network before this script ever runs, so a plain
      # membership check (`grep -q floci-static`, what every other
      # ensure_restart_policies_* still uses) sees "already connected" and
      # skips the explicit --ip request, leaving Docker's own auto-assigned
      # address in place instead. jenkins/argocd/observability/app_services
      # never hit this because they were all created before floci-static
      # existed, so this script's own --ip request was their first-ever
      # connection to it.
      CURRENT_IP=$(docker inspect "$CONTAINER" --format '{{(index .NetworkSettings.Networks "floci-static").IPAddress}}' 2>/dev/null || true)
      NEEDED_FIX=false
      if [ "$CURRENT_IP" != "$DESIRED_IP" ]; then
        NEEDED_FIX=true
        docker network disconnect floci-static "$CONTAINER" 2>/dev/null || true
        docker network connect --ip "$DESIRED_IP" floci-static "$CONTAINER"
      fi

      # See ensure_restart_policies_app_services' own comment on this same
      # block for the full k3s node-ip story.
      DESIRED_K3S_CONFIG="node-ip: $DESIRED_IP
node-external-ip: $DESIRED_IP
disable-network-policy: true
"
      CURRENT_K3S_CONFIG=$(docker cp "$CONTAINER:/etc/rancher/k3s/config.yaml" - 2>/dev/null | tar -xO 2>/dev/null || true)
      if [ "$CURRENT_K3S_CONFIG" != "$(printf '%s' "$DESIRED_K3S_CONFIG")" ]; then
        NEEDED_FIX=true
        TMP_K3S_CONFIG=$(mktemp)
        printf '%s' "$DESIRED_K3S_CONFIG" > "$TMP_K3S_CONFIG"
        docker cp "$TMP_K3S_CONFIG" "$CONTAINER:/etc/rancher/k3s/config.yaml"
        rm -f "$TMP_K3S_CONFIG"
      fi

      # If either the network or config.yaml needed correcting, the
      # container may have ALREADY booted once with the wrong IP/config
      # (module.eks starts it immediately at creation, before this step
      # ever runs) -- confirmed live, a plain restart alone does NOT fix
      # this: k3s persists its own first-ever self-registered node identity
      # and keeps it forever after, silently ignoring a corrected
      # config.yaml on subsequent boots (no crash, just wrong, since
      # disable-network-policy already removed the one check that would
      # have caught it). Wiping /var/lib/rancher/k3s and rebooting is safe
      # specifically for backing_services when triggered right after a
      # fresh install like this: nothing has been written to
      # Postgres/RabbitMQ yet at this point in the dependency chain (this
      # resource runs before postgres_install/rabbitmq_install/redis_install
      # further down), so there is no real data to lose -- same "nothing
      # here is a source of truth yet" reasoning kubeconfig.sh's own
      # wipe-loop already relies on for observability/argocd.
      if [ "$NEEDED_FIX" = "true" ]; then
        ALREADY_BOOTED=$(docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && echo true || echo false)
        if [ "$ALREADY_BOOTED" = "true" ]; then
          echo "container already booted once before this fix landed -- wiping its k3s datastore for a clean re-init on the corrected network..."
          docker stop "$CONTAINER" >/dev/null
          docker run --rm --entrypoint sh -v "$CONTAINER:/data" rancher/k3s:latest -c 'rm -rf /data/*' >/dev/null
          docker start "$CONTAINER" >/dev/null
        else
          docker restart "$CONTAINER" >/dev/null
        fi
        echo "waiting for k3s to come back up..."
        for i in $(seq 1 60); do
          docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
          sleep 2
        done
      fi
    EOT
  }
}

resource "terraform_data" "k8s_reconcile_backing_services" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.ensure_restart_policies_backing_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      echo "cleaning up stale Terminating/Unknown pods..."
      kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating" || $4=="Unknown"{print $2, $1}' | \
        while read -r ns name; do
          kubectl delete pod "$name" -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
        done

      echo "removing NotReady nodes..."
      for node in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
        status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$status" != "True" ]; then
          kubectl delete node "$node" >/dev/null 2>&1 || true
        fi
      done

      echo "k8s reconcile complete."
    EOT
  }
}

resource "terraform_data" "backing_services_secrets" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.k8s_reconcile_backing_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_backing_services.cluster_name}" "${module.eks_backing_services.cluster_endpoint}"

      kubectl create namespace backing-services --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      # Named "app-secrets", not "backing-services-secrets" -- postgres.yaml.tftpl
      # and rabbitmq.yaml.tftpl both hardcode secretKeyRef.name: app-secrets
      # (carried over unchanged from when these lived directly in
      # app_services' own ai-notification namespace). Confirmed live: this
      # was live-patched once already after postgres_install's rollout
      # picked up the wrong name and stuck on a missing-secret ContainerCreating.
      kubectl create secret generic app-secrets -n backing-services \
        --from-literal=POSTGRES_PASSWORD='${var.postgres_password}' \
        --from-literal=RABBITMQ_PASSWORD='${var.rabbitmq_password}' \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      echo "app-secrets applied in backing-services namespace."
    EOT
  }
}

# --- jenkins ---------------------------------------------------------------
# Plain Docker container, not its own EKS-emulated cluster, and reached
# directly on its own host port -- no ALB in front of it either. Running a
# full k3s control plane just to host one Jenkins pod was pure CPU overhead
# this project never needed for what Jenkins actually does here (a single
# CI controller, not something that itself needs to scale) -- confirmed the
# hard way this session (see scripts/cpu-priority.sh's own history: 5
# separate k3s nodes' control-plane overhead alone was enough to crash
# Docker Desktop under sustained load). `kubernetes` plugin dropped from the
# old plugin list -- builds run directly on this container now, not as
# dynamic k8s agents on some other cluster.

resource "random_password" "jenkins_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "jenkins_admin_password" {
  content         = random_password.jenkins_admin.result
  filename        = "${path.root}/envs/state/jenkins-admin-password.txt"
  file_permission = "0600"
}

resource "local_sensitive_file" "jenkins_init_security" {
  content = templatefile("${path.module}/templates/jenkins/init-security.groovy.tftpl", {
    admin_password       = random_password.jenkins_admin.result
    github_push_username = var.github_push_username
    github_push_token    = var.github_push_token
  })
  filename        = "${path.root}/envs/state/jenkins-init-security.groovy"
  file_permission = "0600"
}

resource "local_file" "jenkins_seed_jobs" {
  content = templatefile("${path.module}/templates/jenkins/seed-jobs.groovy.tftpl", {
    git_repo_url         = "https://github.com/dip7501686040/platform-gitops.git"
    git_branch            = "main"
    services_groovy_list = join(", ", [for s in var.ecr_repository_names : "\"${s}\""])
  })
  filename = "${path.root}/envs/state/jenkins-seed-jobs.groovy"
}

# Versions pinned for the same reason platform-gitops' old Helm values did
# -- an unpinned "latest" resolve reliably wedges the plugin installer on
# this connection.
resource "local_file" "jenkins_plugins_txt" {
  content  = <<-EOT
    git:5.10.1
    workflow-aggregator:608.v67378e9d3db_1
    credentials-binding:728.v902a_273b_8947
    credentials:1511.v2e3cb_0008ef0
    configuration-as-code:2117.vc05a_0b_e6b_f4e
  EOT
  filename = "${path.root}/envs/state/jenkins-plugins.txt"
}

resource "docker_image" "jenkins" {
  name         = "jenkins/jenkins:lts"
  keep_locally = true
}

resource "docker_volume" "jenkins_home" {
  name = "floci-jenkins-home"
}

resource "docker_container" "jenkins" {
  count = var.manage_floci ? 1 : 0
  name  = "floci-jenkins"
  image = docker_image.jenkins.image_id

  # runSetupWizard=false -- init-security.groovy below seeds the admin
  # account immediately instead, same as the old Helm values' jenkinsOpts.
  #
  # CONFIG_HASH: unused by Jenkins itself -- its only purpose is forcing
  # Terraform to recreate this container whenever any of the 3 mounted
  # init.groovy.d/plugins.txt files change. Init scripts and plugins.txt
  # are read ONCE at JVM boot, there's no live-reload concept for them the
  # way Prometheus has /-/reload -- a recreate is the only way a content
  # change ever takes effect. Safe specifically because build history/jobs/
  # credentials live on the separate `floci-jenkins-home` named volume
  # below, untouched by a container recreate.
  env = [
    "JAVA_OPTS=-Djenkins.install.runSetupWizard=false",
    "CONFIG_HASH=${sha256("${local_sensitive_file.jenkins_init_security.content}${local_file.jenkins_seed_jobs.content}${local_file.jenkins_plugins_txt.content}")}",
  ]

  ports {
    internal = 8080
    # 9091, not 8091 -- floci's own extra_ports map still forwards 8091 to
    # wherever floci-eks-floci-jenkins USED to be (that EKS cluster is
    # being torn down, per the same apply that creates this container), and
    # this repo's explicit instruction this round was "don't touch floci"
    # -- so its now-stale 8091 forward is left alone rather than edited,
    # and this container claims a different host port instead of fighting
    # it for the same one.
    external = 9091
  }

  # ECR registry reachability (image pushes from CI builds) -- same
  # floci-static network floci-ecr-registry itself is already on.
  networks_advanced {
    name = "floci-static"
  }

  volumes {
    volume_name    = docker_volume.jenkins_home.name
    container_path = "/var/jenkins_home"
  }
  volumes {
    host_path      = abspath(local_sensitive_file.jenkins_init_security.filename)
    container_path = "/usr/share/jenkins/ref/init.groovy.d/init-security.groovy"
    read_only      = true
  }
  volumes {
    host_path      = abspath(local_file.jenkins_seed_jobs.filename)
    container_path = "/usr/share/jenkins/ref/init.groovy.d/seed-jobs.groovy"
    read_only      = true
  }
  volumes {
    host_path      = abspath(local_file.jenkins_plugins_txt.filename)
    container_path = "/usr/share/jenkins/ref/plugins.txt"
    read_only      = true
  }

  restart  = "unless-stopped"
  must_run = true
}

# --- argocd ------------------------------------------------------------------
# Plain Docker containers (redis, repo-server, application-controller,
# applicationset-controller, server) instead of ArgoCD's own EKS-emulated
# cluster -- same reasoning as jenkins above. ArgoCD's own control-plane
# data (Applications, AppProjects, cluster-registration Secrets) still needs
# SOME Kubernetes API to live in though -- unlike Jenkins, ArgoCD's data
# model is fundamentally k8s-native, it can't just write to a local file.
# app_services is that home now: these containers run OUTSIDE any cluster
# (their own KUBECONFIG points at app_services remotely), the same pattern
# ArgoCD's own upstream dev-mode tooling uses to run its components as
# plain processes against a target cluster instead of in-cluster. This
# collapses "the cluster ArgoCD manages" and "the cluster ArgoCD's own
# storage lives on" into the same one (app_services) -- which is fine,
# app_services was always the only cluster it actually needed to manage.

resource "docker_image" "argocd" {
  name         = "quay.io/argoproj/argocd:v3.5.1"
  keep_locally = true
}

resource "docker_image" "argocd_redis" {
  name         = "redis:7-alpine"
  keep_locally = true
}

# Rewrites app_services' own kubeconfig to address it by its floci-static
# IP on its native port (6443), not the host-mapped localhost:6500 the
# normal kubeconfig uses -- these containers run on floci-static, not the
# host network, so "localhost" inside them means themselves, not this Mac.
resource "terraform_data" "argocd_target_kubeconfig" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.k8s_reconcile_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"
      sed "s|server: https://localhost:[0-9]*|server: https://${local.static_ips.app_services}:6443|" \
        "$KUBECONFIG" > "${path.root}/envs/state/kubeconfig-argocd-target.yaml"

      # Without this, argocd-server/application-controller/
      # applicationset-controller all default to the "default" namespace
      # (the kubeconfig's own context carries no explicit namespace) --
      # confirmed live, argocd-server logs "configmap \"argocd-cm\" not
      # found" with namespace="default" even though argocd-cm exists fine
      # in the argocd namespace. `argocd-server` also honors
      # ARGOCD_NAMESPACE (set on each container below) for the same
      # reason, belt-and-suspenders.
      export KUBECONFIG="${path.root}/envs/state/kubeconfig-argocd-target.yaml"
      kubectl config set-context --current --namespace=argocd
    EOT
  }
}

resource "random_password" "argocd_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "argocd_admin_password" {
  content         = random_password.argocd_admin.result
  filename        = "${path.root}/envs/state/argocd-admin-password.txt"
  file_permission = "0600"
}

resource "random_password" "argocd_server_secretkey" {
  length  = 32
  special = false
}

# Minimal versions of the ConfigMaps/Secret the Helm chart used to create
# automatically as part of the argocd release. argocd-server hard-fails
# without them -- confirmed live, twice: first "configmap \"argocd-cm\" not
# found", then (once that was seeded) "secret \"argocd-secret\" not found"
# -- unlike a plain k8s Secret's own signing/TLS material, argocd-server
# does NOT auto-generate this one itself if missing, that auto-generation
# only happens as part of the Helm chart's own install hook, which nothing
# here runs anymore. `htpasswd` (already present on this Mac, part of the
# base OS) does the same bcrypt hashing the ArgoCD docs' own manual-install
# instructions use.
resource "terraform_data" "argocd_bootstrap_configmaps" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [terraform_data.argocd_target_kubeconfig]

  triggers_replace = {
    always_run     = timestamp()
    admin_password = random_password.argocd_admin.result
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      kubectl get configmap argocd-cm -n argocd >/dev/null 2>&1 || kubectl create configmap argocd-cm -n argocd \
        --from-literal=_placeholder=true
      kubectl label configmap argocd-cm -n argocd app.kubernetes.io/part-of=argocd --overwrite >/dev/null

      kubectl get configmap argocd-rbac-cm -n argocd >/dev/null 2>&1 || kubectl create configmap argocd-rbac-cm -n argocd \
        --from-literal=_placeholder=true
      kubectl label configmap argocd-rbac-cm -n argocd app.kubernetes.io/part-of=argocd --overwrite >/dev/null

      BCRYPT_HASH=$(htpasswd -nbBC 10 "" "${random_password.argocd_admin.result}" | tr -d ':\n' | sed 's/$2y/$2a/')
      kubectl create secret generic argocd-secret -n argocd \
        --from-literal=server.secretkey="${random_password.argocd_server_secretkey.result}" \
        --from-literal=admin.password="$BCRYPT_HASH" \
        --from-literal=admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl label secret argocd-secret -n argocd app.kubernetes.io/part-of=argocd --overwrite >/dev/null
    EOT
  }
}

resource "docker_container" "argocd_redis" {
  count = var.manage_floci ? 1 : 0
  name  = "floci-argocd-redis"
  image = docker_image.argocd_redis.image_id

  networks_advanced {
    name = "floci-static"
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "docker_container" "argocd_repo_server" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_redis]
  name       = "floci-argocd-repo-server"
  image      = docker_image.argocd.image_id
  command    = ["argocd-repo-server", "--redis", "floci-argocd-redis:6379"]

  networks_advanced {
    name = "floci-static"
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "docker_container" "argocd_application_controller" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_repo_server, terraform_data.argocd_target_kubeconfig, terraform_data.argocd_bootstrap_configmaps]
  name       = "floci-argocd-application-controller"
  image      = docker_image.argocd.image_id
  command = [
    "argocd-application-controller",
    "--redis", "floci-argocd-redis:6379",
    "--repo-server", "floci-argocd-repo-server:8081",
    "--app-resync", "60",
  ]
  env = ["KUBECONFIG=/tmp/kubeconfig", "ARGOCD_NAMESPACE=argocd"]

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    host_path      = abspath("${path.root}/envs/state/kubeconfig-argocd-target.yaml")
    container_path = "/tmp/kubeconfig"
    read_only      = true
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "docker_container" "argocd_applicationset_controller" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_repo_server, terraform_data.argocd_target_kubeconfig, terraform_data.argocd_bootstrap_configmaps]
  name       = "floci-argocd-applicationset-controller"
  image      = docker_image.argocd.image_id
  command = [
    "argocd-applicationset-controller",
    "--argocd-repo-server", "floci-argocd-repo-server:8081",
    "--enable-progressive-syncs",
  ]
  env = ["KUBECONFIG=/tmp/kubeconfig", "ARGOCD_NAMESPACE=argocd"]

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    host_path      = abspath("${path.root}/envs/state/kubeconfig-argocd-target.yaml")
    container_path = "/tmp/kubeconfig"
    read_only      = true
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "docker_container" "argocd_server" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_repo_server, docker_container.argocd_application_controller, terraform_data.argocd_target_kubeconfig, terraform_data.argocd_bootstrap_configmaps]
  name       = "floci-argocd-server"
  image      = docker_image.argocd.image_id
  # --insecure: plain HTTP on 8080 -- no real trust boundary to give up on a
  # purely local dev setup, and it's what makes a raw host-port publish
  # (below) usable straight from a browser without a self-signed-cert
  # warning.
  command = [
    "argocd-server",
    "--insecure",
    "--redis", "floci-argocd-redis:6379",
    "--repo-server", "floci-argocd-repo-server:8081",
  ]
  env = ["KUBECONFIG=/tmp/kubeconfig", "ARGOCD_NAMESPACE=argocd"]

  ports {
    internal = 8080
    external = 9092
  }

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    host_path      = abspath("${path.root}/envs/state/kubeconfig-argocd-target.yaml")
    container_path = "/tmp/kubeconfig"
    read_only      = true
  }

  restart  = "unless-stopped"
  must_run = true
}

# Registers app_services with ArgoCD's own storage (now living in the
# `argocd` namespace on app_services itself) as the managed cluster named
# "app-services" -- matches what platform-gitops' Application/
# ApplicationSet manifests already address via destination.name.
resource "terraform_data" "argocd_register_app_services" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_server, terraform_data.remote_access_token]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      APP_SERVICES_IP="${local.static_ips.app_services}"
      TOKEN=$(cat "${path.module}/envs/state/remote-access-token-app-services.txt")

      kubectl apply -f - <<SECEOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-app-services
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: app-services
  server: https://$APP_SERVICES_IP:6443
  config: |
    {"bearerToken": "$TOKEN", "tlsClientConfig": {"insecure": true}}
SECEOF

      echo "app_services registered with ArgoCD as cluster 'app-services'."
    EOT
  }
}

resource "terraform_data" "argocd_manifests" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.argocd_server]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      # The Helm chart used to install these automatically as part of the
      # argocd release -- now that argocd runs as plain containers (not
      # installed via Helm onto any cluster), nothing has ever put the
      # Application/ApplicationSet/AppProject CRDs onto app_services, so
      # kubectl apply on the manifests below would fail with "no matches
      # for kind Application" without this. Pinned to the same tag as
      # docker_image.argocd so the CRD schema always matches what the
      # running controllers actually understand.
      # Plain curl+apply, not `kubectl apply -k <git URL>` -- confirmed
      # live, kustomize's remote-URL fetch shells out to `git fetch` under
      # the hood and that reliably hit its own 27s timeout on this
      # connection. A raw file GET per CRD has no such indirection. Checks
      # ALL THREE CRDs, not just one -- confirmed live, a partial success
      # (application + appproject created, applicationset failed) would
      # otherwise skip re-attempting the missing one on every future apply
      # forever, since the whole block was gated on a single CRD's
      # presence.
      if ! kubectl get crd applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io >/dev/null 2>&1; then
        for crd in application appproject; do
          curl -sL --max-time 15 \
            "https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/crds/$${crd}-crd.yaml" \
            | kubectl apply -f -
        done

        # ApplicationSet's full upstream CRD is ~1.4MB (its generator union
        # type schema is enormous) -- confirmed live, every attempt to
        # write that object hit the k3s apiserver's own fixed internal
        # request-handler timeout ("http: Handler timeout"), independent of
        # kubectl's --request-timeout (client-side only) and independent of
        # host load at the time (retried across a quiet moment too, same
        # failure). application's CRD (405KB) writes fine, so this isn't a
        # blanket k3s/kine CRD-size limit, just this one object crossing
        # whatever internal threshold trips it. A permissive schema
        # (x-kubernetes-preserve-unknown-fields, ~600 bytes total) keeps
        # the CRD itself fully functional -- same kind/plural/scope/
        # shortNames/status-subresource as upstream -- just without
        # per-field validation, an acceptable tradeoff for a local dev/
        # load-test cluster over ApplicationSets not working at all.
        kubectl apply -f - <<'APPSETCRD'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  labels:
    app.kubernetes.io/name: applicationsets.argoproj.io
    app.kubernetes.io/part-of: argocd
  name: applicationsets.argoproj.io
spec:
  group: argoproj.io
  names:
    kind: ApplicationSet
    listKind: ApplicationSetList
    plural: applicationsets
    shortNames:
    - appset
    - appsets
    singular: applicationset
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    subresources:
      status: {}
APPSETCRD
      fi

      # The "default" AppProject -- every Application implicitly belongs to
      # it unless it names a different one, and (also normally a Helm
      # install-hook's job) nothing creates it otherwise now. Confirmed
      # live: every one of nest-services-local's 11 generated Applications
      # failed validation with "references project default which does not
      # exist" without this. Applied here, after the CRD-install block
      # above, not in argocd_bootstrap_configmaps -- the AppProject CRD
      # itself doesn't exist yet that early.
      kubectl get appproject default -n argocd >/dev/null 2>&1 || kubectl apply -f - <<'PROJEOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: Default, permissive project (single-project local setup)
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
PROJEOF

      kubectl apply -f "${var.platform_gitops_path}/k8s/argocd/applications/"
      kubectl apply -f "${var.platform_gitops_path}/k8s/argocd/applicationsets/"
    EOT
  }
}

# --- observability -----------------------------------------------------
# Plain Docker containers (Jaeger, otel-collector, Prometheus, Grafana),
# same reasoning as jenkins/argocd above -- none of these four need their
# own Kubernetes control plane to run; they only ever needed NETWORK
# reachability to app_services (to scrape it / receive its OTLP pushes),
# which floci-static already provides directly. kube-state-metrics dropped
# from this lighter setup -- app-level metrics/traces arrive via the
# OTLP-push -> otel-collector -> Prometheus-exporter path below, which is
# what the load test actually needs to watch (request rates/latencies per
# service), not cluster-object-count metrics.

resource "docker_image" "jaeger" {
  name         = "jaegertracing/all-in-one:1.60"
  keep_locally = true
}

# All-in-one's default storage backend is pure in-memory -- confirmed live,
# every captured trace was gone after any restart. badger persists to disk
# instead (single-node embedded k/v store, no separate Cassandra/
# Elasticsearch needed, matching this project's existing "single-instance,
# no extra backing service" observability choices).
resource "docker_volume" "jaeger_data" {
  name = "floci-jaeger-data"
}

resource "docker_container" "jaeger" {
  count = var.manage_floci ? 1 : 0
  name  = "floci-jaeger"
  image = docker_image.jaeger.image_id
  # Confirmed live: the image's default non-root user can't mkdir inside
  # a freshly-created named volume (root-owned by default) --
  # "Error Creating Dir: /badger/key: permission denied", crash-looped
  # instantly. Root avoids that entirely -- same pragmatic no-real-trust-
  # boundary stance already used elsewhere in this repo (ArgoCD
  # --insecure, ECR plain HTTP), not a new exception.
  user = "0:0"
  env = [
    "COLLECTOR_OTLP_ENABLED=true",
    "SPAN_STORAGE_TYPE=badger",
    "BADGER_EPHEMERAL=false",
    "BADGER_DIRECTORY_VALUE=/badger/data",
    "BADGER_DIRECTORY_KEY=/badger/key",
  ]

  ports {
    internal = 16686
    external = 9095
  }

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    volume_name    = docker_volume.jaeger_data.name
    container_path = "/badger"
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "local_file" "otel_collector_config" {
  content  = <<-EOT
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
    exporters:
      otlp/jaeger:
        endpoint: floci-jaeger:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/jaeger]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [prometheus]
  EOT
  filename = "${path.root}/envs/state/otel-collector-config.yaml"
}

resource "docker_image" "otel_collector" {
  name         = "otel/opentelemetry-collector-contrib:latest"
  keep_locally = true
}

resource "docker_container" "otel_collector" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.jaeger]
  name       = "floci-otel-collector"
  image      = docker_image.otel_collector.image_id
  command    = ["--config=/etc/otel-collector-config.yaml"]
  # otel-collector has no config hot-reload -- unused by the app itself,
  # forces a recreate (which re-mounts the already-updated file) whenever
  # the rendered config changes. Safe: this container is a pure pipeline,
  # nothing it stores itself (Jaeger/Prometheus, both persistent now, are
  # what actually hold the data flowing through it).
  env = ["CONFIG_HASH=${local_file.otel_collector_config.content_sha256}"]

  # Fixed IP: this is the one observability container app_services' pods
  # actually need to reach directly (via the stub Service below) -- Jaeger/
  # Prometheus/Grafana are only ever reached by a browser (host port) or by
  # each other (floci-static's own container-name DNS), so they don't need
  # a pinned address.
  networks_advanced {
    name         = "floci-static"
    ipv4_address = local.static_ips.observability
  }

  volumes {
    host_path      = abspath(local_file.otel_collector_config.filename)
    container_path = "/etc/otel-collector-config.yaml"
    read_only      = true
  }

  restart  = "unless-stopped"
  must_run = true
}

resource "local_file" "prometheus_config" {
  content  = <<-EOT
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'otel-collector'
        static_configs:
          - targets: ['floci-otel-collector:8889']
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
      - job_name: 'rabbitmq'
        static_configs:
          - targets: ['${local.static_ips.backing_services}:${local.rabbitmq_prometheus_node_port}']
      - job_name: 'api-gateway'
        static_configs:
          - targets: ['${local.static_ips.app_services}:${local.api_gateway_metrics_node_port}']
  EOT
  filename = "${path.root}/envs/state/prometheus-config.yaml"
}

resource "docker_image" "prometheus" {
  name         = "prom/prometheus:latest"
  keep_locally = true
}

# TSDB persistence -- confirmed live, with no volume every collected
# metric (exactly what a load test needs to review afterward) was gone on
# any restart, same gap Jaeger/Grafana had.
resource "docker_volume" "prometheus_data" {
  name = "floci-prometheus-data"
}

resource "docker_container" "prometheus" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.otel_collector]
  name       = "floci-prometheus"
  image      = docker_image.prometheus.image_id
  # --web.enable-lifecycle exposes POST /-/reload -- unlike
  # otel-collector/grafana/jenkins, Prometheus DOES support live config
  # reload, so this uses that instead of a recreate-on-hash-change trigger
  # (see terraform_data.prometheus_reload below): no restart, no gap in
  # in-progress scraping, TSDB stays warm. Default CMD's other two flags
  # preserved (--config.file, --storage.tsdb.path).
  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--web.enable-lifecycle",
  ]

  ports {
    internal = 9090
    external = 9094
  }

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    host_path      = abspath(local_file.prometheus_config.filename)
    container_path = "/etc/prometheus/prometheus.yml"
    read_only      = true
  }
  volumes {
    volume_name    = docker_volume.prometheus_data.name
    container_path = "/prometheus"
  }

  restart  = "unless-stopped"
  must_run = true
}

# Bind-mounted config files update instantly on the host side, but
# Prometheus doesn't hot-watch its own config file -- confirmed live, a
# local_file.prometheus_config change landed on disk correctly but
# Prometheus kept serving its stale in-memory config until manually
# restarted. This reload call is what actually applies it, triggered only
# when the rendered config's content changes (not on every apply, unlike
# most of this file's terraform_data resources).
resource "terraform_data" "prometheus_reload" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.prometheus]

  triggers_replace = {
    config_hash = local_file.prometheus_config.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      for i in $(seq 1 10); do
        curl -sf -X POST http://localhost:9094/-/reload && exit 0
        sleep 2
      done
      echo "prometheus reload endpoint never became reachable" >&2
      exit 1
    EOT
  }
}

resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

resource "local_sensitive_file" "grafana_admin_password" {
  content         = random_password.grafana_admin.result
  filename        = "${path.root}/envs/state/grafana-admin-password.txt"
  file_permission = "0600"
}

resource "local_file" "grafana_datasource" {
  content  = <<-EOT
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://floci-prometheus:9090
        isDefault: true
  EOT
  filename = "${path.root}/envs/state/grafana-datasource.yaml"
}

resource "docker_image" "grafana" {
  name         = "grafana/grafana:latest"
  keep_locally = true
}

# Grafana's own SQLite state (dashboards created in the UI, users, alert
# rules) -- confirmed live, with no volume that was gone on every restart.
# Datasource provisioning itself is unaffected either way (re-applied from
# the mounted file below on every boot regardless).
resource "docker_volume" "grafana_data" {
  name = "floci-grafana-data"
}

resource "docker_container" "grafana" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.prometheus]
  name       = "floci-grafana"
  image      = docker_image.grafana.image_id
  # CONFIG_HASH: Grafana only reads datasource provisioning files at boot
  # (no live-reload for datasources specifically, unlike its dashboard
  # provisioner's optional polling) -- unused by the app, forces a
  # recreate when the mounted file's content changes. Safe: dashboards/
  # users/alert rules now live on the separate grafana_data volume above.
  env = [
    "GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}",
    "CONFIG_HASH=${local_file.grafana_datasource.content_sha256}",
  ]

  ports {
    internal = 3000
    external = 9093
  }

  networks_advanced {
    name = "floci-static"
  }

  volumes {
    host_path      = abspath(local_file.grafana_datasource.filename)
    container_path = "/etc/grafana/provisioning/datasources/datasource.yaml"
    read_only      = true
  }
  volumes {
    volume_name    = docker_volume.grafana_data.name
    container_path = "/var/lib/grafana"
  }

  restart  = "unless-stopped"
  must_run = true
}

# Lets app_services' pods reach otel-collector at the exact in-cluster DNS
# name the nest-service chart already expects
# (otel-collector-opentelemetry-collector.observability.svc.cluster.local)
# without any chart/values changes -- a headless-style Service + manually-
# managed Endpoints pointing at the plain container's floci-static IP
# directly on its native port (4317, no NodePort indirection needed now
# that there's no k3s node in between).
resource "terraform_data" "otel_cross_cluster_stub" {
  count      = var.manage_floci ? 1 : 0
  depends_on = [docker_container.otel_collector, terraform_data.k8s_reconcile_app_services]

  triggers_replace = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      OBSERVABILITY_IP="${local.static_ips.observability}"

      source "${path.module}/scripts/kubeconfig.sh" "${module.eks_app_services.cluster_name}" "${module.eks_app_services.cluster_endpoint}"

      kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      kubectl apply -f - <<STUBEOF
apiVersion: v1
kind: Service
metadata:
  name: otel-collector-opentelemetry-collector
  namespace: observability
spec:
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
---
apiVersion: v1
kind: Endpoints
metadata:
  name: otel-collector-opentelemetry-collector
  namespace: observability
subsets:
  - addresses:
      - ip: $OBSERVABILITY_IP
    ports:
      - name: otlp-grpc
        port: 4317
STUBEOF

      echo "otel-collector reachable from app_services via $OBSERVABILITY_IP:4317."
    EOT
  }
}
