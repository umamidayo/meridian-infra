output "grafana_url" {
  description = "Grafana; dashboards are in the Meridian folder."
  value       = "http://localhost:3000"
}

output "grafana_admin_password" {
  description = "Grafana admin password (user: admin)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "prometheus_url" {
  description = "Prometheus UI."
  value       = "http://localhost:9090"
}

output "argocd_url" {
  description = "Argo CD UI (user: admin). Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}', then base64-decode it."
  value       = "http://localhost:8088"
}

output "gitops_revision" {
  description = "Git revision Argo CD deploys the pipeline-observability chart from."
  value       = var.gitops_revision
}
