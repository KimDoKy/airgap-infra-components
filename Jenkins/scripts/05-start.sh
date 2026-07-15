#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# Jenkins 컨테이너를 기동합니다. 설치 마법사(UI)는 완전히 비활성화되며,
# init.groovy.d 스크립트가 CLI(무인)로 관리자 계정을 생성합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p jenkins_home/init.groovy.d
cp config/init.groovy.d/basic-security.groovy jenkins_home/init.groovy.d/basic-security.groovy

echo ">> ./jenkins_home 디렉터리 소유권을 ${JENKINS_UID}:${JENKINS_GID} 로 설정합니다 (sudo 필요)."
sudo chown -R "${JENKINS_UID}:${JENKINS_GID}" jenkins_home

"$(dirname "$0")/04-generate-tls-cert.sh"

docker compose up -d

echo ">> Jenkins 기동 중입니다 (최초 기동은 1~2분 소요될 수 있습니다)."
echo ">> 준비 상태 확인:"
READY=0
for i in $(seq 1 60); do
  CODE=$(docker exec jenkins curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login || true)
  if [ "${CODE}" = "200" ] || [ "${CODE}" = "403" ]; then
    READY=1
    break
  fi
  sleep 3
done

if [ "${READY}" -ne 1 ]; then
  echo "!! Jenkins가 시간 내에 기동되지 않았습니다. docker logs jenkins 로 확인하세요." >&2
  exit 1
fi

echo ">> nginx(TLS) 기동 대기 중..."
TLS_READY=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert certs/server.crt \
    "https://localhost:${TLS_PORT}/login" || true)
  if [ "${CODE}" != "000" ]; then
    TLS_READY=1
    break
  fi
  sleep 2
done

if [ "${TLS_READY}" -ne 1 ]; then
  echo "!! nginx가 시간 내에 기동되지 않았습니다. docker logs jenkins-nginx 로 확인하세요." >&2
  exit 1
fi

echo ""
echo ">> Jenkins 준비 완료 (설치 마법사 없이 CLI로 초기화됨, TLS 적용됨)"
echo "   Web: https://<VM_IP>:${TLS_PORT} (또는 https://${TLS_DOMAIN}/)"
echo "   관리자 계정: ${JENKINS_ADMIN_ID} / (.env 의 JENKINS_ADMIN_PASSWORD)"
echo "   자체 서명 인증서이므로 브라우저 경고가 뜨는 것은 정상입니다."
echo ""
echo ">> CLI 전용 관리를 위한 Jenkins CLI 사용법:"
echo "   docker exec jenkins curl -s http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar"
echo "   docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ \\"
echo "     -auth ${JENKINS_ADMIN_ID}:<password> who-am-i"
