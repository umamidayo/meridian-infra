output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = aws_subnet.private[*].id
}

output "registry_url" {
  description = "Registry host to push container images to, e.g. <registry_url>/meridian-app:1.0.0."
  value       = "localhost:${var.registry_port}"
}

output "registry_bucket_name" {
  description = "S3 bucket backing the container registry's image storage."
  value       = aws_s3_bucket.registry.bucket
}

output "s3_bucket_name" {
  description = "Name of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "artifact_publisher_role_arn" {
  description = "Role CI assumes to publish releases, SBOMs, attestations, plans and metrics."
  value       = aws_iam_role.artifact_publisher.arn
}

output "artifact_reader_role_arn" {
  description = "Read-only role for consumers that fetch and verify released artifacts."
  value       = aws_iam_role.artifact_reader.arn
}
