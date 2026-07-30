# Jenkins 구축 가이드 (서버 구축자)

폐쇄망 VM(`acme-cicd`=<CICD_IP>, bastion 뒤)에 Jenkins(**CI 서버**)를 Docker 로 올리고, 파이프라인
자산을 오프라인 반입하는 절차. GUI 없이(JCasC), AWS 는 CLI 없이(ECR 인증만 REST). **배포는 ArgoCD** 담당.

## 0. 사전 조건

- **로컬 PC**: Docker(이미지 pull/save·에이전트 이미지 빌드), `ssh`/`rsync`, `ssh acme-cicd`.
- **cicd VM**: Docker/Compose(미설치 시 `../Docker/` 먼저), `openssl`, `sudo`, RAM 4GB+.
- **SG**(구축 시점엔 22만 열림 → 아래 규칙 추가 필요):
  | 흐름 | 규칙 | 용도 |
  |---|---|---|
  | Jenkins→Nexus | `cicd → nexus(<NEXUS_IP>):443` | npm 의존성 |
  | Jenkins→Gitea | `cicd → gitea(<GITEA_IP>):2222` | app clone + 폴링 + **GitOps repo push** |
  | Jenkins→AWS | **ECR**/S3 **VPC 엔드포인트** | ECR push(인터넷 없이). EKS/STS 는 불필요(ArgoCD 담당) |
  > webhook 미사용(폴링)이라 `gitea→cicd` 인바운드는 **불필요**. 배포용 EKS 접근도 Jenkins 엔 **없음**.

## 1. 설정 (`.env`) — 이미 cicd 대상으로 설정됨

```
JENKINS_IMAGE=jenkins/jenkins:2.479.2-lts-jdk17   NGINX_IMAGE=nginx:1.27-alpine
VM_SSH_HOST=acme-cicd  VM_SSH_USER=ubuntu  VM_REMOTE_DIR=/home/ubuntu/Jenkins
TLS_DOMAIN=<CICD_IP>   JENKINS_ADMIN_ID=admin   JENKINS_ADMIN_PASSWORD=<강력한 값>
AGENT_PORT=50000   TLS_PORT=443
```

## 2. Jenkins 기동 (오프라인)

```bash
# [로컬] 이미지 pull+save (빌드 PC가 Apple Silicon이면 amd64 강제)
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./scripts/01-pull-and-save-image.sh
./scripts/02-transfer-to-vm.sh
# [VM]  (ssh acme-cicd; cd /home/ubuntu/Jenkins)
./scripts/03-load-image.sh
./scripts/05-start.sh            # 설치 마법사 없이 init.groovy 로 admin 생성, TLS 적용
```

## 3. 파이프라인 자산 반입 (핵심 — 상세: [pipeline/README.md](pipeline/README.md))

```bash
# [로컬] CI 에이전트 이미지(node/docker/git, aws cli 없음) 빌드·저장 + 플러그인 다운로드
pipeline/scripts/10-build-ci-agent-image.sh
pipeline/scripts/11-download-jenkins-plugins.sh
pipeline/scripts/12-transfer-pipeline.sh          # pipeline/ + 이미지 + 플러그인 → cicd

# [VM] DooD + JCasC 활성화 오버라이드 적용 후 재기동
cp pipeline/docker-compose.override.yml docker-compose.override.yml
export NEXUS_CI_USER=ci NEXUS_CI_PASSWORD='...' GITEA_SSH_PRIVATE_KEY="$(cat key)"
docker compose up -d                               # docker.sock 마운트 + JCasC 로 Job/자격 생성
```
> `docker-compose.override.yml` 의 `group_add` GID 는 VM 의 `getent group docker` 값으로 조정.

## 4. 검증(연결 후) / 이후

- 상태: `docker ps --filter name=jenkins`, `curl --cacert certs/server.crt https://localhost/login`.
- Job/자격/플러그인 관리, 앱 저장소 온보딩 → [ADMIN.md](ADMIN.md)
- 개발자 사용(브랜치→환경, 트리거) → [USER.md](USER.md)
- ECR placeholder·SigV4·GitOps 커밋 → [pipeline/README.md](pipeline/README.md)
- 배포(ArgoCD)·Helm 차트·노드 taint → [gitops/README.md](../gitops/README.md)
- **ECR/EKS/ArgoCD 미생성 상태의 무검증 스캐폴드** — 연결 후 dev 브랜치로 1회 검증.
