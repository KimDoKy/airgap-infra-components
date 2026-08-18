# GitOps (ArgoCD) — acme 앱 배포(CD)

> **대상 클러스터 = NHN Cloud NKS.** 테스트는 **3노드(ops/dev/prd) 최소 구성**으로 진행하며, 노드
> 사양·label·taint 는 [`cluster/nodepools.nks.md`](cluster/nodepools.nks.md) 가 기준이다. 관측은 **B안
> (Prometheus + Grafana)** 를 `acme-ops` 노드(2 vCPU/8GB, taint 없음)에 올린다.
> (`cluster/nodegroups.eksctl.yaml` 은 과거 EKS 검토 시의 **레거시 참고용** — 활성 경로는 NKS.)
>
> **✅ 실측 검증 완료(2026-08-13) — Git→Jenkins→Nexus→NCR→ArgoCD→NKS 전체 배포 플로우 hands-on:
> [`nks-deploy-flow.md`](nks-deploy-flow.md).** SG 설정(NKS 노드 CIDR→Gitea:443), NCR push/pull,
> ArgoCD 직접 감시(insecure), dev/prd taint 격리, 모니터링 배포까지 실제 통과 기록.

**배포는 ArgoCD 가 담당**합니다(Jenkins 는 CI=빌드·레지스트리 push·태그 커밋까지만). ArgoCD 가 이 GitOps
저장소를 감시하다가, 이미지 태그 변경 커밋을 감지하면 클러스터(NKS)로 자동 동기화합니다.

이 `gitops/` 디렉터리는 **CD 자산 모음**이다: 활성 경로는 **config-repo 환경 브랜치**(별도 Gitea 저장소,
`config-repo-init.sh`/`nks-deploy-flow.md`)이고, `helm/acme-app` + `argocd/application-<env>.yaml` 은
frontend/backend 2컴포넌트용 **helm 스캐폴드**(별도 `acme-gitops` 저장소, HTTPS)다.

## 구조

```
gitops/                         ← GitOps repo 루트
├── helm/acme-app/             # 앱 차트(frontend+backend 한 릴리스) + values-{dev,test,prd}.yaml
│   └── values-<env>.yaml       #   components.*.image.tag ← Jenkins(CI)가 커밋으로 갱신
├── argocd/
│   ├── application-<env>.yaml  # ArgoCD Application(환경별): repo watch → NKS sync (app-of-apps 가 관리)
│   └── install/                # ArgoCD 설치 부트스트랩(ns·project·repo-secret·app-of-apps·helm values)
└── cluster/                    # 클러스터 1회 준비
    ├── nodepools.nks.md        #   ★ NKS 노드풀 사양(ops/dev/prd) + label/taint — 활성 기준
    ├── namespaces.yaml         #   환경 네임스페이스
    ├── node-taints.sh          #   label+taint 폴백(ops 무-taint)
    └── nodegroups.eksctl.yaml  #   (레거시) EKS 노드그룹 참고용
```

## 흐름 (CI → CD 분리)

```
Jenkins(CI): build → NCR push → config-repo dev 브랜치 apps/test-app/deployment.yaml image tag 갱신 + git push
                                          │
ArgoCD(CD): config-repo 감시 → 변경 감지 → NKS 동기화 (ns=acme-app-<env>, node taint env=<env>)
```
- config-repo = **환경 브랜치**(dev/test/prd). ArgoCD Application: `targetRevision=<env 브랜치>`, `path=apps/test-app`.
- CI 는 **dev 브랜치**만 갱신 → dev 자동배포. test/prd 는 **승격**(`../tools/promote-image.sh`), **prd 는 수동 Sync 승인**.
> `helm/acme-app`(frontend/backend 2컴포넌트) + `argocd/application-<env>.yaml` 은 helm 기반 **스캐폴드**다.
> 실측·활성 경로는 config-repo 환경 브랜치 모델([nks-deploy-flow.md](nks-deploy-flow.md), [config-repo-init.sh](config-repo-init.sh)).

## 적용 (NKS 준비 후)

```bash
# 1) NKS 노드풀 3개 생성(ops/dev/prd) — 사양·label·taint 는 cluster/nodepools.nks.md 기준.
kubectl apply -f cluster/namespaces.yaml
#    노드풀 생성 시 label(env=ops / env=dev / env=prd) 지정(+ 지원 시 taint).
#    taint 미지원이면 폴백: ./cluster/node-taints.sh  (label 로 대상 선택, 미매칭 시 노드풀명 접두어)

# 2) ArgoCD 설치 + 부트스트랩 → 이후 dev/prd 앱은 ArgoCD 가 자동 관리 (argocd/install/README.md)
#    namespace → helm install → project → repo-secret → app-of-apps
#    (test 는 이 3노드 테스트 클러스터에 노드풀이 없어 배포 대상 아님 — nodepools.nks.md 참고)
```
> 배포 자체는 손으로 `kubectl apply` 하지 않습니다 — **app-of-apps** 를 한 번 적용하면 ArgoCD 가
> `argocd/application-<env>.yaml` 을 GitOps 로 동기화합니다. 상세: [argocd/install/README.md](argocd/install/README.md).

## 필요 사항 (연결 시)

- **ArgoCD → config-repo(Gitea)** 접근: repo Secret(**HTTPS + `insecure:"true"`**) 등록 + **NKS 노드 CIDR → gitea:443 SG** 허용.
  (git-SSH 2222 는 NKS 에서 도달 불가 → HTTPS 443 사용.)
- **NKS 노드 → NCR** pull: 앱 네임스페이스에 `ncr-cred` **docker-registry imagePullSecret**(IAM/IRSA 아님, basic auth).
- ArgoCD 서버는 NKS 내부 `env=ops` 노드에 설치. 상세: [argocd/install/README.md](argocd/install/README.md), [nks-deploy-flow.md](nks-deploy-flow.md).
