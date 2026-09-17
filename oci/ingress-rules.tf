# Host-based routing through the single ingress-nginx controller/LB from
# ingress.tf. Two DuckDNS names, both already pointed at the LB's IP:
#   ainotification.duckdns.org      -> web
#   ainotification-api.duckdns.org  -> api-gateway

resource "kubernetes_ingress_v1" "web" {
  metadata {
    name      = "web"
    namespace = kubernetes_namespace.ai_notification.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["ainotification.duckdns.org"]
      secret_name = "web-tls"
    }

    rule {
      host = "ainotification.duckdns.org"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "web"
              port {
                number = 3000
              }
            }
          }
        }
      }
    }
  }

  # web's own Deployment/Service are ArgoCD-managed now (Phase 4), not a
  # Terraform resource -- nothing left here to depend on but ingress-nginx
  # and the issuer, both still Terraform's.
  depends_on = [helm_release.ingress_nginx, kubernetes_manifest.letsencrypt_prod]
}

resource "kubernetes_ingress_v1" "api_gateway" {
  metadata {
    name      = "api-gateway"
    namespace = kubernetes_namespace.ai_notification.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["ainotification-api.duckdns.org"]
      secret_name = "api-gateway-tls"
    }

    rule {
      host = "ainotification-api.duckdns.org"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "api-gateway"
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }

  # api-gateway's Deployment/Service are ArgoCD-managed now (Phase 4), same
  # reasoning as web's Ingress above.
  depends_on = [helm_release.ingress_nginx, kubernetes_manifest.letsencrypt_prod]
}
