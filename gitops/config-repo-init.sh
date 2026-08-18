#!/usr/bin/env bash
# config-repo(Gitea)를 **환경별 브랜치 모델**로 초기화. (nks/scripts/04 의 전제)
#   dev/test/prd 브랜치: 각각 apps/test-app/{deployment,service}.yaml (ns/env=해당 환경)
#   main 브랜치: 브랜치 모델 README (배포 대상 아님)
# 사용:
#   CONFIG_REPO_URL=acme-gitea:admin/config-repo.git \
#   NCR_REGISTRY=<host> NCR_PROJECT=acme-poc IMAGE_TAG=bootstrap \
#   ./config-repo-init.sh
set -euo pipefail
: "${CONFIG_REPO_URL:?config-repo git URL 필요(예: acme-gitea:admin/config-repo.git)}"
: "${NCR_REGISTRY:?}"; : "${NCR_PROJECT:=acme-poc}"; : "${IMAGE_TAG:=bootstrap}"
APP_NS_PREFIX="${APP_NS_PREFIX:-acme-app}"
ENVS="${ENVS:-dev test prd}"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git clone -q "$CONFIG_REPO_URL" "$W/cfg" 2>/dev/null || { mkdir -p "$W/cfg"; git -C "$W/cfg" init -q; git -C "$W/cfg" remote add origin "$CONFIG_REPO_URL"; }
cd "$W/cfg"
git config user.email ci@acme.local; git config user.name config-repo-init
BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

gen() {  # env
  local e="$1"; mkdir -p apps/test-app
  cat > apps/test-app/deployment.yaml <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: ${APP_NS_PREFIX}-${e}
  labels: { app: test-app, env: ${e} }
spec:
  replicas: 1
  selector: { matchLabels: { app: test-app } }
  template:
    metadata: { labels: { app: test-app, env: ${e} } }
    spec:
      imagePullSecrets: [{ name: ncr-cred }]
      nodeSelector: { env: ${e} }
      tolerations: [ { key: env, value: ${e}, effect: NoSchedule } ]
      containers:
        - name: test-app
          image: ${NCR_REGISTRY}/${NCR_PROJECT}/test-app:${IMAGE_TAG}
          ports: [{ containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /, port: 8080 }, initialDelaySeconds: 3, periodSeconds: 5 }
YAML
  cat > apps/test-app/service.yaml <<YAML
apiVersion: v1
kind: Service
metadata: { name: test-app, namespace: ${APP_NS_PREFIX}-${e} }
spec:
  selector: { app: test-app }
  ports: [{ port: 80, targetPort: 8080 }]
YAML
}

for e in $ENVS; do
  git checkout -q -B "$e" "$BASE" 2>/dev/null || git checkout -q -B "$e"
  git rm -q -r apps >/dev/null 2>&1 || true
  gen "$e"
  git add -A
  git commit -q -m "config-repo(${e}): apps/test-app (env=${e}, ns=${APP_NS_PREFIX}-${e})" || true
  echo "  ✓ 브랜치 ${e}"
done

# main = 브랜치 모델 문서
git checkout -q -B main "$BASE" 2>/dev/null || git checkout -q -B main
git rm -q -r apps >/dev/null 2>&1 || true
cat > README.md <<'MD'
# config-repo — 환경별 브랜치 모델
dev/test/prd 브랜치가 각 환경 매니페스트(apps/test-app/)를 가진다. main 은 배포 대상 아님(문서용).
ArgoCD: targetRevision=<브랜치>, path=apps/test-app. dev/test 자동, prd 수동 Sync.
승격(dev→test→prd)은 git merge 가 아니라 이미지 태그만 반영(../tools/promote-image.sh).
MD
git add -A; git commit -q -m "config-repo(main): 브랜치 모델 문서" || true

echo ">> push: $ENVS main"
git push -q origin $ENVS main
echo "✓ config-repo 브랜치 초기화 완료"
