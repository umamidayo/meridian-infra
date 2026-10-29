# meridian-infra

OpenTofu configuration for the Meridian cloud environment, run against [LocalStack](https://localstack.cloud), with:

- **Supply chain security at SLSA Build L3**: signed provenance, an SBOM, and verify-before-deploy. See [docs/supply-chain.md](docs/supply-chain.md).
- **Artifact lifecycle rules and bucket policies** for releases, SBOMs, attestations and plans.
- **Pipeline SLIs/SLOs and DORA metrics** on Grafana with kube-prometheus-stack and Argo CD. See [docs/observability.md](docs/observability.md).

## What it creates

Root module (LocalStack):

| File            | Resources |
|-----------------|-----------|
| `network.tf`    | VPC (`10.20.0.0/16`), internet gateway, 2 public + 2 private subnets, public route table |
| `registry.tf`   | Self-hosted container registry (`registry:2.8.3` container on `localhost:5000`) storing image layers in the S3 bucket `meridian-dev-registry`; lifecycle rule that aborts stale uploads; TLS-only bucket policy |
| `storage.tf`    | S3 artifacts bucket: versioned, AES256-encrypted, public access blocked, lifecycle rules per artifact class, deny-only bucket policy |
| `iam.tf`        | GitHub OIDC provider, an artifact publisher role (assumable only from `main`), and a read-only artifact reader role |
| `outputs.tf`    | VPC/subnet IDs, registry URL and storage bucket, artifacts bucket name and ARN, artifact role ARNs |
| `versions.tf`   | Provider pins and the **S3 state backend** (bucket `meridian-tofu-state` in LocalStack, S3-native lockfile) |

`platform/` module (kind): kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Argo CD, and the
`charts/pipeline-observability` chart (GitHub Actions exporter, SLO recording and alerting rules, Pipeline SLO and DORA
dashboards). Its state sits in the same bucket under `meridian/dev/platform.tfstate`.

## Prerequisites

- OpenTofu >= 1.10 (CI uses 1.13.0)
- Docker
- A LocalStack auth token (the free tier is enough). Current LocalStack images refuse to start without one.
  Get it from https://app.localstack.cloud, or run `lstk login`.
- For the platform: [kind](https://kind.sigs.k8s.io) v0.33.0, kubectl and Python 3. About 4 GB of free memory for Docker.

ECR isn't in the free LocalStack license, so the registry is a plain Docker registry container managed by the
`kreuzwerker/docker` provider. Its image layers go to a LocalStack S3 bucket.

## Running locally on Windows

Needs Docker Desktop, OpenTofu and `lstk` (run `lstk login` once). Bash and the AWS CLI aren't needed. Syft,
Helm, promtool and Linux Python run from digest-pinned Docker images.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 up       # start LocalStack, create state bucket, init, apply
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 plan
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 output
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 test     # the same checks as CI's validate job
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 sbom     # CycloneDX SBOM -> meridian-infra.cdx.json
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 metrics  # DORA / pipeline SLO report from the GitHub API
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 destroy
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 down     # destroy, then stop LocalStack
```

Observability platform on kind:

```powershell
$env:TF_VAR_github_token = '<optional token with read access to Actions>'  # without it: 60 GitHub API requests/hour
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 platform-up    # kind cluster + kube-prometheus-stack + Argo CD + dashboards
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 platform-test  # end-to-end smoke test
powershell -ExecutionPolicy Bypass -File .\scripts\local.ps1 platform-down  # destroy and delete the cluster
```

Then open Grafana at http://localhost:3000 (user `admin`, password from `tofu -chdir=platform output -raw grafana_admin_password`),
Prometheus at http://localhost:9090 and Argo CD at http://localhost:8088. Argo CD deploys the chart from GitHub.
If `charts/` has changes that aren't pushed, `platform-up` installs it from your working tree with Helm instead and says so.

`-ExecutionPolicy Bypass` is only needed if your execution policy blocks local scripts.
Without `lstk`, set `$env:LOCALSTACK_AUTH_TOKEN` and the script falls back to `docker compose`.

## Running locally on Linux/macOS

```bash
export LOCALSTACK_AUTH_TOKEN=...
export TF_CLI_CONFIG_FILE=$PWD/tofu.tfrc   # provider allow-list, as in CI
docker compose up -d
bash scripts/bootstrap-state.sh      # creates the state bucket (needs the AWS CLI)
tofu init
tofu apply
tofu output

# Platform
kind create cluster --config platform/kind-cluster.yaml
tofu -chdir=platform init
tofu -chdir=platform apply -var gitops_revision=$(git rev-parse --abbrev-ref HEAD)   # add -var pipeline_observability_source=helm for unpushed chart changes
python3 scripts/smoke_platform.py
```

Push an image:

```bash
docker tag my-app:latest localhost:5000/meridian-app:1.0.0
docker push localhost:5000/meridian-app:1.0.0
```

## CI/CD and Git flow

`.github/workflows/opentofu.yml` runs on GitHub Actions:

| Job | PR targeting `main` | Push/merge to `main` |
|---|---|---|
| `Format and validate` | fmt, validate both modules with read-only lockfiles, `tofu test`, exporter unit tests, chart lint, promtool rule checks and tests, chart digest check | same |
| `Build and SBOM` | source bundle (`git archive`) + CycloneDX SBOM | same, plus a signed SBOM attestation |
| `SLSA provenance` | skipped | SLSA Build L3 provenance from `slsa-github-generator` |
| `Plan` / `Plan and apply` | integrity-check the bundle, plan against a fresh LocalStack | verify provenance, plan, apply, publish bundle/SBOM/provenance/plan to the artifacts bucket |
| `Platform (kind)` | deploy the platform on kind from the bundle (Argo CD syncs the PR commit), smoke test | verify provenance, then the same |

`.github/workflows/pipeline-metrics.yml` posts a DORA and pipeline-SLO report daily (also runnable manually).

Workflow:

1. Branch off `main`, change `.tf` files, push, open a PR.
2. CI must pass.
3. Merge the PR into `main`. The push to `main` builds, attests, verifies and applies.

Setup on GitHub:

- Add the repository secret **`LOCALSTACK_AUTH_TOKEN`** (Settings → Secrets and variables → Actions). Use a CI auth token.
- Protect `main` (Settings → Branches): require a pull request with a review, block force pushes, and require the
  `Format and validate`, `Build and SBOM`, `Plan` and `Platform (kind)` status checks. This is the source half of SLSA,
  and only `main` can publish artifacts.

> **Note:** LocalStack in CI is ephemeral. Each run starts empty, so the state bucket and the published evidence only
> live for that job, and every apply on `main` builds the environment from scratch. That's fine for validating the
> config. Provenance and SBOMs stay downloadable as workflow artifacts, and the SBOM attestation stays in GitHub. For
> persistent state, point the backend at a long-lived LocalStack instance or at real AWS.
