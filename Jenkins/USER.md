# Jenkins 사용자 가이드 (개발자)

CI/CD 를 쓰는 개발자용. **GUI 없음** — 코드 push 로 트리거하고, 결과는 CLI 로 확인합니다.
흐름: Gitea push → (폴링) → **Jenkins(CI)** frontend·backend 빌드(Nexus 의존성) → ECR push →
GitOps repo 이미지 태그 커밋 → **ArgoCD(CD)** 가 EKS(dev/stg/prd)에 배포.

## 1. 앱 저장소 구조

Gitea 저장소(`acme/acme-app`) 루트에 아래가 있어야 파이프라인이 동작합니다(샘플: 레포 `sample-app/`).
```
frontend/   backend/          # 각 컴포넌트(Dockerfile 포함)
Jenkinsfile                   # CI 정의(두 컴포넌트 빌드→ECR→gitops 태그 커밋)
pipeline/                     # scripts·config·pipeline.env (Jenkins/pipeline/ 복사본)
```

## 2. 트리거 — 브랜치에 push (폴링)

Jenkins 가 3분 주기로 변경을 감지합니다(webhook 아님). **브랜치 = 환경**:

| push 대상 | 환경 | 네임스페이스 |
|---|---|---|
| `dev` 브랜치 | dev | `acme-app-dev` |
| `stg` 브랜치 | stg | `acme-app-stg` |
| `main` 브랜치 또는 태그 `v*` | prd | `acme-app-prd` (ArgoCD 수동 승인) |
| 그 외 브랜치 | 빌드만(배포 스킵) | — |

```bash
git checkout dev && git commit -m "..." && git push origin dev     # → dev 환경으로
```
각 컴포넌트는 `acme-app-frontend` / `acme-app-backend` 이미지로 ECR push 되고, CI 가 **GitOps repo 의
해당 env 이미지 태그를 커밋**합니다. 이후 **ArgoCD** 가 감지해 해당 env 네임스페이스에 배포합니다(노드는
`env=<env>` taint 로 물리 분리). prd 는 ArgoCD 에서 수동 Sync 승인.

## 3. 결과 확인 (GUI 없이)

운영자에게 요청하거나, Jenkins CLI/kubectl 접근 권한이 있으면:
```bash
# Jenkins CLI (컨테이너 내부에서; 운영자 경유)
docker exec jenkins java -jar /var/jenkins_home/war/WEB-INF/lib/cli-*.jar \
  -s http://localhost:8080/ -auth admin:<pw> list-builds "acme-app/dev"

# 배포 상태 (kubectl 접근 시)
kubectl -n acme-app-dev get deploy,pod,svc
```

## 4. 유의

- **의존성은 Nexus 에서만** 받습니다(폐쇄망). 새 npm 패키지가 필요하면 관리자에게 Nexus 등록을 요청하세요.
- 빌드 실패 대부분: Nexus 에 없는 패키지, `Dockerfile` 오류, lockfile 미커밋. (실서비스는 `package-lock.json`
  커밋 + `npm ci` 권장)
- 프론트는 `/api/` 를 같은 네임스페이스의 `acme-app-backend:3000` 으로 프록시합니다(서비스명 env 무관).
