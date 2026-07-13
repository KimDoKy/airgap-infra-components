# Jenkins 구동 및 초기화 매뉴얼 (VM 관리자용)

이 문서는 `Jenkins/` 디렉터리 전체(이미지 tar.gz 포함)가 로컬 PC에서
`scripts/02-transfer-to-vm.sh` 로 **이미 이 VM에 SSH 전송되어 있는 상태**를 전제로, VM에서
수행할 작업만 다룹니다. 로컬 PC에서의 이미지 다운로드/전송 절차는 `README.md` 를 참고하세요.

브라우저 접속 없이 CLI만으로 끝까지 진행합니다 (설치 마법사 자체가 비활성화되어 있음).

---

## 0. 체크리스트

- [ ] `Jenkins/` 디렉터리 전체가 이 VM에 존재 (`.env`, `docker-compose.yml`, `config/`, `images/jenkins-image.tar.gz`, `scripts/`)
- [ ] Docker, Docker Compose 플러그인 설치됨 —
      미설치 시 [../Docker/MANUAL.md](../Docker/MANUAL.md) 를 먼저 진행
- [ ] `sudo` 권한 있음
- [ ] 열어야 할 포트(기본 8080, 50000)에 대한 방화벽/보안그룹 허용
- [ ] 메모리 최소 2GB 이상 여유 (기본 JVM 힙 미설정 = 컨테이너 메모리 기준 자동 산정)

## 1. 설정값 확인 (.env)

```bash
cd Jenkins
vi .env
```

| 항목 | 설명 |
|---|---|
| `JENKINS_ADMIN_PASSWORD` | 초기 관리자 비밀번호. 기본값(`ChangeMe123!`) 그대로 두지 말 것 |
| `JENKINS_ADMIN_ID` | 초기 관리자 계정 ID (기본 `admin`) |
| `HTTP_PORT` / `AGENT_PORT` | 다른 서비스와 충돌 시에만 변경 |

## 2. 이미지 로드

```bash
./scripts/03-load-image.sh
```

`docker images` 목록에 `jenkins/jenkins` 이 보이면 정상입니다.

## 3. 기동 + CLI 초기화

```bash
./scripts/04-start.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. `config/init.groovy.d/basic-security.groovy` 를 `./jenkins_home/init.groovy.d/` 로 복사
2. `./jenkins_home` 소유권(`JENKINS_UID:JENKINS_GID`) 설정
3. `docker compose up -d` — `JAVA_OPTS` 에 `-Djenkins.install.runSetupWizard=false` 가 전달되어
   Unlock 화면, 플러그인 설치 화면이 아예 나타나지 않음
4. 컨테이너 기동과 동시에 `init.groovy.d` 스크립트가 실행되어 `JENKINS_ADMIN_ID` /
   `JENKINS_ADMIN_PASSWORD` 로 관리자 계정을 **자동 생성**
5. `/login` 페이지가 응답할 때까지 대기 후 완료 메시지 출력

## 4. 정상 동작 확인 (CLI)

```bash
# 컨테이너 상태
docker ps --filter name=jenkins

# 로그인 페이지 응답 확인 (200 또는 403이면 정상 기동)
docker exec jenkins curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/login

# Jenkins CLI 로 인증 확인
docker exec jenkins curl -s http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar
docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ \
  -auth <JENKINS_ADMIN_ID>:<JENKINS_ADMIN_PASSWORD> who-am-i
```

`who-am-i` 결과에 관리자 계정 ID가 출력되면 정상입니다.

## 5. CLI 전용 운영 (Job/설정 관리)

UI 없이 Jenkins CLI 또는 REST API로 대부분의 관리 작업이 가능합니다.

```bash
# 컨테이너 안에 jenkins-cli.jar 준비 (최초 1회)
docker exec jenkins curl -s http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar
CLI="docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth admin:<PASSWORD>"

# 설치된 플러그인 목록
$CLI list-plugins

# Job 목록
$CLI list-jobs

# Job 생성 (XML 설정 파일을 표준입력으로 전달)
docker exec -i jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ \
  -auth admin:<PASSWORD> create-job my-job < job-config.xml

# 안전 종료 / 재시작
$CLI safe-restart
```

REST API 예시:

```bash
curl -u admin:<PASSWORD> http://localhost:8080/api/json?pretty=true
```

## 6. 운영 명령어

```bash
docker logs -f jenkins         # 로그 확인
docker compose restart         # 재시작
./scripts/05-stop.sh           # 중지 (데이터 보존)
docker compose up -d           # 재기동
```

## 7. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `/login` 응답 없음 (타임아웃) | `docker logs jenkins` 확인. `./jenkins_home` 권한 문제일 수 있음 — `sudo chown -R 1000:1000 jenkins_home` |
| 관리자 계정으로 로그인/인증 실패 | `init.groovy.d` 가 이미 한 번 실행되어 이후 `.env` 비밀번호 변경이 반영되지 않은 경우. 아래 "관리자 비밀번호 재설정" 절차 참고 |
| 설치 마법사(Unlock Jenkins) 화면이 뜸 | `JAVA_OPTS` 가 컨테이너에 제대로 전달되지 않음. `docker exec jenkins env \| grep JAVA_OPTS` 로 확인 |
| 메모리 부족으로 컨테이너 재시작 반복 | VM 메모리 확인 후 `docker-compose.yml` 의 `JAVA_OPTS` 에 `-Xmx1g` 등 힙 상한 명시적으로 추가 |
| 플러그인 설치가 안 됨 | 폐쇄망 특성상 정상입니다. 8절 참고 (오프라인 플러그인 설치는 별도 절차) |

### 관리자 비밀번호 재설정 (UI 없이)

`init.groovy.d` 스크립트는 보안 realm이 이미 설정되어 있으면 재실행되지 않습니다.
비밀번호를 잊었거나 변경해야 하면 아래처럼 임시 groovy 스크립트로 재설정합니다.

```bash
docker exec jenkins bash -c 'cat > /var/jenkins_home/init.groovy.d/reset-password.groovy' <<'EOF'
import jenkins.model.*
import hudson.security.*
def instance = Jenkins.get()
def realm = (HudsonPrivateSecurityRealm) instance.getSecurityRealm()
realm.createAccount("admin", "NewPassword123!")
instance.save()
EOF

docker compose restart

# 반영 확인 후 반드시 스크립트 제거 (매 재시작마다 비밀번호가 초기화되는 것을 방지)
docker exec jenkins rm /var/jenkins_home/init.groovy.d/reset-password.groovy
```

## 8. 참고: 오프라인 플러그인 설치

1. 인터넷 가능 PC에서 https://updates.jenkins.io 또는 사내 미러에서 필요한 `.hpi`/`.jpi` 파일 다운로드
2. 파일들을 VM으로 전송
3. `docker cp <plugin>.hpi jenkins:/var/jenkins_home/plugins/`
4. `docker compose restart`
5. `$CLI list-plugins` 로 설치 확인

## 9. 백업 / 복구

- 백업 대상: `./jenkins_home/` 전체 (Job 설정, 빌드 기록, 플러그인, 시크릿 포함)
- 백업 절차:
  ```bash
  ./scripts/05-stop.sh
  tar czf jenkins-home-backup-$(date +%F).tar.gz jenkins_home/
  docker compose up -d
  ```
- 복구 절차: 새 VM/디렉터리에 `jenkins_home/` 을 동일 경로로 복원 후 `docker compose up -d`

## 10. 버전 업그레이드

1. 로컬 PC에서 `.env` 의 `JENKINS_IMAGE` 태그를 변경 후 `01-pull-and-save-image.sh` 재실행
2. `./scripts/02-transfer-to-vm.sh` 로 새 이미지를 VM에 재전송
3. VM에서 `.env` 의 `JENKINS_IMAGE` 를 동일하게 변경
4. 업그레이드 전 반드시 9절의 백업을 먼저 수행
5. `./scripts/03-load-image.sh` → `docker compose up -d`
6. 플러그인 호환성 문제가 발생할 수 있으므로 업그레이드 후 로그(`docker logs jenkins`)를 반드시 확인
