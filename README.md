# meridian-infra

OpenTofu configuration for the Meridian cloud environment, run against [LocalStack](https://localstack.cloud).

## What it creates

| File            | Resources |
|-----------------|-----------|
| `network.tf`    | VPC (`10.20.0.0/16`), internet gateway, 2 public + 2 private subnets, public route table |
| `registry.tf`   | Self-hosted container registry (`registry:2.8.3` container on `localhost:5000`) storing image layers in the S3 bucket `meridian-dev-registry` |
| `storage.tf`    | S3 artifacts bucket: versioned, AES256-encrypted, public access blocked |
| `outputs.tf`    | VPC/subnet IDs, registry URL and storage bucket, artifacts bucket name and ARN |
| `versions.tf`   | Provider pins and the **S3 state backend** (bucket `meridian-tofu-state` in LocalStack, S3-native lockfile) |

## Prerequisites

- OpenTofu >= 1.10 (CI uses 1.13.0)
- Docker
- AWS CLI (used by `scripts/bootstrap-state.sh`)
- A LocalStack auth token (the free tier is enough). Current LocalStack images refuse to start without one.
  Get it from https://app.localstack.cloud, or run `lstk login`.

ECR isn't in the free LocalStack license, so the registry is a plain Docker registry container managed by the
`kreuzwerker/docker` provider. Its image layers go to a LocalStack S3 bucket.

## Running locally

```bash
export LOCALSTACK_AUTH_TOKEN=...      # PowerShell: $env:LOCALSTACK_AUTH_TOKEN = "..."
docker compose up -d
bash scripts/bootstrap-state.sh      # creates the state bucket
# Docker Desktop on Windows only (PowerShell: $env:DOCKER_HOST = "npipe:////./pipe/dockerDesktopLinuxEngine")
export DOCKER_HOST=npipe:////./pipe/dockerDesktopLinuxEngine
tofu init
tofu plan
tofu apply
tofu output
```

Push an image:

```bash
docker tag my-app:latest localhost:5000/meridian-app:1.0.0
docker push localhost:5000/meridian-app:1.0.0
```

## CI/CD and Git flow

`.github/workflows/opentofu.yml` runs on GitHub Actions:

| Trigger              | Jobs |
|----------------------|------|
| PR targeting `main`  | `fmt -check`, `validate`, then `plan` against a fresh LocalStack; the plan is posted to the job summary |
| Push/merge to `main` | Same, then `apply` and print outputs |
| Manual dispatch      | Same as push |

Workflow:

1. Branch off `main`, change `.tf` files, push, open a PR.
2. CI must pass (fmt, validate, plan).
3. Merge the PR into `main`. The push to `main` triggers `apply`.

Setup on GitHub:

- Add the repository secret **`LOCALSTACK_AUTH_TOKEN`** (Settings → Secrets and variables → Actions). Use a CI auth token.
- Recommended: protect `main` (Settings → Branches), require a pull request, and require the
  `Format and validate` and `Plan` status checks.

> **Note:** LocalStack in CI is ephemeral. Each run starts empty, so the state bucket only lives for that job,
> and every apply on `main` builds the environment from scratch. That's fine for validating the config. For
> persistent state, point the backend at a long-lived LocalStack instance or at real AWS.
