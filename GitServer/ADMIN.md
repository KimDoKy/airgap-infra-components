# GitServer 관리자 가이드

운영 중인 Gitea 서버의 일상 관리. **웹 UI 는 사용하지 않으며**, 모든 관리는 VM에서 CLI/API 로 합니다.

접속: `ssh acme-git` (운영자 pem 필요) → `cd /home/ubuntu/GitServer`
아래 예시의 `<ADMIN_PASSWORD>` 는 `.env` 의 `ADMIN_PASSWORD` 로 바꿔 쓰세요.
Gitea CLI 는 반드시 `-u 1000`(= `USER_UID`)으로 실행합니다(root 실행 거부).

## 1. 신규 사용자 온보딩

사용자에게 **SSH 공개키 1개**를 받아 **두 곳**에 등록합니다. (사용자는 pem 불필요)

```bash
# --- (A) bastion: 게이트웨이 통과 허용 (bastion에 접속해 실행) ---
PUB='ssh-ed25519 AAAA...사용자공개키... user@host'
CMD='command="ssh -i /home/gitgw/.ssh/tunnel_key -o StrictHostKeyChecking=accept-new -W localhost:2222 gitfwd@<GITEA_IP>",no-pty,no-X11-forwarding,no-agent-forwarding,no-port-forwarding,no-user-rc'
echo "$CMD $PUB" | sudo tee -a /home/gitgw/.ssh/authorized_keys >/dev/null

# --- (B) VM: Gitea 계정 생성 + 그 계정에 사용자 SSH 키 등록 ---
docker exec -u 1000 gitea gitea admin user create \
  --username alice --password 'InitPw!234' --email alice@example.com --must-change-password=true
curl --cacert certs/server.crt -u 'admin:<ADMIN_PASSWORD>' -X POST \
  https://localhost/api/v1/admin/users/alice/keys \
  -H 'Content-Type: application/json' -d "{\"title\":\"alice-laptop\",\"key\":\"$PUB\"}"
```

사용자에게는 `USER.md` 의 `~/.ssh/config` 블록만 전달하면 됩니다.

**차단/탈퇴**: bastion `gitgw` authorized_keys 에서 해당 줄 삭제 + Gitea 에서 키/계정 삭제.
```bash
docker exec -u 1000 gitea gitea admin user delete --username alice --purge   # 저장소까지 삭제 시 --purge
```

## 2. 계정 관리 (CLI)

```bash
docker exec -u 1000 gitea gitea admin user list
docker exec -u 1000 gitea gitea admin user create --username bob --password 'Pw!' --email bob@x.com --admin   # 관리자
docker exec -u 1000 gitea gitea admin user change-password --username alice --password 'NewPw!'
```

## 3. 저장소 / 조직 관리 (REST API)

`curl` 은 `--cacert certs/server.crt` 로 자체서명 인증서를 검증합니다.

```bash
AUTH='admin:<ADMIN_PASSWORD>'; C='--cacert certs/server.crt'; B=https://localhost
# 저장소 생성 (auto_init = 기본 브랜치+README 자동)
curl $C -u "$AUTH" -X POST $B/api/v1/user/repos          -d '{"name":"my-repo","private":true,"auto_init":true}' -H 'Content-Type: application/json'
curl $C -u "$AUTH" -X POST $B/api/v1/admin/users/alice/repos -d '{"name":"alice-repo","private":true,"auto_init":true}' -H 'Content-Type: application/json'  # 특정 사용자 소유
# 목록 / 삭제
curl $C -u "$AUTH" "$B/api/v1/repos/search?limit=50"
curl $C -u "$AUTH" -X DELETE $B/api/v1/repos/admin/my-repo
# 조직 + 조직 소유 저장소
curl $C -u "$AUTH" -X POST $B/api/v1/admin/users/alice/orgs -d '{"username":"myteam","visibility":"private"}' -H 'Content-Type: application/json'
curl $C -u "$AUTH" -X POST $B/api/v1/orgs/myteam/repos      -d '{"name":"service-a","private":true,"auto_init":true}' -H 'Content-Type: application/json'
```

## 4. 운영

```bash
docker ps --filter name=gitea                    # gitea, gitea-nginx 둘 다 Up 확인
docker logs -f gitea                             # 로그
docker logs -f gitea-nginx
docker compose restart                           # 재시작
./scripts/06-stop.sh                             # 중지(데이터 보존)  /  재기동: docker compose up -d
```

**상태 점검**:
```bash
docker exec -u 1000 gitea gitea admin user list
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/api/healthz   # 200
```

**백업/복구** (대상: `./data/` = DB·저장소·설정 전부):
```bash
./scripts/06-stop.sh
tar czf gitea-data-$(date +%F).tar.gz data/ certs/
docker compose up -d
# 복구: 새 위치에 data/(및 certs/) 복원 후 docker compose up -d
```

## 5. (필요 시) 웹 UI 임시 접근

평소엔 안 쓰지만 브라우저로 봐야 할 때만 즉석 터널(상시 서비스 없음, 운영자 pem 필요):
```bash
ssh -L 9443:localhost:443 acme-git        # 열어둔 세션 유지
# 브라우저: https://localhost:9443/   (자체서명 경고 정상)
```
