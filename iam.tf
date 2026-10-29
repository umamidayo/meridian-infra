# Who may write to and read from the artifacts bucket. In real AWS, GitHub
# Actions assumes the publisher role through OIDC, and only from main, so
# feature branches and forks can never publish releases or attestations.

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "artifact_publisher" {
  name = "${local.name_prefix}-artifact-publisher"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "GitHubActionsMainBranch"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main"
          }
        }
      },
      {
        # LocalStack cannot validate GitHub OIDC tokens, so CI assumes the role with its account credentials instead.
        Sid       = "SameAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "artifact_publisher" {
  name = "publish-artifacts"
  role = aws_iam_role.artifact_publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteArtifacts"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion"]
        Resource = [for p in concat(keys(local.tiered_prefixes), keys(local.expiring_prefixes)) : "${aws_s3_bucket.artifacts.arn}/${p}/*"]
      },
      {
        Sid      = "ListArtifacts"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.artifacts.arn
      },
    ]
  })
}

resource "aws_iam_role" "artifact_reader" {
  name = "${local.name_prefix}-artifact-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "artifact_reader" {
  name = "read-artifacts"
  role = aws_iam_role.artifact_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.artifacts.arn
      },
    ]
  })
}
