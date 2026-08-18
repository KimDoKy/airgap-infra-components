# 폐쇄망 인프라 구축 (Docker / Git Server / Jenkins / Nexus)

폐쇄망(에어갭) 클라우드의 서로 다른 VM 3대에, 각각 컨테이너로 다음을 구축합니다.
VM 자체에는 Docker도 미리 설치되어 있어야 하므로, 그 선행 단계도 별도 디렉터리로 포함합니다.
여기에 더해, 앱은 클라우드 **NHN NKS**에 **ArgoCD(GitOps)**로 배포합니다(`gitops/`, `nks/`).

## 역할별 통합 매뉴얼 (여기서 시작)

각 디렉터리의 개별 문서(`README/BUILD/ADMIN/USER/MANUAL`)는 **그대로 유지**하고, 전체를 역할 관점으로
통합한 매뉴얼을 제공합니다.

| 역할 | 매뉴얼 | 내용 |
|---|---|---|
| **인프라 구축자** | [BUILDER.md](BUILDER.md) | Docker→GitServer→Nexus→Jenkins→NKS **순서·실행 스크립트·정상 출력 확인** |
| **운영자** | [OPERATOR.md](OPERATOR.md) | 계정·저장소·배포(GitOps/ArgoCD)·모니터링·승격·게이트 |
| **사용자/개발자** | [USER.md](USER.md) | git push→dev 자동배포, 승격 요청, GUI 접근 |

> CD/클러스터 상세: [`gitops/`](gitops/README.md)(ArgoCD·Helm·config-repo 브랜치), [`nks/`](nks/README.md)(노드/설치 스크립트),
> 전체 아키텍처: [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

| 디렉터리 | 역할 | 비고 |
|---|---|---|
| `Docker/` | Docker Engine + Compose 설치 (선행 단계) | 세 VM 각각에 설치 필요 |
| `GitServer/` | Gitea (Git Server) | 이미지: `gitea/gitea` |
| `Jenkins/` | Jenkins | 이미지: `jenkins/jenkins` |
| `Nexus/` | Nexus Repository | 이미지: `sonatype/nexus3` |
| `check/` | 가짜 VM에 실제로 배포해보는 end-to-end 검증 스크립트 | 로컬 PC에서만 사용 (VM에 올리는 대상 아님) |

**네 디렉터리는 서로 완전히 독립적입니다.** 각 디렉터리를 통째로 해당 VM에 복사해서
그 디렉터리 안에서만 명령을 실행하면 됩니다. 하나의 통합 명령이나 공용 compose 파일은
의도적으로 두지 않았습니다 (각 VM에서 관리자가 매뉴얼을 보고 개별적으로 실행하기 위함).

## 진행 순서

1. **`Docker/`** — 세 VM 각각에 Docker Engine/Compose를 먼저 설치 (컨테이너를 띄우기 위한 전제 조건)
2. **`GitServer/`**, **`Jenkins/`**, **`Nexus/`** — Docker가 설치된 각 VM에서 서비스 구축 (순서 무관, 서로 독립적)

## 공통 워크플로우

VM은 폐쇄망이라 무엇이든 직접 받을 수 없으므로, **로컬 PC에서 미리 파일(Docker 바이너리 또는
컨테이너 이미지)을 내려받아 SSH로 VM에 업로드**합니다. 네 디렉터리 모두 동일한 흐름을 따릅니다.

1. **로컬(인터넷 가능) PC** 에서 파일을 다운로드 (`scripts/01-*.sh`)
2. **로컬 PC** 에서 SSH로 디렉터리 전체(스크립트 + `.env` + 다운로드한 파일)를 **폐쇄망 VM** 으로 전송
   (`scripts/02-transfer-to-vm.sh` — 로컬/VM 양쪽에 `rsync`가 모두 있으면 `rsync`로, 하나라도
   없으면 `tar+scp`로 자동 전송)
3. **VM** 에서 설치/로드 → 기동 → **CLI만으로** 초기화 (관리자 계정 생성 등)

SSH 전송을 위해 각 디렉터리 `.env` 에 `VM_SSH_HOST` / `VM_SSH_USER` / `VM_SSH_PORT` /
`VM_REMOTE_DIR` 을 설정해야 합니다. 키 기반 SSH 인증(`ssh-copy-id`)을 미리 구성해 두면
전송 스크립트가 비밀번호 입력 없이 동작합니다.

브라우저(UI)를 사용할 수 없는 환경을 전제로, 세 서비스 모두 **웹 설치 마법사를 거치지 않고
CLI/REST API로 무인 초기화**되도록 구성했습니다.

| 서비스 | 초기화 방식 |
|---|---|
| Gitea | `INSTALL_LOCK=true` 로 웹 설치 화면 자체를 비활성화 + `gitea admin user create` CLI로 관리자 계정 생성 |
| Jenkins | `-Djenkins.install.runSetupWizard=false` + `init.groovy.d` 그루비 스크립트로 기동 시 관리자 계정 자동 생성 |
| Nexus | 설치 마법사 없이 REST API(curl)로 초기 admin 비밀번호 변경 및 익명 접근 비활성화 |

세 서비스 모두 **앞단에 nginx 컨테이너를 함께 띄워 TLS를 종료**합니다. 각 서비스는 컨테이너
내부에서만 평문 HTTP로 열려 있고, 호스트에는 nginx의 443(HTTPS)/80(HTTPS 리다이렉트)만
노출됩니다. 인증서는 자체 서명(self-signed)이며 VM에서 `openssl`로 직접 생성됩니다
(각 디렉터리의 `scripts/04-generate-tls-cert.sh`, 기동 스크립트가 자동 호출). Gitea의 git-SSH
클론용 포트(기본 2222), Jenkins의 에이전트(JNLP) 포트(기본 50000)는 HTTP가 아니므로 nginx를
거치지 않고 그대로 직접 노출됩니다.

각 디렉터리에는 문서가 두 종류 있습니다.

- `README.md` : 로컬 PC 작업부터 VM 작업까지 전체 흐름 개요
- `MANUAL.md` : **VM에 파일이 이미 전달된 이후** 설치/구동·초기화·검증·트러블슈팅·백업·업그레이드를
  다루는 VM 관리자용 실행 매뉴얼 (실제 운영 시에는 이 문서를 기준으로 진행)

| 디렉터리 | 개요 | VM 실행 매뉴얼 |
|---|---|---|
| Docker | [README.md](Docker/README.md) | [MANUAL.md](Docker/MANUAL.md) |
| GitServer | [README.md](GitServer/README.md) | [MANUAL.md](GitServer/MANUAL.md) |
| Jenkins | [README.md](Jenkins/README.md) | [MANUAL.md](Jenkins/MANUAL.md) |
| Nexus | [README.md](Nexus/README.md) | [MANUAL.md](Nexus/MANUAL.md) |

## 시작하기 전에

각 디렉터리의 `.env` 파일에서 배포 전 아래 값을 반드시 실제 환경에 맞게 변경하세요.

- SSH 전송 대상 (`VM_SSH_HOST`, `VM_SSH_USER`, `VM_SSH_PORT`, `VM_REMOTE_DIR`) — 네 디렉터리 모두
- Docker 설치 대상 VM의 CPU 아키텍처 (`Docker/.env` 의 `ARCH`)
- 관리자 비밀번호 (`ADMIN_PASSWORD` / `JENKINS_ADMIN_PASSWORD`)
- `TLS_DOMAIN` (VM의 실제 접속 주소, IP 또는 사내 도메인) — GitServer/Jenkins/Nexus 세 디렉터리
  모두. TLS 인증서의 CN/SAN에 사용되며, Gitea는 `GITEA_DOMAIN` 도 동일하게 맞춰야 함
- 필요 시 포트 값

## 이번 범위 밖 (다음 단계)

- Jenkins 플러그인 오프라인 설치 (Update Center 접근 불가로 별도 진행 필요)
- Nexus를 Maven/npm/Docker 등 프록시 저장소로 구성하여 Jenkins/빌드에서 활용
- 자체 서명 인증서 대신 사내 내부 CA로 발급받은 인증서 사용 (각 디렉터리 `MANUAL.md` 의
  "내부 CA로 발급받은 인증서로 교체하기" 참고 — `certs/server.crt`/`server.key` 교체 후 nginx만 재시작)
- 외부 DB(PostgreSQL 등) 연동, 백업 자동화 등 운영 고도화
