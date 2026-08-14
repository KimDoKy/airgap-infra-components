# CI 파이프라인 (Jenkins) — NCR 기준

**Jenkins = CI 만.** Gitea 액션 → 빌드(Node.js, 의존성은 Nexus) → 컨테이너 이미지 → **NCR** push →
**GitOps repo(config-repo) 의 이미지 태그 커밋**. **배포(NKS)는 ArgoCD(CD)** 가 담당(→ [`gitops/`](../../gitops/README.md)).
NCR(NHN Container Registry)는 **docker login(basic, `ncr-cred`)** 으로 push — 인터넷 egress.

> 단일 컴포넌트 검증 흐름(실측 통과)은 [`../test/test.md`](../test/test.md) + [`../../gitops/nks-deploy-flow.md`](../../gitops/nks-deploy-flow.md).
> 이 `pipeline/` 은 frontend/backend 2컴포넌트 앱용 스캐폴드다.

## 아키텍처

```
Gitea(<GITEA_IP>)                        Nexus(<NEXUS_IP>, npm)
   ▲ (1) 폴링(cicd 로컬 gitea 터널)          ▲ (3) npm ci  (cicd 로컬 nexus 터널 localhost:8443)
   │ (2) git clone                          │
Jenkins @ cicd ── 에이전트 컨테이너(node+docker+git, docker.sock DooD) ──┐
   │ (4) docker build (--network host → nexus 터널) ────────────────────┘
   │ (5) docker push ─────────▶ NCR  (docker login basic, ncr-cred, 인터넷 egress)
   └ (6) GitOps 태그 커밋 ─────▶ Gitea(config-repo) ──watch──▶ ArgoCD(NKS) ──sync──▶ NKS
```
- **CI/CD 분리**: Jenkins 는 NKS 에 접근하지 않음. config-repo 의 이미지 태그만 커밋.
- 환경 매핑(git ref → env): `dev`→dev, `test`→test, `main`/tag `v*`→prd. (Jenkinsfile `Resolve env`)
- dev/test/prd 분리(배포는 ArgoCD): **namespace(논리)** + **노드 taint/label `env=<env>`(물리)**. ops 는 taint 없음(플랫폼).

## 트리거 (권장: 폴링)

Gitea→cicd 인바운드는 열지 않는다(Jenkins 는 NCR push 자격을 가진 민감 노드).
- **권장 = SCM 폴링**: cicd→gitea(터널)로 3분 주기 감지. 새 인바운드 0, JCasC 로 완결.
- 대안 = **Gitea webhook**(`gitea→cicd:443` 개방 필요, `scripts/30-create-gitea-webhook.sh`).

## 필요한 보안그룹(SG) / 네트워크

| 흐름 | 규칙 | 용도 |
|---|---|---|
| Jenkins→Nexus | cicd→nexus:443 (cicd 로컬 터널 경유) | npm 의존성 |
| Jenkins→Gitea | cicd→gitea:2222 (cicd 로컬 터널 경유) | app clone + 폴링 + **config-repo push** |
| Jenkins→NCR | cicd→NCR:443 (**인터넷 egress**, SG 불필요) | 이미지 push |
| ArgoCD→Gitea | **NKS 노드 CIDR → gitea:443** | config-repo watch (gitops/nks-deploy-flow.md) |

## 사전 준비

1. **Jenkins 배포**: `Jenkins/` 오프라인 흐름(01~06)으로 cicd VM 기동.
2. **DooD 활성화**: `cp pipeline/docker-compose.override.yml docker-compose.override.yml` → `docker compose up -d`.
3. **CI 에이전트 이미지 + 플러그인 오프라인 반입**:
   ```bash
   pipeline/scripts/10-build-ci-agent-image.sh
   pipeline/scripts/11-download-jenkins-plugins.sh
   pipeline/scripts/12-transfer-pipeline.sh
   ```
4. **NCR 자격증명(`ncr-cred`)**: `Jenkins/.ncr`(레지스트리/access/secret) 로 생성 —
   `scripts/13-create-ncr-credential.sh` 또는 JCasC(`NCR_ACCESS_KEY`/`NCR_SECRET_KEY` env 주입).
5. **JCasC(GUI 없이)**: `jcasc/jenkins.yaml` 이 자격(`nexus-ci`, `ncr-cred`, `gitea-ssh`) + 멀티브랜치 Job(폴링) 생성.
   비밀은 컨테이너 env 주입. `gitea-ssh` 계정은 **app repo + config-repo 둘 다 write** 권한 필요.
6. **설정 채우기**: `pipeline.env` 의 `NCR_REGISTRY`/`NCR_PROJECT`·`GITEA_SSH_URL`·`GITOPS_REPO_URL`·`NEXUS_NPM_REGISTRY`.

## 앱 / GitOps 저장소 구성

- **앱 저장소**(Gitea `acme-app`): `frontend/ backend/`(각 Dockerfile) + `Jenkinsfile` + `pipeline/`.
  CI 가 브랜치 push 시 두 컴포넌트 빌드→NCR→config-repo 태그 커밋.
- **GitOps 저장소**(Gitea `config-repo`): [`gitops/`](../../gitops/README.md) 참고. ArgoCD 가 watch.
  CI 는 `apps/<app>-<env>/deployment.yaml` 의 image tag 를 커밋.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `Jenkinsfile` | CI(빌드→NCR push→**config-repo 태그 커밋**), git ref→env, `pollSCM` |
| `jcasc/jenkins.yaml` | GUI 없이 자격(`nexus-ci`/`ncr-cred`/`gitea-ssh`)+멀티브랜치 Job(폴링) |
| `agent/Dockerfile` | CI 에이전트(node/docker/git/curl/openssl/jq) — 오프라인 반입 |
| `config/npmrc.tmpl` | npm → Nexus 레지스트리(+CI 자격) |
| `scripts/13-create-ncr-credential.sh` | Jenkins 에 `ncr-cred` 생성(.ncr 기반) |
| `scripts/20-ncr-login-push.sh` | NCR docker login(basic)+push |
| `scripts/21-update-gitops.sh` | config-repo 의 이미지 태그 갱신·커밋·push |
| `scripts/30-create-gitea-webhook.sh` | (대안) Gitea webhook 등록 |
| `scripts/10,11,12` | 오프라인 에이전트·플러그인 반입 |
| `docker-compose.override.yml`, `plugins.txt`, `pipeline.env` | DooD+JCasC, 플러그인, 설정 |

> 배포 매니페스트(helm·ArgoCD Application·클러스터 준비)는 [`gitops/`](../../gitops/README.md) + [`nks/`](../../nks/README.md).
