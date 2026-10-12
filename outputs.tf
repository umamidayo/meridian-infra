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

output "ecr_repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "URL to push container images to."
  value       = aws_ecr_repository.app.repository_url
}

output "s3_bucket_name" {
  description = "Name of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}
