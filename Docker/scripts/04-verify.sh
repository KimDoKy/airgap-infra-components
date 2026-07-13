#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# Docker/Compose 설치 및 서비스 상태를 검증합니다.
# (이미지가 없는 상태이므로 `docker run` 을 이용한 pull 테스트는 하지 않습니다 -
#  실제 이미지 로드/기동 검증은 GitServer/Jenkins/Nexus 각 디렉터리에서 진행합니다.)
set -euo pipefail

echo ">> docker 바이너리 위치: $(command -v docker || echo 'NOT FOUND')"

echo ">> Docker 버전:"
if ! docker version; then
  echo "!! docker 명령 실행 실패." >&2
  echo "!! docker 그룹에 막 추가되었다면 재로그인(또는 'newgrp docker') 이 필요합니다." >&2
  echo "!! 급하게 확인하려면: sudo docker version" >&2
  exit 1
fi

echo ""
echo ">> Docker Compose 플러그인 버전:"
docker compose version

echo ""
echo ">> systemd 서비스 상태:"
systemctl is-active docker
systemctl is-enabled docker

echo ""
echo ">> docker info:"
docker info

echo ""
echo ">> 정상입니다. 이제 GitServer / Jenkins / Nexus 디렉터리의 이미지 로드(load-image) 및"
echo ">> 기동(start) 스크립트를 진행할 수 있습니다."
