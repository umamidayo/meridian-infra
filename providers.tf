provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = var.localstack_endpoint
    iam = var.localstack_endpoint
    s3  = var.localstack_endpoint
    sts = var.localstack_endpoint
  }

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "opentofu"
    }
  }
}

# With docker_host null the provider uses DOCKER_HOST, else the platform default
# (Docker Desktop's named pipe on Windows, /var/run/docker.sock on Linux).
provider "docker" {
  host = var.docker_host
}
