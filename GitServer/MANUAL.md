# Gitea 구동 및 초기화 매뉴얼 (VM 관리자용)

이 문서는 `GitServer/` 디렉터리 전체(이미지 tar.gz 포함)가 로컬 PC에서
`scripts/02-transfer-to-vm.sh` 로 **이미 이 VM에 SSH 전송되어 있는 상태**를 전제로, VM에서
수행할 작업만 다룹니다. 로컬 PC에서의 이미지 다운로드/전송 절차는 `README.md` 를 참고하세요.

브라우저 접속 없이 CLI만으로 끝까지 진행합니다. Gitea 앞단은 nginx 컨테이너가 TLS(자체 서명
인증서)를 종료하며, Gitea 자체는 호스트에 직접 노출되지 않습니다.

---

## 0. 체크리스트

- [ ] `GitServer/` 디렉터리 전체가 이 VM에 존재 (`.env`, `docker-compose.yml`, `nginx/nginx.conf`,
      `images/gitea-image.tar.gz`, `scripts/`)
- [ ] Docker, Docker Compose 플러그인 설치됨 (`docker -v`, `docker compose version`) —
      미설치 시 [../Docker/MANUAL.md](../Docker/MANUAL.md) 를 먼저 진행
- [ ] `openssl` 사용 가능 (`openssl version`) — 자체 서명 인증서 생성에 필요, 대부분의 Linux에 기본 포함
- [ ] `sudo` 권한 있음
- [ ] 열어야 할 포트(기본 443, 80, 2222)에 대한 방화벽/보안그룹 허용. **3000 포트는 더 이상 사용하지
      않습니다** (nginx 뒤로 숨겨짐)

## 1. 설정값 확인 (.env)

```bash
cd GitServer
vi .env
```

배포 전 반드시 확인/변경할 항목:

| 항목 | 설명 |
|---|---|
| `ADMIN_PASSWORD` | 초기 관리자 비밀번호. 기본값(`ChangeMe123!`) 그대로 두지 말 것 |
| `GITEA_DOMAIN` | 이 VM의 실제 접속 주소(IP 또는 사내 도메인). clone URL 생성에 사용됨 |
| `TLS_DOMAIN` | TLS 인증서의 CN/SAN에 들어갈 값. **`GITEA_DOMAIN` 과 동일하게 설정 권장** |
| `TLS_PORT` / `SSH_PORT` | 다른 서비스와 충돌 시에만 변경 (기본 443 / 2222) |

> `GITEA_SECRET_KEY` / `GITEA_INTERNAL_TOKEN` 은 빈 값으로 두세요. 3단계에서 자동 생성됩니다.
> `GITEA_ROOT_URL` 도 기본값(`https://localhost/`)을 그대로 두면 `GITEA_DOMAIN` 변경과 별개로
> 동작에는 문제가 없지만, clone URL을 올바르게 표시하려면 `GITEA_DOMAIN` 과 맞춰 `https://<도메인>/`
> 로 수정하는 것을 권장합니다.

## 2. 이미지 로드

```bash
./scripts/03-load-image.sh
```

`docker images` 목록에 `gitea/gitea` 와 `nginx` 가 모두 보이면 정상입니다.

## 3. 기동 + CLI 초기화

```bash
./scripts/05-start.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. `./data` 생성 및 소유권(`USER_UID:USER_GID`) 설정
2. `SECRET_KEY` / `INTERNAL_TOKEN` 생성 → `.env` 에 저장
3. 자체 서명 TLS 인증서 생성 (`04-generate-tls-cert.sh` 자동 호출, 이미 있으면 재사용)
4. `docker compose up -d` — Gitea + nginx 두 컨테이너 기동. `INSTALL_LOCK=true` 이므로 브라우저
   설치 화면 자체가 나타나지 않음
5. Gitea 컨테이너가 준비되면 `docker exec -u <USER_UID> gitea gitea admin user create ...` 로
   관리자 계정을 **CLI에서 직접 생성** (Gitea는 root로 실행되는 것을 거부하므로 반드시
   `-u <USER_UID>` 를 지정해야 함, 기본값 1000)
6. nginx가 443에서 응답하는지 확인

정상 종료 시 아래와 같은 메시지가 출력됩니다.

```
>> Gitea 준비 완료 (UI 없이 CLI로 초기화됨, TLS 적용됨)
   Web: https://<VM_IP>:443 (또는 https://<TLS_DOMAIN>/)
   SSH clone 포트: 2222
   관리자 계정: admin / (.env 의 ADMIN_PASSWORD)
   자체 서명 인증서이므로 브라우저 경고가 뜨는 것은 정상입니다.
```

## 4. 정상 동작 확인 (CLI)

```bash
# 컨테이너 상태 (gitea, gitea-nginx 둘 다 Up 이어야 함)
docker ps --filter name=gitea

# 관리자 계정이 생성되었는지 확인 (root로 실행하면 거부되므로 -u 1000 필수)
docker exec -u 1000 gitea gitea admin user list

# nginx를 거쳐 HTTPS 응답 확인 (자체 서명 인증서를 신뢰해 검증)
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/api/healthz

# API로 로그인 확인 (Basic Auth, HTTPS)
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> https://localhost/api/v1/user

# Gitea 컨테이너 자체(내부 HTTP, nginx 우회) 헬스체크 - 문제 구간 분리용
docker exec gitea curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/api/healthz
```

`gitea admin user list` 에 `admin` 계정이 `Is Admin` = true 로 보이면 정상입니다.

## 5. 사용자/저장소 관리 (CLI 전용)

```bash
# 추가 사용자 생성 (root로 실행하면 거부되므로 -u 1000 필수)
docker exec -u 1000 gitea gitea admin user create \
  --username <user> --password <pw> --email <user>@example.com --must-change-password=false

# 사용자 목록
docker exec -u 1000 gitea gitea admin user list

# 비밀번호 초기화
docker exec -u 1000 gitea gitea admin user change-password --username <user> --password <newpw>
```

저장소(repository) 생성은 CLI 서브커맨드가 제한적이므로, Gitea REST API를 사용합니다.

```bash
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> -X POST \
  https://localhost/api/v1/user/repos \
  -H 'Content-Type: application/json' \
  -d '{"name": "my-repo", "private": true}'
```

git 클라이언트에서 자체 서명 인증서로 clone 하려면:

```bash
# 방법 1: 인증서를 지정해서 검증 유지 (권장)
git -c http.sslCAInfo=/path/to/server.crt clone https://<VM_IP>/<user>/<repo>.git

# 방법 2: 검증 자체를 끔 (테스트용, 운영 비권장)
GIT_SSL_NO_VERIFY=true git clone https://<VM_IP>/<user>/<repo>.git
```

## 6. 운영 명령어

```bash
docker logs -f gitea           # Gitea 로그 확인
docker logs -f gitea-nginx     # nginx(TLS) 로그 확인
docker compose restart         # 재시작
./scripts/06-stop.sh           # 중지 (데이터 보존)
docker compose up -d           # 재기동
```

## 7. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `05-start.sh` 에서 Gitea 대기 단계 실패 | `docker logs gitea` 확인. 대부분 `./data` 권한 문제(`USER_UID/GID` 불일치) — `sudo chown -R <uid>:<gid> data` 재실행 |
| `05-start.sh` 에서 nginx 대기 단계 실패 | `docker logs gitea-nginx` 확인. 대부분 `certs/server.crt`/`server.key` 누락 — `./scripts/04-generate-tls-cert.sh` 재실행 후 `docker compose restart nginx` |
| 관리자 계정 생성 시 "already exists" | 정상입니다. 이미 생성된 계정을 재사용합니다 |
| 포트 443/80/2222 바인딩 실패 | 다른 프로세스가 포트 점유 중 (`sudo ss -tlnp \| grep -E '443\|80\|2222'`). `.env` 에서 포트 변경 |
| SSH clone 시 `Connection refused` | 보안그룹/방화벽에서 `SSH_PORT`(기본 2222) 미개방 여부 확인 |
| `gitea generate secret` 단계에서 실패 | 이미지가 로드되지 않았을 가능성. `docker images` 로 `gitea/gitea` 존재 확인 후 재시도 |
| 브라우저에서 "신뢰할 수 없는 인증서" 경고 | 자체 서명 인증서이므로 정상입니다. 매번 경고를 없애려면 `certs/server.crt` 를 각 클라이언트 브라우저/OS의 신뢰 저장소에 직접 등록하거나, 사내 내부 CA로 발급받은 인증서로 교체하세요 (아래 참고) |
| `curl: (60) SSL certificate problem` | `--cacert certs/server.crt` 를 빠뜨렸거나, 접속 주소가 인증서의 CN/SAN(`TLS_DOMAIN`, `localhost`, `127.0.0.1`)과 다름. `TLS_DOMAIN` 을 실제 접속 주소와 일치시킨 뒤 인증서 재발급 |

### 내부 CA로 발급받은 인증서로 교체하기

자체 서명 대신 사내 내부 CA가 있다면, 발급받은 인증서 파일을 아래 경로에 그대로 배치하고
nginx만 재시작하면 됩니다 (Gitea 재기동 불필요).

```bash
cp <발급받은 인증서>.crt certs/server.crt
cp <발급받은 개인키>.key certs/server.key
chmod 600 certs/server.key
docker compose restart nginx
```

## 8. 백업 / 복구

- 백업 대상: `./data/` 디렉터리 전체 (DB, 저장소, 설정 포함)
- 인증서(`./certs/`)는 재발급이 간단하므로 필수 백업 대상은 아니지만, 사내 CA로 발급받은
  인증서를 쓰는 경우 재발급 절차가 번거로울 수 있어 함께 백업하는 것을 권장합니다.
- 백업 절차:
  ```bash
  ./scripts/06-stop.sh
  tar czf gitea-data-backup-$(date +%F).tar.gz data/ certs/
  docker compose up -d
  ```
- 복구 절차: 새 VM/디렉터리에 `data/`(및 필요 시 `certs/`)를 동일 경로로 복원 후 `docker compose up -d`

## 9. 버전 업그레이드

1. 로컬 PC에서 `.env` 의 `GITEA_IMAGE`(또는 `NGINX_IMAGE`) 태그를 변경 후 `01-pull-and-save-image.sh` 재실행
2. `./scripts/02-transfer-to-vm.sh` 로 새 이미지를 VM에 재전송
3. VM에서 `.env` 의 `GITEA_IMAGE` 를 동일하게 변경 (전송 스크립트가 `.env` 도 함께 덮어쓰므로, VM에서
   `ADMIN_PASSWORD` 등을 VM 쪽에서 직접 수정했다면 덮어써지지 않도록 주의)
4. `./scripts/03-load-image.sh` → `docker compose up -d` (데이터/인증서는 `./data`, `./certs` 그대로
   유지, Gitea가 기동 시 자동으로 DB 마이그레이션 수행)
5. 업그레이드 전 반드시 8절의 백업을 먼저 수행할 것
