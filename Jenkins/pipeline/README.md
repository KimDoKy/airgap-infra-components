# CI 파이프라인 (Jenkins) — 스캐폴드

**Jenkins = CI 만.** Gitea 액션 → 빌드(Node.js, 의존성은 Nexus) → 컨테이너 이미지 → **ECR** push →
**GitOps repo 의 이미지 태그 커밋**. **배포(EKS)는 ArgoCD(CD)** 가 담당(→ [`gitops/`](../../gitops/README.md)).
폐쇄망(인터넷 없음). 설정은 GUI 없이 코드/API, AWS(ECR)는 CLI 없이 REST(SigV4).
**ECR/EKS/ArgoCD 미생성이라 검증 안 된 스캐폴드** — `<...>` 채우고 SG/자격 준비 후 동작.

## 아키텍처

```
Gitea(<GITEA_IP>)                     Nexus(<NEXUS_IP>, npm)
   ▲ (1) 폴링: cicd→gitea:2222             ▲ (3) npm ci  (cicd→nexus:443)
   │ (2) git clone (cicd→gitea:2222)        │
Jenkins @ cicd(<CICD_IP>) ── 에이전트 컨테이너(node+docker+git, aws cli 없음) ──┐
   │ (4) docker build ────────────────────────────────────────────────────────┘
   │ (5) docker push ─────────▶ ECR  (VPC 엔드포인트, IAM=IMDS, 인증=REST GetAuthorizationToken)
   └ (6) GitOps 태그 커밋 ─────▶ Gitea(gitops repo) ──watch──▶ ArgoCD(EKS 내부) ──sync──▶ EKS
```
- **CI/CD 분리**: Jenkins 는 EKS 에 접근하지 않음. GitOps repo 의 `values-<env>.yaml` 이미지 태그만 커밋.
- 환경 매핑(git ref → env): `dev`→dev, `stg`→stg, `main`/tag `v*`→prd. (Jenkinsfile `Resolve env`)
- dev/stg/prd 분리(배포는 ArgoCD): **namespace(논리)** + **노드 taint/label `env=<env>`(물리)**.

## 트리거 (권장: 폴링)

gitea→cicd 는 22만 열림. Jenkins 는 ECR push 권한을 가진 민감 노드라 **인바운드를 열지 않음**.
- **권장 = SCM 폴링**: `cicd→gitea:2222`(clone 채널)로 3분 주기 감지. 새 인바운드 0, JCasC 로 완결.
- 대안 = **Gitea webhook**(`gitea→cicd:443` 개방 필요, `scripts/30-create-gitea-webhook.sh`).

## 반드시 추가할 보안그룹(SG) 규칙 — 현재 전부 미개방(22만 열림)

| 흐름 | 규칙 | 용도 |
|---|---|---|
| Jenkins→Nexus | `cicd → nexus:443` | npm 의존성 |
| Jenkins→Gitea | `cicd → gitea:2222` | app clone + 폴링 + **GitOps repo push** |
| Jenkins→AWS | ECR/S3 **VPC 엔드포인트** | ECR push(REST/SigV4). **EKS/STS 는 이제 불필요**(ArgoCD가 담당) |
| ArgoCD→Gitea | `EKS(ArgoCD) → gitea:2222` | GitOps repo watch |

## 사전 준비

1. **Jenkins 배포**: `Jenkins/` 오프라인 흐름(01~06)으로 cicd VM 기동(`.env` acme-cicd).
2. **DooD 활성화**: `cp pipeline/docker-compose.override.yml docker-compose.override.yml` → `docker compose up -d`.
3. **CI 에이전트 이미지 + 플러그인 오프라인 반입**:
   ```bash
   pipeline/scripts/10-build-ci-agent-image.sh
   pipeline/scripts/11-download-jenkins-plugins.sh
   pipeline/scripts/12-transfer-pipeline.sh
   ```
4. **AWS(ECR, REST-only)**: cicd VM 에 **ECR 권한 IAM 인스턴스 프로파일**(EKS 권한은 불필요해짐). ECR/S3 VPC 엔드포인트.
5. **JCasC(GUI 없이)**: `jcasc/jenkins.yaml` 이 자격(`nexus-ci`, `gitea-ssh`) + 멀티브랜치 Job(폴링) 생성.
   비밀은 컨테이너 env 주입(`NEXUS_CI_PASSWORD`, `GITEA_SSH_PRIVATE_KEY`). `gitea-ssh` 계정은 **app repo +
   gitops repo 둘 다 write** 권한 필요(태그 커밋).
6. **설정 채우기**: `pipeline.env` 의 `<AWS_ACCOUNT_ID>`·`ECR_*`·`GITEA_SSH_URL`·`GITOPS_REPO_URL`·`NEXUS_NPM_REGISTRY`.

## 앱 / GitOps 저장소 구성

- **앱 저장소**(Gitea `acme/acme-app`): `frontend/ backend/`(각 Dockerfile) + `Jenkinsfile` + `pipeline/`.
  샘플: [`sample-app/`](../../sample-app/README.md). CI 가 브랜치 push 시 두 컴포넌트 빌드→ECR→태그 커밋.
- **GitOps 저장소**(Gitea `acme/acme-gitops`): [`gitops/`](../../gitops/README.md) 내용이 루트.
  ArgoCD 가 watch. CI 는 `helm/acme-app/values-<env>.yaml` 의 image tag 를 커밋.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `Jenkinsfile` | CI(빌드→ECR push→**GitOps 태그 커밋**), git ref→env, `pollSCM` |
| `jcasc/jenkins.yaml` | GUI 없이 자격+멀티브랜치 Job(폴링) 코드 정의 |
| `agent/Dockerfile` | CI 에이전트(node/docker/git, **aws cli 없음**) — 오프라인 반입. *kubectl/helm 은 CI 에 불필요(다음 리빌드 때 제거 가능)* |
| `config/npmrc.tmpl` | npm → Nexus 레지스트리(+CI 자격) |
| `scripts/20-ecr-login-push.sh` | ECR login(REST/SigV4)+push |
| `scripts/21-update-gitops.sh` | GitOps repo 의 이미지 태그 갱신·커밋·push |
| `scripts/lib-awssigv4.sh` | aws CLI 대체 — IMDS 자격 + SigV4(**ECR 만**) |
| `scripts/30-create-gitea-webhook.sh` | (대안) Gitea webhook 등록 |
| `scripts/10,11,12` | 오프라인 에이전트·플러그인 반입 |
| `docker-compose.override.yml`, `plugins.txt`, `pipeline.env` | DooD+JCasC, 플러그인, 설정 |

> 배포 매니페스트(helm 차트·ArgoCD Application·클러스터 준비)는 이제 [`gitops/`](../../gitops/README.md) 에 있습니다.

## 미검증 (요청대로 실행/검증 안 함)

ECR/EKS/ArgoCD 미생성이라 push·GitOps커밋·배포는 스캐폴드입니다. 연결 시: (1) ECR VPC엔드포인트+IAM,
(2) `pipeline.env`/`gitops` 값 채우기, (3) GitOps repo 생성 + ArgoCD Application 등록, (4) dev 브랜치 1회 검증.
