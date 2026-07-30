#!/usr/bin/env bash
# [로컬] 파이프라인 자산(pipeline/ 전체) + CI 에이전트 이미지 + 플러그인을 cicd VM 으로 반입.
# Jenkins 디렉터리는 별도(Jenkins/scripts/02-transfer-to-vm.sh)로 이미 반입돼 있다고 가정.
set -euo pipefail
cd "$(dirname "$0")/../.."        # Jenkins/ 루트
set -a; source .env; set +a
: "${VM_SSH_HOST:?}"; : "${VM_SSH_USER:?}"; VM_SSH_PORT="${VM_SSH_PORT:-22}"
: "${VM_REMOTE_DIR:?}"

echo ">> pipeline/ 전송 → ${VM_REMOTE_DIR}/pipeline"
rsync -avzP -e "ssh -p ${VM_SSH_PORT}" --exclude '.npmrc' \
  pipeline/ "${VM_SSH_USER}@${VM_SSH_HOST}:${VM_REMOTE_DIR}/pipeline/"

# CI 에이전트 이미지 로드 (cicd VM docker 로)
if [ -f pipeline/images/ci-agent.tar.gz ]; then
  echo ">> CI 에이전트 이미지 로드 (cicd VM)"
  ssh -p "${VM_SSH_PORT}" "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "gunzip -c '${VM_REMOTE_DIR}/pipeline/images/ci-agent.tar.gz' | docker load"
fi

# 플러그인 반입 (jenkins_home/plugins/)
if [ -d pipeline/plugins ]; then
  echo ">> 플러그인 반입 → jenkins_home/plugins/"
  ssh -p "${VM_SSH_PORT}" "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "mkdir -p '${VM_REMOTE_DIR}/jenkins_home/plugins' && cp ${VM_REMOTE_DIR}/pipeline/plugins/*.hpi '${VM_REMOTE_DIR}/jenkins_home/plugins/' 2>/dev/null || true"
fi
echo ">> 완료. Jenkins 재기동(docker compose up -d) 후 플러그인/에이전트가 반영됩니다."
