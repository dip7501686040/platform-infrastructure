# Started/pulled before anything else touches the aws provider — see
# module.floci's own depends_on chain (docker_container -> wait_for_floci).
# count-based (not a plain resource block) so real-AWS applies (manage_floci
# = false) never require the docker provider to be reachable at all.
module "floci" {
  count  = var.manage_floci ? 1 : 0
  source = "./modules/floci"
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

module "jenkins_ec2" {
  count      = var.jenkins_mode == "ec2" ? 1 : 0
  source     = "./modules/jenkins-ec2"
  depends_on = [module.floci]

  instance_type        = var.jenkins_instance_type
  admin_cidr           = var.jenkins_admin_cidr
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.public_subnet_ids[0]
  github_push_username = var.github_push_username
  github_push_token    = var.github_push_token
  service_names        = var.ecr_repository_names
  tags                 = var.tags
}

# Floci-only: when aws_instance.jenkins gets replaced, Floci's own
# "terminate" doesn't reliably remove the old floci-ec2-<id> Docker
# container -- it's been observed sitting around, still running, long
# after Terraform moved on to a new instance ID. Left alone, that's not
# just clutter: a stale container can still be holding the SSH port the
# new one needs, which is exactly what caused the "unexpected state
# 'terminated'" failures earlier. Removes anything matching floci-ec2-*
# that isn't the currently tracked instance, every apply.
resource "terraform_data" "cleanup_stale_ec2_containers" {
  count = (var.manage_floci && var.jenkins_mode == "ec2") ? 1 : 0

  depends_on = [module.jenkins_ec2]

  triggers_replace = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      CURRENT="floci-ec2-${module.jenkins_ec2[0].instance_id}"
      for c in $(docker ps -a --format '{{.Names}}' | grep '^floci-ec2-' || true); do
        if [ "$c" != "$CURRENT" ]; then
          echo "removing stale EC2 container $c (current is $CURRENT)"
          docker rm -f "$c" || true
        fi
      done
    EOT
  }
}

# Browser access to the Jenkins UI from this Mac, without re-running any
# manual port-forward by hand after every apply. An SSH local-forward
# rather than relying on how Floci happens to publish container ports —
# works the same way against real AWS too (jenkins_admin_cidr there is
# meant to stay locked down, so a tunnel through the already-open SSH port
# is the point, not a workaround). Opt-in via jenkins_local_tunnel_port so
# a plain `terraform apply` on a CI box never tries to spawn one.
resource "terraform_data" "jenkins_ssh_tunnel" {
  count = (var.jenkins_mode == "ec2" && var.jenkins_local_tunnel_port > 0) ? 1 : 0

  # Any change here tears down the old tunnel (destroy provisioner) and
  # opens a fresh one (create provisioner) — covers instance replacement
  # (new IP) and simply changing the desired local port.
  triggers_replace = {
    public_ip  = module.jenkins_ec2[0].public_ip
    local_port = var.jenkins_local_tunnel_port
    key_path   = module.jenkins_ec2[0].ssh_private_key_path
    # public_ip alone isn't enough to detect a replaced instance: Floci
    # always reports 127.0.0.1 regardless of which underlying container it
    # is, so without instance_id here a replaced instance (new container,
    # new Floci-assigned SSH port) silently leaves the tunnel pointed at
    # the old, now-gone port.
    instance_id = module.jenkins_ec2[0].instance_id
    # Bump this whenever the provisioner script body below changes —
    # terraform_data only re-runs provisioners on replace, and replacement
    # is driven solely by this map, not by the script text itself.
    script_version = 3
    # Re-run on every apply, not just when the inputs above change: the
    # actual ssh process can die independently (killed by hand, laptop
    # sleep, anything) with none of those inputs ever changing, silently
    # leaving Jenkins unreachable until something forces a replace. Same
    # self-healing-every-apply pattern as k8s_reconcile/argocd_install/
    # argocd_manifests/app_secrets below.
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      PIDFILE="${path.root}/envs/state/jenkins-tunnel-${var.jenkins_local_tunnel_port}.pid"
      HOST="${module.jenkins_ec2[0].public_ip}"
      KEY="${module.jenkins_ec2[0].ssh_private_key_path}"
      SSH_PORT=22
      SSH_USER=ec2-user

      %{if var.manage_floci}
      # Floci's EC2 emulation is a plain amazonlinux:2023 container, not the
      # real AMI's cloud-init — there's no ec2-user account at all, only
      # root, which is who the generated key pair actually gets authorized
      # for (confirmed via `docker exec ... cat /root/.ssh/authorized_keys`).
      SSH_USER=root
      CONTAINER="floci-ec2-${module.jenkins_ec2[0].instance_id}"
      for i in $(seq 1 30); do
        MAPPED=$(docker port "$CONTAINER" 22 2>/dev/null | head -1)
        if [ -n "$MAPPED" ]; then
          SSH_PORT="$${MAPPED##*:}"
          break
        fi
        sleep 2
      done
      %{endif}

      SSH_OPTS="-i $KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        sleep 1
      fi

      echo "waiting for sshd on $HOST:$SSH_PORT..."
      for i in $(seq 1 60); do
        if ssh $SSH_OPTS -o ConnectTimeout=3 -o BatchMode=yes "$SSH_USER@$HOST" true 2>/dev/null; then
          break
        fi
        sleep 2
      done

      nohup ssh $SSH_OPTS -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N \
        -L ${var.jenkins_local_tunnel_port}:localhost:8080 "$SSH_USER@$HOST" \
        >/dev/null 2>&1 &
      echo $! > "$PIDFILE"

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

  depends_on = [module.jenkins_ec2]
}

# Floci-only: k3s (inside the floci-eks-<cluster> container) registers a
# brand-new Node identity essentially every time its process restarts, not
# just when the container itself is recreated. The old Node never gets a
# clean kubelet handoff, so its pods get stuck "Terminating" forever, and
# any PVC bound to that old Node (local-path's PVs are hard node-affinity
# pinned) becomes permanently unmountable. This doesn't fix *why* k3s does
# that — it self-heals the fallout on every apply instead: force-delete
# zombie Terminating pods, remove NotReady nodes, and delete any PVC whose
# PV is pinned to a node that's no longer live (its StatefulSet recreates a
# fresh one against the current node automatically).
resource "terraform_data" "k8s_reconcile" {
  count = var.manage_floci ? 1 : 0

  # module.jenkins_ec2 too, not just module.eks: this whole chain (through
  # argocd_install, which starts 5 pods and needs real CPU to stabilize)
  # would otherwise run concurrently with the Jenkins EC2 container coming
  # up from nothing -- this machine can't handle that much at once (see
  # the "unexpected state 'terminated'" / helm --wait timeout failures
  # that happen when both run in parallel). Sequenced, not parallel.
  depends_on = [module.eks, module.jenkins_ec2]

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

      echo "cleaning up stale Terminating pods..."
      kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating"{print $2, $1}' | \
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

      helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
      helm repo update argo >/dev/null 2>&1

      helm upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace \
        -f "${var.platform_gitops_path}/k8s/argocd/values-core.yaml" \
        --wait --timeout 5m
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
