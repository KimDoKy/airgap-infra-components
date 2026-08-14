# Nexus 구축 가이드 (서버 구축자)

폐쇄망 VM(bastion 뒤 private subnet)에 Nexus Repository 를 Docker 로 올리는 절차. 한 번 수행하면 됩니다.
소비자는 CICD 서버 하나뿐이라 다중 사용자 게이트웨이는 필요 없습니다.

## 0. 사전 조건

- **로컬 PC**: Docker(이미지 pull/save), `ssh`/`rsync`, bastion 경유 VM 접속(`ssh acme-nexus`).
- **Nexus VM**: Docker/Compose(미설치 시 `../Docker/` 먼저), `curl`, `openssl`, `sudo`, **RAM 4GB+**.
- **보안그룹(SG)**:
  | SG | 인바운드 | 출발지 |
  |---|---|---|
  | Nexus VM | `TCP 22` | bastion (운영자 접속·업로드 터널) |
  | Nexus VM | `TCP 443` | **CICD VM 이 생기면** 그 서버로만 (소비 경로, [USER.md](USER.md)) |
  > 443/8081 은 그 외에게 열지 않습니다. 운영자 접근은 22 터널로 처리합니다.

## 1. 설정 (`.env`)

```
NEXUS_IMAGE=sonatype/nexus3:3.70.1     NGINX_IMAGE=nginx:1.27-alpine
VM_SSH_HOST=acme-nexus                # ssh config alias (bastion ProxyJump). IP 직접 금지
VM_SSH_USER=ubuntu  VM_SSH_PORT=22  VM_REMOTE_DIR=/home/ubuntu/Nexus   # 절대경로(~ 금지)
TLS_PORT=443  TLS_HTTP_PORT=80         # Nexus 8081 은 컨테이너 내부만(호스트 미노출)
TLS_DOMAIN=<NEXUS_IP>                # 인증서 CN/SAN
NEXUS_UID=200  NEXUS_GID=200           # Nexus 고정 uid
NEXUS_MIN_HEAP=1200m  NEXUS_MAX_HEAP=1200m   # VM 메모리에 맞게(7.8G면 여유. 필요시 상향)
ADMIN_PASSWORD=<강력한 값>             DISABLE_ANONYMOUS_ACCESS=true
```

## 2. 이미지 배포 + 기동 + 초기화

```bash
# [로컬] 이미지 pull+save (빌드 PC=Intel(amd64) → VM(amd64)과 동일 아키텍처라 플랫폼 강제 불필요)
./scripts/01-pull-and-save-image.sh
./scripts/02-transfer-to-vm.sh                 # VM에 전체 전송

# [VM]  (ssh acme-nexus; cd /home/ubuntu/Nexus)
./scripts/03-load-image.sh                     # 이미지 로드
./scripts/05-start.sh                          # 인증서 생성 + compose up + status 200 까지 대기(1~2분+)
./scripts/06-configure.sh                      # admin 비번(.env) 설정 + 익명 접근 비활성화 (REST API)
```

## 3. 검증

```bash
# [VM]
docker ps --filter name=nexus                                                   # nexus, nexus-nginx Up
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/service/rest/v1/status  # 200
curl -s --cacert certs/server.crt -u 'admin:<ADMIN_PASSWORD>' https://localhost/service/rest/v1/repositories  # 기본 repo 목록
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/repository/maven-central/  # 익명 401(정상)
```

## 4. 이후

- CI 서비스 계정 발급·저장소 관리·백업 → [ADMIN.md](ADMIN.md)
- CICD 서버에서의 소비(연결 경로·업로드/다운로드) → [USER.md](USER.md)
- 버전 업그레이드: `.env` 태그 변경 → 로컬 `01`→`02` 재실행 → VM `03` → `docker compose up -d`
  (업그레이드 전 `nexus-data/` 백업 필수, 기동 시 자동 마이그레이션)
- SSH 호스트 포트가 22→다른 포트로 바뀌면 SG 규칙과 접속 설정만 새 번호로 갱신.
