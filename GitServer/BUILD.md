# GitServer 구축 가이드 (서버 구축자)

폐쇄망 VM(bastion 뒤 private subnet)에 Gitea 를 올리고, bastion:22 SSH 게이트웨이로만 접근하도록
구축하는 절차. 처음부터 한 번 수행하면 됩니다.

## 0. 사전 조건

- **로컬 PC**: Docker(이미지 pull/save 용), `ssh`/`rsync`, bastion 경유 VM SSH 접속(`ssh acme-git`).
- **GitServer VM**: Docker/Compose 설치됨(미설치 시 `../Docker/` 먼저 진행), `openssl`, `sudo`.
- **보안그룹(SG)** — 최종적으로 아래만 열려 있으면 됩니다:
  | SG | 인바운드 | 출발지 |
  |---|---|---|
  | bastion | `TCP 22` | 개발자/관리자 IP |
  | GitServer VM | `TCP 22` | **bastion 에서만** |
  > git-SSH(2222)·HTTPS(443)는 열지 않습니다. 2222는 VM 내부 loopback으로만 접근하므로 SG와 무관합니다.

## 1. 설정 (`.env`)

배포 전 값 확인:
```
GITEA_IMAGE=gitea/gitea:1.23.1        NGINX_IMAGE=nginx:1.27-alpine
VM_SSH_HOST=acme-git                 # ssh config alias (bastion ProxyJump). IP 직접 금지
VM_SSH_USER=ubuntu   VM_SSH_PORT=22   VM_REMOTE_DIR=/home/ubuntu/GitServer   # 절대경로(~ 금지)
SSH_PORT=2222        TLS_PORT=443     TLS_HTTP_PORT=80        # SSH_PORT=Gitea git-SSH(내부 loopback)
TLS_DOMAIN=<GITEA_IP>   GITEA_DOMAIN=<GITEA_IP>   GITEA_ROOT_URL=https://<GITEA_IP>/
USER_UID=1000   USER_GID=1000
ADMIN_USER=admin   ADMIN_PASSWORD=<강력한 값으로 변경>
```
> `GITEA_SECRET_KEY`/`GITEA_INTERNAL_TOKEN` 은 비워두면 `05-start.sh` 가 자동 생성합니다.

## 2. 이미지 배포 + 기동

```bash
# [로컬] 이미지 pull + save  (빌드 PC가 Apple Silicon이면 반드시 amd64로 강제)
DOCKER_DEFAULT_PLATFORM=linux/amd64 ./scripts/01-pull-and-save-image.sh
./scripts/02-transfer-to-vm.sh                 # rsync/scp 로 VM에 전체 전송

# [VM]  (ssh acme-git; cd /home/ubuntu/GitServer)
./scripts/03-load-image.sh                     # 이미지 로드
./scripts/05-start.sh                          # 인증서 생성 + compose up + admin 계정 CLI 생성
```
`05-start.sh` 정상 종료 시 gitea·gitea-nginx 두 컨테이너가 Up 이고 admin 계정이 생성됩니다.
검증: `docker exec -u 1000 gitea gitea admin user list` 에 admin(Is Admin=true) 표시.

## 3. SSH 게이트웨이 구축 (핵심)

사용자가 pem 없이 bastion:22 만으로 Git에 접근하게 하는 부분. **한 번 구축하면 온보딩은 키 추가만** 하면 됩니다.

### (A) GitServer VM — 저권한 포워드 계정 `gitfwd`

포워딩 전용 키가 접속할, **셸 없는 저권한 계정**. 이 계정/키는 오직 Gitea(2222) loopback 포워딩만 허용.
```bash
# [VM]
sudo useradd -m -s /usr/sbin/nologin gitfwd
sudo install -d -m 700 -o gitfwd -g gitfwd /home/gitfwd/.ssh
# tunnel_key.pub 는 (B)에서 생성한 공개키를 붙여넣기
echo 'restrict,port-forwarding,permitopen="localhost:2222",permitopen="127.0.0.1:2222" ssh-ed25519 AAAA...tunnel_key.pub...' \
  | sudo tee /home/gitfwd/.ssh/authorized_keys >/dev/null
sudo chown gitfwd:gitfwd /home/gitfwd/.ssh/authorized_keys && sudo chmod 600 /home/gitfwd/.ssh/authorized_keys
```

### (B) bastion — 잠긴 게이트웨이 계정 `gitgw` + 터널 전용 키

```bash
# [bastion]
sudo useradd -m -s /bin/bash gitgw
sudo install -d -m 700 -o gitgw -g gitgw /home/gitgw/.ssh
# 터널 전용 키 생성 (개인키는 bastion에만 존재. 이 .pub 을 (A) gitfwd 에 등록)
sudo -u gitgw ssh-keygen -t ed25519 -f /home/gitgw/.ssh/tunnel_key -N '' -C gitgw-tunnel
sudo cat /home/gitgw/.ssh/tunnel_key.pub          # → (A) 로
```
`gitgw` 의 `authorized_keys` 는 **사용자별 1줄**(강제명령 + 사용자 공개키). 신규 사용자 추가 = 이 줄 append:
```bash
# [bastion]  PUB = 개발자 공개키
PUB='ssh-ed25519 AAAA...user...'
CMD='command="ssh -i /home/gitgw/.ssh/tunnel_key -o StrictHostKeyChecking=accept-new -W localhost:2222 gitfwd@<GITEA_IP>",no-pty,no-X11-forwarding,no-agent-forwarding,no-port-forwarding,no-user-rc'
echo "$CMD $PUB" | sudo tee -a /home/gitgw/.ssh/authorized_keys >/dev/null
sudo chown gitgw:gitgw /home/gitgw/.ssh/authorized_keys && sudo chmod 600 /home/gitgw/.ssh/authorized_keys
```

### 접근 경로 (완성 형태)
```
개발자 PC ──ssh22, 개인키──▶ gitgw@bastion(강제명령) ──ssh22, tunnel_key──▶ gitfwd@GitServerVM
                                                                            └(-W localhost:2222)▶ Gitea git-SSH(loopback)
```
- 모든 홉이 **22 위**에서만 → SG 22-only 충족.
- `tunnel_key`/`gitfwd` 는 **셸 불가·2222 포워딩만** → bastion 침해가 VM 셸로 번지지 않음.
- **상시 프로세스 없음**: 표준 sshd가 연결 시 강제명령을 즉석 실행.

## 4. 검증

```bash
# [gitgw 에 등록한 키를 가진 PC 에서]  USER.md 의 ~/.ssh/config 적용 후
git clone acme-gitea:admin/<repo>.git      # clone/push/pull 동작 확인
```
게이트웨이 제한 확인(bastion에서, tunnel_key 로): `-W localhost:2222` 는 배너 수신 / `-W localhost:22` 는
`administratively prohibited` / 셸 exec 은 `account not available` 이면 정상.

## 5. 이후

- 사용자 온보딩·계정/저장소 관리·백업 → `ADMIN.md`
- 사용자 clone/push/pull → `USER.md`
- 동작 테스트 스크립트 → `Test/test-commands.sh`
- SSH 호스트 포트를 22→다른 포트로 바꿀 경우: SG 규칙 + 사용자 config 의 `ProxyCommand -p` +
  `gitgw` 강제명령의 `-p` 만 갱신(Gitea 내부 2222는 불변).
