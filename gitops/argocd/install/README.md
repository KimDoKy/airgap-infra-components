# ArgoCD 설치 (폐쇄망 EKS) — 스캐폴드

ArgoCD 는 **EKS 클러스터 내부**에 설치되어 클러스터 RBAC 로 배포합니다(외부 EKS 자격 불필요).
폐쇄망이라 ArgoCD 컴포넌트 이미지도 **ECR 로 미러링**한 뒤 설치합니다. (미검증 스캐폴드 — EKS/ECR 생성 후 검증)

## 구성 파일

| 파일 | 역할 | 적용 시점 |
|---|---|---|
| `namespace.yaml` | `argocd` 네임스페이스 | 부트스트랩 1회 |
| `values-argocd.yaml` | argo-cd Helm 차트 values (이미지 ECR 미러 override, dex off) | ArgoCD 설치 |
| `project.yaml` | AppProject `acme` (허용 repo/ns 제한) | 부트스트랩 1회 |
| `repo-secret.yaml` | GitOps repo(Gitea) 접근 SSH 키 Secret | 부트스트랩 1회 |
| `app-of-apps.yaml` | `acme-apps` — argocd/ 의 env Application 들을 GitOps 로 자기관리 | 부트스트랩 1회 |

## 설치 순서

```bash
# 0) [로컬 인터넷] ArgoCD/redis 이미지를 ECR 로 미러링 (예: v2.12.4)
#    docker pull quay.io/argoproj/argocd:v2.12.4 → tag → ECR push (또는 skopeo copy).
#    values-argocd.yaml 의 <AWS_ACCOUNT_ID>·tag 를 미러 경로로 맞춤.
#    argo-cd Helm 차트도 오프라인 반입(helm pull argo/argo-cd --version <x> → tgz).

# 1) 네임스페이스 + ArgoCD 설치 (Helm)
kubectl apply -f namespace.yaml
helm install argocd ./argo-cd-<ver>.tgz -n argocd -f values-argocd.yaml

# 2) AppProject + GitOps repo 자격
kubectl apply -f project.yaml
#    repo SSH 키는 파일 평문 대신 명령으로 주입(권장):
kubectl -n argocd create secret generic acme-gitops-repo \
  --from-literal=type=git \
  --from-literal=url=ssh://git@<GITEA_IP>:2222/acme/acme-gitops.git \
  --from-file=sshPrivateKey=./argocd_gitops_key
kubectl -n argocd label secret acme-gitops-repo argocd.argoproj.io/secret-type=repository

# 3) App-of-Apps → 이후 dev/stg/prd Application 은 ArgoCD 가 자동 생성·동기화
kubectl apply -f app-of-apps.yaml
```

## 필요 사항 / 주의

- **네트워크**: `EKS(ArgoCD) → gitea:2222` SG 허용(GitOps repo watch). ArgoCD 는 이 repo 만 sourceRepos 로 허용.
- **ECR pull**: EKS 노드 IAM 역할/IRSA 로 앱·ArgoCD 이미지 pull(별도 imagePullSecret 불필요하게).
- **Gitea 자체서명 CA**: git-SSH(2222) 사용이라 TLS CA 불필요. (HTTP(S) repo 를 쓰면 CA 등록 필요)
- **GUI 없이 운영**: `kubectl -n argocd ...` / `argocd` CLI(포트포워드) 로. 최초 admin 비번:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- **prd**: `application-prd.yaml` 은 automated 미설정 → ArgoCD 에서 **수동 Sync 승인**.
