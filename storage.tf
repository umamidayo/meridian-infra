resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name_prefix}-artifacts"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Key layout (written by CI, see .github/workflows/opentofu.yml):
#   releases/<sha>/      source bundle that was planned and applied
#   sboms/<sha>/         CycloneDX SBOM of the bundle and its providers
#   attestations/<sha>/  SLSA provenance; kept longest so every release stays verifiable
#   plans/<sha>/         plan JSON; may hold sensitive values, so it expires quickly
#   metrics/             pipeline SLO and DORA reports
locals {
  retention = var.artifact_retention

  # Prefixes that move to colder storage and then expire.
  tiered_prefixes = {
    releases     = local.retention.releases_expire_days
    sboms        = local.retention.releases_expire_days
    attestations = local.retention.attestations_expire_days
  }

  # Prefixes that only expire.
  expiring_prefixes = {
    plans   = local.retention.plans_expire_days
    metrics = local.retention.metrics_expire_days
  }

  # Supply-chain evidence only an admin may delete. Lifecycle expiry is not subject to bucket policy.
  protected_prefixes = ["releases", "sboms", "attestations"]

  artifact_admin_arns = length(var.artifact_admin_principal_arns) > 0 ? var.artifact_admin_principal_arns : [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
  ]

  deny_insecure_transport = {
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # Noncurrent-version rules only make sense once versioning is on.
  depends_on = [aws_s3_bucket_versioning.artifacts]

  dynamic "rule" {
    for_each = local.tiered_prefixes

    content {
      id     = "${rule.key}-tiering"
      status = "Enabled"

      filter {
        prefix = "${rule.key}/"
      }

      transition {
        days          = local.retention.infrequent_access_days
        storage_class = "STANDARD_IA"
      }

      transition {
        days          = local.retention.glacier_days
        storage_class = "GLACIER"
      }

      expiration {
        days = rule.value
      }
    }
  }

  dynamic "rule" {
    for_each = local.expiring_prefixes

    content {
      id     = "${rule.key}-expiry"
      status = "Enabled"

      filter {
        prefix = "${rule.key}/"
      }

      expiration {
        days = rule.value
      }
    }
  }

  rule {
    id     = "bucket-hygiene"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = local.retention.noncurrent_expire_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = local.retention.abort_multipart_days
    }
  }

  rule {
    id     = "expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.require_secure_transport ? [merge(local.deny_insecure_transport, {
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      })] : [],
      [
        {
          # Default encryption covers uploads without the header; this rejects uploads that ask for something else.
          Sid       = "DenyWrongEncryptionHeader"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:PutObject"
          Resource  = "${aws_s3_bucket.artifacts.arn}/*"
          Condition = {
            StringNotEquals = { "s3:x-amz-server-side-encryption" = ["AES256", "aws:kms"] }
            Null            = { "s3:x-amz-server-side-encryption" = "false" }
          }
        },
        {
          Sid       = "DenyWritesExceptPublisher"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:PutObject", "s3:PutObjectAcl", "s3:PutObjectTagging"]
          Resource  = "${aws_s3_bucket.artifacts.arn}/*"
          Condition = {
            ArnNotLike = { "aws:PrincipalArn" = concat([aws_iam_role.artifact_publisher.arn], local.artifact_admin_arns) }
          }
        },
        {
          Sid       = "ProtectSupplyChainEvidence"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
          Resource  = [for p in local.protected_prefixes : "${aws_s3_bucket.artifacts.arn}/${p}/*"]
          Condition = {
            ArnNotLike = { "aws:PrincipalArn" = local.artifact_admin_arns }
          }
        },
      ],
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
