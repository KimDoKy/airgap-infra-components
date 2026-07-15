# check/ - 실전형 배포 검증 스크립트

`GitServer/`, `Jenkins/`, `Nexus/` 각각의 **실제 배포 스크립트(01~06/07)를 수정 없이 그대로** 가짜
VM에 대해 실행해, 문서에 적힌 절차가 실제로 끝까지 동작하는지 end-to-end로 검증합니다.
"진짜처럼" 검증하기 위해 더미 데이터나 mock 응답을 쓰지 않고, 실제 컨테이너 이미지를 내려받아
실제로 기동하고, 실제 REST API/CLI 호출로 관리자 계정 생성·저장소 생성·Job 생성 같은 기능까지
확인합니다.

```
check/
├── lib/
│   └── mock-vm.sh          # 가짜 VM 기동/종료 공용 함수
├── gitserver-check.sh       # GitServer(Gitea + nginx) 검증
├── jenkins-check.sh         # Jenkins(+ nginx) 검증
└── nexus-check.sh           # Nexus(+ nginx) 검증
```

## 사용법

```bash
cd check
./gitserver-check.sh
./jenkins-check.sh
./nexus-check.sh
```

각 스크립트는 완전히 독립적으로 실행되며, 끝나면 자동으로 정리(컨테이너/네트워크/임시 파일 삭제)
됩니다. 마지막 줄에 `PASS` 또는 `FAIL` 이 출력되고, 종료 코드도 그에 맞게 0/1 입니다.

**한 번에 하나씩 실행하세요.** 가짜 VM이 호스트 네트워크를 공유하는 방식이라(아래 설명 참고)
동시에 두 개 이상 실행하면 SSH 포트(2222)가 충돌합니다.

## 사전 준비물

- Docker(로컬 PC), `ssh-keygen`/`ssh`/`scp`, `curl`, `openssl`
- 인터넷 연결 (실제 컨테이너 이미지 및 가짜 VM용 베이스 이미지를 내려받습니다 - 각 서비스 이미지가
  100MB~600MB 정도라 최초 실행 시 시간이 걸릴 수 있습니다. 이후에는 로컬 캐시를 사용해 빠릅니다)

## 원본 파일은 건드리지 않습니다

각 체크 스크립트는 `GitServer/`(등) 디렉터리를 `check/.work/<service>/` 아래로 복사한 뒤,
그 사본의 `.env`만 검증 전용 값(다른 포트, 테스트용 비밀번호 등)으로 바꿔서 사용합니다.
원본 `.env`, `certs/`, `data/`(`jenkins_home/`, `nexus-data/`) 는 절대 건드리지 않고,
스크립트 종료 시 `.work/` 전체가 삭제됩니다.

## "가짜 VM"은 어떻게 동작하나

`lib/mock-vm.sh` 는 SSH 데몬이 떠 있는 컨테이너(`linuxserver/openssh-server`)를 하나 띄우고,
그 컨테이너에 **호스트의 docker.sock을 그대로 공유**시킵니다(Docker-outside-of-Docker). 그 안에
SSH로 들어가서 실제 `02-transfer-to-vm.sh` → `03-load-image.sh` → `05-start.sh` 등을 그대로
실행하면, 그 안에서 실행되는 `docker compose up -d` 는 실제로는 이 가짜 VM "안"이 아니라
**호스트 도커 데몬에 형제 컨테이너로** gitea/jenkins/nexus/nginx를 띄웁니다.

몇 가지 신경 쓴 부분:

- **`--network host` 로 기동**: 형제 컨테이너들이 게시하는 포트(443 등)를 가짜 VM 안에서
  "localhost"로 접근했을 때도 똑같이 보여야, 각 서비스의 `05-start.sh`가 자체적으로 수행하는
  "localhost:포트" 헬스체크가 실제 VM에서와 동일하게 동작합니다. 별도 네트워크 네임스페이스를
  쓰면 이 헬스체크가 항상 실패합니다 (실제로 겪은 문제입니다, 아래 참고).
- **동일 경로 바인드 마운트**: 가짜 VM의 작업 디렉터리(`check/.work/...`)를 호스트와 **완전히
  동일한 절대경로**로 그 안에도 마운트합니다. `docker compose` 가 `./data` 같은 상대경로를
  절대경로로 바꿔 호스트 데몬에 넘길 때, 그 경로가 호스트에도 실제로 존재해야 바인드 마운트가
  정상 동작하기 때문입니다.
- **docker.sock 권한**: macOS(Docker Desktop/OrbStack 등)는 데몬이 리눅스 VM 안에서 돌기 때문에,
  호스트 셸에서 보이는 소켓 소유권과 컨테이너 "안"에서 보이는 소유권이 다릅니다. 컨테이너를 통해
  실제 소유 GID를 감지해서 가짜 VM 사용자를 그 그룹에 넣습니다.
- **SSH 키/known_hosts 자동 신뢰**: `02-transfer-to-vm.sh` 등은 우리가 만든 테스트 키를 알지
  못하므로, 진짜 `ssh`/`scp`보다 먼저 찾히도록 PATH 앞에 래퍼를 깔아 `-i`/`-o` 옵션을 주입합니다
  (스크립트 자체는 수정하지 않습니다).

## 이 작업으로 실제로 찾아서 고친 버그

이 체크 스크립트들을 실제로 실행하며 검증하는 과정에서, 기존에는 발견되지 않았던 실제 배포
스크립트의 버그를 몇 가지 찾아 수정했습니다 (더미 데이터로는 절대 드러나지 않았을 문제들입니다).

- `GitServer/scripts/05-start.sh` : `docker exec gitea gitea admin user ...` 가 기본적으로
  root로 실행되는데, Gitea는 root 실행을 명시적으로 거부합니다. `-u <USER_UID>` 를 지정하도록
  수정 (README/MANUAL의 해당 명령어도 함께 수정).
- `GitServer/scripts/05-start.sh` : Gitea 준비 상태를 `gitea admin user list` (DB 접근만 확인)
  로 판단하고 있어, 실제 웹 서버(:3000)가 리스닝을 시작하기 전에 "준비 완료"로 오판할 수 있는
  경합 상태가 있었습니다. 실제 HTTP 헬스체크(`/api/healthz`)로 교체.
- `*/scripts/02-transfer-to-vm.sh` (Docker/GitServer/Jenkins/Nexus 공통) : rsync 사용 가능
  여부를 **로컬에서만** 확인하고 있어, 로컬에는 rsync가 있지만 VM(특히 최소 설치된 폐쇄망 VM)에는
  없는 흔한 상황에서 전송이 실패했습니다. VM 쪽도 함께 확인해 자동으로 tar+scp로 폴백하도록 수정.

## 알려진 참고 사항 (버그 아님)

- Apple Silicon(arm64) 로컬 PC에서 Nexus 체크를 돌리면 `sonatype/nexus3` 이미지가 arm64를
  지원하지 않아 `The requested image's platform ... does not match ...` 경고가 뜹니다. 에뮬레이션으로
  정상 동작하지만 느릴 수 있습니다 (실제 폐쇄망 VM이 x86_64라면 해당 없음).
- Nexus의 `GET /service/rest/v1/repositories` 는 익명 접근을 막아도(`DISABLE_ANONYMOUS_ACCESS=true`)
  항상 공개로 응답합니다 (저장소 이름 목록 자체는 민감 정보로 취급되지 않는 Nexus의 기본 동작).
  실제 익명 차단 여부는 `/service/rest/v1/security/users` 같은 엔드포인트로 확인해야 의미가 있습니다.
