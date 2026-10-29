# Supply chain security

Every change that reaches `main` is built once, described by an SBOM, given signed
SLSA provenance, and verified before anything is planned or applied. Deploy jobs
never check out the repository: they run only the bundle the build job produced.

```
validate ──► build ──────────────► provenance ──► plan-apply  (verify → plan → apply → publish evidence)
             git archive bundle    slsa-github-   └► platform (verify → kind → Helm/Argo CD → smoke test)
             CycloneDX SBOM        generator L3
             SBOM attestation
```

## SLSA level

| Requirement | How it is met |
|---|---|
| **Build L1**: provenance exists | `slsa-framework/slsa-github-generator` generic generator, in-toto SLSA v1 provenance (`meridian-infra.intoto.jsonl`) |
| **Build L2**: hosted platform, signed provenance | GitHub-hosted runners; keyless Sigstore signature, recorded in the public Rekor log |
| **Build L3**: provenance unforgeable by the build | Provenance is created and signed in an isolated reusable workflow. Build steps never see the signing identity, and every job runs on a fresh ephemeral VM |
| Consumption: verify before use | `plan-apply` and `platform` run `slsa-verifier verify-artifact` against the source repo and branch before unpacking the bundle |

One caveat about the generic generator: the build job computes the subject hashes and hands them to the generator. The generator does attest who built them, from which commit and trigger, and that can't be forged. This is the documented L3 model for `generator_generic_slsa3`.

Outside `main` (PRs, dispatches from other branches), provenance isn't generated. Deploy jobs then only check the bundle against the build job's SHA-256 output, and nothing is applied.

### Source (configure on GitHub)

The repository can't enforce source integrity by itself. To complete the picture:

- Protect `main`: require PRs, at least one review, and the status checks `Format and validate`, `Build and SBOM`, `Plan` and `Platform (kind)`.
- Block force pushes and branch deletion on `main`. The artifact publisher's OIDC trust is limited to `refs/heads/main` (see `iam.tf`), so whoever can push to `main` can publish.

## Dependencies

| Dependency | Control |
|---|---|
| OpenTofu providers | `tofu.tfrc` allow-lists provider sources. `.terraform.lock.hcl` (root and `platform/`) records hashes for linux/darwin amd64+arm64 and windows amd64. CI runs `init -lockfile=readonly`, and OpenTofu verifies registry GPG signatures on every download |
| GitHub Actions | Pinned to commit SHAs with a version comment. Dependabot updates them weekly, with a 7-day cooldown on new releases. The SLSA generator is pinned by tag because slsa-verifier identifies the trusted builder by tag |
| Container images | Pinned by digest: LocalStack, `registry`, the exporter's Python base, Syft, Prometheus (promtool), Helm, the kind node image |
| Helm charts | `platform/charts.lock.json` pins version and SHA-256. `scripts/verify_charts.py` re-downloads and checks them on every CI run, and OpenTofu reads versions from the same file |
| Exporter | Python standard library only, mounted from a ConfigMap, so there are no third-party packages or image builds |

Known gaps:

- The Helm provider downloads charts itself at apply time. The digest check runs in `validate`, not inside the provider, so a chart replaced in between wouldn't be caught.
- Images referenced *inside* kube-prometheus-stack and Argo CD are tag-pinned by those charts, not digest-pinned. To close this, mirror them into the local registry, or enforce signatures with an admission policy such as Kyverno `verifyImages`.
- Argo CD pulls `charts/pipeline-observability` from GitHub at the commit SHA under test. That's the same commit as the attested bundle, but Argo CD doesn't verify the attestation itself.

## SBOM

The build job runs `tofu init` for both root modules, so the provider binaries are on disk. Syft then scans the checkout and produces a CycloneDX JSON SBOM covering:

- OpenTofu providers from the lockfiles, plus the Go modules compiled into each provider binary
- GitHub Actions referenced by the workflows
- The three Helm charts, added by `scripts/verify_charts.py` with their SHA-256

The job summary shows counts by package type. On `main` the SBOM is also attested with `actions/attest` (in-toto, CycloneDX predicate) against the bundle, and the SLSA provenance covers it as a second subject.

Generate one locally with `.\scripts\local.ps1 sbom` (Windows). Syft runs in Docker.

## Verifying a release yourself

```bash
gh run download <run-id> --repo umamidayo/meridian-infra -n release -n meridian-infra.intoto.jsonl

slsa-verifier verify-artifact meridian-infra.tar.gz meridian-infra.cdx.json \
  --provenance-path meridian-infra.intoto.jsonl \
  --source-uri github.com/umamidayo/meridian-infra --source-branch main

gh attestation verify meridian-infra.tar.gz --repo umamidayo/meridian-infra \
  --predicate-type https://cyclonedx.org/bom
```

## Artifact storage

After a successful apply on `main`, CI assumes `meridian-dev-artifact-publisher` and writes the evidence to the artifacts bucket:

| Prefix | Content | Lifecycle (defaults, `var.artifact_retention`) |
|---|---|---|
| `releases/<sha>/` | source bundle | Standard-IA at 30 days, Glacier at 90, expire at 400 |
| `sboms/<sha>/` | CycloneDX SBOM | same as releases |
| `attestations/<sha>/` | SLSA provenance | Standard-IA at 30 days, Glacier at 90, expire at 730 (outlives the releases it describes) |
| `plans/<sha>/` | `tofu show -json` plan | expire at 30 days (plans can hold sensitive values) |
| `metrics/` | pipeline reports | expire at 90 days |
| whole bucket | | noncurrent versions expire at 30 days; incomplete multipart uploads abort at 7; expired delete markers are removed |

Bucket policy (`storage.tf`). Every statement is a `Deny`; access itself comes from the IAM roles:

| Statement | Effect |
|---|---|
| `DenyInsecureTransport` | rejects non-TLS requests (`var.require_secure_transport`, on by default) |
| `DenyWrongEncryptionHeader` | rejects uploads that request anything other than SSE-S3 or SSE-KMS |
| `DenyWritesExceptPublisher` | only the publisher role and admins may write |
| `ProtectSupplyChainEvidence` | nobody but admins may delete releases, SBOMs or attestations; lifecycle expiry still applies |

Admins default to the account root; override them with `var.artifact_admin_principal_arns`. LocalStack stores these policies but only enforces them with `ENFORCE_IAM=1`. `tests/storage.tftest.hcl` checks the rules and statements offline.
