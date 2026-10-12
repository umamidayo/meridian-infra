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
