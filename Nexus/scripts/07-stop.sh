#!/usr/bin/env bash
# [폐쇄망 VM] 에서 실행합니다.
# Nexus 컨테이너를 중지합니다 (데이터는 ./nexus-data 에 보존됩니다).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down
