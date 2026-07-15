#!/usr/bin/env bash
# GitServer(Gitea + nginx TLS) 를 "가짜 VM"에 실제로 배포해 end-to-end로 검증합니다.
#
# GitServer/scripts/ 안의 실제 배포 스크립트(01~06)를 수정 없이 그대로,
# 문서(README.md/MANUAL.md)에 적힌 순서대로 실행합니다:
#   01-pull-and-save-image.sh (로컬) -> 02-transfer-to-vm.sh (로컬, SSH 전송)
#   -> 03-load-image.sh (VM) -> 05-start.sh (VM, TLS 인증서 생성 + 기동 + CLI 초기화)
#   -> HTTPS 헬스체크 / 관리자 API / 저장소 생성-조회-삭제 -> 06-stop.sh (VM) -> 정리
#
# 원본 GitServer/.env, GitServer/certs, GitServer/data 는 전혀 건드리지 않습니다.
# (검증용 사본을 check/.work/ 아래에 만들어 그 안에서만 작업합니다)
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CHECK_DIR/.." && pwd)"
# shellcheck source=lib/mock-vm.sh
source "$CHECK_DIR/lib/mock-vm.sh"

SERVICE_NAME="GitServer"
VM_NAME="mock-vm-gitserver"
VM_SSH_PORT="$MOCK_VM_SSH_PORT"
VM_USER=tester
WORKDIR="$CHECK_DIR/.work/gitserver"
REMOTE_DIR="$WORKDIR/$SERVICE_NAME"

TLS_PORT=18443
TLS_HTTP_PORT=18080
GITEA_SSH_PORT=12222
ADMIN_PASSWORD="CheckOnly123!"

PASS=1
STARTED=0

cleanup() {
  local code=$?
  echo ""
  echo "== 정리 중 =="
  if [ "$STARTED" -eq 1 ]; then
    ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
      "cd '${REMOTE_DIR}' && ./scripts/06-stop.sh" 2>/dev/null || true
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
echo "== 1. 실제 GitServer/ 디렉터리를 검증용 작업 디렉터리로 복사 =="
cp -R "$REPO_ROOT/$SERVICE_NAME/." "$REMOTE_DIR/"
rm -rf "${REMOTE_DIR:?}/data" "${REMOTE_DIR:?}/certs" "${REMOTE_DIR:?}/images"
mkdir -p "$REMOTE_DIR/images"

GITEA_IMAGE=$(grep '^GITEA_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)
NGINX_IMAGE=$(grep '^NGINX_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)

echo "== 2. 검증 전용 .env 로 교체 (원본 .env는 건드리지 않음) =="
cat > "$REMOTE_DIR/.env" <<EOF
GITEA_IMAGE=${GITEA_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
IMAGE_TAR_NAME=gitea-image.tar.gz
VM_SSH_HOST=127.0.0.1
VM_SSH_USER=${VM_USER}
VM_SSH_PORT=${VM_SSH_PORT}
VM_REMOTE_DIR=${REMOTE_DIR}
TLS_PORT=${TLS_PORT}
TLS_HTTP_PORT=${TLS_HTTP_PORT}
SSH_PORT=${GITEA_SSH_PORT}
TLS_DOMAIN=localhost
TLS_CERT_DAYS=825
USER_UID=1000
USER_GID=1000
TZ=Asia/Seoul
GITEA_DOMAIN=localhost
GITEA_ROOT_URL=https://localhost/
ADMIN_USER=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_EMAIL=admin@example.com
GITEA_SECRET_KEY=
GITEA_INTERNAL_TOKEN=
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
echo "== 6. [VM] 05-start.sh (TLS 인증서 생성 + 기동 + CLI 관리자 계정 생성) =="
STARTED=1
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "cd '${REMOTE_DIR}' && ./scripts/05-start.sh"

echo ""
echo "== 7. 검증 =="
CACERT="${REMOTE_DIR}/certs/server.crt"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" "https://127.0.0.1:${TLS_PORT}/api/healthz")
check "HTTPS healthz" "$CODE" "200"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" "https://127.0.0.1:${TLS_PORT}/api/v1/user")
check "관리자 API 인증" "$CODE" "200"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"check-repo","private":true}' \
  "https://127.0.0.1:${TLS_PORT}/api/v1/user/repos")
check "저장소 생성" "$CODE" "201"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" "https://127.0.0.1:${TLS_PORT}/api/v1/repos/admin/check-repo")
check "저장소 조회" "$CODE" "200"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
  -u "admin:${ADMIN_PASSWORD}" -X DELETE \
  "https://127.0.0.1:${TLS_PORT}/api/v1/repos/admin/check-repo")
check "저장소 삭제" "$CODE" "204"

ADMIN_LIST=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" 'docker exec -u 1000 gitea gitea admin user list')
if echo "$ADMIN_LIST" | grep -qw admin; then
  echo "   [OK] CLI 관리자 계정 목록에 admin 존재"
else
  echo "   [FAIL] CLI 관리자 계정 목록에서 admin을 찾지 못함"
  echo "$ADMIN_LIST"
  PASS=0
fi
