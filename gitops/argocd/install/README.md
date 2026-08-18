# ArgoCD 설치 (NHN NKS) — 매니페스트 스캐폴드

ArgoCD 는 **NKS 클러스터 내부**(`env=ops` 노드)에 설치되어 클러스터 RBAC 로 배포합니다(외부 클러스터
자격 불필요). NKS 는 **인터넷 egress** 가 되므로 ArgoCD 컴포넌트 이미지는 **공개 레지스트리에서 직접
pull** 합니다(별도 미러링 불필요). config-repo(Gitea)는 **HTTPS** 로 등록하고, 앱 이미지는 **NCR** 에서
`ncr-cred` imagePullSecret 으로 pull 합니다.

> **실측 검증 절차**는 [`../../nks-deploy-flow.md`](../../nks-deploy-flow.md) 5절, 자동화 스크립트는
> `nks/scripts/04-install-argocd.sh` 를 참고하세요. 이 디렉터리는 그 매니페스트 스캐폴드입니다.

## 구성 파일

| 파일 | 역할 | 적용 시점 |
|---|---|---|
| `namespace.yaml` | `argocd` 네임스페이스 | 부트스트랩 1회 |
| `../projects/appproject-*.yaml` | env AppProject(acme-dev/test/prd, prd 수동 sync) | 부트스트랩 1회 |
| `argocd-rbac-cm.yaml` | RBAC(developer=dev/test sync, releasemgr=prd sync, 그 외 readonly) | 부트스트랩 1회 |
| `values-argocd.yaml` | (선택) argo-cd Helm 차트 설치 시 values(`server.insecure` 등). upstream `install.yaml` 로 설치하면 불필요 | ArgoCD 설치 |
| `repo-secret.yaml` | config-repo(Gitea) 접근 repo Secret 템플릿 — **HTTPS + `insecure: "true"`** | 부트스트랩 1회 |
| `app-of-apps.yaml` | (선택) env Application 들을 GitOps 로 자기관리하는 app-of-apps | 부트스트랩 1회 |

## 설치 순서

```bash
# 1) 네임스페이스 + ArgoCD 설치
#    (a) upstream install.yaml (검증된 기본 경로 — NKS egress 로 공개 이미지 직접 pull)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
#    CRD 크기 이슈 시: 위 명령을 --server-side 로 1회 더
#    (b) 또는 argo-cd Helm 차트로 설치하고 values-argocd.yaml 적용:
#        helm upgrade --install argocd argo/argo-cd -n argocd -f values-argocd.yaml
#    ArgoCD/모니터링/ingress 는 ops 노드 배치: nodeSelector env=ops (helm) 또는 patch(install.yaml).

# 2) config-repo(Gitea) 등록 — 직접 HTTPS, self-signed → insecure
#    repo-secret.yaml 을 채워 apply (또는 명령으로 주입):
kubectl apply -f repo-secret.yaml
#    핵심: url=https://<GITEA_IP>/admin/config-repo.git, username/password, insecure: "true"

# 3) env AppProject + RBAC + 로컬 계정
kubectl apply -f ../projects/     # env AppProjects (acme-dev/test/prd; <GITEA_REPO_URL> 치환 후)
kubectl apply -f argocd-rbac-cm.yaml                                   # RBAC 정책
kubectl -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"accounts.developer":"apiKey,login","accounts.releasemgr":"apiKey,login"}}'   # 로컬 계정
kubectl -n argocd rollout restart deploy/argocd-server                 # 계정/정책 반영
# 비번 설정: argocd account update-password --account developer|releasemgr --new-password '<...>'

# 4) env Application(dev/test/prd) — targetRevision=<env 브랜치>, path=apps/test-app
#    prd 는 syncPolicy.automated 미설정(=수동 승인). app-of-apps.yaml 로 자기관리하거나 직접 apply.
kubectl apply -f app-of-apps.yaml
```

## 필요 사항 / 주의

- **네트워크(★)**: `NKS 노드 CIDR(<NKS_NODE_CIDR>) → gitea:443` SG 인바운드 허용(config-repo HTTPS watch).
  NAT 미사용이라 파드→Gitea 는 노드 IP 로 SNAT → 출발지 = 노드 서브넷. **git-SSH 2222 는 NKS 에서 도달
  불가** → 반드시 **443(HTTPS)** 로 등록. ArgoCD 는 config-repo 만 sourceRepos 로 허용.
- **NCR pull**: 앱 네임스페이스(`acme-app-<env>`)에 `ncr-cred` **docker-registry imagePullSecret** 생성,
  각 Deployment 에 `imagePullSecrets: [{name: ncr-cred}]`. (별도 IAM/IRSA 없음 — basic auth.)
- **Gitea 자체서명**: HTTPS 로 감시하므로 repo Secret 에 `insecure: "true"` 필수(self-signed 우회).
  누락 시 `x509: certificate signed by unknown authority`. 운영 전 사설 CA 신뢰/정식 인증서 권장.
- **노드 배치**: ArgoCD 는 `env=ops` 노드(taint 없음)에 `nodeSelector env=ops` 로 배치. dev/test/prd
  노드는 `env=<e>:NoSchedule` taint 로 앱 전용.
- **GUI 없이 운영**: `kubectl -n argocd ...` / `argocd` CLI(포트포워드 또는 Ingress) 로. 최초 admin 비번:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- **prd**: prd Application 은 automated 미설정 → ArgoCD 에서 **수동 Sync 승인**(releasemgr).
