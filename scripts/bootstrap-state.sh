#!/usr/bin/env bash
# Creates the S3 bucket that holds OpenTofu remote state inside LocalStack.
# Safe to run repeatedly.
set -euo pipefail

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
BUCKET="${STATE_BUCKET:-meridian-tofu-state}"
REGION="${AWS_REGION:-us-east-1}"

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION"

echo "Waiting for LocalStack at $ENDPOINT..."
for _ in $(seq 1 60); do
  if curl -fsS "$ENDPOINT/_localstack/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "$ENDPOINT/_localstack/health" >/dev/null

if aws --endpoint-url "$ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "State bucket $BUCKET already exists."
else
  aws --endpoint-url "$ENDPOINT" s3api create-bucket --bucket "$BUCKET" >/dev/null
  aws --endpoint-url "$ENDPOINT" s3api put-bucket-versioning \
    --bucket "$BUCKET" --versioning-configuration Status=Enabled
  echo "Created state bucket $BUCKET."
fi
