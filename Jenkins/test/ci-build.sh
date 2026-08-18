#!/usr/bin/env bash
# acme CICD 연동 검증 — Jenkins Freestyle 잡이 실행하는 CI 스크립트.
# 핵심: Jenkins ↔ GitServer(소스 clone / config-repo push) ↔ Nexus(빌드 중 패키지 download) 연동.
# 잡 환경변수 NEXUS_PW(=ci 계정 비밀번호)를 주입받아 실행한다.
#   - jenkins 컨테이너는 host 의 docker.sock 을 마운트(DooD)하고 docker 그룹에 속함
#   - GitServer 접근: host.docker.internal:2222 (cicd 의 gitea 터널) + /var/jenkins_home/.ssh/id_ed25519
#   - Nexus 접근: docker build --network host → cicd 의 localhost:8443 (nexus 터널)
set -e
export GIT_SSH_COMMAND="ssh -i /var/jenkins_home/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new"
G=ssh://git@host.docker.internal:2222
TAG=b${BUILD_NUMBER}

echo "===== [1] 앱 소스 체크아웃 (GitServer) — git push 이벤트 → 최신 clone ====="
rm -rf app && git clone "$G/admin/test-app.git" app
cd app

echo "===== [2] 이미지 빌드 — 빌드 중 Nexus(raw-hosted)에서 패키지 다운로드 ====="
AUTH_B64=$(printf 'ci:%s' "${NEXUS_PW}" | base64 | tr -d '\n')
docker build --no-cache --network host \
  --build-arg NEXUS_URL=https://localhost:8443 \
  --build-arg NEXUS_AUTH_B64="$AUTH_B64" \
  -t test-app:${TAG} .

echo "===== [3] 이미지 검증 (Nexus 패키지 포함 확인) ====="
docker run --rm test-app:${TAG} | tee /tmp/out.txt
grep -q "acme build dependency" /tmp/out.txt && echo "NEXUS 패키지 포함 확인 OK"

echo "===== [4] NCR push (테스트 생략/표기만) ====="
echo "NCR push skip — 실제: pipeline/scripts/20-ncr-login-push.sh"

echo "===== [5] config-repo 업데이트 (GitServer) — ArgoCD 감시 대상 ====="
cd /var/jenkins_home
rm -rf cfg && git clone "$G/admin/config-repo.git" cfg
cd cfg
sed -i "s|tag: .*|tag: \"${TAG}\"|" apps/test-app/values.yaml
git config user.email ci@acme.local
git config user.name jenkins-ci
git commit -am "ci: bump test-app image tag -> ${TAG}"
git push origin main
echo "config-repo 갱신 완료:"; grep 'tag:' apps/test-app/values.yaml

docker image rm -f test-app:${TAG} >/dev/null 2>&1 || true
echo "===== DONE ====="
