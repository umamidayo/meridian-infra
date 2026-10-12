terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }

  # Remote state lives in an S3 bucket inside LocalStack. The bucket is created
  # by scripts/bootstrap-state.sh before `tofu init`, since a backend cannot
  # provision its own storage.
  backend "s3" {
    bucket       = "meridian-tofu-state"
    key          = "meridian/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true

    endpoints = {
      s3 = "http://localhost:4566"
    }

    access_key                  = "test"
    secret_key                  = "test"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }
}
