#!/usr/bin/env bash
# CI 마지막 단계 — GitOps repo 의 values-<env>.yaml 이미지 태그를 갱신·커밋·push.
# 이후 ArgoCD 가 커밋을 감지해 NKS 로 동기화(배포는 ArgoCD 담당, Jenkins 는 NKS 미접근).
# Git 인증: Jenkinsfile 이 sshagent(['gitea-ssh']) 로 키 제공 → 여기선 GIT_SSH_COMMAND 만 지정.
# 사용: 21-update-gitops.sh <dev|test|prd> <IMAGE_TAG>
set -euo pipefail
cd "$(dirname "$0")/../.."
. pipeline/pipeline.env

DEPLOY_ENV="${1:?dev|test|prd 필요}"; TAG="${2:?IMAGE_TAG 필요}"
: "${GITOPS_REPO_URL:?}"; GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
case "$DEPLOY_ENV" in dev|test|prd) ;; *) echo "환경은 dev|test|prd" >&2; exit 1;; esac

export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
WORK=$(mktemp -d)
git clone --depth 1 -b "$GITOPS_BRANCH" "$GITOPS_REPO_URL" "$WORK"

VF="$WORK/helm/acme-app/values-${DEPLOY_ENV}.yaml"
[ -f "$VF" ] || { echo "!! $VF 없음" >&2; exit 1; }
# frontend/backend 둘 다 같은 커밋(IMAGE_TAG)으로 빌드됐으므로 파일 내 모든 image tag 를 일괄 치환
sed -i "s/\(tag:[[:space:]]*\)\"[^\"]*\"/\1\"${TAG}\"/g" "$VF"

cd "$WORK"
git config user.email "ci@acme.local"; git config user.name "jenkins-ci"
git add "$VF"
if git diff --cached --quiet; then echo ">> 태그 변경 없음(동일) — push 생략"; else
  git commit -m "ci(${DEPLOY_ENV}): image tag -> ${TAG}"
  git push origin "$GITOPS_BRANCH"
  echo ">> GitOps 갱신 완료: ${DEPLOY_ENV} -> ${TAG} (ArgoCD 가 동기화)"
fi
rm -rf "$WORK"
