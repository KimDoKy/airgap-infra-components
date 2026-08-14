#!/usr/bin/env bash
# [로컬/kubectl] NKS 셋업 검증: 노드 taint / 워크로드 배치 / ArgoCD / 모니터링 / 외부접근.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo "== 노드 label/taint =="
kubectl get nodes -L "$ENV_KEY" -o custom-columns='NODE:.metadata.name,ENV:.metadata.labels.'"$ENV_KEY"',TAINTS:.spec.taints[*].key' 2>/dev/null

echo; echo "== 워크로드 배치(env 노드 일치 확인) =="
for e in dev test prd; do
  ns="${APP_NS_PREFIX}-${e}"
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl get pods -n "$ns" -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' --no-headers 2>/dev/null
done

echo; echo "== ArgoCD Applications =="
kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || echo "(argocd 미설치)"

echo; echo "== 모니터링 =="
kubectl get pods -n monitoring --no-headers 2>/dev/null | awk '{print "  "$1" "$3}'
echo "  node-exporter DS: $(kubectl get ds -n monitoring kps-prometheus-node-exporter -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"

echo; echo "== 외부 접근 (ingress) =="
kubectl get ingress -A 2>/dev/null | grep -vE '^NAMESPACE' || true
LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
[ -n "$LB" ] && echo "  LB_IP=$LB  → https://grafana.${LB}.nip.io / https://prometheus.${LB}.nip.io"
