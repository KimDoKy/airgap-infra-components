#!/usr/bin/env bash
# 공통 로더/헬퍼 — 각 스크립트가 source 한다.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NKS_DIR="$(dirname "$HERE")"

# .env 로드(없으면 .env.example 안내 후 종료)
if [ -f "$NKS_DIR/.env" ]; then
  set -a; . "$NKS_DIR/.env"; set +a
else
  echo "!! $NKS_DIR/.env 없음. '.env.example' 를 복사해 값을 채우세요:  cp .env.example .env" >&2
  exit 1
fi

: "${ENV_KEY:=env}"
: "${APP_NS_PREFIX:=acme-app}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! 필요 도구 없음: $1" >&2; exit 1; }; }
need kubectl

# 환경별 노드 목록 반환 (NODE_DEV 등). 인자: dev/test/prd/ops
nodes_for() {
  local e="$1"; local var="NODE_$(echo "$e" | tr '[:lower:]' '[:upper:]')"
  echo "${!var:-}"
}
# kubectl 컨텍스트 표시
kctx() { kubectl config current-context 2>/dev/null || echo "?"; }
