# acme CI/CD 아키텍처 — 폐쇄망 CI(Jenkins) + 클라우드 CD(ArgoCD on NKS)

**CI 는 폐쇄망 VM(Jenkins), CD 는 클라우드 NKS(ArgoCD)** 로 분리된 GitOps 구조. 폐쇄망 세 서버
(Gitea·Nexus·Jenkins)의 **구조 · 연동 방법 · 선택 이유**와, 이들을 NHN NKS 클러스터로 잇는 배포
플로우를 정리한 문서. 각 서버의 상세 절차는 해당 디렉터리의 `README/BUILD/ADMIN/USER.md` 를,
전체 배포 플로우의 실측 런북은 [`gitops/nks-deploy-flow.md`](gitops/nks-deploy-flow.md) 를 참고하세요.

---

## 0. 공통 환경

- **폐쇄망(air-gapped) VM**: 대상 VM(Gitea/Nexus/Jenkins)은 인터넷/외부 레지스트리에 접근 불가.
  이미지·패키지·도구는 모두 **로컬(인터넷) PC 에서 받아 bastion 경유로 반입**.
- **클라우드 NKS**: 별도 네트워크의 NHN **NKS** 클러스터. **인터넷 egress 만** 가능(→ NCR pull 가능,
  Gitea 는 SG 로 명시 허용해야 도달). 폐쇄망 VM 망과는 기본적으로 단절.
- **네트워크(VM)**: 모든 서비스 VM 은 private subnet. 외부에서는 **bastion(공인 `<BASTION_PUBLIC_IP>`)** 을
  거쳐야 접근. VM 간·VM 인바운드는 **SG 로 포트 22 만** 기본 허용(그 외는 명시적으로만 개방).

| 구성요소 | 별칭 | 사설 IP | 역할 |
|---|---|---|---|
| GitServer | `acme-git` | <GITEA_IP> | Gitea (형상관리: app + config-repo) |
| Nexus | `acme-nexus` | <NEXUS_IP> | 아티팩트 저장소(npm 의존성) |
| CICD | `acme-cicd` | <CICD_IP> | Jenkins (CI: 빌드·NCR push·config-repo 갱신) |
| bastion | `acme-bastion` | <BASTION_PUBLIC_IP>(공인) | 점프 호스트 |
| NKS 클러스터 | — | 노드 CIDR `<NKS_NODE_CIDR>` | ArgoCD(CD)·모니터링·Ingress·앱 실행 |
| NCR | — | `<NCR_REGISTRY_HOST>`(kr1) | 컨테이너 이미지 레지스트리(NHN NCR) |

- **레지스트리 = NHN NCR**: `docker login`(basic auth, Jenkins 자격 `ncr-cred`)로 push, NKS 는
  `ncr-cred` docker-registry **imagePullSecret** 으로 pull. AWS/IAM/IRSA 없음.
- **공통 배포 패턴(VM)**: 각 서비스 디렉터리(`GitServer/`,`Nexus/`,`Jenkins/`)는 독립적이며
  `01 이미지 pull+save(로컬) → 02 전송 → 03 load(VM) → 05 start → (init/configure)` 순서.
  선행으로 `Docker/`(정적 바이너리 오프라인 설치)로 각 VM 에 Docker 를 깐다.
- **공통 서비스 구조(VM)**: 서비스 컨테이너 + **nginx 사이드카(TLS 종료, 자체서명)**. 서비스는 컨테이너
  내부 평문 HTTP, 호스트엔 nginx 443/80 만. 초기화는 **UI 없이 CLI/REST API** 로.

---

## 1. Gitea (GitServer) — 형상관리 (app + config-repo)

### 구조
- `gitea` + `nginx`(TLS 443, 로컬). git-SSH 는 컨테이너 내부 **2222(loopback)**. 데이터 `data/`.
- 저장소 2종: **app 저장소**(소스, Jenkins 가 폴링/clone) + **config-repo**(배포 매니페스트,
  ArgoCD 가 감시). config-repo 는 **환경별 브랜치**(4절 참고).
- 개발자 접근은 **bastion 의 잠긴 게이트웨이 계정 `gitgw`** 경유(포트 22 만).

### 연동 방법
```
개발자 PC ──ssh22, 개인키──▶ gitgw@bastion(강제명령) ──ssh22, tunnel_key──▶ gitfwd@gitVM
                                                                            └(-W localhost:2222)▶ Gitea git-SSH
Jenkins(cicd) ── clone/폴링 ──▶ gitVM:2222 (SG: cicd→gitea:2222)
ArgoCD(NKS)   ── config-repo watch ──▶ gitVM:443 (SG: NKS 노드 CIDR→gitea:443, HTTPS)
```
- 개발자: `git clone acme-gitea:<user>/<repo>.git` (`~/.ssh/config` alias + ProxyCommand).
- Jenkins: 같은 git-SSH(2222)로 app clone + 폴링 + config-repo(dev) push.
- ArgoCD: **HTTPS(443)** 로 config-repo 를 감시(자체서명 → repo secret `insecure: "true"`).

### 선택 이유
| 선택 | 이유 |
|---|---|
| git-SSH 를 **2222 loopback + 게이트웨이**(개발자/Jenkins) | SG 가 22 만 열려도 동작(2222 는 VM 내부 loopback → SG 무관). 개발자·Jenkins 모두 22 위에서만 통신 |
| ArgoCD 는 **HTTPS(443)** 로 config-repo 감시 | NKS→VM 은 노드 IP 로 SNAT 되어 나가므로 SG 인바운드 1건(노드 CIDR→443)만 열면 됨. 2222 는 NKS 에서 도달 불가 → HTTPS 채택 |
| bastion **`gitgw` 강제명령 + `gitfwd`(nologin)+`tunnel_key`(`permitopen=localhost:2222`)** | 공용 pem 배포 없이 다중 사용자. bastion 침해가 VM 셸로 번지지 않음(권한 집중 제거) |
| 자체서명 TLS | 폐쇄망·내부 CA 부재. `server.crt` 배포로 검증(ArgoCD 는 `insecure: "true"`) |

---

## 2. Nexus — 아티팩트 저장소

### 구조
- `nexus3` + `nginx`(TLS 443, 로컬). Nexus 8081 은 컨테이너 내부만. 데이터 `nexus-data/`. 익명 접근 차단.

### 연동 방법
```
Jenkins(cicd) ── npm(하드ed repo) ──▶ nexusVM:443 (SG: cicd→nexus:443)
운영자 PC ── 업로드/관리 ──▶ (bastion 22 터널) ──▶ nexusVM:443
```
- **소비자는 CICD(Jenkins) 하나**. CI 는 전용 계정 `ci`(role `ci-deployer`)로 npm 의존성을 받음.
- 폐쇄망이라 인터넷 proxy 불가 → **hosted 저장소**에 아티팩트를 직접 올려 사용.

### 선택 이유
| 선택 | 이유 |
|---|---|
| **hosted 저장소 + 로컬 업로드** | 폐쇄망은 외부 proxy 불가. 필요한 패키지를 내부에 직접 보관 |
| CICD→Nexus **private 직접 443**(SG 규칙 1개) | 신뢰된 단일 내부 서버 1대만 여는 것이라 위험 낮음. 터널 불필요 |
| **admin 아닌 `ci` 서비스 계정** | 최소 권한. 유출 시 파급 제한, 폐기 용이 |
| 다중 사용자 게이트웨이 미도입 | 소비자가 CI 1대뿐이라 불필요(Gitea 와 다른 점) |

---

## 3. Jenkins (CI) + ArgoCD (CD) — 빌드는 폐쇄망 Jenkins, 배포는 NKS 의 ArgoCD(GitOps)

**역할 분리**: Jenkins 는 **CI 만**(빌드·**NCR push**·config-repo 태그 커밋). **배포(CD)는 ArgoCD** 가
config-repo 를 감시해 **NKS** 로 동기화. Jenkins 는 NKS 에 접근하지 않는다.

### 구조
- Jenkins(폐쇄망 cicd VM): `jenkins` + `nginx`(TLS 443, 로컬). 빌드는 **커스텀 에이전트 컨테이너**
  (node/docker/git)에서 호스트 `docker.sock`(DooD)로 이미지 build/push. 설정 **JCasC(코드)**,
  플러그인 오프라인 반입. NCR push 는 `docker login`(자격 `ncr-cred`, basic auth).
- config-repo(Gitea): 배포 매니페스트(Deployment/Service) 저장소. **환경별 브랜치**(dev/test/prd),
  각 브랜치 `apps/test-app/{deployment,service}.yaml`, `main` = 브랜치모델 README(배포 대상 아님).
- ArgoCD(NKS `env=ops` 노드): 클러스터 내부에 설치, 클러스터 RBAC 로 배포(외부 클러스터 자격 불필요).
  config-repo 를 **HTTPS** 로 감시. 노드 배치는 `nodeSelector env=ops`.

### 연동 방법 (엔드투엔드)
```
Gitea(app) push ─폴링→ Jenkins(CI) ─clone→ [frontend·backend]
  npm ci(←Nexus) → docker build → docker login+push(NCR) → config-repo **dev 브랜치** deployment 태그 커밋
                                                              │
ArgoCD(CD, NKS ops노드) ─watch(HTTPS) config-repo→ 변경 감지 → dev/test/prd 노드에 sync(NCR 에서 pull)
```
- 트리거: **SCM 폴링** — Jenkins 인바운드 0.
- 이미지: 앱 컴포넌트별 NCR 리포(`<NCR_REGISTRY_HOST>/acme-poc/...`). CI 는 **dev 브랜치**의 이미지 태그만
  갱신 → dev 자동배포. test/prd 는 **승격**(이미지 태그만 반영, 헬퍼 [`tools/promote-image.sh`](tools/promote-image.sh)).
- 환경: env 브랜치 → env. **namespace(논리, `acme-app-<env>`) + 노드 taint/label `env=<env>`(물리)**.
- 인증: Jenkins→NCR 는 `ncr-cred`(basic auth). NKS→NCR pull 은 `ncr-cred` **imagePullSecret**. AWS/IAM 없음.

### 선택 이유
| 선택 | 이유 |
|---|---|
| **CI/CD 분리(ArgoCD)** | 배포를 GitOps(선언적·감사가능·자동 드리프트 복구)로. Jenkins 에서 클러스터 자격/접근 제거 → 민감도↓ |
| 트리거 **폴링** | Jenkins 로 인바운드 0. 이미 필요한 cicd→gitea:2222 만 사용 |
| **JCasC + Job DSL**(GUI 없이) | 웹 UI 불가 제약. Job·자격을 코드로, 비밀은 컨테이너 env 주입 |
| **NCR `docker login`(basic auth)** | NHN NCR 은 access/secret 키의 basic auth. Jenkins 자격 `ncr-cred` 로 push, NKS 는 동일 자격 imagePullSecret 으로 pull(별도 클라우드 SDK 불필요) |
| **커스텀 에이전트 + DooD** | 폐쇄망 도구 오프라인 반입 + 이미지 build/push |
| **config-repo 환경 브랜치** | env별 ns/노드가 달라 helm values 디렉터리 대신 브랜치로 분리. ArgoCD Application 은 `targetRevision=<env 브랜치>`, `path=apps/test-app` |
| **노드 label/taint `env=<env>`** | 앱을 env 노드에 격리(nodeSelector+tolerations). 노드 라벨/taint 재적용은 `nks/scripts/01-label-taint-nodes.sh` |

> **LEGACY 참고**: `gitops/cluster/nodegroups.eksctl.yaml` 은 과거 **AWS EKS(eksctl)** 검토 시의 노드그룹
> 정의로, 현재 NKS 구성에는 **사용하지 않는 레거시 파일**이다. 현재 노드 라벨/taint 스킴은
> [`gitops/cluster/nodepools.nks.md`](gitops/cluster/nodepools.nks.md) 와 `nks/scripts/01-label-taint-nodes.sh` 를 따른다.

---

## 4. 전체 흐름 & 네트워크(SG) 요약

```
개발자 ─push→ Gitea(app) ─(폴링)→ Jenkins(CI) ─(npm)→ Nexus
                                       └─(build)→ NCR ─┐(pull)
                                       └─(태그 커밋)→ Gitea(config-repo:dev) ─watch(HTTPS)→ ArgoCD(CD) ─sync→ NKS(dev/test/prd)
```

| 흐름 | 규칙(출발지→목적지:포트) | 상태 |
|---|---|---|
| 개발자/운영자 → bastion | `TCP 22` | 필요(공인) |
| bastion → 각 VM | `TCP 22` | 열림 |
| 개발자 → Gitea(git) | bastion `gitgw`(22) → gitVM localhost:2222 | 게이트웨이(구성됨) |
| Jenkins → Gitea | `cicd → gitea:2222` | **추가 필요** (app clone + config-repo push) |
| Jenkins → Nexus | `cicd → nexus:443` | **추가 필요** |
| Jenkins → NCR | `cicd → <NCR_REGISTRY_HOST>:443` | 인터넷 egress 로 도달(SG 작업 불필요) |
| **ArgoCD(NKS) → Gitea** | **`NKS 노드 CIDR(<NKS_NODE_CIDR>) → gitea:443`** | **★ 추가 필요** (config-repo HTTPS watch) |
| NKS → NCR(pull) | `NKS → <NCR_REGISTRY_HOST>:443` | 인터넷 egress 로 도달(SG 작업 불필요) |
| (미채택) Gitea → Jenkins webhook | `gitea → cicd:443` | 폴링 채택으로 불필요 |

- **핵심 전제**: NKS 는 인터넷 egress 만 가능해 NCR 은 열려 있으나 Gitea 는 단절 상태다. NAT 미사용이라
  파드→Gitea 트래픽은 **노드 IP 로 SNAT** → 출발지 = **노드 CIDR**. 따라서 Gitea SG 인바운드에
  `<NKS_NODE_CIDR> → 443` 1건만 열면 ArgoCD→config-repo 감시가 된다. (git-SSH 2222 는 NKS 에서 도달 불가.)
- 상세·실측: [`gitops/nks-deploy-flow.md`](gitops/nks-deploy-flow.md) 의 SG 절.

### prd 릴리스 게이트 (3중)
| 게이트 | 내용 |
|---|---|
| (a) Gitea prd 브랜치 보호 | config-repo `prd` 브랜치 직접 push 는 릴리스만, 그 외 PR+승인(`tools/gitea-protect-prd.sh`) |
| (b) ArgoCD RBAC | `releasemgr` 만 prd sync 가능, `developer` 는 dev/test 만([`gitops/argocd/install/argocd-rbac-cm.yaml`](gitops/argocd/install/argocd-rbac-cm.yaml)) |
| (c) prd Application 수동 Sync | prd Application 은 `syncPolicy.automated` 미설정 → ArgoCD 에서 수동 승인 |

---

## 5. 공통 선택 이유 (횡단)

| 결정 | 이유 |
|---|---|
| **오프라인 반입**(이미지/패키지/도구/플러그인) | 대상 VM 인터넷 차단. 로컬에서 받아 bastion 경유 전송 |
| **SG 22-only + loopback 트릭**(VM) | 최소 표면. 서비스 포트(2222/443)는 VM 내부 loopback 으로 접근해 SG 를 우회하지 않으면서 동작 |
| **NKS 노드 CIDR → gitea:443 단일 인바운드** | ArgoCD 만 config-repo 를 봐야 하므로 최소 규칙 1건. NAT 없이 노드 SNAT 를 이용 |
| **자체서명 TLS + nginx 사이드카** | 내부 CA 부재. 서비스는 직접 노출하지 않고 TLS 는 nginx 가 종료(ArgoCD 는 `insecure`) |
| **UI 없이 CLI/REST/코드** | GUI 접근 불가 가정. Gitea/Nexus=REST·CLI, Jenkins=JCasC, NKS=kubectl/helm |
| **최소 권한 계정/자격**(gitfwd/ci/jenkins/ncr-cred) | 침해 시 파급 최소화, 폐기·회전 용이 |
| **VM 절대경로 / alias(ProxyJump)** | `~` 로컬확장, bastion 경유 반복 함정 회피 (빌드 PC=Intel(amd64)=VM 동일 아키텍처라 이미지 플랫폼 강제는 불필요) |
| **문서 역할별 분리**(BUILD/ADMIN/USER) | 구축자·관리자·사용자가 필요한 것만 보게 |

> 계정/비밀번호 등 실제 값은 각 서비스 `.env` 및 시크릿에만 두고 문서엔 남기지 않음.
