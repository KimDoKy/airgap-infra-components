# GitServer (Gitea) — 폐쇄망 Git 서버

bastion 뒤 private subnet VM에 Gitea 를 Docker 로 올리고, 개발자는 **bastion:22 SSH 게이트웨이로만**
Git 을 사용하는 구성. 웹 UI·HTTPS·토큰은 사용하지 않으며, 유지해야 할 상시 터널 프로세스가 없습니다.

## 아키텍처

```
개발자 PC ──ssh22, 개인키──▶ gitgw@bastion(강제명령) ──ssh22, tunnel_key──▶ gitfwd@GitServerVM
                                                                            └(-W localhost:2222)▶ Gitea git-SSH
                                                                                                  (컨테이너, loopback)
```
- SG 는 bastion·GitServer 양쪽 **인바운드 22만** 열림(GitServer 는 bastion 출발지만). 2222/443/80 닫힘.
- `gitgw`(강제명령 전용) → `tunnel_key`(포워딩 전용) → `gitfwd`(nologin, `permitopen=localhost:2222`) 로
  잠겨 있어, 사용자는 인프라 pem 없이 본인 키 하나로 접근하고 셸/타포트로 새지 않습니다.

## 빠른 사실

| 항목 | 값 |
|---|---|
| GitServer VM | `<GITEA_IP>` (private, `ssh acme-git` 로 bastion 경유) |
| bastion | `<BASTION_PUBLIC_IP>` (public, 인바운드 22) |
| Git 접근(사용자) | `git clone acme-gitea:<사용자>/<저장소>.git` |
| 이미지 | `gitea/gitea:1.23.1` + `nginx:1.27-alpine`(로컬 443 TLS, REST API/헬스체크용) |
| 관리 | admin 계정, VM에서 CLI/API (웹 UI 미사용) |
| 데이터(백업 대상) | `/home/ubuntu/GitServer/data/` |

## 문서 (역할별)

| 역할 | 문서 | 내용 |
|---|---|---|
| **서버 구축자** | [BUILD.md](BUILD.md) | 이미지 배포·기동, SSH 게이트웨이(`gitgw`/`gitfwd`) 구축, SG |
| **관리자** | [ADMIN.md](ADMIN.md) | 사용자 온보딩/차단, 계정·저장소 관리, 운영·백업 |
| **사용자** | [USER.md](USER.md) | `~/.ssh/config` 설정, clone/push/pull |

동작 테스트: 게이트웨이 키를 가진 PC 에서 `git clone acme-gitea:admin/<repo>.git` (상세: [BUILD.md](BUILD.md) 4절 검증).
