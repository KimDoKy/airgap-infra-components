#!/usr/bin/env bash
# [로컬/kubectl+helm] 모니터링 외부(온콜) 노출: Grafana(자체 로그인) + Prometheus(ingress basic-auth), 자체서명 TLS.
#   host = grafana.<LB_IP>.nip.io / prometheus.<LB_IP>.nip.io. 전제: 03(ingress),05(monitoring) 완료.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need helm; need openssl
: "${GRAFANA_ADMIN_PW:?}"; : "${PROM_BASIC_USER:=oncall}"; : "${PROM_BASIC_PW:?}"

LB="${LB_IP:-}"
[ -n "$LB" ] || LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
[ -n "$LB" ] || { echo "!! LB_IP 미확인. 03-install-ingress.sh 먼저 실행하거나 .env 에 LB_IP 지정"; exit 1; }
GHOST="grafana.${LB}.nip.io"; PHOST="prometheus.${LB}.nip.io"
echo ">> hosts: $GHOST / $PHOST"

# 1) 자체서명 TLS(SAN 두 host) + basic-auth 시크릿
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TD/tls.key" -out "$TD/tls.crt" -days 365 \
  -subj "/CN=acme-monitoring" -addext "subjectAltName=DNS:${GHOST},DNS:${PHOST}" 2>/dev/null
kubectl create secret tls grafana-tls --cert="$TD/tls.crt" --key="$TD/tls.key" -n monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret tls prom-tls    --cert="$TD/tls.crt" --key="$TD/tls.key" -n monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic prom-basic-auth -n monitoring \
  --from-literal=auth="${PROM_BASIC_USER}:$(openssl passwd -apr1 "$PROM_BASIC_PW")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  ✓ grafana-tls / prom-tls / prom-basic-auth"

# 2) Grafana ingress + root_url (helm, 자체 로그인 사용)
VALUES="$NKS_DIR/../gitops/monitoring/values.yaml"
TMPV="$(mktemp)"; sed "s|<GRAFANA_PW>|${GRAFANA_ADMIN_PW}|g" "$VALUES" > "$TMPV"
OV="$(mktemp)"; cat > "$OV" <<YAML
grafana:
  grafana.ini:
    server: { root_url: "https://${GHOST}" }
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts: [ "${GHOST}" ]
    tls: [ { secretName: grafana-tls, hosts: [ "${GHOST}" ] } ]
YAML
helm upgrade kps prometheus-community/kube-prometheus-stack -n monitoring -f "$TMPV" -f "$OV" >/dev/null
rm -f "$TMPV" "$OV"
echo "  ✓ Grafana ingress"

# 3) Prometheus ingress (basic-auth)
kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: prom-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: Prometheus-oncall
spec:
  ingressClassName: nginx
  tls: [ { hosts: [ "${PHOST}" ], secretName: prom-tls } ]
  rules:
    - host: "${PHOST}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: kps-kube-prometheus-stack-prometheus, port: { number: 9090 } } }
YAML
echo "  ✓ Prometheus ingress (basic-auth)"
echo
echo "== 외부 접근 =="
echo "  Grafana    : https://${GHOST}        (admin / \$GRAFANA_ADMIN_PW)"
echo "  Prometheus : https://${PHOST}        (${PROM_BASIC_USER} / \$PROM_BASIC_PW)"
echo "  (자체서명 TLS → 브라우저 경고 수락)"
