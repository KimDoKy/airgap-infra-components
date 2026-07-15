#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# nginx가 사용할 자체 서명(self-signed) TLS 인증서를 생성합니다.
# 05-start.sh 에서 자동으로 호출되므로 보통 직접 실행할 필요는 없습니다.
# 인증서를 갱신하려면 ./certs 를 지우고 다시 실행하세요.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p certs

if [ -f certs/server.crt ] && [ -f certs/server.key ]; then
  echo ">> certs/server.crt, certs/server.key 가 이미 존재합니다. 건너뜁니다."
  echo ">> 재발급하려면 ./certs 를 삭제한 뒤 다시 실행하세요."
  exit 0
fi

SAN="subjectAltName=DNS:${TLS_DOMAIN},DNS:localhost,IP:127.0.0.1"
if [[ "${TLS_DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN="${SAN},IP:${TLS_DOMAIN}"
fi

echo ">> 자체 서명 인증서 생성 중 (CN=${TLS_DOMAIN}, ${TLS_CERT_DAYS}일 유효)"
openssl req -x509 -nodes -newkey rsa:2048 -days "${TLS_CERT_DAYS}" \
  -keyout certs/server.key -out certs/server.crt \
  -subj "/CN=${TLS_DOMAIN}" -addext "${SAN}"

chmod 600 certs/server.key

echo ">> 생성 완료: certs/server.crt, certs/server.key"
echo ">> 자체 서명 인증서이므로 브라우저에서 신뢰할 수 없다는 경고가 표시됩니다 (정상입니다)."
echo ">> 사내에 내부 CA가 있다면 이 스크립트 대신 발급받은 .crt/.key 를 certs/server.crt,"
echo ">> certs/server.key 로 직접 배치해도 됩니다."
