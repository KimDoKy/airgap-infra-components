#!/usr/bin/env bash
# SECRET_KEY / INTERNAL_TOKEN 을 생성해 .env 에 기록합니다.
# Gitea 이미지가 로컬 docker에 존재해야 합니다 (pull 또는 load 이후에 실행).
# 03-start.sh 에서 자동으로 호출되므로 보통 직접 실행할 필요는 없습니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

if [ -n "${GITEA_SECRET_KEY}" ] && [ -n "${GITEA_INTERNAL_TOKEN}" ]; then
  echo ">> SECRET_KEY / INTERNAL_TOKEN 이 이미 생성되어 있습니다. 건너뜁니다."
  exit 0
fi

echo ">> SECRET_KEY 생성 중..."
SECRET_KEY=$(docker run --rm "${GITEA_IMAGE}" gitea generate secret SECRET_KEY)

echo ">> INTERNAL_TOKEN 생성 중..."
INTERNAL_TOKEN=$(docker run --rm "${GITEA_IMAGE}" gitea generate secret INTERNAL_TOKEN)

sed -i.bak "s|^GITEA_SECRET_KEY=.*|GITEA_SECRET_KEY=${SECRET_KEY}|" .env
sed -i.bak "s|^GITEA_INTERNAL_TOKEN=.*|GITEA_INTERNAL_TOKEN=${INTERNAL_TOKEN}|" .env
rm -f .env.bak

echo ">> .env 에 SECRET_KEY / INTERNAL_TOKEN 을 저장했습니다."
