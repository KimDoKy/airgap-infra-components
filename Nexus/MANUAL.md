# Nexus 구동 및 초기화 매뉴얼 (VM 관리자용)

이 문서는 `Nexus/` 디렉터리 전체(이미지 tar.gz 포함)가 로컬 PC에서
`scripts/02-transfer-to-vm.sh` 로 **이미 이 VM에 SSH 전송되어 있는 상태**를 전제로, VM에서
수행할 작업만 다룹니다. 로컬 PC에서의 이미지 다운로드/전송 절차는 `README.md` 를 참고하세요.

브라우저 접속 없이 REST API(curl)만으로 끝까지 진행합니다. Nexus 앞단은 nginx 컨테이너가
TLS(자체 서명 인증서)를 종료하며, Nexus 자체는 호스트에 직접 노출되지 않습니다.

---

## 0. 체크리스트

- [ ] `Nexus/` 디렉터리 전체가 이 VM에 존재 (`.env`, `docker-compose.yml`, `nginx/nginx.conf`,
      `images/nexus-image.tar.gz`, `scripts/`)
- [ ] Docker, Docker Compose 플러그인 설치됨 —
      미설치 시 [../Docker/MANUAL.md](../Docker/MANUAL.md) 를 먼저 진행
- [ ] `curl`, `openssl`, `sudo` 사용 가능
- [ ] 열어야 할 포트(기본 443, 80)에 대한 방화벽/보안그룹 허용. **8081 포트는 더 이상 사용하지
      않습니다** (nginx 뒤로 숨겨짐)
- [ ] 메모리 최소 4GB 이상 여유 (Nexus 최소 권장 사양)

## 1. 설정값 확인 (.env)

```bash
cd Nexus
vi .env
```

| 항목 | 설명 |
|---|---|
| `ADMIN_PASSWORD` | 초기화 후 적용할 admin 비밀번호. 기본값(`ChangeMe123!`) 그대로 두지 말 것 |
| `DISABLE_ANONYMOUS_ACCESS` | `true` 권장 (익명 접근 차단) |
| `NEXUS_MIN_HEAP` / `NEXUS_MAX_HEAP` | VM 메모리에 맞게 조정 (기본 1200m) |
| `TLS_DOMAIN` | TLS 인증서의 CN/SAN에 들어갈 값. VM의 실제 접속 주소(IP 또는 사내 도메인)로 변경 |
| `TLS_PORT` | 다른 서비스와 충돌 시에만 변경 (기본 443) |

## 2. 이미지 로드

```bash
./scripts/03-load-image.sh
```

`docker images` 목록에 `sonatype/nexus3` 와 `nginx` 가 모두 보이면 정상입니다.

## 3. 기동

```bash
./scripts/05-start.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. `./nexus-data` 생성 및 소유권(`200:200`, Nexus 고정 uid) 설정
2. 자체 서명 TLS 인증서 생성 (`04-generate-tls-cert.sh` 자동 호출, 이미 있으면 재사용)
3. `docker compose up -d` (Nexus + nginx)
4. nginx를 거쳐 `GET /service/rest/v1/status` 가 `200 OK` 를 반환할 때까지 대기 (최초 기동은
   DB 초기화로 1~2분 이상 걸릴 수 있음)

## 4. CLI(REST API) 초기 설정

```bash
./scripts/06-configure.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. 컨테이너 내부 `/nexus-data/admin.password` 에서 최초 생성된 임시 비밀번호를 읽음
   (이미 초기화된 적이 있어 파일이 없으면 현재 비밀번호를 직접 입력받음)
2. `PUT /service/rest/v1/security/users/admin/change-password` 로 `.env` 의 `ADMIN_PASSWORD` 로 변경
3. `DISABLE_ANONYMOUS_ACCESS=true` 인 경우 `PUT /service/rest/v1/security/anonymous` 로 익명 접근 비활성화

모두 nginx를 거친 HTTPS 요청이며, 브라우저의 "최초 설정 마법사" 화면은 무시해도 됩니다 —
REST API는 마법사 완료 여부와 무관하게 처음부터 정상 동작합니다.

## 5. 정상 동작 확인 (CLI)

```bash
# 컨테이너 상태 (nexus, nexus-nginx 둘 다 Up 이어야 함)
docker ps --filter name=nexus

# 상태 확인 (자체 서명 인증서를 신뢰해 검증)
curl --cacert certs/server.crt https://localhost:${TLS_PORT}/service/rest/v1/status

# admin 인증 확인
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> https://localhost/service/rest/v1/repositories

# 익명 접근이 차단되었는지 확인 (401 이 나와야 정상)
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/service/rest/v1/repositories

# Nexus 컨테이너 자체(내부 HTTP, nginx 우회) 헬스체크 - 문제 구간 분리용
docker exec nexus curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/service/rest/v1/status
```

## 6. CLI 전용 운영 (저장소 관리)

UI 없이 REST API로 저장소를 생성/조회/삭제할 수 있습니다.

```bash
# 저장소 목록 조회
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> https://localhost/service/rest/v1/repositories

# 예: Maven proxy 저장소 생성 (내부에서 접근 가능한 미러 URL 필요)
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> -X POST \
  -H 'Content-Type: application/json' \
  https://localhost/service/rest/v1/repositories/maven/proxy \
  -d '{
        "name": "maven-central-proxy",
        "online": true,
        "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
        "proxy": {"remoteUrl": "http://<내부-미러-주소>/", "contentMaxAge": 1440, "metadataMaxAge": 1440},
        "negativeCache": {"enabled": true, "timeToLive": 1440},
        "httpClient": {"blocked": false, "autoBlock": true},
        "maven": {"versionPolicy": "RELEASE", "layoutPolicy": "STRICT"}
      }'

# 예: raw hosted 저장소 생성
curl --cacert certs/server.crt -u admin:<ADMIN_PASSWORD> -X POST \
  -H 'Content-Type: application/json' \
  https://localhost/service/rest/v1/repositories/raw/hosted \
  -d '{"name": "internal-files", "online": true,
       "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "ALLOW"}}'
```

## 7. 운영 명령어

```bash
docker logs -f nexus             # Nexus 로그 확인
docker logs -f nexus-nginx       # nginx(TLS) 로그 확인
docker compose restart           # 재시작
./scripts/07-stop.sh             # 중지 (데이터 보존)
docker compose up -d             # 재기동
```

## 8. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `05-start.sh` 가 대기 중 타임아웃 | `docker logs nexus` 와 `docker logs nexus-nginx` 확인. 대부분 메모리 부족, `./nexus-data` 권한 문제, 또는 `certs/server.crt`/`server.key` 누락 |
| nginx 인증서 관련 오류 | `./scripts/04-generate-tls-cert.sh` 재실행 후 `docker compose restart nginx` |
| `06-configure.sh` 에서 `admin.password` 를 못 찾음 | 이미 한 번 초기화된 상태입니다. 프롬프트에 현재 admin 비밀번호를 입력하면 계속 진행됨 |
| `change-password` 호출 시 401 | 입력한 현재 비밀번호가 틀림. `docker exec nexus cat /nexus-data/admin.password` 로 재확인(파일이 남아있는 경우에만) |
| 컨테이너가 반복 재시작(OOM) | `.env` 의 `NEXUS_MIN_HEAP`/`NEXUS_MAX_HEAP` 를 VM 메모리에 맞게 낮추거나, VM 메모리 증설 |
| 첫 기동이 매우 느림 | 정상입니다. 내부 DB(OrientDB/H2) 초기화에 수 분 소요될 수 있음. `docker logs -f nexus` 로 진행상황 확인 |
| 브라우저에서 "신뢰할 수 없는 인증서" 경고 | 자체 서명 인증서이므로 정상입니다. 매번 경고를 없애려면 `certs/server.crt` 를 각 클라이언트 브라우저/OS의 신뢰 저장소에 직접 등록하거나, 사내 내부 CA로 발급받은 인증서로 교체하세요 (아래 참고) |
| 대용량 아티팩트 업로드 시 413/504 오류 | `nginx/nginx.conf` 의 `client_max_body_size`(기본 1g)/`proxy_read_timeout`(기본 600s) 를 늘리고 `docker compose restart nginx` |

### 내부 CA로 발급받은 인증서로 교체하기

자체 서명 대신 사내 내부 CA가 있다면, 발급받은 인증서 파일을 아래 경로에 그대로 배치하고
nginx만 재시작하면 됩니다 (Nexus 재기동 불필요).

```bash
cp <발급받은 인증서>.crt certs/server.crt
cp <발급받은 개인키>.key certs/server.key
chmod 600 certs/server.key
docker compose restart nginx
```

## 9. 백업 / 복구

- 백업 대상: `./nexus-data/` 전체 (저장소 콘텐츠, 설정, 보안 정보 포함)
- 인증서(`./certs/`)는 재발급이 간단하므로 필수 백업 대상은 아니지만, 사내 CA로 발급받은
  인증서를 쓰는 경우 재발급 절차가 번거로울 수 있어 함께 백업하는 것을 권장합니다.
- 백업 절차:
  ```bash
  ./scripts/07-stop.sh
  tar czf nexus-data-backup-$(date +%F).tar.gz nexus-data/ certs/
  docker compose up -d
  ```
- 복구 절차: 새 VM/디렉터리에 `nexus-data/`(및 필요 시 `certs/`)를 동일 경로로 복원 후
  `docker compose up -d`
- 대용량 운영 시에는 Nexus 자체 백업 기능(Blob Store export) 사용을 권장 (별도 검토 필요)

## 10. 버전 업그레이드

1. 로컬 PC에서 `.env` 의 `NEXUS_IMAGE`(또는 `NGINX_IMAGE`) 태그를 변경 후 `01-pull-and-save-image.sh` 재실행
2. `./scripts/02-transfer-to-vm.sh` 로 새 이미지를 VM에 재전송
3. VM에서 `.env` 의 `NEXUS_IMAGE` 를 동일하게 변경
4. 업그레이드 전 반드시 9절의 백업을 먼저 수행
5. `./scripts/03-load-image.sh` → `docker compose up -d` (Nexus가 기동 시 자동으로 DB 마이그레이션 수행)
6. 마이그레이션에 시간이 걸릴 수 있으므로 `docker logs -f nexus` 로 완료까지 지켜볼 것
