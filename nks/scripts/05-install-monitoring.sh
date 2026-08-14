#!/usr/bin/env bash
# [로컬/kubectl+helm] kube-prometheus-stack 설치(ops 노드). values 는 gitops/monitoring/values.yaml.
#   node-exporter 는 전 노드(DS, tolerations Exists). Grafana 외부노출은 06-expose-monitoring.sh.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need helm
: "${GRAFANA_ADMIN_PW:?}"

VALUES="$NKS_DIR/../gitops/monitoring/values.yaml"
[ -f "$VALUES" ] || { echo "!! values 없음: $VALUES"; exit 1; }

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# values 의 <GRAFANA_PW> 플레이스홀더를 .env 값으로 치환한 임시 파일 사용(원본 불변)
TMPV="$(mktemp)"; sed "s|<GRAFANA_PW>|${GRAFANA_ADMIN_PW}|g" "$VALUES" > "$TMPV"
echo ">> kube-prometheus-stack 설치/업그레이드..."
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f "$TMPV" >/dev/null
rm -f "$TMPV"

kubectl -n monitoring rollout status deploy/kps-grafana --timeout=180s >/dev/null 2>&1 || true
echo "  ✓ 설치 완료. node-exporter DS: $(kubectl get ds -n monitoring kps-prometheus-node-exporter -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
