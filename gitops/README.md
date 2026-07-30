# GitOps (ArgoCD) — acme 앱 배포(CD)

**배포는 ArgoCD 가 담당**합니다(Jenkins 는 CI=빌드·ECR push·태그 커밋까지만). ArgoCD 가 이 GitOps
저장소를 감시하다가, 이미지 태그 변경 커밋을 감지하면 EKS 로 자동 동기화합니다.

이 `gitops/` 디렉터리는 **별도 GitOps 저장소(Gitea `acme/acme-gitops`)의 루트**가 됩니다.
(ArgoCD Application 의 `path` 는 이 루트 기준: `helm/acme-app`)

## 구조

```
gitops/                         ← GitOps repo 루트
├── helm/acme-app/             # 앱 차트(frontend+backend 한 릴리스) + values-{dev,stg,prd}.yaml
│   └── values-<env>.yaml       #   components.*.image.tag ← Jenkins(CI)가 커밋으로 갱신
├── argocd/
│   ├── application-<env>.yaml  # ArgoCD Application(환경별): repo watch → EKS sync (app-of-apps 가 관리)
│   └── install/                # ArgoCD 설치 부트스트랩(ns·project·repo-secret·app-of-apps·helm values)
└── cluster/                    # 클러스터 1회 준비: namespaces.yaml, nodegroups.eksctl.yaml, node-taints.sh
```

## 흐름 (CI → CD 분리)

```
Jenkins(CI): build → ECR push → gitops values-<env>.yaml 의 image.tag 갱신 + git push
                                          │
ArgoCD(CD): 이 repo 감시 → 변경 감지 → helm 렌더 → EKS 동기화 (ns=acme-app-<env>, node taint env=<env>)
```
- 환경 매핑: git ref(app repo) `dev`→dev, `stg`→stg, `main`/tag→prd (Jenkins 가 해당 env values 갱신).
- dev/stg 는 자동 동기화(automated), **prd 는 수동 Sync 승인** 권장(application-prd.yaml).

## 적용 (EKS 준비 후)

```bash
# 1) 클러스터 준비 (관리자 1회). 노드 taint 는 nodegroup 정의 권장(아래 참고).
kubectl apply -f cluster/namespaces.yaml
#    환경별 노드그룹 label+taint 는 cluster/nodegroups.eksctl.yaml 로 선언(권장) — node-taints.sh 는 폴백.

# 2) ArgoCD 설치 + 부트스트랩 → 이후 dev/stg/prd 앱은 ArgoCD 가 자동 관리 (argocd/install/README.md)
#    namespace → helm install → project → repo-secret → app-of-apps
```
> 배포 자체는 손으로 `kubectl apply` 하지 않습니다 — **app-of-apps** 를 한 번 적용하면 ArgoCD 가
> `argocd/application-<env>.yaml` 을 GitOps 로 동기화합니다. 상세: [argocd/install/README.md](argocd/install/README.md).

## 필요 사항 (연결 시)

- **ArgoCD → GitOps repo(Gitea)** 접근: repo 자격(SSH 키/토큰) 등록 + **EKS(ArgoCD) → gitea:2222 SG** 허용.
- **EKS 노드 → ECR** pull 권한: 노드 IAM 역할 또는 IRSA (imagePullSecrets 불필요하게).
- ArgoCD 서버는 EKS 클러스터 내부에 설치(별도). 본 스캐폴드는 Application/차트만 제공(미검증).
