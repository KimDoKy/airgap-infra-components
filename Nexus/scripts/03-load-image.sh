#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# 로컬 PC에서 전달받은 이미지 tar.gz 파일(Nexus + nginx)을 이 VM의 docker에 로드합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

TAR_FILE="images/${IMAGE_TAR_NAME}"

if [ ! -f "${TAR_FILE}" ]; then
  echo "!! ${TAR_FILE} 파일이 없습니다. 로컬 PC에서 01-pull-and-save-image.sh 를 먼저 실행하고" >&2
  echo "!! 생성된 파일을 이 VM의 동일 경로(images/)로 옮기세요." >&2
  exit 1
fi

echo ">> Loading image from ${TAR_FILE}"
gunzip -c "${TAR_FILE}" | docker load

echo ">> 로드된 이미지 목록:"
docker images
