# Nexus 구동 및 초기화 매뉴얼 (VM 관리자용)

이 문서는 `Nexus/` 디렉터리 전체(이미지 tar.gz 포함)가 로컬 PC에서
`scripts/02-transfer-to-vm.sh` 로 **이미 이 VM에 SSH 전송되어 있는 상태**를 전제로, VM에서
수행할 작업만 다룹니다. 로컬 PC에서의 이미지 다운로드/전송 절차는 `README.md` 를 참고하세요.

브라우저 접속 없이 REST API(curl)만으로 끝까지 진행합니다.

---

## 0. 체크리스트

- [ ] `Nexus/` 디렉터리 전체가 이 VM에 존재 (`.env`, `docker-compose.yml`, `images/nexus-image.tar.gz`, `scripts/`)
- [ ] Docker, Docker Compose 플러그인 설치됨 —
      미설치 시 [../Docker/MANUAL.md](../Docker/MANUAL.md) 를 먼저 진행
- [ ] `curl`, `sudo` 사용 가능
- [ ] 열어야 할 포트(기본 8081)에 대한 방화벽/보안그룹 허용
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
| `HTTP_PORT` | 다른 서비스와 충돌 시에만 변경 |

## 2. 이미지 로드

```bash
./scripts/03-load-image.sh
```

`docker images` 목록에 `sonatype/nexus3` 이 보이면 정상입니다.

## 3. 기동

```bash
./scripts/04-start.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. `./nexus-data` 생성 및 소유권(`200:200`, Nexus 고정 uid) 설정
2. `docker compose up -d`
3. `GET /service/rest/v1/status` 가 `200 OK` 를 반환할 때까지 대기 (최초 기동은 DB 초기화로
   1~2분 이상 걸릴 수 있음)

## 4. CLI(REST API) 초기 설정

```bash
./scripts/05-configure.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. 컨테이너 내부 `/nexus-data/admin.password` 에서 최초 생성된 임시 비밀번호를 읽음
   (이미 초기화된 적이 있어 파일이 없으면 현재 비밀번호를 직접 입력받음)
2. `PUT /service/rest/v1/security/users/admin/change-password` 로 `.env` 의 `ADMIN_PASSWORD` 로 변경
3. `DISABLE_ANONYMOUS_ACCESS=true` 인 경우 `PUT /service/rest/v1/security/anonymous` 로 익명 접근 비활성화

브라우저의 "최초 설정 마법사" 화면은 무시해도 됩니다 — REST API는 마법사 완료 여부와
무관하게 처음부터 정상 동작합니다.

## 5. 정상 동작 확인 (CLI)

```bash
# 컨테이너 상태
docker ps --filter name=nexus

# 상태 확인
curl -s http://localhost:8081/service/rest/v1/status

# admin 인증 확인
curl -u admin:<ADMIN_PASSWORD> http://localhost:8081/service/rest/v1/repositories

# 익명 접근이 차단되었는지 확인 (401 이 나와야 정상)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/service/rest/v1/repositories
```

## 6. CLI 전용 운영 (저장소 관리)

UI 없이 REST API로 저장소를 생성/조회/삭제할 수 있습니다.

```bash
# 저장소 목록 조회
curl -u admin:<ADMIN_PASSWORD> http://localhost:8081/service/rest/v1/repositories

# 예: Maven proxy 저장소 생성 (내부에서 접근 가능한 미러 URL 필요)
curl -u admin:<ADMIN_PASSWORD> -X POST \
  -H 'Content-Type: application/json' \
  http://localhost:8081/service/rest/v1/repositories/maven/proxy \
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
curl -u admin:<ADMIN_PASSWORD> -X POST \
  -H 'Content-Type: application/json' \
  http://localhost:8081/service/rest/v1/repositories/raw/hosted \
  -d '{"name": "internal-files", "online": true,
       "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "ALLOW"}}'
```

## 7. 운영 명령어

```bash
docker logs -f nexus            # 로그 확인
docker compose restart          # 재시작
./scripts/06-stop.sh            # 중지 (데이터 보존)
docker compose up -d            # 재기동
```

## 8. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `04-start.sh` 가 대기 중 타임아웃 | `docker logs nexus` 확인. 대부분 메모리 부족 또는 `./nexus-data` 권한 문제 |
| `05-configure.sh` 에서 `admin.password` 를 못 찾음 | 이미 한 번 초기화된 상태입니다. 프롬프트에 현재 admin 비밀번호를 입력하면 계속 진행됨 |
| `change-password` 호출 시 401 | 입력한 현재 비밀번호가 틀림. `docker exec nexus cat /nexus-data/admin.password` 로 재확인(파일이 남아있는 경우에만) |
| 컨테이너가 반복 재시작(OOM) | `.env` 의 `NEXUS_MIN_HEAP`/`NEXUS_MAX_HEAP` 를 VM 메모리에 맞게 낮추거나, VM 메모리 증설 |
| 첫 기동이 매우 느림 | 정상입니다. 내부 DB(OrientDB/H2) 초기화에 수 분 소요될 수 있음. `docker logs -f nexus` 로 진행상황 확인 |

## 9. 백업 / 복구

- 백업 대상: `./nexus-data/` 전체 (저장소 콘텐츠, 설정, 보안 정보 포함)
- 백업 절차:
  ```bash
  ./scripts/06-stop.sh
  tar czf nexus-data-backup-$(date +%F).tar.gz nexus-data/
  docker compose up -d
  ```
- 복구 절차: 새 VM/디렉터리에 `nexus-data/` 를 동일 경로로 복원 후 `docker compose up -d`
- 대용량 운영 시에는 Nexus 자체 백업 기능(Blob Store export) 사용을 권장 (별도 검토 필요)

## 10. 버전 업그레이드

1. 로컬 PC에서 `.env` 의 `NEXUS_IMAGE` 태그를 변경 후 `01-pull-and-save-image.sh` 재실행
2. `./scripts/02-transfer-to-vm.sh` 로 새 이미지를 VM에 재전송
3. VM에서 `.env` 의 `NEXUS_IMAGE` 를 동일하게 변경
4. 업그레이드 전 반드시 9절의 백업을 먼저 수행
5. `./scripts/03-load-image.sh` → `docker compose up -d` (Nexus가 기동 시 자동으로 DB 마이그레이션 수행)
6. 마이그레이션에 시간이 걸릴 수 있으므로 `docker logs -f nexus` 로 완료까지 지켜볼 것
