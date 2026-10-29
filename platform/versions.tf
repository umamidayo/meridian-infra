terraform {
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Same LocalStack state bucket as the root module, separate key.
  backend "s3" {
    bucket       = "meridian-tofu-state"
    key          = "meridian/dev/platform.tfstate"
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
