# 사용자/개발자 통합 매뉴얼 (User / Developer)

개발자가 **코드를 올리면 자동으로 dev 에 배포**되고, test/prd 로 **승격**하는 흐름과 접근 방법.

## 전체 흐름 (내가 하는 것 = git push)

```
[개발자] git push (app repo)
   → Jenkins 가 폴링으로 감지 → 빌드(의존성 Nexus) → 이미지 → NCR push
   → config-repo 'dev' 브랜치 이미지 태그 갱신
   → ArgoCD 가 dev 자동 동기화 → NKS dev 네임스페이스에 배포
```
- **dev 는 자동.** test/prd 는 운영/릴리스가 **승격**(수동)한다.

## 1. Gitea 접근 (clone / push)

pem 없이 **bastion:22 SSH 게이트웨이**로 접근. 관리자에게 **공개키 등록**을 요청한 뒤:

1. `~/.ssh/config` 에 게이트웨이 별칭(`acme-gitea`, ProxyCommand) 추가 — 블록은 [`GitServer/USER.md`](GitServer/USER.md).
2. clone/push:
   ```bash
   git clone acme-gitea:admin/<repo>.git
   # 커밋 후
   git push
   ```
**정상 확인**: clone/push 성공. 실패 시 공개키 등록 여부(관리자)·config 별칭 확인. 상세: [`GitServer/USER.md`](GitServer/USER.md).

## 2. 빌드 / 배포 트리거 (dev 자동)

- 앱 저장소(예: `test-app`)의 기본 브랜치에 **push** 하면 Jenkins 가 **3분 폴링**으로 감지해 빌드→NCR→
  config-repo `dev` 갱신→ArgoCD dev 자동배포.
- 빌드 결과 확인(Jenkins GUI, 운영자에게 접근 문의): 잡 콘솔에 `NCR push` → `config-repo(dev) 갱신` → `SUCCESS`.
- 배포 확인(ArgoCD): `test-app-dev`(dev) 앱이 새 이미지로 `Synced/Healthy`.

> npm 등 의존성은 빌드 중 **Nexus** 에서 받는다(사내 레지스트리). `.npmrc` 는 파이프라인이 주입.

## 3. 환경 승격 (test → prd)

개발자는 보통 dev 까지. **test/prd 승격은 릴리스 매니저/운영**이 수행(권한 분리):
- 승격 = 대상 env 브랜치에 이미지 태그 반영(`tools/promote-image.sh`).
- **prd** 는 (a) `prd` 브랜치 보호(PR+승인) (b) ArgoCD `releasemgr` 권한 (c) 수동 Sync 로 게이트.
- 개발자는 prd 반영을 **요청**(PR 또는 릴리스 티켓)한다.

## 4. GUI 접근

| 대상 | URL | 인증 |
|---|---|---|
| ArgoCD(배포 상태 조회) | `https://argocd.<LB_IP>.nip.io` | 부여받은 계정(예: `developer`) |
| Grafana(관측) | `https://grafana.<LB_IP>.nip.io` | 부여받은 계정 |
| Gitea/Jenkins/Nexus | 운영자 터널(`tools/gui`) 또는 접근 요청 | 각 계정 |

- ArgoCD RBAC: `developer` 는 **dev/test sync 가능, prd 불가**(조회는 가능). `<LB_IP>` 는 운영자 안내.

## 5. 자주 겪는 문제

| 증상 | 원인/조치 |
|---|---|
| `git push` `Permission denied (publickey)` | 공개키 미등록(관리자 요청) 또는 `~/.ssh/config` 별칭 오류 |
| push 했는데 배포 안 됨 | 폴링 3분 대기, Jenkins 잡 SUCCESS 여부, ArgoCD dev 앱 Synced 확인 |
| prd 에 반영 안 됨 | 정상(자동 아님). 승격+수동 Sync 는 릴리스 권한 필요 |
| 빌드 중 npm 실패 | Nexus 자격/저장소 문제 — 운영자에게 문의 |

- 개발자 상세(Gitea): [`GitServer/USER.md`](GitServer/USER.md) · 배포 파이프라인: [`Jenkins/README.md`](Jenkins/README.md)
- 운영/승격: [`OPERATOR.md`](OPERATOR.md)
