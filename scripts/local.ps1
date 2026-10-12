<#
.SYNOPSIS
  Runs the Meridian OpenTofu environment against LocalStack on Windows.

.DESCRIPTION
  Needs only Docker Desktop, OpenTofu and either lstk (`lstk login` done) or a
  LOCALSTACK_AUTH_TOKEN for docker compose. No bash or AWS CLI required.

.EXAMPLE
  .\scripts\local.ps1 up        # start LocalStack, create state bucket, init, apply
  .\scripts\local.ps1 plan
  .\scripts\local.ps1 destroy
  .\scripts\local.ps1 down      # destroy resources, then stop LocalStack
#>
param(
    [ValidateSet('start', 'bootstrap', 'init', 'plan', 'apply', 'up', 'output', 'destroy', 'down')]
    [string]$Action = 'up'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Endpoint = if ($env:LOCALSTACK_ENDPOINT) { $env:LOCALSTACK_ENDPOINT } else { 'http://localhost:4566' }
$StateBucket = if ($env:STATE_BUCKET) { $env:STATE_BUCKET } else { 'meridian-tofu-state' }
$RepoRoot = Split-Path -Parent $PSScriptRoot

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
    param([string[]]$Arguments)
    # `tofu output` rejects -input; every other subcommand used here accepts it.
    if ($Arguments[0] -ne 'output') { $Arguments = @($Arguments) + '-input=false' }
    Push-Location $RepoRoot
    try {
        Invoke-Native tofu $Arguments
    } finally {
        Pop-Location
    }
}

function Initialize-Tofu {
    Start-LocalStack
    New-StateBucket
    Invoke-Tofu @('init')
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
}
