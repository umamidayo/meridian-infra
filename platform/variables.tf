variable "kubeconfig_path" {
  description = "Kubeconfig holding the cluster context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context to deploy into. kind names it kind-<cluster>."
  type        = string
  default     = "kind-meridian"
}

variable "github_repository" {
  description = "Repository (owner/name) that Argo CD syncs from and the pipeline exporter measures."
  type        = string
  default     = "umamidayo/meridian-infra"
}

variable "gitops_revision" {
  description = "Git revision (branch, tag or commit SHA) Argo CD deploys charts/pipeline-observability from. It must be pushed to GitHub."
  type        = string
  default     = "main"
}

variable "pipeline_observability_source" {
  description = "How charts/pipeline-observability is deployed: \"argocd\" syncs gitops_revision from GitHub (GitOps, used in CI); \"helm\" installs the local working tree, for testing unpushed chart changes."
  type        = string
  default     = "argocd"

  validation {
    condition     = contains(["argocd", "helm"], var.pipeline_observability_source)
    error_message = "pipeline_observability_source must be \"argocd\" or \"helm\"."
  }
}

variable "github_token" {
  description = "Optional GitHub token for the pipeline exporter (read-only actions/contents access). Empty uses the unauthenticated API."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slo" {
  description = "Pipeline SLO objectives passed to the pipeline-observability chart."
  type = object({
    success_objective          = optional(number, 0.95)
    duration_objective         = optional(number, 0.90)
    duration_threshold_seconds = optional(number, 900)
  })
  default = {}

  validation {
    condition     = var.slo.success_objective > 0 && var.slo.success_objective < 1 && var.slo.duration_objective > 0 && var.slo.duration_objective < 1
    error_message = "SLO objectives must be between 0 and 1 (exclusive), or the error budget is undefined."
  }
}

variable "node_ports" {
  description = "NodePorts for the UIs. platform/kind-cluster.yaml maps them to localhost 3000 (Grafana), 9090 (Prometheus) and 8088 (Argo CD)."
  type = object({
    grafana    = optional(number, 30030)
    prometheus = optional(number, 30090)
    argocd     = optional(number, 30080)
  })
  default = {}
}
