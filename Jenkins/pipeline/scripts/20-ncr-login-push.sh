#!/usr/bin/env bash
# 컴포넌트 이미지를 NCR(NHN Container Registry)로 push. docker login(basic auth).
# 자격은 Jenkins Credentials(id: ncr-cred) → 잡에서 NCR_USR/NCR_PSW 로 바인딩해 주입.
# 사용: 20-ncr-login-push.sh <component> <IMAGE_TAG>   (컴포넌트: frontend|backend)
set -euo pipefail
cd "$(dirname "$0")/../.."
. pipeline/pipeline.env

COMP="${1:?component 필요(frontend|backend)}"; IMAGE_TAG="${2:?IMAGE_TAG 필요}"
: "${NCR_REGISTRY:?}"; : "${NCR_PROJECT:?}"; : "${APP_NAME:?}"
: "${NCR_USR:?ncr-cred 바인딩 필요}"; : "${NCR_PSW:?ncr-cred 바인딩 필요}"
REPO="${NCR_REGISTRY}/${NCR_PROJECT}/${APP_NAME}-${COMP}"   # 예: .../acme-poc/acme-app-frontend

echo ">> NCR docker login: ${NCR_REGISTRY}"
echo "$NCR_PSW" | docker login "$NCR_REGISTRY" -u "$NCR_USR" --password-stdin

SRC="${APP_NAME}-${COMP}:${IMAGE_TAG}"
echo ">> tag & push: ${REPO}:${IMAGE_TAG}"
docker tag  "$SRC" "${REPO}:${IMAGE_TAG}"
docker push "${REPO}:${IMAGE_TAG}"
docker tag  "$SRC" "${REPO}:latest" && docker push "${REPO}:latest"
docker logout "$NCR_REGISTRY" >/dev/null 2>&1 || true
echo ">> push 완료: ${REPO}:${IMAGE_TAG}"
