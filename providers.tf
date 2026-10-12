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

# Uses DOCKER_HOST when docker_host is null. On Docker Desktop for Windows set
# DOCKER_HOST=npipe:////./pipe/dockerDesktopLinuxEngine (or pass -var docker_host=...).
provider "docker" {
  host = var.docker_host
}
