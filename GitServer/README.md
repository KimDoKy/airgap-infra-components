# GitServer (Gitea) - 폐쇄망 구축 매뉴얼

이 디렉터리는 **다른 VM(Jenkins, Nexus)과 완전히 독립적으로** 실행됩니다.
이 디렉터리 전체를 Git Server용 VM으로 SSH를 통해 전송하고, 아래 순서대로 실행하세요.

VM은 인터넷/사설망 이미지 저장소에 접근할 수 없다고 가정하므로, 컨테이너 이미지는 반드시
**로컬 PC에서 미리 받아 SSH로 VM에 업로드**합니다. 브라우저(UI)도 사용할 수 없다고 가정하므로,
초기 설치/관리자 계정 생성까지 모두 **CLI 스크립트**로 처리합니다.

## 사전 준비물

- 로컬(인터넷 가능) PC: Docker 설치, `ssh`/`scp` (가능하면 `rsync`도)
- 대상 VM(폐쇄망): Docker / Docker Compose 플러그인 설치, `sudo` 권한
  (미설치 상태라면 [../Docker/README.md](../Docker/README.md) 를 먼저 진행하세요)
- 로컬 PC → VM SSH 접근 가능 (키 기반 인증 권장: `ssh-copy-id <user>@<vm-ip>`)

## 디렉터리 구조

```
GitServer/
├── .env                   # 설정값 (포트, 버전, 관리자 계정, SSH 대상 등)
├── docker-compose.yml
├── images/                # 이미지 tar.gz 저장 위치
├── data/                  # Gitea 데이터 (최초 실행 시 자동 생성)
└── scripts/
    ├── 00-generate-secrets.sh     # SECRET_KEY/INTERNAL_TOKEN 생성 (자동 호출됨)
    ├── 01-pull-and-save-image.sh  # [로컬] 이미지 다운로드+저장
    ├── 02-transfer-to-vm.sh       # [로컬] SSH로 VM에 전체 디렉터리 업로드
    ├── 03-load-image.sh           # [VM] 이미지 로드
    ├── 04-start.sh                # [VM] 기동 + CLI 초기화
    └── 05-stop.sh                 # [VM] 중지
```

## 실행 순서

### 1단계. 로컬 PC에서 이미지 다운로드 (인터넷 가능 환경)

```bash
cd GitServer
./scripts/01-pull-and-save-image.sh
```

`images/gitea-image.tar.gz` 파일이 생성됩니다.

### 2단계. 배포 전 설정값 확인 (.env)

`.env` 파일을 열어 아래 값을 실제 환경에 맞게 수정하세요.

- `VM_SSH_HOST`, `VM_SSH_USER`, `VM_SSH_PORT`, `VM_REMOTE_DIR` : SSH 전송 대상 VM 정보
- `ADMIN_PASSWORD` : 반드시 변경
- `GITEA_DOMAIN`, `GITEA_ROOT_URL` : VM의 실제 접속 주소(IP 또는 사내 도메인)
- `HTTP_PORT`, `SSH_PORT` : 필요 시 변경

### 3단계. SSH로 VM에 전송 (로컬 PC에서 실행)

```bash
./scripts/02-transfer-to-vm.sh
```

SSH 접속을 확인한 뒤, `rsync`(있으면) 또는 `tar+scp`(없으면)로 `GitServer/` 디렉터리 전체
(스크립트, `.env`, `images/gitea-image.tar.gz` 포함)를 `.env` 의 `VM_REMOTE_DIR` 경로로 업로드합니다.

### 4단계. VM에서 이미지 로드

```bash
ssh -p <VM_SSH_PORT> <VM_SSH_USER>@<VM_SSH_HOST>
cd <VM_REMOTE_DIR>
./scripts/03-load-image.sh
```

### 5단계. 기동 및 CLI 초기화 (VM에서 실행)

```bash
./scripts/04-start.sh
```

이 스크립트가 자동으로 수행하는 작업:

1. `./data` 디렉터리 생성 및 소유권 설정
2. SECRET_KEY / INTERNAL_TOKEN 생성 (`INSTALL_LOCK=true` 로 웹 설치 마법사 자체를 비활성화)
3. `docker compose up -d`
4. `docker exec gitea gitea admin user create ...` 로 관리자 계정을 **CLI에서 직접 생성**
   (브라우저 설치 화면을 거치지 않음)

### 6단계. 확인

- Web UI(선택): `http://<VM_IP>:3000`
- Git clone (SSH): `git clone ssh://git@<VM_IP>:2222/<user>/<repo>.git`
- Git clone (HTTP): `git clone http://<VM_IP>:3000/<user>/<repo>.git`
- CLI로 추가 사용자/조직 관리: `docker exec gitea gitea admin user create --help`

VM에서의 상세 운영/트러블슈팅은 [MANUAL.md](MANUAL.md) 를 참고하세요.

## 운영 명령어 (VM)

```bash
# 로그 확인
docker logs -f gitea

# 재시작
docker compose restart

# 중지 (데이터 보존)
./scripts/05-stop.sh

# 데이터 백업 대상
./data/
```

## 버전 변경

`.env` 의 `GITEA_IMAGE` 값을 원하는 태그로 변경한 뒤,
로컬에서 `01-pull-and-save-image.sh` → `02-transfer-to-vm.sh` 재실행 →
VM에서 `03-load-image.sh` → `docker compose up -d` 로 이미지를 갱신하세요.

## 참고 (다음 단계 - 이번 범위 밖)

- 대규모 운영 시 SQLite 대신 외부 PostgreSQL/MySQL 연동 고려
- HTTPS 적용 시 리버스 프록시(Nginx 등) 또는 Gitea 자체 TLS 설정 필요
