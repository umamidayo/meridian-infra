# Pipeline SLOs, DORA metrics and the platform

`platform/` is a second OpenTofu root module. It deploys onto a local kind cluster, and its
state sits in the same LocalStack bucket under its own key:

| Component | Source | URL (local) |
|---|---|---|
| kube-prometheus-stack (Prometheus, Alertmanager, Grafana, operator) | Helm, `platform/main.tf` | Grafana http://localhost:3000, Prometheus http://localhost:9090 |
| Argo CD | Helm, `platform/main.tf` | http://localhost:8088 |
| `pipeline-observability` (exporter, SLO rules, dashboards) | `charts/pipeline-observability`, deployed by Argo CD (GitOps) or Helm | |

Grafana user is `admin`; password: `tofu -chdir=platform output -raw grafana_admin_password`.
Argo CD user is `admin`; password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'`, base64-decoded.

## How chart changes get deployed

`var.pipeline_observability_source` controls this:

- `argocd` (default, used in CI): an Argo CD Application syncs `charts/pipeline-observability` from GitHub at
  `var.gitops_revision`. CI sets that to the commit under test.
- `helm`: OpenTofu installs the chart from the working tree, for chart changes that aren't pushed yet.

`.\scripts\local.ps1 platform-up` chooses for you. It uses `helm` when `charts/` differs from the pushed branch,
and `argocd` otherwise. Force either mode with `$env:PIPELINE_SOURCE`.

## Pipeline exporter

`charts/pipeline-observability/files/pipeline_exporter.py` polls the GitHub Actions API every 5 minutes and
serves `/metrics`. It uses only the Python standard library, so the image is just a digest-pinned
`python:3.12-alpine`. Without a token it uses the unauthenticated API (60 requests/hour, enough for one repo).
Set `TF_VAR_github_token` to a token with read access to Actions to raise that.

The same script makes reports: `python3 pipeline_exporter.py --once --format markdown|json|prometheus`.
`.github/workflows/pipeline-metrics.yml` runs it daily and writes the report to the job summary, and
`.\scripts\local.ps1 metrics` runs it locally.

## SLIs and SLOs

Each SLI is reported per workflow for the 1d, 7d and 28d windows.

| SLI | Definition | Objective (28d) |
|---|---|---|
| Success | successful / (successful + failed + timed out) runs on `main`. Cancelled runs and PR runs are excluded: a failing PR is the pipeline working, not failing | 95% |
| Duration | share of successful runs that finish within 15 minutes | 90% |
| Queue time | creation to start, p50/p90/p99 (reported, no objective) | |

Objectives are chart values (`slo.*`), set from `var.slo` in `platform/`.

Recording rules turn the SLIs into `meridian:pipeline_error_budget_burn_rate` and
`meridian:pipeline_error_budget_remaining`. Pipelines run a few times a day, not thousands of times an hour,
so the multi-window burn-rate alerts use days rather than minutes:

| Alert | Condition | Severity |
|---|---|---|
| `PipelineErrorBudgetFastBurn` | burn > 6x over 1d and > 2x over 7d | critical |
| `PipelineErrorBudgetSlowBurn` | burn > 2x over 7d and > 1x over 28d | warning |
| `PipelineSLOViolated` | 28d error budget below 0 | warning |
| `DeploymentPipelineBroken` | deploys to `main` failing for over an hour | critical |
| `PipelineExporterDown` | no successful GitHub refresh for 15 minutes | warning |
| `PipelineExporterRateLimited` | under 10 API requests left | info |

`tests/prometheus/slo_rules_test.yaml` unit-tests these with `promtool test rules`.

## DORA metrics

A *deployment* is a run of `opentofu.yml` on `main` triggered by `push` or `workflow_dispatch`. It's
successful when the run (verify, plan, apply, publish) succeeds.

| Metric | Definition | Elite band |
|---|---|---|
| Deployment frequency | successful deployments per day | >= 1/day |
| Lead time for changes | for every commit a deployment shipped (GitHub compare API, previous successful deploy to this one): commit author time to deployment finished | < 1 day |
| Change failure rate | failed deployments / all deployments | <= 5% |
| Time to restore | first failed deployment after a success, to the next successful deployment | < 1 hour |

Change failure rate and time to restore measure the *deployment pipeline*. They don't capture production
incidents found later, because this environment has no production traffic to observe. If an incident
tracker gets added, feed its open and close times into the same metrics.

The DORA dashboard also shows Argo CD syncs by result (`argocd_app_sync_total`), which count GitOps
deployments inside the cluster.

## Dashboards

Both are in the Grafana **Meridian** folder, provisioned from ConfigMaps by the Grafana sidecar:

- **Meridian / Pipeline SLOs** (`meridian-pipeline-slo`): SLIs against objectives, error budget left, burn rate, duration and queue percentiles, runs by result, exporter health.
- **Meridian / DORA metrics** (`meridian-dora`): the four keys, colored by DORA band, plus trends, last deployment, open incident age and Argo CD syncs.

## Testing

- `.\scripts\local.ps1 test` covers tofu tests, exporter unit tests, chart lint, and promtool rule checks and unit tests (the same set as CI `validate`).
- `.\scripts\local.ps1 platform-test` (or `python3 scripts/smoke_platform.py`) is the end-to-end check, also run by CI's `Platform (kind)` job. It confirms the workloads are available, Argo CD is synced (or the Helm release is up), Prometheus scrapes the exporter and Argo CD, the SLO rules are loaded, and both dashboards are provisioned.
