# ArgoCD itself (Tier 2 — cuttable under resource/budget pressure without
# taking Tier 1 down, per the original plan). Dex (SSO) and the
# notifications-controller are disabled — single-operator project, admin
# login is fine, no chat/email integrations needed. Everything else gets
# explicit modest resource requests, same discipline as ingress-nginx and
# cert-manager, since this is a single 2 OCPU/12GB node.

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.9.2"

  set {
    name  = "dex.enabled"
    value = "false"
  }
  set {
    name  = "notifications.enabled"
    value = "false"
  }

  # --enable-progressive-syncs -- required for the nest-services-prod
  # ApplicationSet's RollingSync strategy to do anything at all; the local
  # setup's own values-core.yaml comment confirms this is opt-in, not a
  # default, and silently has no effect without it.
  set {
    name  = "applicationSet.extraArgs[0]"
    value = "--enable-progressive-syncs"
  }

  # Probe timeouts below: the local setup hit a real incident on these
  # exact components at chart defaults (timeoutSeconds: 1) -- controller
  # and repoServer crash-looped (22 and 16 restarts) under concurrent load
  # despite not actually being broken, just briefly slow to answer.
  # Applying the same fix here proactively instead of waiting to
  # rediscover it.
  set {
    name  = "controller.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "250m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "256Mi"
  }
  set {
    name  = "controller.readinessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "controller.readinessProbe.failureThreshold"
    value = "6"
  }
  set {
    name  = "controller.livenessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "controller.livenessProbe.failureThreshold"
    value = "6"
  }

  set {
    name  = "repoServer.resources.requests.cpu"
    value = "30m"
  }
  set {
    name  = "repoServer.resources.requests.memory"
    value = "96Mi"
  }
  set {
    name  = "repoServer.resources.limits.cpu"
    value = "150m"
  }
  set {
    name  = "repoServer.resources.limits.memory"
    value = "192Mi"
  }
  set {
    name  = "repoServer.readinessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "repoServer.readinessProbe.failureThreshold"
    value = "6"
  }
  set {
    name  = "repoServer.livenessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "repoServer.livenessProbe.failureThreshold"
    value = "6"
  }

  set {
    name  = "server.resources.requests.cpu"
    value = "30m"
  }
  set {
    name  = "server.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "server.resources.limits.cpu"
    value = "150m"
  }
  set {
    name  = "server.resources.limits.memory"
    value = "128Mi"
  }
  set {
    name  = "server.readinessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "server.readinessProbe.failureThreshold"
    value = "6"
  }
  set {
    name  = "server.livenessProbe.timeoutSeconds"
    value = "10"
  }
  set {
    name  = "server.livenessProbe.failureThreshold"
    value = "6"
  }

  set {
    name  = "redis.resources.requests.cpu"
    value = "30m"
  }
  set {
    name  = "redis.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "redis.resources.limits.cpu"
    value = "150m"
  }
  set {
    name  = "redis.resources.limits.memory"
    value = "128Mi"
  }

  set {
    name  = "applicationSet.resources.requests.cpu"
    value = "30m"
  }
  set {
    name  = "applicationSet.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "applicationSet.resources.limits.cpu"
    value = "150m"
  }
  set {
    name  = "applicationSet.resources.limits.memory"
    value = "128Mi"
  }
}
