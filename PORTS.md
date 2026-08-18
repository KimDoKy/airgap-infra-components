# 포트 정리 (Ports Reference)

인프라 전 구간의 포트를 계층별로 정리한다. IP·호스트·비밀은 플레이스홀더(`<...>`)로 표기하며 실제 값은
각 디렉터리의 `.env`(untracked)·라이브 환경에만 둔다. SSH 별칭(`acme-git`/`acme-cicd`/`acme-nexus`/
`acme-bastion`)은 운영자 로컬 `~/.ssh/config` 기준.

## 1. VM 서비스 노출 포트 (nginx 사이드카 종단, `.env` 변수)

각 서비스 컨테이너는 평문 HTTP 만 in-container 로 열고, **nginx 사이드카가 443(HTTPS)** 로 종단한다.

| 서비스 | 노출 포트 | `.env` 변수 | 비고 |
|---|---|---|---|
| 공통(3 VM) | **443** HTTPS / **80**→443 리다이렉트 | `TLS_PORT` / `TLS_HTTP_PORT` | nginx 사이드카만 노출 |
| 공통(3 VM) | **22** SSH | `VM_SSH_HOST` / `VM_SSH_PORT` | bastion 경유 관리 |
| **Gitea**(GitServer) | **2222** git-SSH | `SSH_PORT` | nginx 우회 **직접** 노출(git clone/push) |
| **Jenkins** | **50000** JNLP agent | `AGENT_PORT` | nginx 우회 직접 노출 |
| **Nexus** | 443 만 | — | git-SSH/agent 없음 |

## 2. VM 컨테이너 내부 / loopback 터널 (호스트 미노출)

| 대상 | 내부 포트 | 접근 방법 |
|---|---|---|
| Jenkins (in-container) | **8080** HTTP | 호스트 미노출 → nginx 뒤 `https://localhost/`(443) |
| Nexus (in-container) | **8081** HTTP | 〃 nginx→443 |
| Gitea (in-container) | **3000** HTTP | 〃 nginx→443 |
| CI 빌드 → Gitea | `host.docker.internal:`**2222** | cicd 로컬 SSH 터널 → gitea:2222 (clone/config-repo push) |
| CI 빌드 → Nexus | `localhost:`**8443** | cicd 로컬 SSH 터널 → nexus:443 (npm 패키지 다운로드) |

> `8443` 은 cicd **로컬 SSH 터널 종단**일 뿐, 실제 네트워크 경로는 `cicd → nexus:443`(SG 대상).

## 3. NKS 외부 접근 (ingress-nginx LoadBalancer, 공인 IP, host 기반 라우팅)

ingress-nginx 가 **LoadBalancer(공인 IP)** 로 443/80 을 잡고, `*.<LB_IP>.nip.io` 호스트로 분기한다(self-signed TLS).

| 대상 | URL | 포트 | 인증 |
|---|---|---|---|
| Grafana | `https://grafana.<LB_IP>.nip.io` | 443 | Grafana 자체 로그인(admin) |
| Prometheus | `https://prometheus.<LB_IP>.nip.io` | 443 | ingress **basic-auth**(oncall) |
| ArgoCD | `https://argocd.<LB_IP>.nip.io` | 443 | admin(초기비번 `argocd-initial-admin-secret`) |

> LB_IP 는 `nks/scripts/03-install-ingress.sh` 가 발급 후 `nks/.env` 의 `LB_IP` 에 자동 기록.
> 노출 스크립트: `06-expose-monitoring.sh`(Grafana/Prometheus), `07-expose-argocd.sh`(ArgoCD).

## 4. GUI 터널 — "잘 알려지지 않은 포트" (`tools/gui/`, 로컬 전용·선택)

기존 설정(폐쇄망·CLI/REST)은 그대로 두고, **로컬에서 GUI 로 보고 싶을 때만** 쓰는 보조 수단.

| 서비스 | 로컬 URL | 기본 포트 | 경로 | 기본 상태 |
|---|---|---|---|---|
| Gitea | `https://localhost:46173` | **46173** | SSH 터널 → `acme-git`:443 | on |
| Jenkins | `https://localhost:46271` | **46271** | SSH 터널 → `acme-cicd`:443 | on |
| Nexus | `https://localhost:46379` | **46379** | SSH 터널 → `acme-nexus`:443 | on |
| Grafana | `https://localhost:46411` | **46411** | port-forward → `kps-grafana`:80 | **opt-in** `GUI_MON_LOCAL=1` |
| Prometheus | `https://localhost:46533` | **46533** | port-forward → prometheus:9090 | **opt-in** `GUI_MON_LOCAL=1` |

> 포트 재정의: `GITEA_PORT=51987 ./gui-up.sh` (`JENKINS_PORT`/`NEXUS_PORT`/`GRAFANA_PORT`/`PROM_PORT` 동일).
> NKS 모니터링의 **운영 접근은 Ingress(3절)** 사용 권장 — 외부·온콜 대응 + 인증. 로컬 포워드는 opt-in.
> 실행/종료: `tools/gui/gui-up.sh` / `tools/gui/gui-down.sh`. 상세: [`tools/gui/README.md`](tools/gui/README.md).

## 5. SG(보안그룹) 인바운드 규칙

기본은 호스트 간 **22-only**, 아래 규칙만 명시적으로 추가한다.

| 흐름 | 규칙(출발지 → 목적지:포트) | 상태 |
|---|---|---|
| 개발자/운영자 → bastion | TCP **22** | 필요(공인) |
| bastion → 각 VM | TCP **22** | 열림 |
| 개발자 → Gitea(git) | bastion `gitgw`:22 → git localhost:**2222** | 게이트웨이(구성됨) |
| Jenkins → Gitea | `cicd → gitea:`**2222** | ★ 추가 필요(app clone + config-repo push) |
| Jenkins → Nexus | `cicd → nexus:`**443** | ★ 추가 필요 |
| **ArgoCD(NKS) → Gitea** | `<NKS_NODE_CIDR> → gitea:`**443** | ★ 추가 필요(config-repo HTTPS watch) |
| Jenkins → NCR | `cicd → <NCR_REGISTRY_HOST>:`**443** | 인터넷 egress 로 도달(SG 불필요) |
| NKS → NCR(pull) | `NKS → <NCR_REGISTRY_HOST>:`**443** | 인터넷 egress 로 도달(SG 불필요) |
| (미채택) Gitea → Jenkins webhook | `gitea → cicd:443` | SCM 폴링 채택으로 불필요 |

> NKS 는 인터넷 egress 만 가능 → NCR 은 열려 있으나 Gitea 는 단절. NAT 미사용이라 파드→Gitea 는 **노드 IP 로 SNAT**
> → 출발지 = **노드 CIDR**. 따라서 Gitea SG 인바운드 `<NKS_NODE_CIDR> → 443` 1건이면 ArgoCD 감시가 된다
> (git-SSH 2222 는 NKS 에서 도달 불가 → HTTPS 채택). 상세: [`gitops/nks-deploy-flow.md`](gitops/nks-deploy-flow.md) SG 절.

## 요약

- **대외 진입점은 둘뿐**: `bastion:22`, `NKS LB:443`(grafana/prometheus/argocd nip.io 3종).
- **VM 서비스**는 전부 nginx **443**(+ Gitea git-SSH **2222**, Jenkins agent **50000**). 내부 HTTP(8080/8081/3000)는 미노출.
- **CI 경로**는 cicd 로컬 터널(gitea 2222, nexus 8443)로 접근, 네트워크상 실제 포트는 2222/443.
- **SG** 기본 22-only + 명시 규칙(2222/443)만. NCR 은 egress 라 SG 불필요.
- **GUI**(46173/46271/46379/46411/46533)는 로컬 보조 수단(선택).

관련: [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`gitops/nks-deploy-flow.md`](gitops/nks-deploy-flow.md) · [`tools/gui/README.md`](tools/gui/README.md)
