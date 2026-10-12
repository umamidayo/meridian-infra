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
  default     = "registry:2.8.3"
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
