# Jenkins - 폐쇄망 구축 매뉴얼

이 디렉터리는 **다른 VM(GitServer, Nexus)과 완전히 독립적으로** 실행됩니다.
이 디렉터리 전체를 Jenkins용 VM으로 SSH를 통해 전송하고, 아래 순서대로 실행하세요.

VM은 인터넷/사설망 이미지 저장소에 접근할 수 없다고 가정하므로, 컨테이너 이미지는 반드시
**로컬 PC에서 미리 받아 SSH로 VM에 업로드**합니다. 브라우저(UI)도 사용할 수 없다고 가정하므로,
최초 설치 마법사(Unlock Jenkins, 플러그인 설치, 관리자 계정 생성)를 **완전히 비활성화**하고
`init.groovy.d` 스크립트로 CLI(무인) 초기화합니다.

## 사전 준비물

- 로컬(인터넷 가능) PC: Docker 설치, `ssh`/`scp` (가능하면 `rsync`도)
- 대상 VM(폐쇄망): Docker / Docker Compose 플러그인 설치, `sudo` 권한
  (미설치 상태라면 [../Docker/README.md](../Docker/README.md) 를 먼저 진행하세요)
- 로컬 PC → VM SSH 접근 가능 (키 기반 인증 권장: `ssh-copy-id <user>@<vm-ip>`)

## 디렉터리 구조

```
Jenkins/
├── .env                       # 설정값 (포트, 버전, 관리자 계정, SSH 대상 등)
├── docker-compose.yml
├── config/
│   └── init.groovy.d/
│       └── basic-security.groovy   # 무인 관리자 계정 생성 스크립트
├── images/                    # 이미지 tar.gz 저장 위치
├── jenkins_home/               # Jenkins 데이터 (최초 실행 시 자동 생성)
└── scripts/
    ├── 01-pull-and-save-image.sh  # [로컬] 이미지 다운로드+저장
    ├── 02-transfer-to-vm.sh       # [로컬] SSH로 VM에 전체 디렉터리 업로드
    ├── 03-load-image.sh           # [VM] 이미지 로드
    ├── 04-start.sh                # [VM] 기동 + CLI 초기화
    └── 05-stop.sh                 # [VM] 중지
```

## 실행 순서

### 1단계. 로컬 PC에서 이미지 다운로드 (인터넷 가능 환경)

```bash
cd Jenkins
./scripts/01-pull-and-save-image.sh
```

### 2단계. 배포 전 설정값 확인 (.env)

- `VM_SSH_HOST`, `VM_SSH_USER`, `VM_SSH_PORT`, `VM_REMOTE_DIR` : SSH 전송 대상 VM 정보
- `JENKINS_ADMIN_PASSWORD` : 반드시 변경

### 3단계. SSH로 VM에 전송 (로컬 PC에서 실행)

```bash
./scripts/02-transfer-to-vm.sh
```

SSH 접속을 확인한 뒤, `rsync`(있으면) 또는 `tar+scp`(없으면)로 `Jenkins/` 디렉터리 전체
(스크립트, `.env`, `config/`, `images/jenkins-image.tar.gz` 포함)를 `.env` 의 `VM_REMOTE_DIR` 경로로
업로드합니다.

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

1. `config/init.groovy.d/basic-security.groovy` 를 `./jenkins_home/init.groovy.d/` 로 복사
   (Jenkins가 기동 시 자동 실행하는 무인 초기화 스크립트)
2. `./jenkins_home` 소유권 설정
3. `docker compose up -d` (JAVA_OPTS 로 `runSetupWizard=false` 전달 → 설치 마법사 자체가 뜨지 않음)
4. Jenkins가 뜨면서 `basic-security.groovy` 가 `JENKINS_ADMIN_ID` / `JENKINS_ADMIN_PASSWORD` 로
   관리자 계정을 **자동 생성** — 브라우저 접속 없이도 계정이 이미 완성된 상태

### 6단계. 확인 (CLI)

```bash
# 로그인 페이지 응답 확인
docker exec jenkins curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/login

# Jenkins CLI 로 인증 확인
docker exec jenkins curl -s http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar
docker exec jenkins java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ \
  -auth <JENKINS_ADMIN_ID>:<JENKINS_ADMIN_PASSWORD> who-am-i
```

이후 Job 생성/설정도 `jenkins-cli.jar` 또는 REST API(`curl -u admin:password ...`)로 UI 없이 진행할 수 있습니다.

VM에서의 상세 운영/트러블슈팅은 [MANUAL.md](MANUAL.md) 를 참고하세요.

## 운영 명령어 (VM)

```bash
# 로그 확인
docker logs -f jenkins

# 재시작
docker compose restart

# 중지 (데이터 보존)
./scripts/05-stop.sh

# 데이터 백업 대상
./jenkins_home/
```

## 참고 (다음 단계 - 이번 범위 밖)

- **플러그인 설치**: 폐쇄망이라 Update Center 접속이 불가능합니다. 필요한 플러그인은
  인터넷 가능 환경에서 `.hpi`/`.jpi` 파일을 내려받아 `jenkins_home/plugins/` 에 복사한 뒤
  재기동하는 방식(오프라인 플러그인 설치)이 필요하며, 이는 별도 작업으로 진행하세요.
- Nexus를 사내 Maven/npm/Docker 프록시 저장소로 구성하면 Jenkins 빌드 시 외부 의존성을
  Nexus 경유로 받아올 수 있습니다 (Nexus 매뉴얼 참고).
