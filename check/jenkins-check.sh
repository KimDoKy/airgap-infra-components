#!/usr/bin/env bash
# Jenkins(+ nginx TLS) 를 "가짜 VM"에 실제로 배포해 end-to-end로 검증합니다.
#
# Jenkins/scripts/ 안의 실제 배포 스크립트(01~06)를 수정 없이 그대로,
# 문서(README.md/MANUAL.md)에 적힌 순서대로 실행합니다:
#   01-pull-and-save-image.sh (로컬) -> 02-transfer-to-vm.sh (로컬, SSH 전송)
#   -> 03-load-image.sh (VM) -> 05-start.sh (VM, TLS 인증서 생성 + 기동 + CLI 초기화)
#   -> HTTPS 헬스체크 / Jenkins CLI 인증 확인 -> 06-stop.sh (VM) -> 정리
#
# 원본 Jenkins/.env, Jenkins/certs, Jenkins/jenkins_home 은 전혀 건드리지 않습니다.
# (검증용 사본을 check/.work/ 아래에 만들어 그 안에서만 작업합니다)
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CHECK_DIR/.." && pwd)"
# shellcheck source=lib/mock-vm.sh
source "$CHECK_DIR/lib/mock-vm.sh"

SERVICE_NAME="Jenkins"
VM_NAME="mock-vm-jenkins"
VM_SSH_PORT="$MOCK_VM_SSH_PORT"
VM_USER=tester
WORKDIR="$CHECK_DIR/.work/jenkins"
REMOTE_DIR="$WORKDIR/$SERVICE_NAME"

TLS_PORT=18444
TLS_HTTP_PORT=18081
AGENT_PORT=15000
ADMIN_ID="admin"
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
echo "== 1. 실제 Jenkins/ 디렉터리를 검증용 작업 디렉터리로 복사 =="
cp -R "$REPO_ROOT/$SERVICE_NAME/." "$REMOTE_DIR/"
rm -rf "${REMOTE_DIR:?}/jenkins_home" "${REMOTE_DIR:?}/certs" "${REMOTE_DIR:?}/images"
mkdir -p "$REMOTE_DIR/images"

JENKINS_IMAGE=$(grep '^JENKINS_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)
NGINX_IMAGE=$(grep '^NGINX_IMAGE=' "$REPO_ROOT/$SERVICE_NAME/.env" | cut -d= -f2)

echo "== 2. 검증 전용 .env 로 교체 (원본 .env는 건드리지 않음) =="
cat > "$REMOTE_DIR/.env" <<EOF
JENKINS_IMAGE=${JENKINS_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
IMAGE_TAR_NAME=jenkins-image.tar.gz
VM_SSH_HOST=127.0.0.1
VM_SSH_USER=${VM_USER}
VM_SSH_PORT=${VM_SSH_PORT}
VM_REMOTE_DIR=${REMOTE_DIR}
TLS_PORT=${TLS_PORT}
TLS_HTTP_PORT=${TLS_HTTP_PORT}
AGENT_PORT=${AGENT_PORT}
TLS_DOMAIN=localhost
TLS_CERT_DAYS=825
TZ=Asia/Seoul
JENKINS_UID=1000
JENKINS_GID=1000
JENKINS_ADMIN_ID=${ADMIN_ID}
JENKINS_ADMIN_PASSWORD=${ADMIN_PASSWORD}
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
echo "== 6. [VM] 05-start.sh (TLS 인증서 생성 + 기동 + CLI 무인 초기화) =="
STARTED=1
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "cd '${REMOTE_DIR}' && ./scripts/05-start.sh"

echo ""
echo "== 7. 검증 =="
CACERT="${REMOTE_DIR}/certs/server.crt"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" "https://127.0.0.1:${TLS_PORT}/login")
check "HTTPS /login 응답" "$CODE" "200"

# 설치 마법사가 비활성화되어 있는지 확인 (뜨면 안 됨)
BODY=$(curl -s --cacert "$CACERT" "https://127.0.0.1:${TLS_PORT}/login")
if echo "$BODY" | grep -qi "Unlock Jenkins"; then
  echo "   [FAIL] 설치 마법사(Unlock Jenkins) 화면이 떠 있음 - runSetupWizard=false 미적용"
  PASS=0
else
  echo "   [OK] 설치 마법사 비활성화 확인 (Unlock Jenkins 화면 없음)"
fi

echo ""
echo "== 8. Jenkins CLI 인증 확인 (init.groovy.d 로 생성된 관리자 계정) =="
ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
  'docker exec jenkins curl -s http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar'
WHOAMI=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
  "docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${ADMIN_ID}:${ADMIN_PASSWORD} who-am-i" 2>&1)
if echo "$WHOAMI" | grep -qw "${ADMIN_ID}"; then
  echo "   [OK] Jenkins CLI who-am-i 인증 성공 (${ADMIN_ID})"
else
  echo "   [FAIL] Jenkins CLI who-am-i 인증 실패"
  echo "$WHOAMI"
  PASS=0
fi

echo ""
echo "== 9. 기능 확인: Job 생성 -> 조회 -> 삭제 =="
# jenkins 컨테이너는 mock VM과 호스트 도커 데몬을 공유하는 형제 컨테이너이므로,
# 설정 XML은 SSH 이중 홉(heredoc) 대신 호스트에서 바로 `docker cp` 로 넣는 편이 안정적입니다.
cat > "$WORKDIR/job-config.xml" <<'EOF_JOB'
<?xml version="1.0" encoding="UTF-8"?><project><actions/><description/><keepDependencies>false</keepDependencies><properties/><scm class="hudson.scm.NullSCM"/><canRoam>true</canRoam><disabled>false</disabled><blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding><blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding><triggers/><concurrentBuild>false</concurrentBuild><builders/><publishers/><buildWrappers/></project>
EOF_JOB
docker cp "$WORKDIR/job-config.xml" jenkins:/tmp/job-config.xml

CREATE_OUT=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
  "docker exec jenkins sh -c 'java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${ADMIN_ID}:${ADMIN_PASSWORD} create-job check-job < /tmp/job-config.xml'" 2>&1) || true

LIST_OUT=$(ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
  "docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${ADMIN_ID}:${ADMIN_PASSWORD} list-jobs" 2>&1)
if echo "$LIST_OUT" | grep -qw "check-job"; then
  echo "   [OK] Job 생성/조회 성공 (check-job)"
else
  echo "   [FAIL] Job 생성/조회 실패"
  echo "$CREATE_OUT"
  echo "$LIST_OUT"
  PASS=0
fi

ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" \
  "docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${ADMIN_ID}:${ADMIN_PASSWORD} delete-job check-job" >/dev/null 2>&1 \
  && echo "   [OK] Job 삭제 성공" \
  || { echo "   [FAIL] Job 삭제 실패"; PASS=0; }
