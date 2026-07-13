#!/usr/bin/env bash
# [로컬 / 인터넷 연결 가능 PC] 에서 실행합니다.
# Docker Engine 정적 바이너리 + Docker Compose 플러그인 바이너리를 다운로드합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p packages

DOCKER_TAR="docker-${DOCKER_VERSION}.tgz"
DOCKER_URL="https://download.docker.com/linux/static/stable/${ARCH}/${DOCKER_TAR}"
COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"

echo ">> Downloading Docker Engine ${DOCKER_VERSION} (${ARCH})"
echo "   ${DOCKER_URL}"
curl -fL -o "packages/${DOCKER_TAR}" "${DOCKER_URL}"

echo ">> Downloading Docker Compose plugin ${COMPOSE_VERSION} (${ARCH})"
echo "   ${COMPOSE_URL}"
curl -fL -o "packages/docker-compose" "${COMPOSE_URL}"
chmod +x "packages/docker-compose"

echo ""
ls -lh packages/
echo ">> 완료. 이 Docker 디렉터리 전체(packages/ 포함)를 VM으로 옮기세요."
