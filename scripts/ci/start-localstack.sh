#!/usr/bin/env bash
# Starts LocalStack for a CI job and waits until it is healthy. Fails fast with
# LocalStack's own error (e.g. license activation) instead of timing out on the port.
set -euo pipefail

IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:2026.10.4@sha256:2290500d7398e6458544fab2f49aaf170b81a1006ee69067e8e7fc59b810a824}"

if [ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
  echo "::error title=Missing secret::LOCALSTACK_AUTH_TOKEN is empty. Add it under Settings > Secrets and variables > Actions > Repository secrets. LocalStack exits on startup without it."
  exit 1
fi

docker run -d --name localstack -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN \
  -e SERVICES=s3,ec2,iam,sts \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$IMAGE"

for _ in $(seq 1 90); do
  if [ "$(docker inspect -f '{{.State.Running}}' localstack)" != "true" ]; then
    docker logs localstack 2>&1 | tail -40
    code=$(docker inspect -f '{{.State.ExitCode}}' localstack)
    echo "::error title=LocalStack exited::LocalStack stopped with exit code $code. Exit code 55 means license activation failed: check that LOCALSTACK_AUTH_TOKEN is valid and allowed for CI use."
    exit 1
  fi
  if curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; then
    echo "LocalStack is ready."
    exit 0
  fi
  sleep 2
done
docker logs localstack 2>&1 | tail -40
echo "::error title=LocalStack timeout::LocalStack did not become healthy within 180s."
exit 1
