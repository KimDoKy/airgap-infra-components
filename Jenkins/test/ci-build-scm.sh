#!/usr/bin/env bash
# acme CICD — SCM 폴링 잡용. Git SCM 이 test-app 을 워크스페이스에 체크아웃한 뒤 실행된다.
# (재clone 없음) 빌드 중 Nexus 다운로드 → config-repo(GitServer) 갱신.
set -e
SHA=$(git rev-parse --short HEAD)                 # 체크아웃된 test-app 커밋
TAG=b${BUILD_NUMBER}-${SHA}                        # 소스 커밋 기반 이미지 태그(추적성)
echo "===== [빌드] test-app ${SHA} — Nexus 패키지 다운로드 포함 ====="
AUTH_B64=$(printf 'ci:%s' "${NEXUS_PW}" | base64 | tr -d '\n')
docker build --no-cache --network host \
  --build-arg NEXUS_URL=https://localhost:8443 \
  --build-arg NEXUS_AUTH_B64="$AUTH_B64" \
  -t test-app:${TAG} .
echo "===== [검증] Nexus 패키지 포함 확인 ====="
docker run --rm test-app:${TAG} | tee /tmp/out.txt
grep -q "acme build dependency" /tmp/out.txt && echo "NEXUS 패키지 포함 확인 OK"
echo "===== [config-repo] 이미지 태그 갱신 → GitServer push (ArgoCD 감시 대상) ====="
export GIT_SSH_COMMAND="ssh -i /var/jenkins_home/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new"
cd /var/jenkins_home; rm -rf cfg
git clone ssh://git@host.docker.internal:2222/admin/config-repo.git cfg; cd cfg
sed -i "s|tag: .*|tag: \"${TAG}\"|" apps/test-app/values.yaml
git config user.email ci@acme.local; git config user.name jenkins-ci
if git commit -am "ci: test-app ${SHA} -> image tag ${TAG}"; then
  git push origin main; echo "config-repo 갱신됨: ${TAG}"
else
  echo "config-repo 변경 없음 (이미 ${TAG})"
fi
grep 'tag:' apps/test-app/values.yaml
docker image rm -f test-app:${TAG} >/dev/null 2>&1 || true
echo "===== DONE ====="
