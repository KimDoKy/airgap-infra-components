#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# Nexus + nginx(TLS) 컨테이너를 기동하고 REST API 준비 상태까지 대기합니다.
# 초기 admin 비밀번호 설정 등 CLI 초기화는 06-configure.sh 에서 진행합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p nexus-data
echo ">> ./nexus-data 디렉터리 소유권을 ${NEXUS_UID}:${NEXUS_GID} 로 설정합니다 (sudo 필요)."
sudo chown -R "${NEXUS_UID}:${NEXUS_GID}" nexus-data

"$(dirname "$0")/04-generate-tls-cert.sh"

docker compose up -d

echo ">> Nexus 기동 대기 중 (nginx 경유, 최초 기동은 1~2분 이상 소요될 수 있습니다)..."
READY=0
for i in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert certs/server.crt \
    "https://localhost:${TLS_PORT}/service/rest/v1/status" || true)
  if [ "${CODE}" = "200" ]; then
    READY=1
    break
  fi
  sleep 5
done

if [ "${READY}" -ne 1 ]; then
  echo "!! Nexus/nginx가 시간 내에 기동되지 않았습니다." >&2
  echo "!! docker logs nexus 또는 docker logs nexus-nginx 로 확인하세요." >&2
  exit 1
fi

echo ">> Nexus 기동 완료 (TLS 적용됨)."
echo ">> 이어서 CLI(REST API)로 초기 설정을 진행하세요:"
echo "   ./scripts/06-configure.sh"
