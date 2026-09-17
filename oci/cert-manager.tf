# cert-manager issues and auto-renews the actual TLS certs (Let's Encrypt).
# The ClusterIssuer + Certificate resources that use its CRDs go in a
# SEPARATE apply (cert-manager-issuer.tf) -- Terraform's kubernetes_manifest
# needs the CRD to already exist at plan time to validate against, which it
# doesn't yet in the same apply that installs it. Same two-step pattern as
# ingress-nginx -> get its LB IP -> then the Ingress rules that needed it.

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.21.2"

  set {
    name  = "crds.enabled"
    value = "true"
  }
  set {
    name  = "resources.requests.cpu"
    value = "30m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "150m"
  }
  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }
}
