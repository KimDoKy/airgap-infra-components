#!/usr/bin/env bash
# config-repo 환경별 브랜치 승격 — 대상 env 브랜치의 apps/test-app 이미지 태그를 지정 태그로 반영·push.
#   dev→test→prd 승격은 git merge 가 아니라(브랜치별 ns/env 상이) 이미지 태그만 반영한다.
#   prd 는 push 후 ArgoCD 에서 **수동 Sync 승인** 필요(AppProject syncWindow deny).
# 사용: CONFIG_REPO_URL=<git url> ./promote-image.sh <dev|test|prd> <IMAGE_TAG>
#   예) ./promote-image.sh prd b12-abc1234
set -euo pipefail
ENVV="${1:?대상 env(dev|test|prd) 필요}"; TAG="${2:?IMAGE_TAG 필요}"
case "$ENVV" in dev|test|prd) ;; *) echo "env 는 dev|test|prd" >&2; exit 1;; esac
URL="${CONFIG_REPO_URL:-acme-gitea:admin/config-repo.git}"   # 로컬 gitea SSH 게이트웨이 별칭

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git clone -q -b "$ENVV" "$URL" "$W/cfg"
cd "$W/cfg"
sed -i "s|\\(image: .*/acme-poc/test-app:\\).*|\\1${TAG}|" apps/test-app/deployment.yaml
git config user.email release@acme.local; git config user.name promoter
if git commit -q -am "promote(${ENVV}): test-app image tag -> ${TAG}"; then
  git push -q origin "$ENVV"
  echo "✓ ${ENVV} 브랜치 승격: ${TAG}"
  [ "$ENVV" = "prd" ] && echo "  ⚠ prd: ArgoCD 에서 수동 Sync 승인 필요(자동 배포 아님)."
else
  echo "· ${ENVV} 변경 없음(이미 ${TAG})"
fi
