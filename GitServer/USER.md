# GitServer 사용자 가이드

개발자가 로컬 PC에서 Git 저장소를 clone/push/pull 하는 방법입니다. 이 서버는 bastion 뒤에 있고
**SSH 게이트웨이(포트 22)로만** 접근합니다. HTTPS/웹 UI/토큰은 사용하지 않습니다.

## 1. 준비 (최초 1회)

1. SSH 키가 없으면 생성: `ssh-keygen -t ed25519`
2. **공개키(`~/.ssh/id_ed25519.pub`)를 관리자에게 전달** → 관리자가 게이트웨이와 Gitea 계정에 등록해 줍니다.
3. `~/.ssh/config` 에 아래 블록 추가 (`<bastion-공인IP>` 는 관리자에게 확인, 예: `<BASTION_PUBLIC_IP>`):

```
Host acme-gitea
    HostName localhost
    Port 2222
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    HostKeyAlias acme-gitea
    StrictHostKeyChecking accept-new
    ProxyCommand ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 gitgw@<bastion-공인IP>
```

> 인프라 키(`*.pem`)는 필요 없습니다. 본인 개인키 하나로 게이트웨이 통과와 Gitea 인증이 모두 됩니다.

## 2. clone / push / pull

```bash
# clone (scp 문법)
git clone acme-gitea:<사용자>/<저장소>.git
# 예)  git clone acme-gitea:alice/service-a.git

cd service-a
git config user.name  "alice"          # 최초 1회
git config user.email "alice@example.com"

# 일상 작업
git add . && git commit -m "메시지"
git push origin main
git pull origin main

# 브랜치
git switch -c feature/login
git push -u origin feature/login
```

로컬 프로젝트를 새 원격에 연결 (관리자가 빈 저장소를 먼저 만든 뒤):
```bash
git init -b main && git add . && git commit -m "init"
git remote add origin acme-gitea:alice/service-a.git
git push -u origin main
```

## 3. 문제 해결

| 증상 | 조치 |
|---|---|
| `Permission denied (publickey)` | 공개키가 아직 등록 안 됨/키 불일치. 관리자에게 등록 확인, `-i` 로 올바른 키 지정 |
| `Connection refused` / 접속 안 됨 | `<bastion-공인IP>` 오타 확인. bastion 22 접근 가능한 네트워크인지 확인 |
| `Host key verification failed` | 최초 접속 경고면 정상(accept-new). 서버 재설치 등으로 바뀌었으면 `ssh-keygen -R acme-gitea` 후 재시도 |
| clone URL 을 뭘 쓰나 | 항상 `acme-gitea:<사용자>/<저장소>.git` (HTTPS 주소 아님) |
| 대용량 push | 이 경로(SSH)는 용량 제한이 없습니다. 그대로 push |
