# 모니터링 (Prometheus + Grafana) + 외부(온콜) 접근

NKS `infra` 노드에 kube-prometheus-stack(helm)을 올리고, **ingress-nginx + LoadBalancer** 로 외부에서
접근한다. 온콜 담당자는 **Grafana 를 자체 로그인**으로, **Prometheus 는 basic-auth** 로 보호된 URL 로 접근한다.

> 운영 접근 = **Ingress(외부·인증)**. `kubectl port-forward` 는 로컬 개발/관리용 보조 수단일 뿐 온콜 대응용이 아니다.

## 구성 요약

| 컴포넌트 | 배치 | 외부 접근 | 인증 |
|---|---|---|---|
| Grafana | infra 노드 | `https://grafana.<LB_IP>.nip.io` | **Grafana 자체 로그인**(admin) |
| Prometheus | infra 노드 | `https://prometheus.<LB_IP>.nip.io` | **ingress basic-auth**(oncall) |
| ingress-nginx | infra 노드 | LoadBalancer 공인 IP `<LB_IP>` | — |
| node-exporter | 전 노드(DS) | — | — |

- `<LB_IP>` 확인: `kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
- 도메인은 `nip.io`(공인 DNS, `grafana.<LB_IP>.nip.io` → `<LB_IP>`)로 별도 DNS 없이 host 라우팅.
- TLS 는 **자체서명**(SAN: 두 host) — 브라우저 경고 수락. 운영 시 cert-manager+Let's Encrypt(nip.io HTTP-01) 권장.
- Grafana 에 Prometheus 가 데이터소스로 연동됨 → **온콜은 Grafana 대시보드**로 대응, Prometheus UI 는 보조.

## 설치/구성 (재현)

### 1) 모니터링 스택
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f values.yaml   # values.yaml 의 <GRAFANA_PW>,<LB_IP> 치환
```
- `values.yaml`: prometheus/grafana/ksm/operator 는 `nodeSelector role=infra`, node-exporter 는 전 노드
  (`tolerations:[{operator:Exists}]`), alertmanager 비활성, Prometheus emptyDir(기본 SC 없음).

### 2) Ingress 컨트롤러 (LoadBalancer)
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.nodeSelector.role=infra \
  --set controller.admissionWebhooks.patch.nodeSelector.role=infra \
  --set controller.service.type=LoadBalancer
# 공인 IP 발급 확인(수십 초~수 분):
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

### 3) TLS + 인증 시크릿 (monitoring ns)
```bash
LBIP=<LB_IP>; GHOST=grafana.$LBIP.nip.io; PHOST=prometheus.$LBIP.nip.io
# 자체서명 TLS(두 host SAN)
openssl req -x509 -nodes -newkey rsa:2048 -keyout tls.key -out tls.crt -days 365 \
  -subj "/CN=acme-monitoring" -addext "subjectAltName=DNS:$GHOST,DNS:$PHOST"
kubectl create secret tls grafana-tls --cert=tls.crt --key=tls.key -n monitoring
kubectl create secret tls prom-tls    --cert=tls.crt --key=tls.key -n monitoring
# Prometheus basic-auth(htpasswd; 계정 oncall)
kubectl create secret generic prom-basic-auth -n monitoring \
  --from-literal=auth="oncall:$(openssl passwd -apr1 '<PROM_BASIC_PW>')"
```

### 4) Ingress
- Grafana: `values.yaml` 의 `grafana.ingress`(+`root_url`)로 helm 이 생성(`<LB_IP>` 치환 후 `helm upgrade`).
- Prometheus: [`prometheus-ingress.yaml`](prometheus-ingress.yaml) 적용(`<LB_IP>` 치환).
```bash
sed "s/<LB_IP>/$LBIP/g" prometheus-ingress.yaml | kubectl apply -f -
```

## 검증
```bash
LBIP=<LB_IP>
curl -k -o /dev/null -w "grafana %{http_code}\n"  https://grafana.$LBIP.nip.io/login          # 200
curl -k -o /dev/null -w "prom-noauth %{http_code}\n" https://prometheus.$LBIP.nip.io/-/ready   # 401
curl -k -u oncall:<PROM_BASIC_PW> -o /dev/null -w "prom-auth %{http_code}\n" \
     https://prometheus.$LBIP.nip.io/-/ready                                                   # 200
```
| 검증 | 기대 |
|---|---|
| Grafana `/login` | 200 (자체 로그인 페이지) |
| Grafana `/api/org` 인증 없이 / admin | 401 / 200 |
| Prometheus 인증 없이 / oncall | 401 / 200 |

## 계정 (플레이스홀더 — 실제 값은 별도 관리)
| 대상 | 계정 | 비밀번호 |
|---|---|---|
| Grafana | admin | `<GRAFANA_PW>` |
| Prometheus(basic-auth) | oncall | `<PROM_BASIC_PW>` |

## 보안/운영 메모
- Grafana 는 공개 노출되므로 강한 admin 비번 + (권장) OAuth/LDAP 연동, 익명 접근 off(기본) 유지.
- Prometheus 는 자체 인증이 없어 **반드시** ingress basic-auth 뒤에 둔다(직접 NodePort/LoadBalancer 노출 금지).
- 자체서명 TLS → 운영은 정식 인증서(cert-manager)로 교체 권장. LB 공인 IP 는 재생성 시 변할 수 있음(그때 host/cert 갱신).
