# Tier 2 (disposable) -- Prometheus/Grafana/Jaeger/OTel collector. All
# emptyDir, no PVCs: OCI Block Volumes have a 50GB minimum regardless of
# what's requested (confirmed live on Postgres's PVC earlier), so giving
# each of these its own volume would burn 150GB+ of the 200GB Always Free
# block-storage budget on data that's fine to lose on a pod restart --
# unlike Postgres's actual application data. Meant to be stood up before a
# diagnosis/demo session and torn down after, not run continuously.

resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
  }
}

# --- Prometheus ---
# persistentVolume disabled (emptyDir instead), retention trimmed to 3
# days, alertmanager off (no paging destination exists for a solo
# project). kube-state-metrics and node-exporter both kept -- small,
# single pods, real value (pod restart counts / resource requests as
# metrics, and OS-level disk/network visibility respectively -- the
# latter matters concretely after the DiskPressure incident earlier).
# The default kubernetes-nodes-cadvisor scrape job is what gives
# per-pod CPU/memory -- no custom RBAC needed this time since Prometheus
# runs in the same cluster it's scraping (unlike the local setup's
# cross-cluster token workaround).
resource "helm_release" "prometheus" {
  name       = "prometheus"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "29.30.0"

  values = [<<-EOT
    server:
      retention: "3d"
      persistentVolume:
        enabled: false
      resources:
        requests:
          cpu: 50m
          memory: 256Mi
        limits:
          cpu: 250m
          memory: 512Mi
    alertmanager:
      enabled: false
    prometheus-pushgateway:
      enabled: false
    kube-state-metrics:
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 50m
          memory: 64Mi
    prometheus-node-exporter:
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 32Mi
  EOT
  ]
}

# --- Jaeger (all-in-one, in-memory) ---
# Plain Deployment/Service rather than the jaegertracing/jaeger chart --
# that chart's default posture assumes a real backing store (Cassandra/ES);
# the all-in-one image alone is exactly "collector+query+storage in one
# process, in memory" with nothing else to configure or disable.
resource "kubernetes_deployment_v1" "jaeger" {
  metadata {
    name      = "jaeger"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels    = { app = "jaeger" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "jaeger" }
    }
    template {
      metadata {
        labels = { app = "jaeger" }
      }
      spec {
        container {
          name = "jaeger"
          # Fully-qualified -- OKE's CRI-O runtime rejects a bare
          # "jaegertracing/all-in-one" reference as ambiguous (same class
          # of issue hit on the backing-services images earlier).
          image = "docker.io/jaegertracing/all-in-one:1.65.0"

          env {
            name  = "COLLECTOR_OTLP_ENABLED"
            value = "true"
          }

          port {
            name           = "otlp-grpc"
            container_port = 4317
          }
          port {
            name           = "ui"
            container_port = 16686
          }

          resources {
            requests = {
              cpu    = "30m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "jaeger" {
  metadata {
    name      = "jaeger"
    namespace = kubernetes_namespace.observability.metadata[0].name
  }
  spec {
    selector = { app = "jaeger" }
    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }
    port {
      name        = "ui"
      port        = 16686
      target_port = 16686
    }
  }
}

# --- OTel Collector ---
# Release name MUST be "otel-collector" -- every app service already has
# OTEL_EXPORTER_OTLP_ENDPOINT baked into the nest-service chart default,
# pointing at "http://otel-collector-opentelemetry-collector...:4317"
# (this chart's standard <release>-<chart> service naming). Matching that
# name means traces start flowing the moment this deploys, no changes
# needed across 13 services' values files.
resource "helm_release" "otel_collector" {
  name       = "otel-collector"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.173.1"

  values = [<<-EOT
    mode: deployment
    replicaCount: 1
    # This chart version stopped defaulting image.repository -- and the
    # core (non-contrib) image needs command.name switched to match its
    # actual binary name. Fully-qualified for the same CRI-O short-name
    # reason as every other image this session.
    image:
      repository: docker.io/otel/opentelemetry-collector
    command:
      name: otelcol
    resources:
      requests:
        cpu: 30m
        memory: 96Mi
      limits:
        cpu: 150m
        memory: 192Mi
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
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlp/jaeger]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [prometheus]
          logs: null
  EOT
  ]

  depends_on = [kubernetes_service_v1.jaeger]
}
