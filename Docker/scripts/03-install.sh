#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다. sudo 권한이 필요합니다.
# Docker Engine 정적 바이너리 + Compose 플러그인을 설치하고 systemd 서비스로 등록합니다.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

DOCKER_TAR="packages/docker-${DOCKER_VERSION}.tgz"
COMPOSE_BIN="packages/docker-compose"

[ -f "${DOCKER_TAR}" ] || { echo "!! ${DOCKER_TAR} 가 없습니다. 로컬에서 01-download.sh 실행 후 02-transfer-to-vm.sh 로 전송하세요." >&2; exit 1; }
[ -f "${COMPOSE_BIN}" ] || { echo "!! ${COMPOSE_BIN} 가 없습니다." >&2; exit 1; }

if command -v docker >/dev/null 2>&1; then
  echo ">> docker 명령이 이미 존재합니다: $(command -v docker)"
  echo ">> 계속 진행하면 바이너리를 덮어씁니다. 계속하려면 Enter, 중단하려면 Ctrl+C"
  read -r
fi

echo ">> 바이너리 추출 중..."
TMP_DIR=$(mktemp -d)
tar xzf "${DOCKER_TAR}" -C "${TMP_DIR}"

echo ">> /usr/bin 에 Docker 바이너리 설치 (sudo 필요)"
sudo cp "${TMP_DIR}"/docker/* /usr/bin/
rm -rf "${TMP_DIR}"

echo ">> docker 그룹 생성"
sudo groupadd -f docker

echo ">> Docker Compose 플러그인 설치"
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo cp "${COMPOSE_BIN}" /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo ">> systemd 서비스 등록"
sudo cp config/docker.service /etc/systemd/system/docker.service
sudo systemctl daemon-reload
sudo systemctl enable --now docker

if [ "${ADD_USER_TO_DOCKER_GROUP}" = "true" ]; then
  echo ">> 현재 사용자(${USER})를 docker 그룹에 추가"
  sudo usermod -aG docker "${USER}"
  echo ">> 그룹 반영을 위해 재로그인(또는 'newgrp docker') 이 필요합니다."
fi

echo ""
echo ">> 설치 완료. 확인 (sudo로 즉시 확인):"
sudo docker version
sudo docker compose version

echo ""
echo ">> 재로그인 후 scripts/04-verify.sh 로 sudo 없이 동작하는지 최종 확인하세요."
