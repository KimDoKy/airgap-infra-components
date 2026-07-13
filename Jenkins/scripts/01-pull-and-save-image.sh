#!/usr/bin/env bash
# [로컬 / 인터넷 연결 가능 PC] 에서 실행합니다.
# Jenkins 컨테이너 이미지를 내려받아 폐쇄망으로 옮길 tar.gz 파일로 저장합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

mkdir -p images

echo ">> Pulling image: ${JENKINS_IMAGE}"
docker pull "${JENKINS_IMAGE}"

echo ">> Saving image to images/${IMAGE_TAR_NAME}"
docker save "${JENKINS_IMAGE}" | gzip > "images/${IMAGE_TAR_NAME}"

ls -lh "images/${IMAGE_TAR_NAME}"
echo ">> 완료. images/${IMAGE_TAR_NAME} 파일과 이 Jenkins 디렉터리 전체를 VM으로 옮기세요."
