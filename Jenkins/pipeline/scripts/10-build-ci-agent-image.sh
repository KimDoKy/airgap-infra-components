#!/usr/bin/env bash
# [로컬 / 인터넷 가능 PC] CI 에이전트 이미지(node+docker+git, NCR/Nexus 접근용 openssl/jq)를 빌드해 tar 로 저장.
# 폐쇄망 반입용. 빌드 PC=Intel(amd64) → cicd VM(amd64)과 동일 아키텍처(플랫폼 강제 불필요).
set -euo pipefail
cd "$(dirname "$0")/.."          # pipeline/ 로

TAG="acme-ci-agent:1.0"
mkdir -p images
echo ">> 빌드: $TAG (amd64)"
docker build -t "$TAG" agent/

echo ">> 저장: images/ci-agent.tar.gz"
docker save "$TAG" | gzip > images/ci-agent.tar.gz
ls -lh images/ci-agent.tar.gz
echo ">> 완료. 12-transfer-pipeline.sh 로 cicd VM 에 반입하세요."
