variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "meridian"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region emulated by LocalStack."
  type        = string
  default     = "us-east-1"
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint for all AWS service APIs."
  type        = string
  default     = "http://localhost:4566"
}

variable "registry_image" {
  description = "Docker Distribution image used for the container registry."
  type        = string
  default     = "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
}

variable "registry_port" {
  description = "Host port the container registry listens on (bound to 127.0.0.1)."
  type        = number
  default     = 5000
}

variable "registry_s3_endpoint" {
  description = "LocalStack S3 endpoint as seen from inside the registry container."
  type        = string
  default     = "http://host.docker.internal:4566"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "docker_host" {
  description = "Docker daemon address for the docker provider. Null falls back to DOCKER_HOST or the platform default socket."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main-branch workflows may assume the artifact publisher role."
  type        = string
  default     = "umamidayo/meridian-infra"
}

variable "require_secure_transport" {
  description = "Add a bucket policy statement that denies non-TLS requests. LocalStack only enforces bucket policies with ENFORCE_IAM=1; keep this on for real AWS."
  type        = bool
  default     = true
}

variable "artifact_admin_principal_arns" {
  description = "Principals exempt from the artifact write/delete guards (break-glass and the identity running OpenTofu). Empty means the account root."
  type        = list(string)
  default     = []
}

variable "artifact_retention" {
  description = "Lifecycle settings, in days, for each artifact class in the artifacts bucket."
  type = object({
    plans_expire_days        = optional(number, 30)
    metrics_expire_days      = optional(number, 90)
    infrequent_access_days   = optional(number, 30)
    glacier_days             = optional(number, 90)
    releases_expire_days     = optional(number, 400)
    attestations_expire_days = optional(number, 730)
    noncurrent_expire_days   = optional(number, 30)
    abort_multipart_days     = optional(number, 7)
  })
  default = {}

  validation {
    condition     = var.artifact_retention.infrequent_access_days >= 30
    error_message = "S3 requires objects to be at least 30 days old before moving to STANDARD_IA."
  }

  validation {
    condition = (
      var.artifact_retention.glacier_days > var.artifact_retention.infrequent_access_days &&
      var.artifact_retention.releases_expire_days > var.artifact_retention.glacier_days &&
      var.artifact_retention.attestations_expire_days >= var.artifact_retention.releases_expire_days
    )
    error_message = "Retention must increase: infrequent_access < glacier < releases_expire <= attestations_expire, so provenance outlives the artifacts it describes."
  }
}
