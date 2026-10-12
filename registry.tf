# ECR is not included in the free LocalStack license, so the container registry
# is a self-hosted Docker Distribution (registry:2) container. Image layers are
# stored in an S3 bucket inside LocalStack.

resource "aws_s3_bucket" "registry" {
  bucket        = "${local.name_prefix}-registry"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "registry" {
  bucket = aws_s3_bucket.registry.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "docker_image" "registry" {
  name         = var.registry_image
  keep_locally = true
}

resource "docker_container" "registry" {
  name    = "${local.name_prefix}-registry"
  image   = docker_image.registry.image_id
  restart = "unless-stopped"

  ports {
    internal = 5000
    external = var.registry_port
    ip       = "127.0.0.1"
  }

  # Lets the registry reach LocalStack on the host, on both Docker Desktop and Linux runners.
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  env = [
    "REGISTRY_STORAGE=s3",
    "REGISTRY_STORAGE_S3_BUCKET=${aws_s3_bucket.registry.bucket}",
    "REGISTRY_STORAGE_S3_REGION=${var.aws_region}",
    "REGISTRY_STORAGE_S3_REGIONENDPOINT=${var.registry_s3_endpoint}",
    "REGISTRY_STORAGE_S3_ACCESSKEY=test",
    "REGISTRY_STORAGE_S3_SECRETKEY=test",
    "REGISTRY_STORAGE_S3_SECURE=false",
    "REGISTRY_STORAGE_DELETE_ENABLED=true",
  ]

  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:5000/v2/"]
    interval = "10s"
    timeout  = "3s"
    retries  = 5
  }

  depends_on = [aws_s3_bucket_public_access_block.registry]
}
