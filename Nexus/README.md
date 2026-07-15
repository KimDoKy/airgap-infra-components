# Nexus (nexus3) - 폐쇄망 구축 매뉴얼

이 디렉터리는 **다른 VM(GitServer, Jenkins)과 완전히 독립적으로** 실행됩니다.
이 디렉터리 전체를 Nexus용 VM으로 SSH를 통해 전송하고, 아래 순서대로 실행하세요.

VM은 인터넷/사설망 이미지 저장소에 접근할 수 없다고 가정하므로, 컨테이너 이미지는 반드시
**로컬 PC에서 미리 받아 SSH로 VM에 업로드**합니다. 브라우저(UI)도 사용할 수 없다고 가정하므로,
초기 admin 비밀번호 변경 및 익명 접근 비활성화까지 모두 **REST API(curl) 기반 CLI 스크립트**로
처리합니다. (Nexus는 "설치 마법사"가 화면 전용 UX일 뿐 API 자체는 처음부터 정상 동작하므로
별도의 wizard-skip 옵션 없이 API 호출만으로 초기화가 가능합니다.)

Nexus 앞단에 **nginx 컨테이너가 TLS를 종료**합니다. Nexus 자체는 컨테이너 내부에서만
평문 HTTP로 열려 있고, 호스트에는 nginx의 443(HTTPS)/80(HTTPS로 리다이렉트)만 노출됩니다.
인증서는 자체 서명(self-signed)이며 VM에서 직접 생성됩니다.

## 사전 준비물

- 로컬(인터넷 가능) PC: Docker 설치, `ssh`/`scp` (가능하면 `rsync`도)
- 대상 VM(폐쇄망): Docker / Docker Compose 플러그인, `curl`, `openssl`, `sudo` 권한
  (미설치 상태라면 [../Docker/README.md](../Docker/README.md) 를 먼저 진행하세요)
  - 최소 4GB RAM 권장 (`.env` 의 힙 설정을 리소스에 맞게 조정)
- 로컬 PC → VM SSH 접근 가능 (키 기반 인증 권장: `ssh-copy-id <user>@<vm-ip>`)

## 디렉터리 구조

```
Nexus/
├── .env                      # 설정값 (포트, 버전, admin 비밀번호, TLS, SSH 대상 등)
├── docker-compose.yml
├── nginx/
│   └── nginx.conf            # TLS 종료 리버스 프록시 설정
├── images/                   # 이미지 tar.gz 저장 위치 (Nexus + nginx)
├── certs/                    # 자체 서명 TLS 인증서 (VM에서 자동 생성)
├── nexus-data/                # Nexus 데이터 (최초 실행 시 자동 생성)
└── scripts/
    ├── 01-pull-and-save-image.sh  # [로컬] 이미지 다운로드+저장 (Nexus + nginx)
    ├── 02-transfer-to-vm.sh       # [로컬] SSH로 VM에 전체 디렉터리 업로드
    ├── 03-load-image.sh           # [VM] 이미지 로드
    ├── 04-generate-tls-cert.sh    # [VM] 자체 서명 TLS 인증서 생성 (자동 호출됨)
    ├── 05-start.sh                # [VM] 기동
    ├── 06-configure.sh            # [VM] REST API로 CLI 초기화
    └── 07-stop.sh                 # [VM] 중지
```

## 실행 순서

### 1단계. 로컬 PC에서 이미지 다운로드 (인터넷 가능 환경)

```bash
cd Nexus
./scripts/01-pull-and-save-image.sh
```

### 2단계. 배포 전 설정값 확인 (.env)

- `VM_SSH_HOST`, `VM_SSH_USER`, `VM_SSH_PORT`, `VM_REMOTE_DIR` : SSH 전송 대상 VM 정보
- `ADMIN_PASSWORD` : 반드시 변경
- `TLS_DOMAIN` : VM의 실제 접속 주소(IP 또는 사내 도메인) — TLS 인증서의 CN/SAN에 사용됨

### 3단계. SSH로 VM에 전송 (로컬 PC에서 실행)

```bash
./scripts/02-transfer-to-vm.sh
```

SSH 접속을 확인한 뒤, 로컬/VM 양쪽에 `rsync`가 모두 있으면 `rsync`로, 하나라도 없으면 `tar+scp`로 `Nexus/` 디렉터리 전체
(스크립트, `.env`, `nginx/`, `images/nexus-image.tar.gz` 포함)를 `.env` 의 `VM_REMOTE_DIR`
경로로 업로드합니다.

### 4단계. VM에서 이미지 로드

```bash
ssh -p <VM_SSH_PORT> <VM_SSH_USER>@<VM_SSH_HOST>
cd <VM_REMOTE_DIR>
./scripts/03-load-image.sh
```

### 5단계. 기동 (VM에서 실행)

```bash
./scripts/05-start.sh
```

자체 서명 TLS 인증서를 생성한 뒤 `docker compose up -d` (Nexus + nginx)로 기동하고,
nginx를 거쳐 `/service/rest/v1/status` API가 200을 반환할 때까지 대기합니다
(최초 기동은 DB 초기화 등으로 1~2분 이상 걸릴 수 있습니다).

### 6단계. CLI(REST API) 초기 설정

```bash
./scripts/06-configure.sh
```

이 스크립트가 자동으로 수행하는 작업:

1. 컨테이너 내부 `/nexus-data/admin.password` 파일에서 최초 생성된 임시 비밀번호를 읽음
2. `PUT /service/rest/v1/security/users/admin/change-password` 로 `.env` 의 `ADMIN_PASSWORD` 로 변경
3. (`DISABLE_ANONYMOUS_ACCESS=true` 인 경우) `PUT /service/rest/v1/security/anonymous` 로 익명 접근 비활성화

모두 curl(HTTPS, nginx 경유)로만 수행되며 브라우저 접속이 필요하지 않습니다.

### 7단계. 확인

```bash
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> https://<VM_IP>/service/rest/v1/status
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> https://<VM_IP>/service/rest/v1/repositories
```

VM에서의 상세 운영/트러블슈팅은 [MANUAL.md](MANUAL.md) 를 참고하세요.

## 운영 명령어 (VM)

```bash
# 로그 확인
docker logs -f nexus
docker logs -f nexus-nginx

# 재시작
docker compose restart

# 중지 (데이터 보존)
./scripts/07-stop.sh

# 데이터 백업 대상
./nexus-data/
```

## 참고 (다음 단계 - 이번 범위 밖)

- **저장소(repository) 생성**: Maven/npm/Docker 등 proxy·hosted 저장소 생성도
  `POST /service/rest/v1/repositories/<format>/<type>` REST API로 UI 없이 가능합니다.
  (폐쇄망 특성상 proxy 저장소의 remote URL은 접근 가능한 내부 미러로 지정해야 합니다.)
- Nexus를 Docker 프라이빗 레지스트리로도 쓰려면 `docker-hosted`/`docker-proxy` 저장소와
  별도 포트 노출(예: 8082)이 추가로 필요합니다 — 필요 시 별도 구성.
- 사내 내부 CA가 있다면 자체 서명 인증서 대신 발급받은 인증서를 `certs/server.crt`,
  `certs/server.key` 로 교체 (자세한 내용은 [MANUAL.md](MANUAL.md) 참고)
