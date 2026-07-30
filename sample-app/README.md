# acme 샘플 앱 (frontend + backend)

CICD 파이프라인 검증용 hello-world 샘플. **프론트엔드**와 **백엔드**가 분리된 2개 컴포넌트입니다.

| 컴포넌트 | 스택 | 내용 | 포트 | 이미지 |
|---|---|---|---|---|
| `backend/`  | Node.js(Express) | `/api/hello` → "Hello World from backend" | 3000 | node 런타임 |
| `frontend/` | Vite 빌드 → nginx | hello world 페이지, `/api/`는 backend 로 프록시 | 80 | nginx 정적 |

- 의존성은 **Nexus npm 레지스트리**에서 받습니다(Dockerfile 이 빌드 컨텍스트의 `.npmrc` 사용 — CI 가 렌더링).
- 프론트 nginx 는 `/api/` 를 같은 네임스페이스의 `acme-app-backend:3000` 서비스로 프록시(환경은 ns 로 분리).

## CICD 연동 (이 저장소를 Gitea `acme/acme-app` 로 push)

앱 저장소 루트에 아래를 함께 두면 폴링 트리거로 파이프라인이 돕니다(자세히는 `Jenkins/pipeline/README.md`):
```
acme-app/            ← Gitea 저장소
├── frontend/         (이 디렉터리)
├── backend/          (이 디렉터리)
├── Jenkinsfile       ← Jenkins/pipeline/Jenkinsfile 복사
└── pipeline/         ← Jenkins/pipeline/ 복사(scripts·config·pipeline.env)
```
파이프라인: 브랜치 push → 두 컴포넌트 각각 `docker build`→ECR push → **GitOps repo 태그 커밋** →
ArgoCD 가 dev/stg/prd 배포(배포 매니페스트는 `gitops/`).
- 환경 매핑: branch `dev`→dev, `stg`→stg, `main`/tag→prd.
- 각 컴포넌트는 ECR 리포 `acme-app-frontend` / `acme-app-backend` 로 push, 환경별 ns(`acme-app-<env>`)에 배포.

## 로컬 확인(참고, 선택)
```bash
# backend
cd backend && npm install && npm start      # http://localhost:3000/api/hello
# frontend
cd frontend && npm install && npm run dev    # http://localhost:5173
```
