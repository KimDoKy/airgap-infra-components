# acme 폐쇄망 CICD 아키텍처 (Gitea · Nexus · Jenkins)

세 서버의 **구조 · 연동 방법 · 선택 이유**를 정리한 문서. 각 서버의 상세 절차는 해당 디렉터리의
`README/BUILD/ADMIN/USER.md` 를 참고하세요.

---

## 0. 공통 환경

- **폐쇄망(air-gapped)**: 대상 VM 은 인터넷/외부 레지스트리에 접근 불가. 이미지·패키지·도구는 모두
  **로컬(인터넷) PC 에서 받아 bastion 경유로 반입**.
- **네트워크**: 모든 서비스 VM 은 private subnet. 외부에서는 **bastion(공인 `<BASTION_PUBLIC_IP>`)** 을
  거쳐야 접근. VM 간·VM 인바운드는 **SG 로 포트 22 만** 기본 허용(그 외는 명시적으로만 개방).

| VM | 별칭 | 사설 IP | 역할 |
|---|---|---|---|
| GitServer | `acme-git` | <GITEA_IP> | Gitea (형상관리) |
| Nexus | `acme-nexus` | <NEXUS_IP> | 아티팩트 저장소 |
| CICD | `acme-cicd` | <CICD_IP> | Jenkins (빌드·배포) |
| bastion | `acme-bastion` | <BASTION_PUBLIC_IP>(공인) | 점프 호스트 |

- **공통 배포 패턴**: 각 서비스 디렉터리(`GitServer/`,`Nexus/`,`Jenkins/`)는 독립적이며
  `01 이미지 pull+save(로컬) → 02 전송 → 03 load(VM) → 05 start → (init/configure)` 순서.
  선행으로 `Docker/`(정적 바이너리 오프라인 설치)로 각 VM 에 Docker 를 깐다.
- **공통 서비스 구조**: 서비스 컨테이너 + **nginx 사이드카(TLS 종료, 자체서명)**. 서비스는 컨테이너
  내부 평문 HTTP, 호스트엔 nginx 443/80 만. 초기화는 **UI 없이 CLI/REST API** 로.

---

## 1. Gitea (GitServer) — 형상관리

### 구조
- `gitea` + `nginx`(TLS 443, 로컬). git-SSH 는 컨테이너 내부 **2222(loopback)**. 데이터 `data/`.
- 사용자 접근은 **bastion 의 잠긴 게이트웨이 계정 `gitgw`** 경유(포트 22 만).

### 연동 방법
```
개발자 PC ──ssh22, 개인키──▶ gitgw@bastion(강제명령) ──ssh22, tunnel_key──▶ gitfwd@gitVM
                                                                            └(-W localhost:2222)▶ Gitea git-SSH
Jenkins(cicd) ── clone/폴링 ──▶ gitVM:2222 (SG: cicd→gitea:2222)
```
- 개발자: `git clone acme-gitea:<user>/<repo>.git` (`~/.ssh/config` alias + ProxyCommand).
- Jenkins: 같은 git-SSH(2222)로 clone + 폴링.

### 선택 이유
| 선택 | 이유 |
|---|---|
| git-SSH 를 **2222 loopback + 게이트웨이** | SG 가 22 만 열려도 동작(2222 는 VM 내부 loopback → SG 무관). Jenkins·개발자 모두 22 위에서만 통신 |
| bastion **`gitgw` 강제명령 + `gitfwd`(nologin)+`tunnel_key`(`permitopen=localhost:2222`)** | 공용 pem 배포 없이 다중 사용자. bastion 침해가 VM 셸로 번지지 않음(권한 집중 제거) |
| 자체서명 TLS | 폐쇄망·내부 CA 부재. `server.crt` 배포로 검증 |

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

## 3. Jenkins (CI) + ArgoCD (CD) — 빌드는 Jenkins, 배포는 ArgoCD(GitOps)

**역할 분리**: Jenkins 는 **CI 만**(빌드·ECR push·GitOps 태그 커밋). **배포(CD)는 ArgoCD** 가
GitOps 저장소를 감시해 EKS 로 동기화. Jenkins 는 EKS 에 접근하지 않음.

### 구조
- Jenkins: `jenkins` + `nginx`(TLS 443, 로컬). 빌드는 **커스텀 에이전트 컨테이너**(node/docker/git,
  aws cli 없음)에서 호스트 `docker.sock`(DooD)로 이미지 build/push. 설정 **JCasC(코드)**, 플러그인 오프라인.
- GitOps: 별도 Gitea 저장소(`acme/acme-gitops`) = `gitops/` (Helm 차트 + `values-<env>.yaml` + ArgoCD Application).
- ArgoCD: EKS 클러스터 내부에 설치, 클러스터 RBAC 로 배포(외부 EKS 자격 불필요).

### 연동 방법 (엔드투엔드)
```
Gitea(app) push ─폴링→ Jenkins(CI) ─clone→ [frontend·backend]
  npm ci(←Nexus) → docker build → ECR push(REST/SigV4) → gitops values-<env>.yaml 태그 커밋
                                                              │
ArgoCD(CD, EKS내부) ─watch gitops repo→ 변경 감지 → helm 렌더 → EKS 동기화(ns=acme-app-<env>, taint env=<env>)
```
- 트리거: **SCM 폴링** — Jenkins 인바운드 0.
- 앱: **2개 컴포넌트** frontend/backend, 컴포넌트별 ECR 리포. 배포는 env별 1개 Helm 릴리스(두 컴포넌트).
- 환경: git ref → env. **namespace(논리) + 노드 taint/label `env=<env>`(물리)**. 노드 taint 는
  **managed nodegroup 정의에 선언**(`gitops/cluster/nodegroups.eksctl.yaml`)해 노드 교체에도 유지.
- AWS: Jenkins 는 **ECR 만** IAM(IMDS)+REST(SigV4)로 인증. EKS 인증은 ArgoCD(클러스터 내부)가 담당.

### 선택 이유
| 선택 | 이유 |
|---|---|
| **CI/CD 분리(ArgoCD)** | 배포를 GitOps(선언적·감사가능·자동 드리프트 복구)로. Jenkins 에서 EKS 자격/접근 제거 → 민감도↓ |
| 트리거 **폴링** | Jenkins 로 인바운드 0. 이미 필요한 cicd→gitea:2222 만 사용 |
| **JCasC + Job DSL**(GUI 없이) | 웹 UI 불가 제약. Job·자격을 코드로, 비밀은 컨테이너 env 주입 |
| **REST/SigV4**(aws cli 없이) | aws CLI 불가 제약. ECR `GetAuthorizationToken` 직접 서명(EKS 토큰 로직은 ArgoCD 전환으로 제거) |
| **커스텀 에이전트 + DooD** | 폐쇄망 도구 오프라인 반입 + 이미지 build/push |
| **nodegroup 레벨 taint/label** | `kubectl taint` 는 노드 교체 시 소실 → 환경별 노드그룹 정의에 선언해 자동 유지 |

---

## 4. 전체 흐름 & 네트워크(SG) 요약

```
개발자 ─push→ Gitea(app) ─(폴링)→ Jenkins(CI) ─(npm)→ Nexus
                                       └─(build)→ ECR ─┐
                                       └─(태그 커밋)→ Gitea(gitops) ─watch→ ArgoCD(CD) ─sync→ EKS(dev/stg/prd)
```

| 흐름 | 규칙(출발지→목적지:포트) | 상태 |
|---|---|---|
| 개발자/운영자 → bastion | `TCP 22` | 필요(공인) |
| bastion → 각 VM | `TCP 22` | 열림 |
| 개발자 → Gitea(git) | bastion `gitgw`(22) → gitVM localhost:2222 | 게이트웨이(구성됨) |
| Jenkins → Gitea | `cicd → gitea:2222` | **추가 필요** (app clone + gitops push) |
| Jenkins → Nexus | `cicd → nexus:443` | **추가 필요** |
| Jenkins → AWS | **ECR**/S3 **VPC 엔드포인트** | ECR 생성 후 (EKS/STS 는 불필요 — ArgoCD 담당) |
| ArgoCD → Gitea | `EKS(ArgoCD) → gitea:2222` | GitOps repo watch (ArgoCD 도입 후) |
| (미채택) Gitea → Jenkins webhook | `gitea → cicd:443` | 폴링 채택으로 불필요 |

---

## 5. 공통 선택 이유 (횡단)

| 결정 | 이유 |
|---|---|
| **오프라인 반입**(이미지/패키지/도구/플러그인) | 대상 VM 인터넷 차단. 로컬에서 받아 bastion 경유 전송 |
| **SG 22-only + loopback 트릭** | 최소 표면. 서비스 포트(2222/443)는 VM 내부 loopback 으로 접근해 SG 를 우회하지 않으면서 동작 |
| **자체서명 TLS + nginx 사이드카** | 내부 CA 부재. 서비스는 직접 노출하지 않고 TLS 는 nginx 가 종료 |
| **UI 없이 CLI/REST/코드** | GUI 접근 불가 가정. Gitea/Nexus=REST·CLI, Jenkins=JCasC |
| **최소 권한 계정**(gitfwd/ci/jenkins) | 침해 시 파급 최소화, 폐기·회전 용이 |
| **VM 절대경로 / alias(ProxyJump)** | `~` 로컬확장, bastion 경유 반복 함정 회피 (빌드 PC=Intel(amd64)=VM 동일 아키텍처라 이미지 플랫폼 강제는 불필요) |
| **문서 역할별 분리**(BUILD/ADMIN/USER) | 구축자·관리자·사용자가 필요한 것만 보게 |

> 계정/비밀번호 등 실제 값은 각 서비스 `.env` 및 시크릿에만 두고 문서엔 남기지 않음.
