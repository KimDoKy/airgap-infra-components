#!/usr/bin/env bash
# [로컬 / 인터넷 가능 PC] CI 에이전트 이미지(node+docker+git, SigV4용 openssl/jq)를 빌드해 tar 로 저장.
# 폐쇄망 반입용. 빌드 PC 가 Apple Silicon 이면 amd64 강제(cicd VM = amd64).
set -euo pipefail
cd "$(dirname "$0")/.."          # pipeline/ 로

TAG="acme-ci-agent:1.0"
mkdir -p images
echo ">> 빌드: $TAG (linux/amd64)"
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build --platform linux/amd64 -t "$TAG" agent/

echo ">> 저장: images/ci-agent.tar.gz"
docker save "$TAG" | gzip > images/ci-agent.tar.gz
ls -lh images/ci-agent.tar.gz
echo ">> 완료. 12-transfer-pipeline.sh 로 cicd VM 에 반입하세요."
