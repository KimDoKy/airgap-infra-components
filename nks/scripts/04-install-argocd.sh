#!/usr/bin/env bash
# [로컬/kubectl+helm] ArgoCD 설치(ops 노드) + config-repo(Gitea) 등록 + env AppProject/Application 생성.
#   전제: NKS→Gitea:443 도달(Gitea SG 인바운드에 NKS 노드 CIDR 허용).
#         config-repo 에 **환경별 브랜치(dev/test/prd)** + 각 브랜치 apps/test-app/ 존재(gitops/config-repo-init.sh).
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need helm
: "${GITEA_REPO_URL:?}"; : "${GITEA_USER:?}"; : "${GITEA_PASSWORD:?}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

OV="$(mktemp)"; cat > "$OV" <<YAML
global:
  nodeSelector: { ${ENV_KEY}: ops }   # ops 는 taint 없음 → toleration 불필요
configs:
  cm:
    accounts.developer: apiKey,login
    accounts.releasemgr: apiKey,login
  rbac:
    policy.default: role:readonly            # 미지정 사용자는 읽기만(sync 불가)
    scopes: '[groups]'
    policy.csv: |
      p, role:developer, applications, get, */*, allow
      p, role:developer, applications, sync, acme-dev/*, allow
      p, role:developer, applications, sync, acme-test/*, allow
      p, role:release-manager, applications, get, */*, allow
      p, role:release-manager, applications, sync, acme-dev/*, allow
      p, role:release-manager, applications, sync, acme-test/*, allow
      p, role:release-manager, applications, sync, acme-prd/*, allow
      g, developer, role:developer
      g, releasemgr, role:release-manager
YAML
echo ">> ArgoCD 설치/업그레이드..."
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f "$OV" >/dev/null
rm -f "$OV"
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s >/dev/null 2>&1 || true

echo ">> config-repo 등록(insecure=${ARGOCD_INSECURE_REPO:-true})"
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: config-repo
  namespace: argocd
  labels: { argocd.argoproj.io/secret-type: repository }
stringData:
  type: git
  url: ${GITEA_REPO_URL}
  username: ${GITEA_USER}
  password: ${GITEA_PASSWORD}
  insecure: "${ARGOCD_INSECURE_REPO:-true}"
YAML

# env 별 AppProject(격리) + Application. prd 는 자동 sync 없음(=수동 승인 게이트). test/dev 는 자동.
PROJ_DIR="$NKS_DIR/../gitops/argocd/projects"
for e in dev test prd; do
  [ -n "$(nodes_for "$e")" ] || continue
  ns="${APP_NS_PREFIX}-${e}"
  # (1) AppProject (repo 화이트리스트 <GITEA_REPO_URL> 치환)
  if [ -f "$PROJ_DIR/appproject-${e}.yaml" ]; then
    sed "s|<GITEA_REPO_URL>|${GITEA_REPO_URL}|g" "$PROJ_DIR/appproject-${e}.yaml" | kubectl apply -f - >/dev/null
    echo ">> AppProject: acme-${e}"
  fi
  # (2) Application — prd 는 automated 제거(수동), dev/test 는 자동
  if [ "$e" = "prd" ]; then SYNC='syncOptions: [ CreateNamespace=true ]'; MODE='수동승인';
  else SYNC='automated: { prune: true, selfHeal: true }, syncOptions: [ CreateNamespace=true ]'; MODE='자동'; fi
  echo ">> Application: test-app-${e} (project=acme-${e}, ${MODE}) → ns ${ns}"
  # config-repo 는 환경별 브랜치(dev/test/prd). targetRevision=<env 브랜치>, path=apps/test-app(통일).
  kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: test-app-${e}, namespace: argocd }
spec:
  project: acme-${e}
  source: { repoURL: ${GITEA_REPO_URL}, targetRevision: ${e}, path: apps/test-app, directory: { recurse: true } }
  destination: { server: https://kubernetes.default.svc, namespace: ${ns} }
  syncPolicy: { ${SYNC} }
YAML
done
echo ">> ArgoCD admin 초기비번:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null; echo
echo ">> RBAC 계정(developer/releasemgr) 비밀번호는 설치 후 설정 필요(헬름은 비번 미설정):"
echo "   argocd login <서버> --username admin --password <admin초기비번>"
echo "   argocd account update-password --account developer  --new-password '<비번>'"
echo "   argocd account update-password --account releasemgr  --new-password '<비번>'"
echo "   (developer=dev/test sync, releasemgr=prd 포함 sync, 그 외 readonly)"
