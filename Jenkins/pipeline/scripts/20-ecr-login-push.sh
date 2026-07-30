#!/usr/bin/env bash
# 컴포넌트 이미지를 ECR 로 push. aws CLI 미사용 — ECR REST(GetAuthorizationToken, SigV4)로 로그인.
# 자격은 VM IAM 인스턴스 프로파일(IMDSv2). ECR 은 VPC 엔드포인트(PrivateLink) 가정.
# 사용: 20-ecr-login-push.sh <component> <IMAGE_TAG>   (컴포넌트: frontend|backend)
set -euo pipefail
cd "$(dirname "$0")/../.."
. pipeline/pipeline.env
source pipeline/scripts/lib-awssigv4.sh

COMP="${1:?component 필요(frontend|backend)}"; IMAGE_TAG="${2:?IMAGE_TAG 필요}"
: "${AWS_REGION:?}"; : "${ECR_REGISTRY:?}"; : "${ECR_REPO:?}"; : "${APP_NAME:?}"
REPO="${ECR_REPO}-${COMP}"                       # 예: acme-app-frontend / acme-app-backend

echo ">> IAM 임시 자격 로드(IMDSv2)"
aws_load_creds_from_imds
echo ">> ECR 로그인(REST) → docker login"
ecr_auth_userpass "$AWS_REGION" | cut -d: -f2- \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

SRC="${APP_NAME}-${COMP}:${IMAGE_TAG}"
DST="${ECR_REGISTRY}/${REPO}:${IMAGE_TAG}"
echo ">> tag & push: $DST"
docker tag  "$SRC" "$DST"
docker push "$DST"                                # Docker Registry v2 API (aws cli 아님)
docker tag  "$SRC" "${ECR_REGISTRY}/${REPO}:latest" && docker push "${ECR_REGISTRY}/${REPO}:latest"
echo ">> push 완료: $DST"
