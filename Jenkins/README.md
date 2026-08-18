# Jenkins (CI) — 폐쇄망 빌드 서버

bastion 뒤 private subnet VM(`acme-cicd`)에 Jenkins 를 Docker 로 올린 **CI 서버**. Gitea push 를
**폴링**으로 감지해 앱(frontend+backend)을 빌드(의존성은 Nexus)하고, 이미지를 **NCR**(NHN Container
Registry) push 후 **config-repo(GitOps)의 이미지 태그를 커밋**합니다. **배포(NKS)는 ArgoCD(CD)** 가
담당 → [`gitops/`](../gitops/README.md).
**GUI 미사용**(JCasC/CLI), **AWS 미사용** — NCR 은 `docker login`(basic auth, 자격 `ncr-cred`)으로 push.

## 아키텍처

```
Gitea(<GITEA_IP>) ──폴링(cicd→gitea:2222)──▶ Jenkins(CI) @ cicd(<CICD_IP>)
                                                   │  빌드(에이전트 컨테이너: node/docker/git)
Nexus(<NEXUS_IP>) ──npm(cicd→nexus:443)────────▶│  frontend/·backend/ 각각 docker build
                                                   │  push ─▶ NCR (docker login basic, 인터넷 egress)
                                                   └  이미지 태그 커밋 ─▶ Gitea(config-repo)
                                                                            └─watch─▶ ArgoCD ─▶ NKS
```
> 배포·매니페스트(Helm·ArgoCD Application·클러스터 준비)는 Jenkins 가 아니라 [`gitops/`](../gitops/README.md) 에 있습니다.

## 빠른 사실

| 항목 | 값 |
|---|---|
| CI VM | `<CICD_IP>` (private, `ssh acme-cicd` bastion 경유) |
| 이미지 | `jenkins/jenkins:2.541.3-lts-jdk17` + `nginx:1.27-alpine` (코어 ≥ 2.504.3 필수) |
| 관리자 | `admin` / `.env` 의 `JENKINS_ADMIN_PASSWORD` (웹 UI 미사용) |
| 트리거 | **폴링(pollSCM 3분)** — Jenkins 인바운드 0 |
| 파이프라인 | Node.js(npm→Nexus) → 컨테이너 → **NCR push** → **config-repo 태그 커밋** (배포는 ArgoCD) |
| 데이터(백업) | `/home/ubuntu/Jenkins/jenkins_home/` |
| 파이프라인 자산 | [`pipeline/`](pipeline/README.md) (Jenkinsfile·JCasC·scripts·agent) |

## 문서 (역할별)

| 역할 | 문서 | 내용 |
|---|---|---|
| **서버 구축자** | [BUILD.md](BUILD.md) | Jenkins 오프라인 기동 + 파이프라인 자산 반입(에이전트·플러그인·JCasC·DooD) |
| **관리자** | [ADMIN.md](ADMIN.md) | JCasC Job/자격, 플러그인(오프라인), 운영·백업, 앱 온보딩 |
| **사용자(개발자)** | [USER.md](USER.md) | 브랜치→환경, 앱 저장소 구조, 결과 확인 |
| (상세) CI 파이프라인 | [pipeline/README.md](pipeline/README.md) | Jenkinsfile·NCR push·config-repo 커밋·SG 규칙 |
| (상세) CD/GitOps | [gitops/README.md](../gitops/README.md) | ArgoCD Application·Helm 차트·노드 taint |
| (실측) CI 연동 hands-on | [test/test.md](test/test.md) | 터널·git 키·SCM 폴링 잡·검증 출력 |
| (실측) NKS 배포 플로우 | [gitops/nks-deploy-flow.md](../gitops/nks-deploy-flow.md) | SG·NCR·config-repo 브랜치·ArgoCD |

전체 아키텍처/서버 연동/선택 이유: 레포 루트 [`ARCHITECTURE.md`](../ARCHITECTURE.md).
