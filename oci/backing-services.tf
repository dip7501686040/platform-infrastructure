# Postgres/RabbitMQ/Redis were deployed directly here as Tier 1 (before
# ArgoCD existed), then handed off to ArgoCD in Phase 4 -- see
# platform-gitops/k8s/argocd/applications/backing-services-prod.yaml.
# `terraform state rm helm_release.backing_services` removed it from this
# state without touching the live resources (Postgres's PVC included --
# confirmed no data disruption through the handoff).
#
# Namespace and the app-secrets Secret stay Terraform-managed: they're not
# part of any Helm release ArgoCD would otherwise own, and every app
# service depends on the Secret existing regardless of who deploys them.

resource "kubernetes_namespace" "ai_notification" {
  metadata {
    name = "ai-notification"
  }
}

resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "app-secrets"
    namespace = kubernetes_namespace.ai_notification.metadata[0].name
  }

  data = {
    JWT_SECRET         = var.jwt_secret
    POSTGRES_PASSWORD  = var.postgres_password
    RABBITMQ_PASSWORD  = var.rabbitmq_password
    RABBITMQ_URL       = "amqp://notification:${var.rabbitmq_password}@rabbitmq:5672"
    ANTHROPIC_API_KEY  = ""
    OPENAI_API_KEY     = ""
    SMTP_PASSWORD      = ""
    STRIPE_SECRET_KEY  = ""
    STRIPE_WEBHOOK_SECRET = ""
    GOOGLE_CLIENT_SECRET  = var.google_client_secret
  }

  type = "Opaque"
}
