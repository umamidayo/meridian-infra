<#
.SYNOPSIS
  Runs the Meridian OpenTofu environment against LocalStack on Windows.

.DESCRIPTION
  Needs only Docker Desktop, OpenTofu and either lstk (`lstk login` done) or a
  LOCALSTACK_AUTH_TOKEN for docker compose. No bash or AWS CLI required.
  The platform actions also need kind and kubectl. Syft, Helm, promtool and
  Linux Python run from digest-pinned Docker images.

.EXAMPLE
  .\scripts\local.ps1 up              # start LocalStack, create state bucket, init, apply
  .\scripts\local.ps1 plan
  .\scripts\local.ps1 test            # tofu test, exporter unit tests, chart lint, promtool rule tests
  .\scripts\local.ps1 sbom            # CycloneDX SBOM of the repo, providers and charts
  .\scripts\local.ps1 metrics         # DORA / pipeline SLO report from the GitHub API
  .\scripts\local.ps1 platform-up     # kind cluster + kube-prometheus-stack + Argo CD
  .\scripts\local.ps1 platform-test   # smoke-test the platform
  .\scripts\local.ps1 platform-down   # destroy the platform and delete the kind cluster
  .\scripts\local.ps1 destroy
  .\scripts\local.ps1 down            # destroy resources, then stop LocalStack
#>
param(
    [ValidateSet('start', 'bootstrap', 'init', 'plan', 'apply', 'up', 'output', 'destroy', 'down',
        'test', 'sbom', 'metrics', 'platform-up', 'platform-test', 'platform-down')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Endpoint = if ($env:LOCALSTACK_ENDPOINT) { $env:LOCALSTACK_ENDPOINT } else { 'http://localhost:4566' }
$StateBucket = if ($env:STATE_BUCKET) { $env:STATE_BUCKET } else { 'meridian-tofu-state' }
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PlatformDir = Join-Path $RepoRoot 'platform'
$ClusterName = 'meridian'
$Repository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'umamidayo/meridian-infra' }

# Same images CI uses, pinned by digest.
$SyftImage = 'anchore/syft:v1.55.0@sha256:4cc92b64ca74ffca4c94d4c8fcc01f217731375300be14d0b6eeb2e82eaa110a'
$PythonImage = 'python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0'
$HelmImage = 'alpine/helm:3.15.1@sha256:206a8f61a27b8d44b2a687bdb9835f38fc6c931f225cee5ad04aaa84658d196e'
$PrometheusImage = 'prom/prometheus:v3.15.1@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2'

# Enforce the provider allow-list unless the caller brought their own CLI config.
if (-not $env:TF_CLI_CONFIG_FILE) { $env:TF_CLI_CONFIG_FILE = Join-Path $RepoRoot 'tofu.tfrc' }

function Test-LocalStack {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Endpoint/_localstack/health" -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# Runs a native command whose stderr and exit code are expected; Windows PowerShell 5.1
# turns redirected native stderr into a terminating error under ErrorActionPreference=Stop.
function Invoke-Quiet {
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>$null
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "$Name is not on PATH. $Hint" }
}

function Start-LocalStack {
    if (Test-LocalStack) {
        Write-Host "LocalStack is already running at $Endpoint."
        return
    }
    if (Get-Command lstk -ErrorAction SilentlyContinue) {
        Invoke-Native lstk @('start', '--non-interactive')
    } elseif ($env:LOCALSTACK_AUTH_TOKEN) {
        Invoke-Native docker @('compose', '-f', (Join-Path $RepoRoot 'docker-compose.yml'), 'up', '-d')
    } else {
        throw 'Install lstk and run `lstk login`, or set LOCALSTACK_AUTH_TOKEN to use docker compose.'
    }

    Write-Host "Waiting for LocalStack at $Endpoint..."
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-LocalStack) { return }
        Start-Sleep -Seconds 2
    }
    throw "LocalStack did not become healthy at $Endpoint."
}

# Plain S3 REST calls: LocalStack accepts unsigned requests, so no AWS CLI is needed.
function New-StateBucket {
    $uri = "$Endpoint/$StateBucket"
    try {
        Invoke-WebRequest -UseBasicParsing -Method Head -Uri $uri | Out-Null
        Write-Host "State bucket $StateBucket already exists."
        return
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -ne 404) { throw }
    }

    Invoke-WebRequest -UseBasicParsing -Method Put -Uri $uri | Out-Null
    $versioning = '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>'
    Invoke-WebRequest -UseBasicParsing -Method Put -Uri "$uri`?versioning" -ContentType 'application/xml' -Body $versioning | Out-Null
    Write-Host "Created state bucket $StateBucket."
}

function Invoke-Tofu {
    param([string[]]$Arguments, [string]$Dir = $RepoRoot)
    # output, validate and test reject -input; every other subcommand used here accepts it.
    if ($Arguments[0] -notin @('output', 'validate', 'test')) { $Arguments = @($Arguments) + '-input=false' }
    Push-Location $Dir
    try {
        Invoke-Native tofu $Arguments
    } finally {
        Pop-Location
    }
}

function Initialize-Tofu {
    param([string]$Dir = $RepoRoot)
    Start-LocalStack
    New-StateBucket
    Invoke-Tofu @('init') $Dir
}

function Invoke-Container {
    param([string[]]$Arguments)
    Invoke-Native docker (@('run', '--rm', '-v', "${RepoRoot}:/src", '-w', '/src') + $Arguments)
}

function Invoke-Tests {
    Invoke-Tofu @('init', '-backend=false')
    Invoke-Tofu @('validate')
    Invoke-Tofu @('test')
    Invoke-Tofu @('init', '-backend=false') $PlatformDir
    Invoke-Tofu @('validate') $PlatformDir

    Invoke-Container @($PythonImage, 'python', '-I', '-m', 'unittest', 'discover', '-s', 'tests')
    Invoke-Container @($HelmImage, 'lint', '--strict', 'charts/pipeline-observability')

    # Render the PrometheusRule spec the way CI does (helm template | yq .spec), then check and unit-test it.
    $rendered = Invoke-Container @($HelmImage, 'template', 'po', 'charts/pipeline-observability', '--show-only', 'templates/prometheusrule.yaml')
    $lines = ($rendered -join "`n") -split "`n"
    $start = [array]::IndexOf($lines, 'spec:') + 1
    $spec = ($lines[$start..($lines.Length - 1)] | ForEach-Object { if ($_.Length -ge 2) { $_.Substring(2) } else { $_ } }) -join "`n"
    [IO.File]::WriteAllText((Join-Path $RepoRoot 'tests\prometheus\rules.yaml'), "$spec`n")
    Invoke-Container @('-w', '/src/tests/prometheus', '--entrypoint', 'promtool', $PrometheusImage, 'check', 'rules', 'rules.yaml')
    Invoke-Container @('-w', '/src/tests/prometheus', '--entrypoint', 'promtool', $PrometheusImage, 'test', 'rules', 'slo_rules_test.yaml')
    Write-Host 'All tests passed.'
}

function New-Sbom {
    # Provider binaries must be present for Syft to catalog their Go modules.
    Invoke-Tofu @('init', '-backend=false')
    Invoke-Tofu @('init', '-backend=false') $PlatformDir
    $sha = (Invoke-Quiet git @('-C', $RepoRoot, 'rev-parse', 'HEAD')).Output
    Invoke-Container @($SyftImage, 'scan', 'dir:/src', '--source-name', 'meridian-infra', '--source-version', "$sha",
        '--exclude', './.git/**', '--exclude', './meridian-infra.cdx.json', '-q', '-o', 'cyclonedx-json=/src/meridian-infra.cdx.json')
    Invoke-Container @($PythonImage, 'sh', '-c',
        'python -I scripts/verify_charts.py --sbom meridian-infra.cdx.json && python -I scripts/sbom_summary.py meridian-infra.cdx.json')
    Write-Host "SBOM written to $(Join-Path $RepoRoot 'meridian-infra.cdx.json')"
}

function Show-Metrics {
    $envArgs = @('-e', "GITHUB_REPOSITORY=$Repository")
    if ($env:GITHUB_TOKEN) { $envArgs += @('-e', 'GITHUB_TOKEN') }
    Invoke-Container ($envArgs + @($PythonImage, 'python', '-I', 'charts/pipeline-observability/files/pipeline_exporter.py', '--once'))
}

# Argo CD can only deploy what is on GitHub. When charts/ differs from the pushed
# branch, install the working tree with Helm instead, unless PIPELINE_SOURCE says otherwise.
function Get-GitOpsSource {
    $branch = (Invoke-Quiet git @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')).Output
    $revision = if ($env:GITOPS_REVISION) { $env:GITOPS_REVISION } else { $branch }
    if ($env:PIPELINE_SOURCE) { return @{ Source = $env:PIPELINE_SOURCE; Revision = $revision } }

    $upstream = Invoke-Quiet git @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $unpushed = $upstream.ExitCode -ne 0 -or
        (Invoke-Quiet git @('-C', $RepoRoot, 'diff', '--quiet', '@{u}', '--', 'charts')).ExitCode -ne 0 -or
        [bool](Invoke-Quiet git @('-C', $RepoRoot, 'status', '--porcelain', '--untracked-files=all', 'charts')).Output
    if ($unpushed) {
        Write-Warning "charts/ differs from what is on GitHub for $branch, so the chart is installed from the working tree with Helm. Push it to test the GitOps path through Argo CD."
        return @{ Source = 'helm'; Revision = $revision }
    }
    return @{ Source = 'argocd'; Revision = $revision }
}

function Start-Platform {
    Assert-Command kind 'Install kind v0.33.0, e.g. `winget install Kubernetes.kind`.'
    Assert-Command kubectl 'Install kubectl, e.g. `winget install Kubernetes.kubectl`.'
    $clusters = (Invoke-Quiet kind @('get', 'clusters')).Output
    if ($clusters -contains $ClusterName) {
        Write-Host "kind cluster $ClusterName already exists."
    } else {
        Invoke-Native kind @('create', 'cluster', '--config', (Join-Path $PlatformDir 'kind-cluster.yaml'), '--wait', '120s')
    }

    Initialize-Tofu $PlatformDir
    $gitops = Get-GitOpsSource
    if ($gitops.Source -eq 'argocd') {
        Write-Host "Argo CD will deploy charts/pipeline-observability from $Repository@$($gitops.Revision)."
    }
    if (-not $env:TF_VAR_github_token) {
        Write-Warning 'TF_VAR_github_token is not set; the exporter uses the unauthenticated GitHub API (60 requests/hour).'
    }
    Invoke-Tofu @('apply', '-auto-approve', "-var=pipeline_observability_source=$($gitops.Source)",
        "-var=gitops_revision=$($gitops.Revision)", "-var=github_repository=$Repository") $PlatformDir
    Invoke-Tofu @('output') $PlatformDir
    Write-Host 'Grafana admin password: tofu -chdir=platform output -raw grafana_admin_password'
}

function Test-Platform {
    $python = @('python', 'python3', 'py') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $python) { throw 'Python 3 is needed for the smoke test.' }
    Invoke-Native $python @((Join-Path $RepoRoot 'scripts\smoke_platform.py'))
}

function Stop-Platform {
    $clusters = (Invoke-Quiet kind @('get', 'clusters')).Output
    if ($clusters -contains $ClusterName) {
        Initialize-Tofu $PlatformDir
        Invoke-Tofu @('destroy', '-auto-approve') $PlatformDir
        Invoke-Native kind @('delete', 'cluster', '--name', $ClusterName)
    } else {
        Write-Host "kind cluster $ClusterName does not exist."
    }
}

switch ($Action) {
    'start' { Start-LocalStack }
    'bootstrap' { Start-LocalStack; New-StateBucket }
    'init' { Initialize-Tofu }
    'plan' { Initialize-Tofu; Invoke-Tofu @('plan') }
    'apply' { Initialize-Tofu; Invoke-Tofu @('apply') }
    'up' { Initialize-Tofu; Invoke-Tofu @('apply', '-auto-approve'); Invoke-Tofu @('output') }
    'output' { Invoke-Tofu @('output') }
    'destroy' { Initialize-Tofu; Invoke-Tofu @('destroy') }
    'down' {
        Initialize-Tofu
        Invoke-Tofu @('destroy', '-auto-approve')
        if (Get-Command lstk -ErrorAction SilentlyContinue) {
            Invoke-Native lstk @('stop')
        } else {
            Invoke-Native docker @('compose', '-f', (Join-Path $RepoRoot 'docker-compose.yml'), 'down')
        }
    }
    'test' { Invoke-Tests }
    'sbom' { New-Sbom }
    'metrics' { Show-Metrics }
    'platform-up' { Start-Platform }
    'platform-test' { Test-Platform }
    'platform-down' { Stop-Platform }
}
