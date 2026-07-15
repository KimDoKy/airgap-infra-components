#!/usr/bin/env bash
# check/*.sh 에서 source 해서 사용하는 공용 함수 모음입니다.
# "가짜 VM"은 sshd가 떠 있는 컨테이너로, 호스트의 docker.sock을 그대로 공유합니다
# (Docker-outside-of-Docker). 그 안에서 실행하는 docker/docker compose 명령은
# 실제로는 이 Mac(호스트)의 도커 데몬에 컨테이너를 띄우지만, SSH로 그 안에 들어가서
# 실제 배포 스크립트(01~06)를 그대로 실행한다는 점에서 실제 폐쇄망 VM 운영과 동일한
# 절차를 검증합니다. 가짜 VM 자체는 이미지를 안 받으면 아무것도 못 하므로
# (반대로 로컬 PC는 인터넷이 있다는 실제 전제와 동일), 에어갭 자체를 흉내낸 것은
# 아니고 "SSH 전송 + VM측 스크립트 실행"이 실제로 동작하는지를 검증하는 용도입니다.

MOCK_VM_IMAGE="linuxserver/openssh-server:latest"
MOCK_VM_SSH_PORT=2222

# mock_vm_up <container_name> <workdir> <ssh_user>
#
# workdir 는 호스트의 실제 디렉터리 경로여야 하며, 컨테이너 내부에도 "동일한 경로"로
# 바인드 마운트됩니다. docker.sock을 공유하는 상태에서 컨테이너 안의 docker compose가
# 상대 경로(./data 등)를 절대경로로 바꿔 호스트 데몬에 넘길 때, 그 절대경로가 호스트에도
# 그대로 존재해야 바인드 마운트가 정상 동작하기 때문입니다 (경로가 다르면 실패합니다).
#
# --network host 로 띄웁니다: docker.sock을 공유하는 상태(Docker-outside-of-Docker)에서
# "docker compose up -d"로 뜨는 gitea/jenkins/nexus/nginx 등은 mock VM 컨테이너 "안"이
# 아니라 호스트 데몬의 형제 컨테이너로 뜨고, 포트도 호스트 네트워크에 게시됩니다. mock VM
# 컨테이너가 별도 네트워크 네임스페이스를 쓰면 그 안에서의 "localhost" 헬스체크(각 서비스의
# 05/06-start.sh 등이 자체적으로 수행)가 형제 컨테이너의 게시된 포트를 보지 못해 항상
# 실패합니다. --network host 로 호스트와 네트워크 네임스페이스를 공유해야 실제 VM에서
# "localhost:포트"로 접근하는 것과 동일한 결과가 나옵니다.
# (이 때문에 SSH 포트는 항상 고정된 MOCK_VM_SSH_PORT=2222 이며, 체크 스크립트를 동시에
# 두 개 이상 병렬 실행할 수 없습니다 - 한 번에 하나씩 실행하세요)
mock_vm_up() {
  local name="$1" workdir="$2" user="${3:-tester}"

  mkdir -p "$workdir"
  ssh-keygen -q -t ed25519 -f "$workdir/id_ed25519" -N "" -C "check-mock-vm" >/dev/null

  docker rm -f "$name" >/dev/null 2>&1 || true

  # /var/run/docker.sock 의 소유 GID를 "컨테이너 관점에서" 감지해 mock VM 사용자를 그 그룹에
  # 넣어줍니다. macOS(Docker Desktop/OrbStack 등)는 데몬이 리눅스 VM 안에서 돌기 때문에,
  # 호스트 셸에서 보는 소유권(예: 이 Mac 사용자 uid)과 컨테이너 안에서 실제로 보이는 소유권
  # (대개 root:root, 0660)이 다릅니다. 그래서 반드시 컨테이너를 통해 감지해야 합니다.
  local sock_gid
  sock_gid=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine \
    stat -c "%g" /var/run/docker.sock)

  docker run -d --name "$name" \
    --network host \
    -e PUBLIC_KEY="$(cat "$workdir/id_ed25519.pub")" \
    -e USER_NAME="$user" \
    -e PASSWORD_ACCESS=false \
    -e SUDO_ACCESS=true \
    -e PGID="$sock_gid" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$workdir:$workdir" \
    "$MOCK_VM_IMAGE" >/dev/null

  echo ">> mock VM(${name}) 컨테이너 응답 대기 중..."
  local tries=0
  until docker exec "$name" echo ready >/dev/null 2>&1; do
    sleep 1
    tries=$((tries + 1))
    if [ "$tries" -gt 30 ]; then
      echo "!! mock VM(${name}) 기동 실패" >&2
      docker logs "$name" >&2 || true
      return 1
    fi
  done

  echo ">> mock VM에 docker CLI / 필수 패키지 설치 중 (docker-cli, docker-cli-compose, openssl, curl, tar, sudo, git)..."
  docker exec -u root "$name" sh -c \
    'apk add --no-cache docker-cli docker-cli-compose openssl curl tar sudo bash git >/dev/null 2>&1'

  local ssh_opts
  ssh_opts=(-i "$workdir/id_ed25519" -p "$MOCK_VM_SSH_PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$workdir/known_hosts" \
    -o ConnectTimeout=3 -o BatchMode=yes)

  echo ">> mock VM SSH 접속 대기 중..."
  tries=0
  until ssh "${ssh_opts[@]}" "${user}@127.0.0.1" 'echo ok' >/dev/null 2>&1; do
    sleep 1
    tries=$((tries + 1))
    if [ "$tries" -gt 30 ]; then
      echo "!! mock VM(${name}) SSH 접속 실패" >&2
      docker logs "$name" >&2 || true
      return 1
    fi
  done

  echo ">> mock VM 준비 완료 (ssh -p ${MOCK_VM_SSH_PORT} ${user}@127.0.0.1)"
}

# mock_vm_down <container_name>
mock_vm_down() {
  local name="$1"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# mock_vm_install_ssh_wrappers <workdir>
#
# 02-transfer-to-vm.sh 등 "실제" 배포 스크립트는 우리가 만든 테스트용 키/known_hosts를
# 알지 못한 채 그냥 ssh/scp/rsync를 호출합니다. 그 스크립트를 수정하지 않고도 우리 키를
# 쓰게 하려면, 진짜 ssh/scp보다 먼저 찾히는 위치(PATH 맨 앞)에 동일한 이름의 래퍼를 두고
# 거기서 -i/-o 옵션을 주입해 실제 바이너리를 호출합니다. rsync는 내부적으로 "ssh"를
# 원격 셸로 PATH에서 찾아 실행하므로 별도 래퍼 없이 이 ssh 래퍼만으로 함께 적용됩니다.
# 호출한 뒤 반환되는 경로를 `export PATH="$(mock_vm_install_ssh_wrappers ...):$PATH"` 처럼
# PATH 맨 앞에 추가해서 사용하세요.
mock_vm_install_ssh_wrappers() {
  local workdir="$1"
  local bindir="$workdir/bin"
  mkdir -p "$bindir"

  cat > "$bindir/ssh" <<EOF
#!/usr/bin/env bash
exec /usr/bin/ssh -i "$workdir/id_ed25519" \\
  -o UserKnownHostsFile="$workdir/known_hosts" \\
  -o StrictHostKeyChecking=accept-new \\
  "\$@"
EOF

  cat > "$bindir/scp" <<EOF
#!/usr/bin/env bash
exec /usr/bin/scp -i "$workdir/id_ed25519" \\
  -o UserKnownHostsFile="$workdir/known_hosts" \\
  -o StrictHostKeyChecking=accept-new \\
  "\$@"
EOF

  chmod +x "$bindir/ssh" "$bindir/scp"
  echo "$bindir"
}
