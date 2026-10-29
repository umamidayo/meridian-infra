# Unit tests for artifact lifecycle rules and bucket policies. Mock providers
# keep these offline: run with `tofu init -backend=false && tofu test`.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
}

mock_provider "docker" {}

run "lifecycle_covers_every_artifact_class" {
  command = apply

  assert {
    condition = toset([for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule : r.id]) == toset([
      "releases-tiering", "sboms-tiering", "attestations-tiering",
      "plans-expiry", "metrics-expiry", "bucket-hygiene", "expired-delete-markers",
    ])
    error_message = "Every artifact prefix needs a lifecycle rule."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r.status == "Enabled"
    ])
    error_message = "All lifecycle rules must be enabled."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r.expiration[0].days if r.id == "attestations-tiering"
      ]) >= one([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r.expiration[0].days if r.id == "releases-tiering"
    ])
    error_message = "Provenance must be kept at least as long as the releases it describes."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.artifacts.rule :
      r.expiration[0].days if r.id == "plans-expiry"
    ]) == 30
    error_message = "Plans hold sensitive values and should expire after 30 days by default."
  }
}

run "bucket_policy_guards" {
  command = apply

  assert {
    condition = toset([for s in jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement : s.Sid]) == toset([
      "DenyInsecureTransport", "DenyWrongEncryptionHeader", "DenyWritesExceptPublisher", "ProtectSupplyChainEvidence",
    ])
    error_message = "Artifacts bucket policy is missing a guard statement."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement : s.Effect == "Deny"
    ])
    error_message = "The bucket policy should only deny; access is granted through the IAM roles."
  }

  assert {
    condition = contains(
      one([for s in jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement : s.Condition.ArnNotLike["aws:PrincipalArn"] if s.Sid == "ProtectSupplyChainEvidence"]),
      "arn:aws:iam::000000000000:root",
    )
    error_message = "With no admins configured, the account root should be the only principal that can delete evidence."
  }

  assert {
    condition     = length(aws_s3_bucket_policy.registry) == 1
    error_message = "The registry bucket should deny insecure transport by default."
  }
}

run "secure_transport_can_be_disabled" {
  command = apply

  variables {
    require_secure_transport = false
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement : s.Sid], "DenyInsecureTransport")
    error_message = "DenyInsecureTransport should be omitted when require_secure_transport is false."
  }

  assert {
    condition     = length(aws_s3_bucket_policy.registry) == 0
    error_message = "Registry policy should not be created when require_secure_transport is false."
  }
}

run "publisher_trust_is_limited_to_main" {
  command = apply

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role.artifact_publisher.assume_role_policy).Statement :
      s.Condition.StringEquals["token.actions.githubusercontent.com:sub"] if s.Sid == "GitHubActionsMainBranch"
    ]) == "repo:umamidayo/meridian-infra:ref:refs/heads/main"
    error_message = "Only main-branch workflows of this repository may assume the publisher role through OIDC."
  }
}

run "retention_must_be_ordered" {
  command = plan

  variables {
    artifact_retention = {
      releases_expire_days     = 400
      attestations_expire_days = 100
    }
  }

  expect_failures = [var.artifact_retention]
}
