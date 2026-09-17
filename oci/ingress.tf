# The single Always Free Flexible Load Balancer, shared by web and
# api-gateway via host-based Ingress routing (not path-based -- Next.js's
# root-relative asset paths break under a path prefix without a basePath
# rebuild). A Service of type=LoadBalancer here is what triggers OKE's
# cloud-controller-manager to actually provision the OCI LB -- Terraform
# doesn't create it directly.

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.15.1"

  # Single node, single controller replica -- no HA needed at this traffic
  # level, and we don't have the budget for a second copy.
  set {
    name  = "controller.replicaCount"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "90Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "180Mi"
  }
}
