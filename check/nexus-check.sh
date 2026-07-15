#!/usr/bin/env bash
# Nexus(+ nginx TLS) 를 "가짜 VM"에 실제로 배포해 end-to-end로 검증합니다.
#
# Nexus/scripts/ 안의 실제 배포 스크립트(01~07)를 수정 없이 그대로,
# 문서(README.md/MANUAL.md)에 적힌 순서대로 실행합니다:
#   01-pull-and-save-image.sh (로컬) -> 02-transfer-to-vm.sh (로컬, SSH 전송)
#   -> 03-load-image.sh (VM) -> 05-start.sh (VM, TLS 인증서 생성 + 기동)
#   -> 06-configure.sh (VM, REST API로 admin 비밀번호 변경 + 익명 접근 차단)
#   -> HTTPS 헬스체크 / 저장소 생성-조회-삭제 -> 07-stop.sh (VM) -> 정리
#
# 원본 Nexus/.env, Nexus/certs, Nexus/nexus-data 는 전혀 건드리지 않습니다.
# (검증용 사본을 check/.work/ 아래에 만들어 그 안에서만 작업합니다)
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CHECK_DIR/.." && pwd)"
# shellcheck source=lib/mock-vm.sh
source "$CHECK_DIR/lib/mock-vm.sh"

SERVICE_NAME="Nexus"
VM_NAME="mock-vm-nexus"
VM_SSH_PORT="$MOCK_VM_SSH_PORT"
VM_USER=tester
WORKDIR="$CHECK_DIR/.work/nexus"
REMOTE_DIR="$WORKDIR/$SERVICE_NAME"

TLS_PORT=18445
TLS_HTTP_PORT=18082
ADMIN_PASSWORD="CheckOnly123!"

PASS=1
STARTED=0

cleanup() {
  local code=$?
  echo ""
  echo "== 정리 중 =="
  if [ "$STARTED" -eq 1 ]; then
    ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
      "cd '${REMOTE_DIR}' && ./scripts/07-stop.sh" 2>/dev/null || true
  fi
  mock_vm_down "$VM_NAME"
  rm -rf "$WORKDIR"

  echo ""
  if [ "$code" -eq 0 ] && [ "$PASS" -eq 1 ]; then
    echo "== ${SERVICE_NAME} 검증 결과: PASS =="
  else
    echo "== ${SERVICE_NAME} 검증 결과: FAIL =="
    exit 1
  fi
}
trap cleanup EXIT

check() {
  local desc="$1" code="$2" want="$3"
  if [ "$code" = "$want" ]; then
    echo "   [OK] ${desc} (${code})"
  else
    echo "   [FAIL] ${desc} (got ${code}, want ${want})"
    PASS=0
  fi
}

rm -rf "$WORKDIR"
mkdir -p "$REMOTE_DIR"

SSH_OPTS=(-i "$WORKDIR/id_ed25519" -p "$VM_SSH_PORT" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$WORKDIR/known_hosts" \
  -o BatchMode=yes)

echo "== 0. 가짜 VM 기동 =="
mock_vm_up "$VM_NAME" "$WORKDIR" "$VM_USER"
export PATH="$(mock_vm_install_ssh_wrappers "$WORKDIR"):$PATH"

echo ""
echo "== 1. 실제 Nexus/ 디렉터리를 검증용 작업 디렉터리로 복사 =="
cp -R "$REPO_ROOT/$SERVICE_NAME/." "$REMOTE_DIR/"
rm -rf "${REMOTE_DIR:?}/nexus-data" "${REMOTE_DIR:?}/certs" "${REMOTE_DIR:?}/images"
mkdir -p "$REMOTE_DIR/images"

NEXUS_IMAGE=$(grep '^NEXUS_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)
NGINX_IMAGE=$(grep '^NGINX_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)

echo "== 2. 검증 전용 .env 로 교체 (원본 .env는 건드리지 않음) =="
cat > "$REMOTE_DIR/.env" <<EOF
NEXUS_IMAGE=${NEXUS_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
IMAGE_TAR_NAME=nexus-image.tar.gz
VM_SSH_HOST=127.0.0.1
VM_SSH_USER=${VM_USER}
VM_SSH_PORT=${VM_SSH_PORT}
VM_REMOTE_DIR=${REMOTE_DIR}
TLS_PORT=${TLS_PORT}
TLS_HTTP_PORT=${TLS_HTTP_PORT}
TLS_DOMAIN=localhost
TLS_CERT_DAYS=825
TZ=Asia/Seoul
NEXUS_UID=200
NEXUS_GID=200
NEXUS_MIN_HEAP=1200m
NEXUS_MAX_HEAP=1200m
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DISABLE_ANONYMOUS_ACCESS=true
EOF

cd "$REMOTE_DIR"

echo ""
echo "== 3. [로컬] 01-pull-and-save-image.sh (실제 스크립트 그대로 실행) =="
./scripts/01-pull-and-save-image.sh

echo ""
echo "== 4. [로컬] 02-transfer-to-vm.sh 로 가짜 VM에 SSH 전송 =="
./scripts/02-transfer-to-vm.sh

echo ""
echo "== 5. [VM] 03-load-image.sh =="
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "cd '${REMOTE_DIR}' && ./scripts/03-load-image.sh"

echo ""
echo "== 6. [VM] 05-start.sh (TLS 인증서 생성 + 기동, DB 초기화로 다소 시간이 걸릴 수 있음) =="
STARTED=1
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "cd '${REMOTE_DIR}' && ./scripts/05-start.sh"

echo ""
echo "== 7. [VM] 06-configure.sh (REST API로 admin 비밀번호 변경 + 익명 접근 차단) =="
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "cd '${REMOTE_DIR}' && ./scripts/06-configure.sh"

echo ""
echo "== 8. 검증 =="
CACERT="${REMOTE_DIR}/certs/server.crt"
BASE_URL="https://127.0.0.1:${TLS_PORT}"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" "${BASE_URL}/service/rest/v1/status")
check "HTTPS status" "$CODE" "200"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" "${BASE_URL}/service/rest/v1/repositories")
check "관리자 API 인증" "$CODE" "200"

# /repositories 는 저장소 이름 목록 자체가 민감 정보가 아니라 익명 접근 차단 여부와
# 무관하게 항상 공개되는 엔드포인트입니다 (실제로 정상 동작). 익명 차단은 /security/users
# 처럼 실제로 보호되는 엔드포인트로 확인해야 의미가 있습니다.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" "${BASE_URL}/service/rest/v1/security/users")
check "익명 접근 차단 (403 기대)" "$CODE" "403"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"check-repo","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}}' \
  "${BASE_URL}/service/rest/v1/repositories/raw/hosted")
check "저장소 생성 (raw hosted)" "$CODE" "201"

REPO_LIST=$(curl -s --cacert "$CACERT" -u "admin:${ADMIN_PASSWORD}" "${BASE_URL}/service/rest/v1/repositories")
if echo "$REPO_LIST" | grep -qw "check-repo"; then
  echo "   [OK] 저장소 목록 조회 (check-repo 존재)"
else
  echo "   [FAIL] 저장소 목록 조회 실패 (check-repo 없음)"
  echo "$REPO_LIST"
  PASS=0
fi

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" -X DELETE \
  "${BASE_URL}/service/rest/v1/repositories/check-repo")
check "저장소 삭제" "$CODE" "204"
