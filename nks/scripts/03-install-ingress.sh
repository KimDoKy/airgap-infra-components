#!/usr/bin/env bash
# [로컬/kubectl+helm] ingress-nginx 설치(ops 노드, LoadBalancer). 외부(온콜) 진입점.
#   설치 후 LB 공인 IP 를 조회해 .env 의 LB_IP 에 기록(비어있을 때).
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need helm

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# ops 배치 (env=ops nodeSelector). ops 는 taint 없음 → toleration 불필요.
OV="$(mktemp)"; cat > "$OV" <<YAML
controller:
  nodeSelector: { ${ENV_KEY}: ops }
  admissionWebhooks:
    patch:
      nodeSelector: { ${ENV_KEY}: ops }
  service: { type: LoadBalancer }
  resources: { requests: { cpu: 50m, memory: 128Mi } }
YAML
echo ">> ingress-nginx 설치/업그레이드..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace -f "$OV" >/dev/null
rm -f "$OV"

echo ">> LoadBalancer 공인 IP 발급 대기..."
LB=""
for i in $(seq 1 30); do
  LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$LB" ] && break; sleep 10
done
[ -n "$LB" ] || { echo "!! LB IP 미발급. 'kubectl get svc -n ingress-nginx' 확인"; exit 1; }
echo "  ✓ LB_IP=$LB"

# .env 의 LB_IP 갱신(비었으면 기록)
if grep -qE '^LB_IP=""?$' "$NKS_DIR/.env" 2>/dev/null; then
  sed -i "s|^LB_IP=.*|LB_IP=$LB|" "$NKS_DIR/.env" && echo "  ✓ .env 에 LB_IP 기록"
fi
