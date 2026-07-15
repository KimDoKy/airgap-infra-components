#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# Gitea 컨테이너를 기동하고, 브라우저 설치 마법사 없이 CLI만으로 초기화합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p data
echo ">> ./data 디렉터리 소유권을 ${USER_UID}:${USER_GID} 로 설정합니다 (sudo 필요)."
sudo chown -R "${USER_UID}:${USER_GID}" data

"$(dirname "$0")/00-generate-secrets.sh"
"$(dirname "$0")/04-generate-tls-cert.sh"

docker compose up -d

echo ">> Gitea 기동 대기 중..."
READY=0
for i in $(seq 1 30); do
  if docker exec gitea gitea admin user list >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "${READY}" -ne 1 ]; then
  echo "!! Gitea가 시간 내에 기동되지 않았습니다. docker logs gitea 로 확인하세요." >&2
  exit 1
fi

echo ">> CLI로 관리자 계정 생성 시도: ${ADMIN_USER}"
if ! CREATE_OUT=$(docker exec gitea gitea admin user create \
    --username "${ADMIN_USER}" \
    --password "${ADMIN_PASSWORD}" \
    --email "${ADMIN_EMAIL}" \
    --admin --must-change-password=false 2>&1); then
  if echo "${CREATE_OUT}" | grep -qi "already exists"; then
    echo ">> 관리자 계정이 이미 존재합니다. 건너뜁니다."
  else
    echo "!! 관리자 계정 생성 실패:" >&2
    echo "${CREATE_OUT}" >&2
    exit 1
  fi
else
  echo ">> 관리자 계정 생성 완료."
fi

echo ">> nginx(TLS) 기동 대기 중..."
TLS_READY=0
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert certs/server.crt \
    "https://localhost:${TLS_PORT}/" || true)
  if [ "${CODE}" != "000" ]; then
    TLS_READY=1
    break
  fi
  sleep 2
done

if [ "${TLS_READY}" -ne 1 ]; then
  echo "!! nginx가 시간 내에 기동되지 않았습니다. docker logs gitea-nginx 로 확인하세요." >&2
  exit 1
fi

echo ""
echo ">> Gitea 준비 완료 (UI 없이 CLI로 초기화됨, TLS 적용됨)"
echo "   Web: https://<VM_IP>:${TLS_PORT} (또는 https://${TLS_DOMAIN}/)"
echo "   SSH clone 포트: ${SSH_PORT}"
echo "   관리자 계정: ${ADMIN_USER} / (.env 의 ADMIN_PASSWORD)"
echo "   자체 서명 인증서이므로 브라우저 경고가 뜨는 것은 정상입니다."
