# Reuses the exact dashboard JSON already written for local dev + the
# earlier load-test work, unchanged -- same datasource uids ("prometheus",
# "jaeger") provisioned below so the panels resolve without editing the
# JSON. tenant-observability.json also references a "loki" datasource --
# no Loki deployed here (out of scope for this pass), so those specific
# panels will show a missing-datasource error; every other panel works.

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }

  data = {
    "platform-health.json"      = file("${path.module}/../../ai-notification-system/infra/grafana/provisioning/dashboards/platform-health.json")
    "tenant-observability.json" = file("${path.module}/../../ai-notification-system/infra/grafana/provisioning/dashboards/tenant-observability.json")
    "grafana-phaseF.json"       = file("${path.module}/../../ai-notification-system/loadtest/grafana-phaseF.json")
  }
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "10.5.15"

  values = [<<-EOT
    persistence:
      enabled: false
    resources:
      requests:
        cpu: 30m
        memory: 96Mi
      limits:
        cpu: 150m
        memory: 192Mi
    datasources:
      datasources.yaml:
        apiVersion: 1
        datasources:
          - name: Prometheus
            type: prometheus
            uid: prometheus
            access: proxy
            url: http://prometheus-server.observability.svc.cluster.local
            isDefault: true
          - name: Jaeger
            type: jaeger
            uid: jaeger
            access: proxy
            url: http://jaeger.observability.svc.cluster.local:16686
    dashboardProviders:
      dashboardproviders.yaml:
        apiVersion: 1
        providers:
          - name: default
            orgId: 1
            folder: ""
            type: file
            disableDeletion: false
            editable: true
            options:
              path: /var/lib/grafana/dashboards/default
    dashboardsConfigMaps:
      default: grafana-dashboards
  EOT
  ]

  depends_on = [helm_release.prometheus, kubernetes_service_v1.jaeger, kubernetes_config_map_v1.grafana_dashboards]
}
