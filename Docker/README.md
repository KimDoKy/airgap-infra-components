# Docker - 폐쇄망 설치 매뉴얼 (선행 단계)

`GitServer/`, `Jenkins/`, `Nexus/` 는 모두 Docker(및 Docker Compose 플러그인)가 VM에 이미
설치되어 있다는 것을 전제로 동작합니다. 이 디렉터리는 그 **선행 단계** — 폐쇄망 VM에 Docker
자체를 설치하는 절차를 다룹니다.

> **세 VM 모두에 각각 설치해야 합니다.** GitServer/Jenkins/Nexus용 VM 3대 각각에 대해 이
> 디렉터리의 절차를 반복하세요 (`.env` 의 `VM_SSH_HOST` 를 바꿔가며 전송 스크립트를 재실행하면 됩니다).

패키지 매니저(apt/yum) 대신 Docker의 **정적 바이너리(static binary)** 배포판을 사용합니다.
의존성 패키지를 개별적으로 받아야 하는 `.deb`/`.rpm` 방식과 달리 압축 파일 하나로 배포되어
폐쇄망 환경에서 가장 다루기 쉽고, 배포판(Ubuntu/CentOS/Rocky 등)에 관계없이 동일하게 동작합니다.

## 사전 준비물

- 로컬(인터넷 가능) PC: `curl`, `ssh`/`scp` (가능하면 `rsync`도)
- 대상 VM(폐쇄망): systemd 기반 Linux, `sudo` 권한
- 로컬 PC → VM SSH 접근 가능 (키 기반 인증 권장: `ssh-copy-id <user>@<vm-ip>`)
- VM의 CPU 아키텍처 확인 (`uname -m` → `x86_64` 또는 `aarch64`). `.env` 의 `ARCH` 와 일치해야 함

## 디렉터리 구조

```
Docker/
├── .env                        # 설정값 (버전, 아키텍처, SSH 대상 등)
├── config/
│   └── docker.service          # dockerd systemd 유닛 파일
├── packages/                   # 다운로드된 바이너리 저장 위치
└── scripts/
    ├── 01-download.sh          # [로컬] Docker/Compose 바이너리 다운로드
    ├── 02-transfer-to-vm.sh    # [로컬] SSH로 VM에 전체 디렉터리 업로드
    ├── 03-install.sh           # [VM] 설치 + systemd 등록
    └── 04-verify.sh            # [VM] 설치 검증
```

## 실행 순서

### 1단계. 로컬 PC에서 바이너리 다운로드 (인터넷 가능 환경)

`.env` 에서 `ARCH` 가 대상 VM과 일치하는지 먼저 확인하세요 (기본값 `x86_64`).

```bash
cd Docker
./scripts/01-download.sh
```

`packages/docker-<version>.tgz` 와 `packages/docker-compose` 가 생성됩니다.

### 2단계. 배포 전 설정값 확인 (.env)

- `VM_SSH_HOST`, `VM_SSH_USER`, `VM_SSH_PORT`, `VM_REMOTE_DIR` : SSH 전송 대상 VM 정보
- `ADD_USER_TO_DOCKER_GROUP` : `true` 면 SSH 접속 사용자를 `docker` 그룹에 추가해 매번 `sudo` 없이
  `docker` 명령을 쓸 수 있게 함 (GitServer/Jenkins/Nexus 스크립트들도 `sudo` 없이 `docker`/
  `docker compose` 를 호출하므로 `true` 권장)

### 3단계. SSH로 VM에 전송 (로컬 PC에서 실행)

```bash
./scripts/02-transfer-to-vm.sh
```

GitServer/Jenkins/Nexus용 VM 3대에 모두 설치해야 한다면, `.env` 의 `VM_SSH_HOST` 를 바꿔가며
이 스크립트를 3번 실행하세요.

### 4단계. VM에서 설치

```bash
ssh -p <VM_SSH_PORT> <VM_SSH_USER>@<VM_SSH_HOST>
cd <VM_REMOTE_DIR>
./scripts/03-install.sh
```

이 스크립트가 자동으로 수행하는 작업:

1. `packages/docker-<version>.tgz` 압축 해제 후 `/usr/bin` 에 Docker 바이너리 설치
2. `docker` 그룹 생성
3. `packages/docker-compose` 를 `/usr/local/lib/docker/cli-plugins/docker-compose` 로 설치
   (`docker compose` 서브커맨드로 동작)
4. `config/docker.service` 를 `/etc/systemd/system/` 에 등록 후 `systemctl enable --now docker`
5. (`ADD_USER_TO_DOCKER_GROUP=true` 인 경우) 현재 사용자를 `docker` 그룹에 추가

### 5단계. 재로그인 후 검증

그룹 변경사항 반영을 위해 SSH 세션을 재접속한 뒤:

```bash
./scripts/04-verify.sh
```

`docker version`, `docker compose version`, `systemctl is-active docker` 가 모두 정상이면
완료입니다.

VM에서의 상세 트러블슈팅은 [MANUAL.md](MANUAL.md) 를 참고하세요.

## 다음 단계

Docker 설치가 끝나면 각 서비스 디렉터리에서 이미지 로드/기동을 진행하세요.

- [../GitServer/MANUAL.md](../GitServer/MANUAL.md)
- [../Jenkins/MANUAL.md](../Jenkins/MANUAL.md)
- [../Nexus/MANUAL.md](../Nexus/MANUAL.md)

## 참고 (이번 범위 밖)

- 프록시가 필요한 폐쇄망(인터넷은 안 되지만 사내 프록시로 사설 레지스트리 접근이 가능한 경우)라면
  `/etc/systemd/system/docker.service.d/http-proxy.conf` 등으로 dockerd 프록시 설정 추가 가능
- 운영 중 재부팅 시 Docker가 자동 기동되도록 이미 `systemctl enable` 처리되어 있음 (추가 조치 불필요)
