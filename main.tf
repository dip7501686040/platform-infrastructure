# Started/pulled before anything else touches the aws provider — see
# module.floci's own depends_on chain (docker_container -> wait_for_floci).
# count-based (not a plain resource block) so real-AWS applies (manage_floci
# = false) never require the docker provider to be reachable at all.
module "floci" {
  count  = var.manage_floci ? 1 : 0
  source = "./modules/floci"

  # The ALB's listener ports (modules/loadbalancer) live inside this
  # container's own network namespace -- host-published here so
  # web/api-gateway are actually browser-reachable, the same way a real
  # ALB's DNS name is reachable in prod. Referencing var.lb_services rather
  # than hardcoding 80/8000 a second time keeps one source of truth for
  # which internal ports need publishing.
  extra_ports = {
    "${var.lb_services["web"].listener_port}"         = var.alb_web_local_port
    "${var.lb_services["api-gateway"].listener_port}" = var.alb_api_gateway_local_port
  }
}

module "network" {
  source     = "./modules/network"
  depends_on = [module.floci]

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = var.tags
}

module "ecr" {
  source     = "./modules/ecr"
  depends_on = [module.floci]

  repository_names = var.ecr_repository_names
  tags             = var.tags
}

module "eks" {
  source     = "./modules/eks"
  depends_on = [module.floci]

  cluster_name        = var.cluster_name
  k8s_version         = var.k8s_version
  private_subnet_ids  = module.network.private_subnet_ids
  public_subnet_ids   = module.network.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  enable_irsa_addons  = var.enable_irsa_addons
  tags                = var.tags
}

module "addons" {
  source     = "./modules/addons"
  depends_on = [module.floci]

  enable_irsa_addons = var.enable_irsa_addons
  cluster_name       = var.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  tags               = var.tags
}

# Fronts web + api-gateway with a real ALB via Floci's ELBv2 emulation
# locally and a real AWS ALB in prod -- same module, same resource blocks;
# only target registration differs (see modules/loadbalancer's own
# comments). depends_on module.eks directly (not just module.floci): needs
# the node group + cluster security group to exist first.
module "loadbalancer" {
  source     = "./modules/loadbalancer"
  depends_on = [module.floci, module.eks]

  manage_floci              = var.manage_floci
  name_prefix               = var.cluster_name
  vpc_id                    = module.network.vpc_id
  public_subnet_ids         = module.network.public_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_group_asg_name       = module.eks.node_group_asg_name
  floci_eks_container_name  = "floci-eks-${var.cluster_name}"
  services                  = var.lb_services
  tags                      = var.tags
}

# Makes the previously-manual "docker update --restart=unless-stopped on
# floci-eks-*" fix permanent instead of something that silently lapses
# whenever the container gets replaced. Floci already sets this on
# floci-ecr-registry itself; only the EKS emulation container it creates
# internally needs catching up. With this plus FLOCI_STORAGE_MODE=persistent
# (modules/floci), every floci-* container auto-restarts together when
# Docker Desktop (re)starts, and Floci actually remembers what it had
# created -- no manual `docker start` step after a reboot.
resource "terraform_data" "ensure_restart_policies" {
  count = var.manage_floci ? 1 : 0

  depends_on = [module.eks]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      docker update --restart=unless-stopped "floci-eks-${module.eks.cluster_name}" >/dev/null
    EOT
  }
}

# Floci-only: containerd (inside the k3s node) defaults to HTTPS for any
# registry host it has no explicit config for, but floci-ecr-registry is
# plain unauthenticated HTTP -- confirmed live, every image pull failed
# with "server gave HTTP response to HTTPS client" against the registry's
# own bridge-internal IP (the same address kaniko pushes to from inside a
# pod -- see jenkins/env/local.properties in platform-gitops for why pods
# and the node resolve this registry differently). Floci's own
# registries.yaml ships mirrors for a stable `localhost:5100`-style alias,
# but that alias only resolves at all via Docker's embedded DNS, which
# doesn't exist on the plain default "bridge" network these containers
# sit on -- confirmed live too, `no such host`. The fix that actually
# works: a self-referencing mirror keyed on the registry's *current*
# bridge IP, forcing plain HTTP for exactly the address pulls already use.
# k3s only reads registries.yaml at startup, not on a hot reload, so
# patching it only has an effect together with a restart -- done here,
# but ONLY when the current IP isn't already covered, so a routine apply
# where nothing drifted doesn't pay for a restart it doesn't need.
resource "terraform_data" "ensure_registry_pull_mirror" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.ensure_restart_policies]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CONTAINER="floci-eks-${module.eks.cluster_name}"
      REGISTRY_IP=$(docker inspect floci-ecr-registry --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' 2>/dev/null || true)
      if [ -z "$REGISTRY_IP" ]; then
        echo "floci-ecr-registry not found yet -- skipping (nothing to mirror)."
        exit 0
      fi

      if docker exec "$CONTAINER" grep -q "\"$REGISTRY_IP:5000\":" /etc/rancher/k3s/registries.yaml 2>/dev/null; then
        echo "registries.yaml already has a working mirror for $REGISTRY_IP:5000 -- nothing to do."
        exit 0
      fi

      echo "registries.yaml is missing a mirror for the current registry IP ($REGISTRY_IP) -- patching and restarting k3s to pick it up..."
      docker exec "$CONTAINER" sh -c "sed -i '1a\\
  \"$REGISTRY_IP:5000\":\\
    endpoint:\\
      - \"http://$REGISTRY_IP:5000\"' /etc/rancher/k3s/registries.yaml"
      docker restart "$CONTAINER" >/dev/null

      echo "waiting for k3s to come back up..."
      for i in $(seq 1 60); do
        docker exec "$CONTAINER" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
        sleep 2
      done
    EOT
  }
}

# Floci-only: k3s (inside the floci-eks-<cluster> container) registers a
# brand-new Node identity essentially every time its process restarts, not
# just when the container itself is recreated. The old Node never gets a
# clean kubelet handoff, so its pods get stuck "Terminating" (or, confirmed
# live, sometimes "Unknown" instead -- same underlying stale-kubelet-handoff
# cause, just a different status string depending on exactly where the
# handoff broke) forever, and any PVC bound to that old Node (local-path's
# PVs are hard node-affinity pinned) becomes permanently unmountable. This
# doesn't fix *why* k3s does that — it self-heals the fallout on every apply
# instead: force-delete zombie Terminating/Unknown pods, remove NotReady
# nodes, and delete any PVC whose PV is pinned to a node that's no longer
# live (its StatefulSet/Deployment recreates a fresh one against the
# current node automatically).
resource "terraform_data" "k8s_reconcile" {
  count = var.manage_floci ? 1 : 0

  # ensure_registry_pull_mirror, not just module.eks: that resource can
  # restart the k3s node container to pick up a registries.yaml fix, and
  # everything from here on needs to run against the node that's actually
  # up afterward, not one that's mid-restart underneath it.
  depends_on = [terraform_data.ensure_registry_pull_mirror]

  # Re-run on every single apply, not just when something in the module.eks
  # graph changed — the whole point is to catch node/pod churn that happened
  # *between* applies, which Terraform's own diffing can't see coming.
  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

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

# Floci-only. app-secrets is read by both the backing-services chart
# (postgres/rabbitmq's own credentials) and every nest-service chart
# (DATABASE_URL/RABBITMQ_URL composition) -- without it, pods sit in
# CreateContainerConfigError regardless of whether their image exists.
# This was always a manual `kubectl create secret --from-env-file` step
# (see k8s/secrets/prod.env.example) that nothing automated or even
# documented in Option B's setup. var.jwt_secret etc. already flow into
# every apply via secrets.local.tfvars -- this just actually uses them.
# Never wired up for prod: real secrets there stay a deliberate manual
# step, not something Terraform auto-applies.
resource "terraform_data" "app_secrets" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.k8s_reconcile]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      kubectl create namespace ai-notification --dry-run=client -o yaml | kubectl apply -f - >/dev/null

      kubectl create secret generic app-secrets -n ai-notification \
        --from-literal=JWT_SECRET='${var.jwt_secret}' \
        --from-literal=POSTGRES_PASSWORD='${var.postgres_password}' \
        --from-literal=RABBITMQ_PASSWORD='${var.rabbitmq_password}' \
        --from-literal=RABBITMQ_URL='amqp://notification:${var.rabbitmq_password}@rabbitmq:5672' \
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

# Floci-only: installs/upgrades ArgoCD itself via the helm CLI directly
# (not Terraform's helm/kubernetes providers -- those need static-ish auth
# config, and this cluster's client cert/key only exist inside the
# floci-eks container, fetched by shelling out; same reason k8s_reconcile
# and argocd_manifests below use kubectl via local-exec instead of the
# kubernetes provider). `helm upgrade --install` is idempotent -- safe and
# cheap to re-run every apply, and self-heals a cluster that never had
# ArgoCD installed at all (a genuinely fresh rebuild) without a manual
# `helm install` step.
resource "terraform_data" "argocd_install" {
  count = var.manage_floci ? 1 : 0

  # app_secrets, not just k8s_reconcile: backing-services starts getting
  # synced once ArgoCD exists, and it needs app-secrets to actually come up
  # clean instead of CreateContainerConfigError while it waits.
  depends_on = [terraform_data.k8s_reconcile, terraform_data.app_secrets]

  triggers_replace = {
    always_run  = timestamp()
    values_hash = filesha256("${var.platform_gitops_path}/k8s/argocd/values-core.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      # Idempotency check: skip the helm upgrade (chart re-render, repo
      # update over the network, --wait polling) entirely when ArgoCD is
      # already deployed with this exact values file and healthy. Without
      # this, every single apply paid the full cost of a helm upgrade
      # regardless of whether anything actually changed -- real time and
      # CPU on a machine that's already tight for it, for zero benefit.
      # The values hash is stamped as an annotation on argocd-server right
      # after a successful install/upgrade below, so this compares against
      # what's *actually running*, not just Terraform's own state -- still
      # self-healing if the deployment is missing, unhealthy, or was
      # touched outside Terraform.
      DEPLOYED_HASH=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.metadata.annotations.values-hash}' 2>/dev/null || true)
      READY=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${filesha256("${var.platform_gitops_path}/k8s/argocd/values-core.yaml")}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "ArgoCD already deployed and healthy with unchanged values -- skipping helm upgrade."
        exit 0
      fi

      source "${path.module}/scripts/helm-unstick.sh" "argocd" "argocd"

      helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
      helm repo update argo >/dev/null 2>&1

      helm upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace \
        -f "${var.platform_gitops_path}/k8s/argocd/values-core.yaml" \
        --wait --timeout 10m

      kubectl annotate deployment argocd-server -n argocd \
        values-hash="${filesha256("${var.platform_gitops_path}/k8s/argocd/values-core.yaml")}" --overwrite
    EOT
  }
}

# Re-applies the ArgoCD Application/ApplicationSet manifests on every apply,
# so this repo's own manifest files are always what's actually live in the
# cluster -- catches both drift (like the stale infra/floci-gitops
# targetRevision this project shipped with for a while, silently breaking
# every sync) and a cluster that's missing them entirely after being
# rebuilt.
resource "terraform_data" "argocd_manifests" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.argocd_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      if ! kubectl get namespace argocd >/dev/null 2>&1; then
        echo "argocd namespace doesn't exist yet -- ArgoCD itself isn't Terraform-managed, skipping manifest apply." >&2
        exit 0
      fi

      kubectl apply -f "${var.platform_gitops_path}/k8s/argocd/applications/"
      kubectl apply -f "${var.platform_gitops_path}/k8s/argocd/applicationsets/"
    EOT
  }
}

# Generated so Jenkins never needs the interactive setup wizard or a
# fetch-from-pod initialAdminPassword dance -- admin/<this> works the
# moment Jenkins is up. (Previously lived in modules/jenkins-ec2 -- moved
# here now that Jenkins is a plain Helm install, not a submodule.)
resource "random_password" "jenkins_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "jenkins_admin_password" {
  content         = random_password.jenkins_admin.result
  filename        = "${path.root}/envs/state/jenkins-admin-password.txt"
  file_permission = "0600"
}

# Rendered to actual files (not embedded inline in the helm command below)
# so `--set-file` can reference them directly -- avoids nesting a nested
# shell heredoc inside Terraform's own heredoc, which gets fragile fast once
# the content itself (Groovy, with its own ${...} syntax) has to survive
# both Terraform's interpolation pass and the shell's.
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
    git_branch           = "main"
    services_groovy_list = join(", ", [for s in var.ecr_repository_names : "\"${s}\""])
  })
  filename = "${path.root}/envs/state/jenkins-seed-jobs.groovy"
}

# Floci-only for now -- Jenkins as a Kubernetes workload instead of a
# dedicated EC2/VM instance. Why: Floci's EC2 emulation has no systemd, so
# nothing supervised Jenkins (or even sshd) once either died -- confirmed
# live, repeatedly, across a full day of debugging -- and Floci's own EC2
# instance state machine proved unreliable under normal Docker Desktop
# restarts (stuck "pending", public IP never assigned, instances vanishing
# outside Terraform's own view). Kubernetes gives Jenkins a Deployment's
# restart guarantees for free and reuses the same kubectl-port-forward
# pattern as the tunnel below instead of an SSH tunnel to a VM. Real-AWS
# wiring (a real kubeconfig instead of scripts/kubeconfig.sh's Floci-only
# docker-exec approach) is deferred prod work, same as Ingress/ALB browser
# access -- see the plan notes this project keeps for that.
#
# Installed directly via helm (not GitOps/ArgoCD-managed), same reasoning as
# argocd_install: platform/CI control plane, not an application -- and
# having ArgoCD manage the very Jenkins that seeds ArgoCD's own sync targets
# is an unnecessary chicken-and-egg for no real benefit. Sequenced after the
# whole ArgoCD/backing-services chain, not parallel with it -- same "this
# machine can't handle concurrent heavy installs" lesson as everything else
# in this file.
resource "terraform_data" "jenkins_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [
    terraform_data.argocd_manifests,
    local_sensitive_file.jenkins_init_security,
    local_file.jenkins_seed_jobs,
  ]

  triggers_replace = {
    always_run    = timestamp()
    values_hash   = filesha256("${var.platform_gitops_path}/k8s/jenkins/values.yaml")
    security_hash = local_sensitive_file.jenkins_init_security.content_sha256
    seed_hash     = local_file.jenkins_seed_jobs.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      # Force-delete jenkins-0 first if it's stuck Terminating/Unknown --
      # same stale-kubelet-handoff class of issue k8s_reconcile already
      # cleans up elsewhere in this file, but that pass runs once, early,
      # right after k3s comes back up -- before Jenkins (by far the
      # slowest pod here to boot, a full JVM + plugin load) has had time to
      # reveal its own staleness. Confirmed live: a StatefulSet with an
      # unchanged, correct spec does NOT self-heal a pod merely stuck in
      # "Unknown" -- the controller only replaces a pod once it's actually
      # gone, not just stale, so without this the pod sat broken until
      # someone noticed and deleted it by hand.
      STUCK=$(kubectl get pod jenkins-0 -n jenkins --no-headers 2>/dev/null | awk '$3=="Unknown" || $3=="Terminating"{print $1}')
      if [ -n "$STUCK" ]; then
        echo "jenkins-0 is stuck ($STUCK) -- force-deleting so the StatefulSet recreates it..."
        kubectl delete pod jenkins-0 -n jenkins --grace-period=0 --force >/dev/null 2>&1 || true
      fi

      # Idempotency check: skip the helm upgrade entirely when Jenkins is
      # already deployed with this exact config and healthy -- confirmed
      # live, re-running this unconditionally cost real time even when
      # nothing changed (chart re-render, --wait polling, and worst case
      # the full plugin-reinstall/pod-restart path this file's own comments
      # already document as expensive). Combines all three hash inputs
      # since any one of them changing means real content changed. Compares
      # against what's actually running (an annotation stamped right after
      # a successful install/upgrade below), not just Terraform's own
      # state, so this stays self-healing if the StatefulSet is missing,
      # unhealthy, or was touched outside Terraform.
      DEPLOYED_HASH=$(kubectl get statefulset jenkins -n jenkins -o jsonpath='{.metadata.annotations.config-hash}' 2>/dev/null || true)
      READY=$(kubectl get statefulset jenkins -n jenkins -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      CURRENT_HASH="${filesha256("${var.platform_gitops_path}/k8s/jenkins/values.yaml")}-${local_sensitive_file.jenkins_init_security.content_sha256}-${local_file.jenkins_seed_jobs.content_sha256}"
      if [ "$DEPLOYED_HASH" = "$CURRENT_HASH" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "Jenkins already deployed and healthy with unchanged config -- skipping helm upgrade."
      else
        source "${path.module}/scripts/helm-unstick.sh" "jenkins" "jenkins"

        helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
        helm repo update jenkins >/dev/null 2>&1

        # Revert plugin-dir to the chart's own emptyDir *before* helm runs,
        # if the earlier patch (below) has it on the PVC right now.
        # Confirmed live: Helm 4 defaults to server-side apply, and it still
        # renders plugin-dir as emptyDir (the chart has no override for
        # this -- see the patch's own comment) on every upgrade. Applying
        # that against a live object already holding persistentVolumeClaim
        # doesn't replace the field, it merges the two field managers'
        # views -- "StatefulSet.apps is invalid: may not specify more than
        # 1 volume type" -- because SSA has no way to know the PVC field
        # should be cleared when a *different* patch (kubectl patch,
        # below) is what set it, not this same upgrade. Reverting first
        # gives helm a clean object with nothing to conflict over; the
        # patch step re-applies right after, same as it always did.
        CURRENT_PLUGIN_VOL_PREUPGRADE=$(kubectl get statefulset jenkins -n jenkins -o jsonpath='{.spec.template.spec.volumes[?(@.name=="plugin-dir")].persistentVolumeClaim.claimName}' 2>/dev/null || true)
        if [ "$CURRENT_PLUGIN_VOL_PREUPGRADE" = "jenkins-plugins" ]; then
          echo "plugin-dir is on the PVC -- reverting to emptyDir before helm upgrade to avoid an SSA field conflict..."
          # Strategic-merge, matched by name (patchMergeKey on
          # PodSpec.volumes) -- not JSON-patch-by-index. The actual failure
          # this is fixing showed plugin-dir at volumes[3]; hardcoding an
          # index here would silently revert whatever volume happens to
          # occupy that slot instead, which is exactly the fragility the
          # original patch (below) was already written to avoid.
          kubectl patch statefulset jenkins -n jenkins --type=strategic -p \
            '{"spec":{"template":{"spec":{"volumes":[{"name":"plugin-dir","persistentVolumeClaim":null,"emptyDir":{}}]}}}}' 2>/dev/null || true
        fi

        # 20m, not 10m: this chart's plugin init container re-downloads every
        # plugin from the internet into an ephemeral (not JENKINS_HOME-backed)
        # volume on every single pod (re)start -- confirmed live, a restart
        # forced by an initScripts content change took ~13m end to end,
        # blowing past a 10m --wait and leaving `terraform apply` erroring out
        # even though the pod finished starting less than a minute later on
        # its own. The plugin-dir-to-PVC patch below fixes the persistence
        # side of this (see its own comment) -- this timeout stays generous
        # regardless, since a genuinely new plugin list still needs a real
        # fresh download the first time either way.
        helm upgrade --install jenkins jenkins/jenkins \
          --namespace jenkins --create-namespace \
          -f "${var.platform_gitops_path}/k8s/jenkins/values.yaml" \
          --set-file "controller.initScripts.basic-security=${local_sensitive_file.jenkins_init_security.filename}" \
          --set-file "controller.initScripts.seed-jobs=${local_file.jenkins_seed_jobs.filename}" \
          --wait --timeout 20m

        kubectl annotate statefulset jenkins -n jenkins config-hash="$CURRENT_HASH" --overwrite
      fi

      # Plugin persistence: templates/jenkins-controller-statefulset.yaml
      # (jenkins/jenkins chart source, confirmed via `helm pull --untar`,
      # not guessed) hardcodes plugin-dir -- the volume mounted at
      # $JENKINS_HOME/plugins/ -- as `emptyDir: {}`, with no values.yaml
      # key to override it. Every pod (re)start re-downloads every plugin
      # from the internet into that empty volume from scratch (the ~13m
      # figure above). Helm 4's --post-renderer requires a registered
      # plugin (a Helm 3-style raw-script path errors "plugin ... not
      # found") -- adding unversioned local machine state outside git for
      # this felt like the wrong tradeoff, so this patches the rendered
      # StatefulSet directly instead: create a real PVC, then repoint
      # plugin-dir at it. Strategic-merge, not JSON-patch-by-index --
      # PodSpec.volumes carries patchMergeKey=name, so this matches
      # plugin-dir by name regardless of its position in the list, and
      # explicitly nulls emptyDir since a Volume can only have one source
      # set (leaving both would fail API validation). Only runs the
      # patch+wait when needed (volume doesn't already point at the PVC)
      # so an unrelated helm upgrade above doesn't force an extra restart
      # every time -- confirmed live, helm upgrade re-applies the chart's
      # own unpatched emptyDir on every run that actually executes, so
      # this has to be unconditional relative to the if/else above, just
      # not relative to its own already-applied state.
      kubectl apply -f - <<'PVCEOF'
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: jenkins-plugins
  namespace: jenkins
  labels:
    app.kubernetes.io/name: jenkins
    app.kubernetes.io/instance: jenkins
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/component: jenkins-plugin-cache
  annotations:
    helm.sh/resource-policy: keep
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
PVCEOF

      CURRENT_PLUGIN_VOL=$(kubectl get statefulset jenkins -n jenkins -o jsonpath='{.spec.template.spec.volumes[?(@.name=="plugin-dir")].persistentVolumeClaim.claimName}' 2>/dev/null || true)
      if [ "$CURRENT_PLUGIN_VOL" != "jenkins-plugins" ]; then
        echo "plugin-dir is still emptyDir -- patching it onto the jenkins-plugins PVC..."
        kubectl patch statefulset jenkins -n jenkins --type=strategic -p \
          '{"spec":{"template":{"spec":{"volumes":[{"name":"plugin-dir","emptyDir":null,"persistentVolumeClaim":{"claimName":"jenkins-plugins"}}]}}}}'
        kubectl rollout status statefulset/jenkins -n jenkins --timeout=20m
      fi
    EOT
  }
}

# Floci-only: a genuinely fresh cluster starts with empty ECR, so every app
# pod sits in ImagePullBackOff until something builds and pushes all 13
# service images once -- previously a manual "click the build-service job in
# the Jenkins UI" step. Every apply: check whether ECR is still empty (a
# fresh cluster) and if so, trigger the generic build-service job with
# SERVICES=all and wait for it to finish. One job run, not 13 -- that job's
# own Jenkinsfile already loops through every service sequentially, one
# kaniko pod at a time (see platform-gitops/jenkins/Jenkinsfile's "Build +
# push (kaniko, one service at a time)" stage), so there's no need to
# reimplement that sequencing here or pay for a separate job/pod/git-clone
# per service. No-ops immediately (checks one repo, exits) once ECR already
# has images -- the common case on every apply after the first.
resource "terraform_data" "seed_first_build" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.jenkins_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e

      # Checked directly against the registry's own v2 API (port 5100 on
      # the Mac host, published from floci-ecr-registry), not `aws ecr
      # describe-images` -- confirmed live, Floci's ECR-metadata simulation
      # came back completely empty after a Floci restart even though the
      # underlying registry storage (and the repositories themselves) were
      # fully intact, `docker exec floci-ecr-registry du -sh /var/lib/registry`
      # still showing every layer. Trusting describe-images here would have
      # silently triggered a full 13-service rebuild of images that already
      # existed. The registry's own tags/list is what's actually true.
      FIRST_REPO="ai-notification/${var.ecr_repository_names[0]}"
      TAGS_JSON=$(curl -s "http://localhost:5100/v2/$FIRST_REPO/tags/list" 2>/dev/null)
      if echo "$TAGS_JSON" | grep -q '"tags":\[[^]]'; then
        echo "Registry already has images for $FIRST_REPO -- skipping first-build seed."
        exit 0
      fi

      echo "ECR is empty -- seeding the first build via build-service (SERVICES=all)..."
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      JPORT=28080
      JURL="http://localhost:$JPORT"
      AUTH="admin:${random_password.jenkins_admin.result}"

      # </dev/null is load-bearing -- see jenkins_tunnel's comment below for
      # why. This port-forward only needs to live for the rest of this
      # script, not across applies like jenkins_tunnel's does, so it's
      # cleaned up via trap instead of a PID file.
      kubectl port-forward svc/jenkins -n jenkins "$JPORT:8080" </dev/null >/dev/null 2>&1 &
      JPID=$!
      COOKIEJAR=$(mktemp)
      trap 'kill $JPID 2>/dev/null || true; rm -f "$COOKIEJAR"' EXIT

      echo "waiting for the Jenkins API..."
      for i in $(seq 1 60); do
        curl -sf -u "$AUTH" "$JURL/api/json" >/dev/null 2>&1 && break
        sleep 2
      done

      # If a build is already running (e.g. a prior apply's trigger is
      # still in flight -- this happens if that apply's own polling loop
      # errored out for an unrelated reason, like the race described
      # below), attach to it instead of triggering a wasteful, resource-
      # competing duplicate.
      LAST_JSON=$(curl -s -u "$AUTH" "$JURL/job/build-service/lastBuild/api/json" 2>/dev/null)
      LAST_BUILDING=$(echo "$LAST_JSON" | grep -o '"building":[a-z]*' | head -1 | cut -d: -f2)
      LAST_NUM=$(echo "$LAST_JSON" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2)
      [ -z "$LAST_NUM" ] && LAST_NUM=0

      if [ "$LAST_BUILDING" = "true" ]; then
        echo "build-service #$LAST_NUM is already running -- attaching to it instead of triggering a duplicate."
        TARGET_NUM="$LAST_NUM"
      else
        # -c/-b share a cookie jar across both calls -- confirmed live, this
        # crumb issuer ties the crumb to the session cookie it hands back,
        # so a crumb fetched and then spent without carrying that same
        # cookie forward gets rejected with "No valid crumb was included in
        # the request" even though the crumb value itself is correct.
        CRUMB=$(curl -s -c "$COOKIEJAR" -u "$AUTH" "$JURL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
        curl -sf -b "$COOKIEJAR" -u "$AUTH" -H "$CRUMB" -X POST "$JURL/job/build-service/buildWithParameters?ENVIRONMENT=local&SERVICES=all" >/dev/null

        # A freshly triggered build sits in Jenkins' queue (not yet a
        # numbered build) for a moment before it actually starts -- polling
        # lastBuild during that window returns the *previous* build's
        # already-terminal state, not the new one. Confirmed live: this
        # raced hard enough to make the very first poll below see the old
        # build's stale "ABORTED" and exit immediately, reporting failure
        # while the real new build kept running in the background,
        # unmonitored, for the next several minutes. Waiting here for
        # lastBuild's number to actually advance past the pre-trigger
        # baseline avoids that -- only then do we know we're looking at the
        # new run, not the old one.
        echo "waiting for the triggered build to leave the queue..."
        TARGET_NUM=""
        for i in $(seq 1 60); do
          NUM=$(curl -s -u "$AUTH" "$JURL/job/build-service/lastBuild/api/json" 2>/dev/null | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2)
          if [ -n "$NUM" ] && [ "$NUM" -gt "$LAST_NUM" ]; then
            TARGET_NUM="$NUM"
            break
          fi
          sleep 2
        done
        if [ -z "$TARGET_NUM" ]; then
          echo "build-service never left the queue after 2 minutes." >&2
          exit 1
        fi
      fi

      echo -n "waiting for build-service #$TARGET_NUM (all ${length(var.ecr_repository_names)} services, one at a time) to finish"
      RESULT=""
      # Up to 90 minutes -- 13 sequential kaniko builds on a resource-
      # constrained Mac can genuinely take a while; polled every 5s so it
      # returns promptly once actually done rather than over-waiting.
      for i in $(seq 1 1080); do
        JSON=$(curl -s -u "$AUTH" "$JURL/job/build-service/$TARGET_NUM/api/json" 2>/dev/null)
        BUILDING=$(echo "$JSON" | grep -o '"building":[a-z]*' | head -1 | cut -d: -f2)
        RESULT=$(echo "$JSON" | grep -o '"result":"[A-Z]*"' | head -1 | cut -d'"' -f4)
        if [ "$BUILDING" = "false" ] && [ -n "$RESULT" ]; then
          break
        fi
        sleep 5
        echo -n "."
      done
      echo " $RESULT"

      if [ "$RESULT" != "SUCCESS" ]; then
        echo "build-service #$TARGET_NUM did not finish successfully (result='$RESULT')." >&2
        exit 1
      fi

      echo "first-build seed complete -- all ${length(var.ecr_repository_names)} services built and pushed."
    EOT
  }
}

# Browser access to the Jenkins UI from this Mac -- a kubectl port-forward
# instead of jenkins_ssh_tunnel's SSH tunnel (there's no VM to SSH into
# anymore). Opt-in via jenkins_local_tunnel_port so a plain `terraform
# apply` on a CI box never tries to spawn one.
resource "terraform_data" "jenkins_tunnel" {
  count = (var.manage_floci && var.jenkins_local_tunnel_port > 0) ? 1 : 0

  depends_on = [terraform_data.jenkins_install]

  triggers_replace = {
    local_port = var.jenkins_local_tunnel_port
    # Re-run on every apply, not just when local_port changes: the actual
    # kubectl port-forward process can die independently (killed by hand,
    # laptop sleep, anything) with nothing here ever changing, silently
    # leaving Jenkins unreachable until something forces a replace. Same
    # self-healing-every-apply pattern as everything else in this file.
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      PIDFILE="${path.root}/envs/state/jenkins-tunnel-${var.jenkins_local_tunnel_port}.pid"

      # Idempotency check: if the tunnel process is still alive AND the
      # port still actually answers, leave it alone instead of killing and
      # re-forwarding it every single apply for no reason -- confirmed
      # live, this was happening unconditionally even when nothing was
      # wrong, needlessly dropping the connection for a few seconds each
      # time. Still self-healing: any real gap (process died, port stopped
      # responding) falls through to the normal re-establish logic below.
      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && \
         curl -sf -o /dev/null "http://localhost:${var.jenkins_local_tunnel_port}/login"; then
        echo "Jenkins tunnel already up and responding on localhost:${var.jenkins_local_tunnel_port} -- leaving it alone."
        exit 0
      fi

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for the jenkins Service to have a ready endpoint..."
      for i in $(seq 1 60); do
        EP=$(kubectl get endpoints jenkins -n jenkins -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        [ -n "$EP" ] && break
        sleep 2
      done

      # </dev/null is load-bearing, not cosmetic -- see jenkins_install's
      # sibling resources in git history (jenkins_ssh_tunnel) for the full
      # story: without it, this process's stdin stays connected to the pipe
      # Terraform used to run this script, and the moment Terraform closes
      # that pipe when the provisioner finishes, the backgrounded process
      # gets an EOF/error on the still-open fd and dies -- fast enough that
      # `echo $!` into the PIDFILE still succeeds and `terraform apply`
      # still reports success, with nothing actually left listening.
      #
      # Double-fork daemonize, not plain nohup or a single setsid() --
      # confirmed live, when this runs as a step in a GitHub Actions
      # self-hosted runner job (Phase 4), the runner killed the tunnel
      # every time the job finished, and neither setsid() nor a proper
      # double-fork daemonize (reparenting confirmed live via `ps -o
      # ppid` showing 1) stopped it. The runner's own diagnostic log gave
      # the real reason: "Cleaning up orphan processes" / "Terminate
      # orphan process: pid (N) (kubectl)" -- it doesn't walk the process
      # tree or process group at all, it scans *every* process on the
      # system and kills any whose environment still carries the
      # RUNNER_TRACKING_ID it stamps onto everything a job spawns. No
      # amount of session/parent detachment escapes that, since fork()
      # and execvp() both inherit the parent's environment unless told
      # otherwise. The fix that actually works: strip that (and other
      # RUNNER_*/GITHUB_*/ACTIONS_* job-tracking) vars before the final
      # exec, via execvpe with an explicit filtered environment instead
      # of plain execvp -- kubectl doesn't need any of them anyway. Kept
      # the double-fork daemonize underneath regardless (harmless, and
      # still the correct way to detach a long-lived process from a
      # short-lived shell in general).
      #
      # No trailing `&`/`echo $!` here on purpose: the shell already
      # returns as soon as the first fork's parent exits (which is
      # immediate), and only the fully-detached grandchild -- invisible to
      # this shell's own $! -- knows its own final PID, so it writes the
      # PIDFILE itself instead.
      python3 -c "
import os, sys
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
with open('$PIDFILE', 'w') as f:
    f.write(str(os.getpid()))
env = {k: v for k, v in os.environ.items() if not k.startswith(('RUNNER_', 'GITHUB_', 'ACTIONS_'))}
os.execvpe('kubectl', ['kubectl', 'port-forward', 'svc/jenkins', '-n', 'jenkins', '${var.jenkins_local_tunnel_port}:8080'], env)
" </dev/null >/dev/null 2>&1

      echo "Jenkins UI: http://localhost:${var.jenkins_local_tunnel_port}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      PIDFILE="${path.root}/envs/state/jenkins-tunnel-${self.triggers_replace.local_port}.pid"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    EOT
  }
}

# Browser access to the ArgoCD UI -- same pattern again. argocd-server serves
# TLS only in this chart (no server.insecure toggle set in values-core.yaml),
# so the forwarded port is 443 and the browser will show a self-signed-cert
# warning -- expected, not a bug. Depends directly on argocd_install (not
# argocd_manifests): the server Service exists as soon as ArgoCD itself is
# up, independent of which Application manifests have been applied.
resource "terraform_data" "argocd_tunnel" {
  count = (var.manage_floci && var.argocd_local_tunnel_port > 0) ? 1 : 0

  depends_on = [terraform_data.argocd_install]

  triggers_replace = {
    local_port = var.argocd_local_tunnel_port
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      PIDFILE="${path.root}/envs/state/argocd-tunnel-${var.argocd_local_tunnel_port}.pid"

      # Idempotency check -- see jenkins_tunnel's comment on the same
      # pattern for why. -k: self-signed cert, same as the browser warning
      # this tunnel already produces on purpose (see comment above).
      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && \
         curl -sfk -o /dev/null "https://localhost:${var.argocd_local_tunnel_port}"; then
        echo "ArgoCD tunnel already up and responding on localhost:${var.argocd_local_tunnel_port} -- leaving it alone."
        exit 0
      fi

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for the argocd-server Service to have a ready endpoint..."
      for i in $(seq 1 60); do
        EP=$(kubectl get endpoints argocd-server -n argocd -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        [ -n "$EP" ] && break
        sleep 2
      done

      # Double-fork daemonize + a filtered exec environment -- see
      # jenkins_tunnel's comment for the full story on why (short version:
      # the GitHub Actions runner kills orphaned processes by scanning for
      # a RUNNER_TRACKING_ID env var, not by process tree/group, so that
      # var has to be stripped before the final exec, not just detached
      # from the process tree).
      python3 -c "
import os, sys
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
with open('$PIDFILE', 'w') as f:
    f.write(str(os.getpid()))
env = {k: v for k, v in os.environ.items() if not k.startswith(('RUNNER_', 'GITHUB_', 'ACTIONS_'))}
os.execvpe('kubectl', ['kubectl', 'port-forward', 'svc/argocd-server', '-n', 'argocd', '${var.argocd_local_tunnel_port}:443'], env)
" </dev/null >/dev/null 2>&1

      echo "ArgoCD UI: https://localhost:${var.argocd_local_tunnel_port} (admin / see 'argocd admin initial-password')"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      PIDFILE="${path.root}/envs/state/argocd-tunnel-${self.triggers_replace.local_port}.pid"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    EOT
  }
}

# ---------------------------------------------------------------------------
# Observability platform -- Terraform-installed, like ArgoCD/Jenkins above
# (platform/CI control plane, not an application). Diagnostic tooling only:
# no HPA/ScaledObject/scaling policy lives here (those are GitOps-managed,
# app-level, and only get turned on once a load test actually names a real
# bottleneck -- see the load-test plan). metrics-server + KEDA's operator are
# the exception -- inert until something references them (an HPA or
# ScaledObject), safe to stand up now alongside the rest.
#
# Deliberately excluded to keep this machine's load down: Loki, Jaeger's
# full multi-component Helm chart (Cassandra/ES by default -- a plain
# Deployment+Service for the all-in-one image instead), Alertmanager,
# node-exporter, the Prometheus Operator/CRDs. Annotation-based Prometheus
# scraping (prometheus.io/scrape, built into the community chart's default
# scrape_configs) instead of ServiceMonitors -- no extra CRDs needed.
# ---------------------------------------------------------------------------

resource "terraform_data" "observability_namespace" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.argocd_tunnel]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"
      # --validate=false: confirmed live, kubeconfig.sh's own readiness wait
      # (a plain `kubectl get nodes`) can succeed before the API server's
      # OpenAPI schema endpoint is ready, which is what client-side
      # validation needs to fetch -- "failed to download openapi: the
      # server could not find the requested resource". Not needed for a
      # plain Namespace object anyway.
      #
      # Retry loop around that same class of readiness gap, one layer
      # deeper: confirmed live (twice, both times right after a heavy step
      # just ahead of this one -- jenkins_tunnel once, jenkins_install's
      # plugin-PVC rollout the other), --validate=false alone isn't enough
      # on its own -- `kubectl apply` still failed with "unable to
      # recognize STDIN: the server could not find the requested resource"
      # because the apiserver's discovery/RESTMapper cache (which resolves
      # "Namespace" to its API endpoint at all, upstream of any schema
      # validation) hadn't caught up yet either. Looped instead of a fixed
      # sleep for the same reason kubeconfig.sh's own waits are loops, not
      # sleeps: how long this takes depends on how busy the apiserver
      # actually is, not a number worth guessing at.
      NS_YAML=$(kubectl create namespace observability --dry-run=client -o yaml)
      NS_APPLIED=false
      for i in $(seq 1 15); do
        if echo "$NS_YAML" | kubectl apply --validate=false -f - >/dev/null 2>&1; then
          NS_APPLIED=true
          break
        fi
        echo "apiserver discovery not ready yet for namespace apply (attempt $i/15) -- retrying..."
        sleep 2
      done
      if [ "$NS_APPLIED" != "true" ]; then
        echo "observability namespace still not applyable after 15 attempts -- apiserver discovery never caught up." >&2
        echo "$NS_YAML" | kubectl apply --validate=false -f -
      fi
    EOT
  }
}

# k3s sometimes ships metrics-server as a built-in addon already -- checked
# first so this doesn't fight or duplicate it.
resource "terraform_data" "metrics_server_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.observability_namespace]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      # Check the ServiceAccount, with a short retry loop -- not the
      # Deployment, and not a one-shot check. Confirmed live: k3s ships its
      # own built-in metrics-server via its own addon mechanism
      # (k3s.cattle.io/v1 Kind=Addon, not Helm-owned) that keeps flapping the
      # Deployment/pod (real liveness-probe timeouts, likely resource
      # contention from everything else running on this machine) -- a
      # Deployment-existence check can race a moment mid-recreate and see
      # nothing, sending this into a `helm upgrade --install` that then
      # fails hard on the ServiceAccount's k3s ownership metadata ("cannot
      # be imported into the current release"). The ServiceAccount itself
      # stayed stable the whole time this was being debugged, unlike the
      # Deployment -- checked here instead, with retries to survive a
      # genuinely-in-flight reconcile rather than assuming one bad instant
      # means "nothing here yet".
      FOUND=false
      for i in $(seq 1 15); do
        if kubectl get serviceaccount metrics-server -n kube-system >/dev/null 2>&1; then
          FOUND=true
          break
        fi
        sleep 2
      done

      if [ "$FOUND" = "true" ]; then
        echo "metrics-server already present (k3s built-in or a prior apply) -- waiting for it to be ready instead of installing a competing Helm release..."
        kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || true
        exit 0
      fi

      helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
      helm repo update metrics-server >/dev/null 2>&1

      # --kubelet-insecure-tls: k3s's kubelet certs are self-signed, same
      # reasoning as kubeconfig.sh's own insecure-skip-tls-verify.
      helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --set args="{--kubelet-insecure-tls}" \
        --wait --timeout 5m
    EOT
  }
}

resource "terraform_data" "kube_state_metrics_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.metrics_server_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      READY=$(kubectl get deployment kube-state-metrics -n observability -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$${READY:-0}" -ge 1 ]; then
        echo "kube-state-metrics already deployed and healthy -- skipping."
        exit 0
      fi

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
      helm repo update prometheus-community >/dev/null 2>&1

      # Service annotations, not a ServiceMonitor -- picked up automatically
      # by the Prometheus chart's default kubernetes-service-endpoints scrape
      # job below, no CRDs involved. --set-string, not --set: annotations
      # must be strings, but --set's own type inference parses `true`/`8080`
      # as bool/number, which Kubernetes then rejects decoding
      # metadata.annotations (must be map[string]string).
      helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
        --namespace observability \
        --set-string service.annotations."prometheus\.io/scrape"=true \
        --set-string service.annotations."prometheus\.io/port"=8080 \
        --wait --timeout 5m
    EOT
  }
}

# Plain Deployment+Service, not the official jaeger Helm chart (which pulls
# in Cassandra/Elasticsearch sub-charts by default) -- all-in-one's native
# OTLP receiver (COLLECTOR_OTLP_ENABLED) is all otel-collector's traces
# pipeline needs to talk to, in-memory storage is fine for a demo window.
resource "terraform_data" "jaeger_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.kube_state_metrics_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app: jaeger }
  template:
    metadata:
      labels: { app: jaeger }
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.60
          env:
            - name: COLLECTOR_OTLP_ENABLED
              value: "true"
          ports:
            - containerPort: 4317
            - containerPort: 4318
            - containerPort: 16686
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { cpu: 250m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector: { app: jaeger }
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: query
      port: 16686
      targetPort: 16686
YAML

      kubectl rollout status deployment/jaeger -n observability --timeout=120s
    EOT
  }
}

# Renders the otel-collector chart's values -- same pipeline shape as
# infra/otel/otel-collector-config.yaml (this repo's docker-compose stack),
# minus the loki exporter/pipeline (logs stay out of scope here), plus the
# k8s-specific bits (ports.prometheus + service annotations) that config
# doesn't need since docker-compose's Prometheus scrapes it by container
# name, not k8s service discovery.
resource "local_file" "otel_collector_values" {
  content  = <<-EOT
    mode: deployment

    # Newer chart versions dropped their own default -- must be set
    # explicitly now. Core distribution, not contrib: only otlp
    # receivers/batch processor/otlp+prometheus exporters are used here,
    # all included in core.
    image:
      repository: otel/opentelemetry-collector

    config:
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
          endpoint: jaeger.observability.svc.cluster.local:4317
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

    ports:
      prometheus:
        enabled: true
        containerPort: 8889
        servicePort: 8889
        protocol: TCP

    service:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8889"

    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits: { cpu: 250m, memory: 256Mi }
  EOT
  filename = "${path.root}/envs/state/otel-collector-values.yaml"
}

resource "terraform_data" "otel_collector_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.jaeger_install, local_file.otel_collector_values]

  triggers_replace = {
    always_run  = timestamp()
    values_hash = local_file.otel_collector_values.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      DEPLOYED_HASH=$(kubectl get deployment otel-collector-opentelemetry-collector -n observability -o jsonpath='{.metadata.annotations.values-hash}' 2>/dev/null || true)
      READY=$(kubectl get deployment otel-collector-opentelemetry-collector -n observability -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${local_file.otel_collector_values.content_sha256}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "otel-collector already deployed and healthy with unchanged config -- skipping."
        exit 0
      fi

      helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
      helm repo update open-telemetry >/dev/null 2>&1

      helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
        --namespace observability \
        -f "${local_file.otel_collector_values.filename}" \
        --wait --timeout 5m

      kubectl annotate deployment otel-collector-opentelemetry-collector -n observability \
        values-hash="${local_file.otel_collector_values.content_sha256}" --overwrite
    EOT
  }
}

resource "terraform_data" "prometheus_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.otel_collector_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      READY=$(kubectl get deployment prometheus-server -n observability -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$${READY:-0}" -ge 1 ]; then
        echo "Prometheus already deployed and healthy -- skipping (upgrade instead if values changed -- see argocd_install's comment on why this skip pattern is safe for a config that rarely changes)."
        exit 0
      fi

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
      helm repo update prometheus-community >/dev/null 2>&1

      # kube-state-metrics.enabled=false: deployed separately above, avoid a
      # duplicate. alertmanager/node-exporter disabled -- not needed for
      # this goal, keeps footprint down. The chart's own default
      # scrape_configs already includes kubernetes-pods (annotation-based,
      # picks up api-gateway's future /metrics) and
      # kubernetes-nodes-cadvisor (per-pod CPU/memory via the kubelet, no
      # separate cAdvisor container needed in k8s) -- nothing custom needed
      # here for either.
      helm upgrade --install prometheus prometheus-community/prometheus \
        --namespace observability \
        --set server.retention=6h \
        --set server.resources.requests.cpu=100m \
        --set server.resources.requests.memory=256Mi \
        --set server.resources.limits.cpu=500m \
        --set server.resources.limits.memory=512Mi \
        --set alertmanager.enabled=false \
        --set prometheus-node-exporter.enabled=false \
        --set kube-state-metrics.enabled=false \
        --set prometheus-pushgateway.enabled=false \
        --wait --timeout 5m
    EOT
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "grafana_admin_password" {
  content         = random_password.grafana_admin.result
  filename        = "${path.root}/envs/state/grafana-admin-password.txt"
  file_permission = "0600"
}

resource "local_file" "grafana_values" {
  content  = <<-EOT
    adminUser: admin
    adminPassword: "${random_password.grafana_admin.result}"

    persistence:
      enabled: false

    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits: { cpu: 250m, memory: 256Mi }

    datasources:
      datasources.yaml:
        apiVersion: 1
        datasources:
          - name: Prometheus
            type: prometheus
            url: http://prometheus-server.observability.svc.cluster.local
            access: proxy
            isDefault: true
          - name: Jaeger
            type: jaeger
            url: http://jaeger.observability.svc.cluster.local:16686
            access: proxy
  EOT
  filename = "${path.root}/envs/state/grafana-values.yaml"
}

resource "terraform_data" "grafana_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.prometheus_install, local_file.grafana_values]

  triggers_replace = {
    always_run  = timestamp()
    values_hash = local_file.grafana_values.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      DEPLOYED_HASH=$(kubectl get deployment grafana -n observability -o jsonpath='{.metadata.annotations.values-hash}' 2>/dev/null || true)
      READY=$(kubectl get deployment grafana -n observability -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$DEPLOYED_HASH" = "${local_file.grafana_values.content_sha256}" ] && [ "$${READY:-0}" -ge 1 ]; then
        echo "Grafana already deployed and healthy with unchanged config -- skipping."
        exit 0
      fi

      helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
      helm repo update grafana >/dev/null 2>&1

      helm upgrade --install grafana grafana/grafana \
        --namespace observability \
        -f "${local_file.grafana_values.filename}" \
        --wait --timeout 5m

      kubectl annotate deployment grafana -n observability \
        values-hash="${local_file.grafana_values.content_sha256}" --overwrite
    EOT
  }
}

# Browser access to Grafana -- same kubectl-port-forward pattern as
# jenkins_tunnel/argocd_tunnel (see jenkins_tunnel's comments for the full
# daemonize/RUNNER_TRACKING_ID story, not repeated here).
resource "terraform_data" "grafana_tunnel" {
  count = (var.manage_floci && var.grafana_local_tunnel_port > 0) ? 1 : 0

  depends_on = [terraform_data.grafana_install]

  triggers_replace = {
    local_port = var.grafana_local_tunnel_port
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      PIDFILE="${path.root}/envs/state/grafana-tunnel-${var.grafana_local_tunnel_port}.pid"

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && \
         curl -sf -o /dev/null "http://localhost:${var.grafana_local_tunnel_port}/login"; then
        echo "Grafana tunnel already up and responding on localhost:${var.grafana_local_tunnel_port} -- leaving it alone."
        exit 0
      fi

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for the grafana Service to have a ready endpoint..."
      for i in $(seq 1 60); do
        EP=$(kubectl get endpoints grafana -n observability -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        [ -n "$EP" ] && break
        sleep 2
      done

      python3 -c "
import os, sys
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
with open('$PIDFILE', 'w') as f:
    f.write(str(os.getpid()))
env = {k: v for k, v in os.environ.items() if not k.startswith(('RUNNER_', 'GITHUB_', 'ACTIONS_'))}
os.execvpe('kubectl', ['kubectl', 'port-forward', 'svc/grafana', '-n', 'observability', '${var.grafana_local_tunnel_port}:80'], env)
" </dev/null >/dev/null 2>&1

      echo "Grafana UI: http://localhost:${var.grafana_local_tunnel_port} (admin / see envs/state/grafana-admin-password.txt)"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      PIDFILE="${path.root}/envs/state/grafana-tunnel-${self.triggers_replace.local_port}.pid"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    EOT
  }
}

# Browser access to Prometheus's own UI -- for ad-hoc PromQL queries/target
# debugging, separate from Grafana's dashboards.
resource "terraform_data" "prometheus_tunnel" {
  count = (var.manage_floci && var.prometheus_local_tunnel_port > 0) ? 1 : 0

  depends_on = [terraform_data.prometheus_install]

  triggers_replace = {
    local_port = var.prometheus_local_tunnel_port
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      PIDFILE="${path.root}/envs/state/prometheus-tunnel-${var.prometheus_local_tunnel_port}.pid"

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && \
         curl -sf -o /dev/null "http://localhost:${var.prometheus_local_tunnel_port}/-/healthy"; then
        echo "Prometheus tunnel already up and responding on localhost:${var.prometheus_local_tunnel_port} -- leaving it alone."
        exit 0
      fi

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for the prometheus-server Service to have a ready endpoint..."
      for i in $(seq 1 60); do
        EP=$(kubectl get endpoints prometheus-server -n observability -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        [ -n "$EP" ] && break
        sleep 2
      done

      python3 -c "
import os, sys
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
with open('$PIDFILE', 'w') as f:
    f.write(str(os.getpid()))
env = {k: v for k, v in os.environ.items() if not k.startswith(('RUNNER_', 'GITHUB_', 'ACTIONS_'))}
os.execvpe('kubectl', ['kubectl', 'port-forward', 'svc/prometheus-server', '-n', 'observability', '${var.prometheus_local_tunnel_port}:80'], env)
" </dev/null >/dev/null 2>&1

      echo "Prometheus UI: http://localhost:${var.prometheus_local_tunnel_port}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      PIDFILE="${path.root}/envs/state/prometheus-tunnel-${self.triggers_replace.local_port}.pid"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    EOT
  }
}

# Browser access to Jaeger's own trace-search UI.
resource "terraform_data" "jaeger_tunnel" {
  count = (var.manage_floci && var.jaeger_local_tunnel_port > 0) ? 1 : 0

  depends_on = [terraform_data.jaeger_install]

  triggers_replace = {
    local_port = var.jaeger_local_tunnel_port
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      PIDFILE="${path.root}/envs/state/jaeger-tunnel-${var.jaeger_local_tunnel_port}.pid"

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && \
         curl -sf -o /dev/null "http://localhost:${var.jaeger_local_tunnel_port}"; then
        echo "Jaeger tunnel already up and responding on localhost:${var.jaeger_local_tunnel_port} -- leaving it alone."
        exit 0
      fi

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for the jaeger Service to have a ready endpoint..."
      for i in $(seq 1 60); do
        EP=$(kubectl get endpoints jaeger -n observability -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        [ -n "$EP" ] && break
        sleep 2
      done

      python3 -c "
import os, sys
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
with open('$PIDFILE', 'w') as f:
    f.write(str(os.getpid()))
env = {k: v for k, v in os.environ.items() if not k.startswith(('RUNNER_', 'GITHUB_', 'ACTIONS_'))}
os.execvpe('kubectl', ['kubectl', 'port-forward', 'svc/jaeger', '-n', 'observability', '${var.jaeger_local_tunnel_port}:16686'], env)
" </dev/null >/dev/null 2>&1

      echo "Jaeger UI: http://localhost:${var.jaeger_local_tunnel_port}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      PIDFILE="${path.root}/envs/state/jaeger-tunnel-${self.triggers_replace.local_port}.pid"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    EOT
  }
}

# KEDA operator only -- inert until a ScaledObject exists (see the load-test
# plan's Phase F). Its own CRDs (ScaledObject, TriggerAuthentication) +
# metrics adapter come with it.
resource "terraform_data" "keda_install" {
  count = var.manage_floci ? 1 : 0

  depends_on = [terraform_data.grafana_install]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      source "${path.module}/scripts/kubeconfig.sh" "${module.eks.cluster_name}" "${module.eks.cluster_endpoint}"

      READY=$(kubectl get deployment keda-operator -n keda -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      if [ "$${READY:-0}" -ge 1 ]; then
        echo "KEDA already installed and healthy -- skipping."
        exit 0
      fi

      helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
      helm repo update kedacore >/dev/null 2>&1

      helm upgrade --install keda kedacore/keda \
        --namespace keda --create-namespace \
        --wait --timeout 5m
    EOT
  }
}
