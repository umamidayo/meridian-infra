locals {
  charts = { for c in jsondecode(file("${path.module}/charts.lock.json")).charts : c.name => c }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

# Always created, since a sensitive value cannot drive count; the exporter treats an empty token as none.
resource "kubernetes_secret_v1" "github_token" {
  metadata {
    name      = "github-token"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    token = var.github_token
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = local.charts["kube-prometheus-stack"].repository
  chart      = "kube-prometheus-stack"
  version    = local.charts["kube-prometheus-stack"].version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  timeout    = 900

  values = [yamlencode({
    # kind binds etcd, the scheduler, the controller manager and kube-proxy to localhost,
    # so scraping them only produces false alerts.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    defaultRules = {
      rules = {
        etcd                   = false
        kubeControllerManager  = false
        kubeProxy              = false
        kubeSchedulerAlerting  = false
        kubeSchedulerRecording = false
      }
    }

    prometheus = {
      service = { type = "NodePort", nodePort = var.node_ports.prometheus }
      prometheusSpec = {
        # Pick up ServiceMonitors and rules from every release (Argo CD, pipeline-observability), not just this one.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        probeSelectorNilUsesHelmValues          = false
        retention                               = "15d"
        resources                               = { requests = { cpu = "100m", memory = "512Mi" } }
      }
    }

    grafana = {
      admin   = { existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name }
      service = { type = "NodePort", nodePort = var.node_ports.grafana }
      sidecar = {
        dashboards = {
          enabled          = true
          label            = "grafana_dashboard"
          labelValue       = "1"
          searchNamespace  = "ALL"
          folderAnnotation = "grafana_folder"
          provider         = { foldersFromFilesStructure = true }
        }
      }
    }
  })]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = local.charts["argo-cd"].repository
  chart      = "argo-cd"
  version    = local.charts["argo-cd"].version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
    configs = {
      # Plain HTTP on localhost only; TLS terminates at an ingress anywhere else.
      params = { "server.insecure" = true }
    }
    server = {
      service = { type = "NodePort", nodePortHttp = var.node_ports.argocd }
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
    }
    # argocd_app_sync_total from the controller feeds the GitOps panel on the DORA dashboard.
    controller = { metrics = { enabled = true, serviceMonitor = { enabled = true } } }
    repoServer = { metrics = { enabled = true, serviceMonitor = { enabled = true } } }
  })]

  # ServiceMonitor CRDs come from kube-prometheus-stack.
  depends_on = [helm_release.kube_prometheus_stack]
}

# Applications live in their own release: Helm validates every manifest before
# installing, so they cannot ship in the same release as the Application CRD.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = local.charts["argocd-apps"].repository
  chart      = "argocd-apps"
  version    = local.charts["argocd-apps"].version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  values = [yamlencode({
    applications = var.pipeline_observability_source != "argocd" ? {} : {
      pipeline-observability = {
        namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = "https://github.com/${var.github_repository}.git"
          targetRevision = var.gitops_revision
          path           = "charts/pipeline-observability"
          helm           = { valuesObject = local.pipeline_observability_values }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
          retry     = { limit = 10, backoff = { duration = "10s", factor = 2, maxDuration = "3m" } }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}

locals {
  pipeline_observability_values = {
    github = {
      repository  = var.github_repository
      tokenSecret = { name = kubernetes_secret_v1.github_token.metadata[0].name, key = "token" }
    }
    slo = {
      successObjective         = var.slo.success_objective
      durationObjective        = var.slo.duration_objective
      durationThresholdSeconds = var.slo.duration_threshold_seconds
    }
  }
}

# Inner loop for chart changes that are not on GitHub yet: install the chart
# straight from the working tree instead of through Argo CD.
resource "helm_release" "pipeline_observability" {
  count = var.pipeline_observability_source == "helm" ? 1 : 0

  name      = "pipeline-observability"
  chart     = "${path.module}/../charts/pipeline-observability"
  namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  values    = [yamlencode(local.pipeline_observability_values)]

  # ServiceMonitor and PrometheusRule CRDs come from kube-prometheus-stack.
  depends_on = [helm_release.kube_prometheus_stack]
}
