# Nexus 관리자 가이드

운영 중인 Nexus 관리. 웹 UI 없이 **REST API(curl)** 로 처리합니다.

접속: `ssh acme-nexus` (운영자 pem, bastion 경유) → `cd /home/ubuntu/Nexus`
API 는 VM 로컬에서 `https://localhost/` (nginx TLS) 로 호출하며 `--cacert certs/server.crt` 로 검증합니다.
아래 `<ADMIN_PASSWORD>` 는 `.env` 의 `ADMIN_PASSWORD`.

```bash
C='--cacert certs/server.crt'; AUTH='admin:<ADMIN_PASSWORD>'; B=https://localhost
```

## 1. CI 서비스 계정 발급 (핵심)

Nexus 는 CICD 서버만 사용합니다. **admin 을 CI 에 주지 말고**, 저장소 접근만 가진 전용 계정을 만듭니다.

```bash
# (1) 역할 생성 — 저장소 view(read/add/edit) 권한. 필요 저장소로 좁히려면 privilege 를 개별 지정
curl $C -u "$AUTH" -X POST -H 'Content-Type: application/json' $B/service/rest/v1/security/roles -d '{
  "id":"ci-deployer","name":"ci-deployer","description":"CI publish/consume",
  "privileges":["nx-repository-view-*-*-*"],"roles":[]}'

# (2) 사용자 생성 — 이 계정을 CICD 서버가 사용
curl $C -u "$AUTH" -X POST -H 'Content-Type: application/json' $B/service/rest/v1/security/users -d '{
  "userId":"ci","firstName":"CI","lastName":"Service","emailAddress":"ci@example.com",
  "password":"<CI_PASSWORD>","status":"active","roles":["ci-deployer"]}'
```
비번 변경: `PUT $B/service/rest/v1/security/users/ci/change-password` (Content-Type: text/plain, body=새 비번).
삭제: `DELETE $B/service/rest/v1/security/users/ci`.

### 계정·역할 조회

```bash
# 전체 사용자 목록 (userId·이름·이메일·status·roles 반환)
curl $C -u "$AUTH" $B/service/rest/v1/security/users
# 특정 사용자만 필터 (source=default = Nexus 내장 계정)
curl $C -u "$AUTH" "$B/service/rest/v1/security/users?userId=ci&source=default"
# 역할 목록 / 특정 역할 상세(부여된 privilege 확인)
curl $C -u "$AUTH" $B/service/rest/v1/security/roles
curl $C -u "$AUTH" $B/service/rest/v1/security/roles/ci-deployer
# 권한(privilege) 목록 — 역할에 넣을 privilege id 찾을 때
curl $C -u "$AUTH" $B/service/rest/v1/security/privileges
```
> 응답에 userId·이름·이메일·status(active)·roles 는 있지만 **비밀번호 필드는 없습니다**(아래 참고).

### 비밀번호 확인 / 검증

**비밀번호는 조회할 수 없습니다** — Nexus 는 단방향 해시로만 저장하므로 API/DB 어디서도 평문을 볼 수
없습니다. 가능한 것은 (a) *후보 비번이 맞는지 검증*, (b) *분실 시 재설정* 뿐입니다.

```bash
# (a) 후보 비번이 맞는지 검증: 200=맞음 / 401=틀림 (무해한 authed 엔드포인트 사용)
curl -s -o /dev/null -w '%{http_code}\n' $C -u "ci:<확인할 비번>" $B/service/rest/v1/status/writable
# (b) 분실 시 admin 이 재설정 (위 change-password). 최초 admin 임시비번은 최초 1회에 한해:
docker exec nexus cat /nexus-data/admin.password    # 비번 변경 후엔 이 파일이 삭제되어 없음
```

## 2. 저장소 관리 (hosted 중심 — 폐쇄망)

인터넷 프록시가 안 되므로 **hosted** 저장소에 CI 가 직접 올립니다. (proxy 는 접근 가능한 내부 미러가 있을 때만)

```bash
curl $C -u "$AUTH" $B/service/rest/v1/repositories                    # 목록

# raw hosted (임의 파일)
curl $C -u "$AUTH" -X POST -H 'Content-Type: application/json' $B/service/rest/v1/repositories/raw/hosted -d '{
  "name":"raw-hosted","online":true,
  "storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW"}}'

# maven hosted (릴리스) — 기본 제공 maven-releases/maven-snapshots 도 사용 가능
curl $C -u "$AUTH" -X POST -H 'Content-Type: application/json' $B/service/rest/v1/repositories/maven/hosted -d '{
  "name":"maven-internal","online":true,
  "storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW_ONCE"},
  "maven":{"versionPolicy":"RELEASE","layoutPolicy":"STRICT"}}'

# 삭제 / 컴포넌트 조회
curl $C -u "$AUTH" -X DELETE $B/service/rest/v1/repositories/raw-hosted
curl $C -u "$AUTH" "$B/service/rest/v1/components?repository=raw-hosted"
```

## 3. bastion 터널로 로컬→Nexus 업로드 (폐쇄망 패키지 반입)

bastion→Nexus VM 은 **포트 22만** 열려 있어 로컬에서 Nexus 443 에 직접 못 붙습니다. **22 위 SSH
포트포워딩 터널**로 접속합니다(터널 목적지가 Nexus VM 의 localhost:443 이라 SG 와 무관).

```bash
# (1) 인증서 1회 복사 + 터널 (로컬 18443 → bastion → nexus:443)
scp acme-nexus:/home/ubuntu/Nexus/certs/server.crt ~/nexus.crt
ssh -f -N -L 18443:localhost:443 acme-nexus        # 작업 후: 그 ssh 프로세스를 PID로 종료
B=https://localhost:18443 ; C="--cacert $HOME/nexus.crt"

# (2) raw 파일 업로드/다운로드 (PUT)
curl $C -u ci:<CI_PW> --upload-file mypkg-1.0.0.tgz $B/repository/raw-hosted/demo/mypkg-1.0.0.tgz
curl $C -u ci:<CI_PW> -O                            $B/repository/raw-hosted/demo/mypkg-1.0.0.tgz
```

### npm 의존성 seed (npm-hosted 채우기)

npmjs.org proxy 가 불가하므로, 앱 의존성(전이 포함)을 **인터넷 되는 PC 에서 받아 npm-hosted 에 publish**
해 둡니다. node/npm 이 로컬에 없으면 CI 에이전트 이미지(node 내장)를 `--network host` 로 사용
(그래야 컨테이너의 `localhost:18443` 이 호스트 터널을 가리킴, **root=비 `-u` 로 실행**해야 npm 정상 동작).

```bash
# 발행용 .npmrc — _auth = base64("<user>:<pw>")
printf '//localhost:18443/repository/npm-hosted/:_auth=%s\nregistry=https://localhost:18443/repository/npm-hosted/\nalways-auth=true\ncafile=/nexus.crt\n' \
  "$(printf '%s' 'admin:<ADMIN_PASSWORD>' | base64 -w0)" > pub.npmrc

npm install                                          # 앱에서 lockfile 생성(인터넷)
grep -o '"resolved": "https[^"]*"' package-lock.json | sed 's/.*"resolved": "//;s/"$//' | sort -u > urls.txt
mkdir -p tgz; while read -r u; do curl -fsSL "$u" -o "tgz/$(basename "$u")"; done < urls.txt
# publish 는 반드시 순차로 (아래 주의)
for f in tgz/*.tgz; do npm publish "$f" --userconfig pub.npmrc || true; done
```
> ⚠️ **병렬 publish 금지**: bastion 단일 SSH 터널(`-L`)은 동시 접속이 몰리면 급격히 느려집니다
> (`xargs -P`/여러 컨테이너 동시 실행 X). **순차로 하나씩** 올리세요. 패키지가 많아 순차도 오래 걸리면,
> 터널 대신 **Nexus VM 에서 직접**(localhost:443, loopback) 올리는 것이 가장 빠르고 안정적입니다
> (tarball 을 VM 으로 scp 후 VM 에서 publish — 터널 병목 없음).

**검증(소비 계정으로 Nexus 만으로 재설치되는지)** — lockfile 의 npmjs URL 을 안 타도록 지우고 npm-group 에서:
```bash
printf 'registry=https://localhost:18443/repository/npm-group/\n//localhost:18443/repository/npm-group/:_auth=%s\nalways-auth=true\ncafile=/nexus.crt\n' \
  "$(printf '%s' 'ci:<CI_PW>' | base64 -w0)" > ci.npmrc
rm -rf node_modules package-lock.json && npm install --userconfig ci.npmrc   # Nexus 에서만 설치되면 seed 완료
```

## 4. 운영

```bash
docker ps --filter name=nexus                    # nexus, nexus-nginx 둘 다 Up
docker logs -f nexus       /    docker logs -f nexus-nginx
docker compose restart
./scripts/07-stop.sh        # 중지(데이터 보존)  /  재기동: docker compose up -d
```

**상태 점검**:
```bash
curl -s -o /dev/null -w '%{http_code}\n' $C $B/service/rest/v1/status                    # 200
curl -s -o /dev/null -w '%{http_code}\n' $C $B/repository/raw-hosted/                     # 익명이면 401(정상)
docker exec nexus curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/service/rest/v1/status  # 구간 분리
```

**백업/복구** (대상: `./nexus-data/` = 저장소 콘텐츠·설정·보안 전부):
```bash
./scripts/07-stop.sh
tar czf nexus-data-$(date +%F).tar.gz nexus-data/ certs/
docker compose up -d
# 복구: 새 위치에 nexus-data/(및 certs/) 복원 후 docker compose up -d
```

## 5. 인증서 · 대용량

- 자체 서명 교체(사내 CA): `certs/server.crt`,`certs/server.key` 덮어쓰고 `docker compose restart nginx`.
- 대용량 아티팩트로 413/504 시: `nginx/nginx.conf` 의 `client_max_body_size`(기본 1g)/`proxy_read_timeout`(600s) 상향 후 nginx 재시작.

## 6. 메모

- 익명 접근은 비활성(`DISABLE_ANONYMOUS_ACCESS=true`). `GET /service/rest/v1/repositories` 는 익명에게
  401 대신 **빈 목록 `[ ]`** 를 주는 것이 정상(실 콘텐츠 `/repository/...` 는 401 차단).
- CICD 서버가 접근하려면 Nexus SG 에 `source=CICD VM → TCP 443` 규칙이 필요합니다 → [USER.md](USER.md) 참고.
