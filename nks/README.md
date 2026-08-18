# nks/ — NHN NKS 셋업 (node taint / NCR / ArgoCD / 모니터링 / 외부접근)

NKS 클러스터 쪽 작업을 **로컬에서 kubectl+helm 으로 재현**하는 스크립트 모음. 서버(Gitea/Nexus/Jenkins)는
각 디렉터리에서 구축하고, 여기서는 클러스터 구성(노드 격리 + 배포/관측 플랫폼)을 담당한다.

> 전체 배포 플로우(Git→Jenkins→Nexus→NCR→ArgoCD→NKS)의 맥락·검증은 [`../gitops/nks-deploy-flow.md`](../gitops/nks-deploy-flow.md).

## 전제

- 로컬에 **kubectl**(대상 NKS 컨텍스트 설정됨) + **helm** + **openssl**.
- **SG**: ArgoCD(NKS)가 Gitea 를 감시하려면 **Gitea VM 의 SG 인바운드에 NKS 노드 서브넷 CIDR → TCP 443** 허용
  (NAT 미사용 시 파드→외부는 노드 IP 로 SNAT). NCR 은 인터넷 egress 로 도달(SG 불필요).
- **config-repo**(Gitea)가 **환경별 브랜치(dev/test/prd)** 로 초기화돼 있어야 함 — 각 브랜치 `apps/test-app/`
  (deployment+service, `env=<e>`). 부트스트랩: [`../gitops/config-repo-init.sh`](../gitops/config-repo-init.sh).

## 노드 taint 스킴 — dev / test / prd / ops

**taint 의 목적 = 앱 배포 격리 전용.** `env` 라벨/taint 키로 구분한다.
- **dev/test/prd = 워크로드 노드**: `env=<e>` 라벨 + `env=<e>:NoSchedule` taint. 앱은 `nodeSelector {env:<e>}`
  + `tolerations env=<e>` 로 해당 노드에만 배치.
- **ops = 플랫폼 노드**: `env=ops` **라벨만(taint 없음)**. ArgoCD·모니터링·Ingress 는 `nodeSelector env=ops`
  로 여기에 배치되고, **NKS 시스템 애드온(CoreDNS·calico-typha·konnectivity 등)도 taint 영향 없이** ops 에 스케줄된다.

> 즉 taint 는 앱(dev/test/prd)만 격리하고, **플랫폼/시스템 컴포넌트는 taint 의 영향을 전혀 받지 않는다.**
> 이 때문에 관리형 애드온이 스케줄 불가로 깨지는 문제가 없다.

## 실행 순서

```bash
cp .env.example .env      # 노드 이름/NCR/Gitea/비번 등 채우기
vi .env

# (사전) config-repo 환경 브랜치 초기화 (Gitea) — 최초 1회
CONFIG_REPO_URL=acme-gitea:admin/config-repo.git NCR_REGISTRY=<host> ../gitops/config-repo-init.sh

./scripts/01-label-taint-nodes.sh    # 노드 env label + taint (dev/test/prd; ops 는 라벨만)
./scripts/02-ncr-pull-secret.sh      # 워크로드 ns + NCR imagePullSecret(ncr-cred)
./scripts/03-install-ingress.sh      # ingress-nginx(LoadBalancer) → LB 공인 IP(.env 자동기록)
./scripts/04-install-argocd.sh       # ArgoCD(ops) + config-repo 등록 + Application(dev/test/prd)
./scripts/05-install-monitoring.sh   # kube-prometheus-stack(ops) — values: ../gitops/monitoring/values.yaml
./scripts/06-expose-monitoring.sh    # Grafana(자체로그인)+Prometheus(basic-auth) Ingress + 자체서명 TLS
./scripts/07-expose-argocd.sh        # ArgoCD 외부접근(insecure+ingress TLS, host argocd.<LB>.nip.io)
./scripts/99-verify.sh               # 전체 검증
```

- 각 스크립트는 **멱등**(label/taint `--overwrite`, `kubectl apply`, `helm upgrade --install`).
- 값은 전부 `.env`(플레이스홀더) 기반 — 문서/스크립트에 실제 IP·비밀 없음.

## 산출물 접근

| 대상 | 접근 | 인증 |
|---|---|---|
| Grafana | `https://grafana.<LB_IP>.nip.io` | Grafana 자체 로그인(admin) |
| Prometheus | `https://prometheus.<LB_IP>.nip.io` | ingress basic-auth(oncall) |
| ArgoCD | `https://argocd.<LB_IP>.nip.io` (07-expose-argocd.sh) | admin(초기비번: `argocd-initial-admin-secret`) |

## 관련
- 노드 사양/플레이버: [`../gitops/cluster/nodepools.nks.md`](../gitops/cluster/nodepools.nks.md)
- 모니터링 상세: [`../gitops/monitoring/README.md`](../gitops/monitoring/README.md)
- config-repo/Helm/ArgoCD 매니페스트: [`../gitops/`](../gitops/)
