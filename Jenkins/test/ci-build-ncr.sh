#!/usr/bin/env bash
# acme CICD (NKS/NCR) — Git SCM 이 test-app 을 워크스페이스에 체크아웃한 뒤 실행.
# 빌드 중 Nexus 패키지 다운로드 → 이미지 빌드 → NCR push → config-repo(GitOps) deployment 이미지 갱신.
# 잡에서 주입: NEXUS_PW(=ci 비번), NCR_USR/NCR_PSW(=ncr-cred 바인딩).
set -e
SHA=$(git rev-parse --short HEAD)
TAG=b${BUILD_NUMBER}-${SHA}
REG=<NCR_REGISTRY_HOST>
IMG=$REG/acme-poc/test-app

echo "===== [빌드] test-app ${SHA} — Nexus 패키지 다운로드 포함 ====="
AUTH_B64=$(printf 'ci:%s' "${NEXUS_PW}" | base64 | tr -d '\n')
docker build --no-cache --network host \
  --build-arg NEXUS_URL=https://localhost:8443 \
  --build-arg NEXUS_AUTH_B64="$AUTH_B64" \
  -t "$IMG:$TAG" .

echo "===== [NCR push] $IMG:$TAG ====="
echo "$NCR_PSW" | docker login "$REG" -u "$NCR_USR" --password-stdin
docker push "$IMG:$TAG"
docker logout "$REG" >/dev/null 2>&1 || true

echo "===== [config-repo] dev 브랜치 deployment 이미지 갱신 → push (ArgoCD 자동배포) ====="
# 환경별 브랜치 모델(dev/test/prd). CI 는 dev 브랜치만 갱신 → ArgoCD 가 dev 자동배포.
#   test/prd 승격은 별도(대상 브랜치의 이미지 태그 반영 + prd 는 수동 Sync 승인).
export GIT_SSH_COMMAND="ssh -i /var/jenkins_home/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new"
cd /var/jenkins_home; rm -rf cfg
git clone -b dev ssh://git@host.docker.internal:2222/admin/config-repo.git cfg; cd cfg
sed -i "s|image: .*/acme-poc/test-app:.*|image: ${IMG}:${TAG}|" apps/test-app/deployment.yaml
git config user.email ci@acme.local; git config user.name jenkins-ci
if git commit -am "ci(dev): test-app ${SHA} -> ${IMG}:${TAG}"; then
  git push origin dev; echo "config-repo(dev) 갱신됨: ${TAG}"
else
  echo "config-repo(dev) 변경 없음"
fi
grep 'image:' apps/test-app/deployment.yaml
docker image rm -f "$IMG:$TAG" >/dev/null 2>&1 || true
echo "===== DONE ====="
