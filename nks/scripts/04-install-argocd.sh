#!/usr/bin/env bash
# [로컬/kubectl+helm] ArgoCD 설치(ops 노드) + config-repo(Gitea) 등록 + Application(dev/test/prd) 생성.
#   전제: NKS→Gitea:443 도달(Gitea SG 인바운드에 NKS 노드 CIDR 허용). config-repo 에 apps/test-app-<env>/ 존재.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need helm
: "${GITEA_REPO_URL:?}"; : "${GITEA_USER:?}"; : "${GITEA_PASSWORD:?}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

OV="$(mktemp)"; cat > "$OV" <<YAML
global:
  nodeSelector: { ${ENV_KEY}: ops }   # ops 는 taint 없음 → toleration 불필요
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

for e in dev test prd; do
  [ -n "$(nodes_for "$e")" ] || continue
  ns="${APP_NS_PREFIX}-${e}"
  echo ">> Application: test-app-${e} → path apps/test-app-${e} → ns ${ns}"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: test-app-${e}, namespace: argocd }
spec:
  project: default
  source: { repoURL: ${GITEA_REPO_URL}, targetRevision: main, path: apps/test-app-${e}, directory: { recurse: true } }
  destination: { server: https://kubernetes.default.svc, namespace: ${ns} }
  syncPolicy: { automated: { prune: true, selfHeal: true }, syncOptions: [ CreateNamespace=true ] }
YAML
done
echo ">> ArgoCD admin 초기비번:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null; echo
