#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# 브라우저 설치 마법사 없이 REST API(curl, nginx 경유 HTTPS)만으로 admin 비밀번호 변경 및
# 익명 접근 비활성화를 수행합니다. 05-start.sh 로 Nexus가 기동된 뒤 실행하세요.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

BASE_URL="https://localhost:${TLS_PORT}"
CACERT="certs/server.crt"

DEFAULT_PW=$(docker exec nexus cat /nexus-data/admin.password 2>/dev/null || true)

if [ -n "${DEFAULT_PW}" ]; then
  echo ">> 최초 생성된 admin 임시 비밀번호를 사용합니다."
  CURRENT_PW="${DEFAULT_PW}"
else
  echo ">> /nexus-data/admin.password 파일이 없습니다 (이미 비밀번호가 변경되었을 수 있음)."
  echo -n ">> 현재 admin 비밀번호를 입력하세요: "
  read -r -s CURRENT_PW
  echo ""
fi

echo ">> admin 비밀번호 변경 중..."
curl -sf --cacert "${CACERT}" -u "admin:${CURRENT_PW}" -X PUT \
  -H 'Content-Type: text/plain' \
  --data "${ADMIN_PASSWORD}" \
  "${BASE_URL}/service/rest/v1/security/users/admin/change-password"
echo ""
echo ">> admin 비밀번호가 .env 의 ADMIN_PASSWORD 로 변경되었습니다."

if [ "${DISABLE_ANONYMOUS_ACCESS}" = "true" ]; then
  echo ">> 익명(anonymous) 접근 비활성화 중..."
  curl -sf --cacert "${CACERT}" -u "admin:${ADMIN_PASSWORD}" -X PUT \
    -H 'Content-Type: application/json' \
    --data '{"enabled": false, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}' \
    "${BASE_URL}/service/rest/v1/security/anonymous"
  echo ""
fi

echo ">> Nexus CLI 초기 설정 완료 (TLS 적용됨)."
echo "   Web: https://<VM_IP>:${TLS_PORT} (또는 https://${TLS_DOMAIN}/)"
echo "   관리자 계정: admin / (.env 의 ADMIN_PASSWORD)"
echo "   자체 서명 인증서이므로 브라우저 경고가 뜨는 것은 정상입니다."
echo ""
echo ">> 이후 저장소(repository) 생성 등도 REST API로 UI 없이 진행할 수 있습니다. 예:"
echo "   curl --cacert ${CACERT} -u admin:<password> -X GET ${BASE_URL}/service/rest/v1/repositories"
