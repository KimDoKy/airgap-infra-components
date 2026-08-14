#!/usr/bin/env bash
# [로컬/kubectl] ArgoCD 외부(운영) 접근: argocd-server insecure(HTTP) + ingress TLS 종료 + host.
#   host = argocd.<LB_IP>.nip.io. ArgoCD 자체 로그인(admin) 사용. 전제: 03(ingress),04(argocd) 완료.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need openssl

LB="${LB_IP:-}"
[ -n "$LB" ] || LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
[ -n "$LB" ] || { echo "!! LB_IP 미확인. 03-install-ingress.sh 먼저"; exit 1; }
AHOST="argocd.${LB}.nip.io"
echo ">> host: $AHOST"

# 1) argocd-server 를 insecure(HTTP) 로 (ingress 에서 TLS 종료)
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null
kubectl -n argocd rollout restart deploy/argocd-server >/dev/null
kubectl -n argocd rollout status deploy/argocd-server --timeout=120s >/dev/null 2>&1 || true

# 2) 자체서명 TLS
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TD/tls.key" -out "$TD/tls.crt" -days 365 \
  -subj "/CN=argocd" -addext "subjectAltName=DNS:${AHOST}" 2>/dev/null
kubectl create secret tls argocd-tls --cert="$TD/tls.crt" --key="$TD/tls.key" -n argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 3) Ingress
kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTP
spec:
  ingressClassName: nginx
  tls: [ { hosts: [ "${AHOST}" ], secretName: argocd-tls } ]
  rules:
    - host: "${AHOST}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: argocd-server, port: { number: 80 } } }
YAML
echo "  ✓ ArgoCD: https://${AHOST}  (admin / 초기비번: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
