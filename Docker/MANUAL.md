# Docker 설치 매뉴얼 (VM 관리자용)

이 문서는 `Docker/` 디렉터리 전체(다운로드된 바이너리 포함)가 로컬 PC에서
`scripts/02-transfer-to-vm.sh` 로 **이미 이 VM에 SSH 전송되어 있는 상태**를 전제로, VM에서
수행할 작업만 다룹니다. 로컬 PC에서의 바이너리 다운로드/전송 절차는 `README.md` 를 참고하세요.

GitServer, Jenkins, Nexus 세 VM 모두에서 이 절차를 각각 진행해야 합니다.

---

## 0. 체크리스트

- [ ] `Docker/` 디렉터리 전체가 이 VM에 존재 (`.env`, `config/docker.service`,
      `packages/docker-<version>.tgz`, `packages/docker-compose`, `scripts/`)
- [ ] systemd 기반 Linux (`systemctl --version` 확인)
- [ ] `sudo` 권한 있음
- [ ] VM 아키텍처가 다운로드한 바이너리와 일치 (`uname -m`)
- [ ] 이 VM에 Docker가 아직 설치되어 있지 않음 (이미 설치된 경우 3절 설치 스크립트가 경고 후
      확인을 요청함)

## 1. 아키텍처 확인

```bash
uname -m
```

모든 VM 은 `x86_64`(Intel) 로 확인됐으므로 `.env` 의 기본값 `ARCH=x86_64` 를 그대로 사용합니다.
(만약 다른 아키텍처 VM을 쓰게 되면 로컬 PC에서 `.env` 의 `ARCH` 를 그 값으로 바꿔 바이너리를 다시
받아 전송해야 합니다 — VM에서 값만 바꿔서는 안 됩니다. 실제 바이너리 파일 자체가 아키텍처별로 다릅니다.)

## 2. 설치

```bash
cd Docker
./scripts/03-install.sh
```

내부적으로 다음이 순서대로 실행됩니다.

1. `packages/docker-<version>.tgz` 압축 해제
2. `/usr/bin` 에 `docker`, `dockerd`, `containerd`, `runc` 등 바이너리 복사 (sudo)
3. `docker` 그룹 생성
4. `packages/docker-compose` 를 `/usr/local/lib/docker/cli-plugins/docker-compose` 로 설치
5. `config/docker.service` 를 `/etc/systemd/system/docker.service` 로 등록,
   `systemctl daemon-reload && systemctl enable --now docker`
6. (`ADD_USER_TO_DOCKER_GROUP=true`) 현재 SSH 사용자를 `docker` 그룹에 추가

## 3. 재로그인

`docker` 그룹 추가는 **새 로그인 세션부터** 적용됩니다. SSH 세션을 끊고 다시 접속하세요.

```bash
exit
ssh -p <port> <user>@<host>
```

(재접속이 번거로우면 `newgrp docker` 로 현재 셸에서만 즉시 적용할 수도 있습니다.)

## 4. 검증

```bash
cd Docker
./scripts/04-verify.sh
```

확인 항목:

- `docker version` — Client/Server 버전 모두 출력되어야 함
- `docker compose version` — Compose 플러그인 버전 출력
- `systemctl is-active docker` → `active`
- `systemctl is-enabled docker` → `enabled` (재부팅 시 자동 기동)
- `docker info` — 에러 없이 데몬 정보 출력

> 폐쇄망 특성상 `docker run hello-world` 같은 이미지 pull 기반 테스트는 **실패하는 것이
> 정상**입니다 (레지스트리 접근 불가). 실제 동작 검증은 GitServer/Jenkins/Nexus 의
> `load-image.sh` 로 로컬 이미지를 로드한 뒤 진행하세요.

## 5. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `docker version` 실행 시 `permission denied` | 재로그인을 하지 않았거나 `ADD_USER_TO_DOCKER_GROUP=false` 였음. `newgrp docker` 또는 재접속, 급하면 `sudo docker version` |
| `systemctl is-active docker` 가 `failed` | `sudo systemctl status docker -l --no-pager` 로 로그 확인. 대부분 바이너리 손상(재다운로드) 또는 `/etc/systemd/system/docker.service` 오타 |
| `03-install.sh` 에서 "이미 존재" 경고 후 진행 | 기존 배포판 패키지(apt/yum)로 설치된 Docker가 있을 수 있음. 충돌 방지를 위해 기존 설치를 먼저 제거하는 것을 권장 (`sudo systemctl stop docker`, 배포판 패키지 제거 후 재시도) |
| `docker compose` 명령을 찾을 수 없음 | `/usr/local/lib/docker/cli-plugins/docker-compose` 존재 및 실행권한 확인. Docker CLI가 인식하는 plugin 경로에 있는지 `docker info \| grep -A5 Plugins` 로 확인 |
| 아키텍처 불일치로 바이너리 실행 불가 (`cannot execute binary file`) | `uname -m` 결과와 다운로드한 `ARCH` 가 다름. 로컬에서 올바른 `ARCH` 로 다시 다운로드/전송 |
| 사내 프록시를 통해서만 사설 레지스트리 접근 가능 | `/etc/systemd/system/docker.service.d/http-proxy.conf` 를 만들어 `HTTP_PROXY`/`HTTPS_PROXY` 환경변수 설정 후 `systemctl daemon-reload && systemctl restart docker` (이번 매뉴얼 범위 밖, 필요 시 별도 구성) |

## 6. 재설치 / 업그레이드

1. 로컬 PC에서 `.env` 의 `DOCKER_VERSION`(또는 `COMPOSE_VERSION`)을 변경 후 `01-download.sh` 재실행
2. `./scripts/02-transfer-to-vm.sh` 로 VM에 재전송
3. VM에서 `sudo systemctl stop docker` 로 서비스 중지
4. `./scripts/03-install.sh` 재실행 (기존 바이너리를 새 버전으로 덮어씀 — 확인 프롬프트에서 Enter)
5. `./scripts/04-verify.sh` 로 새 버전 확인

기존 컨테이너/이미지/볼륨 데이터는 `/var/lib/docker/` 에 보존되며, 바이너리 교체만으로는
삭제되지 않습니다.

## 7. 제거 (필요 시)

```bash
sudo systemctl stop docker
sudo systemctl disable docker
sudo rm /etc/systemd/system/docker.service
sudo systemctl daemon-reload
sudo rm /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 \
        /usr/bin/ctr /usr/bin/docker-init /usr/bin/docker-proxy /usr/bin/runc
sudo rm -rf /usr/local/lib/docker/cli-plugins/docker-compose
# 컨테이너/이미지/볼륨 데이터까지 완전히 삭제하려면 (주의: 되돌릴 수 없음)
# sudo rm -rf /var/lib/docker
```
