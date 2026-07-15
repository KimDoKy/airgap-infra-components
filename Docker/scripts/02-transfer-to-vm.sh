#!/usr/bin/env bash
# [로컬 / VM에 SSH로 접근 가능한 PC] 에서 실행합니다.
# 이 디렉터리 전체(.env, config/, scripts/, packages/*)를 SSH를 통해 폐쇄망 VM으로 전송합니다.
#
# GitServer/Jenkins/Nexus 세 VM 모두에 Docker를 설치해야 한다면, .env 의 VM_SSH_HOST 등을
# 대상 VM으로 바꿔가며 이 스크립트를 여러 번 실행하세요.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

: "${VM_SSH_HOST:?.env 에 VM_SSH_HOST 를 설정하세요 (예: <VM_IP>)}"
: "${VM_SSH_USER:?.env 에 VM_SSH_USER 를 설정하세요}"
VM_SSH_PORT="${VM_SSH_PORT:-22}"
VM_REMOTE_DIR="${VM_REMOTE_DIR:?.env 에 VM_REMOTE_DIR 을 설정하세요 (예: ~/Docker)}"

SERVICE_DIR="$(pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR")"

if [ -z "$(ls -A packages 2>/dev/null)" ]; then
  echo "!! packages/ 디렉터리가 비어 있습니다. 먼저 01-download.sh 를 실행하세요." >&2
  exit 1
fi

echo ">> SSH 접속 확인: ${VM_SSH_USER}@${VM_SSH_HOST}:${VM_SSH_PORT}"
ssh -p "${VM_SSH_PORT}" -o BatchMode=yes -o ConnectTimeout=5 \
  "${VM_SSH_USER}@${VM_SSH_HOST}" 'echo ok' >/dev/null \
  || { echo "!! SSH 접속 실패. VM_SSH_HOST/VM_SSH_USER/VM_SSH_PORT 및 SSH 키(ssh-copy-id 등)를 확인하세요." >&2; exit 1; }

echo ">> 원격 디렉터리 준비: ${VM_REMOTE_DIR}"
ssh -p "${VM_SSH_PORT}" "${VM_SSH_USER}@${VM_SSH_HOST}" "mkdir -p '${VM_REMOTE_DIR}'"

RSYNC_OK=0
if command -v rsync >/dev/null 2>&1 && \
   ssh -p "${VM_SSH_PORT}" "${VM_SSH_USER}@${VM_SSH_HOST}" 'command -v rsync' >/dev/null 2>&1; then
  RSYNC_OK=1
fi

if [ "${RSYNC_OK}" = "1" ]; then
  echo ">> rsync 로 전송 중 (${SERVICE_NAME} -> ${VM_REMOTE_DIR})..."
  rsync -avzP -e "ssh -p ${VM_SSH_PORT}" \
    "${SERVICE_DIR}/" "${VM_SSH_USER}@${VM_SSH_HOST}:${VM_REMOTE_DIR}/"
else
  echo ">> 로컬 또는 VM 중 한쪽에 rsync가 없어 tar+scp 로 전송합니다..."
  TMP_TAR="/tmp/${SERVICE_NAME}-transfer.tar.gz"
  tar czf "${TMP_TAR}" -C "${SERVICE_DIR}" .
  scp -P "${VM_SSH_PORT}" "${TMP_TAR}" "${VM_SSH_USER}@${VM_SSH_HOST}:/tmp/"
  ssh -p "${VM_SSH_PORT}" "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "tar xzf '/tmp/$(basename "${TMP_TAR}")' -C '${VM_REMOTE_DIR}' && rm -f '/tmp/$(basename "${TMP_TAR}")'"
  rm -f "${TMP_TAR}"
fi

echo ""
echo ">> 전송 완료."
echo ">> VM에 접속해 이어서 진행하세요:"
echo "   ssh -p ${VM_SSH_PORT} ${VM_SSH_USER}@${VM_SSH_HOST}"
echo "   cd ${VM_REMOTE_DIR} && ./scripts/03-install.sh"
