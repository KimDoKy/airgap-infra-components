# NKS 배포 플로우 검증 (hands-on) — Git → Jenkins → Nexus → NCR → ArgoCD → NKS

폐쇄망 CI(Jenkins on cicd VM)와 클라우드 CD(ArgoCD on NHN NKS)를 잇는 **전체 배포 플로우**를 실제로
구축·검증한 런북. 아래를 순서대로 따라 하면 동일하게 재현된다. (실측 통과: 2026-08-13)

> 비밀번호/키는 `<...>` 플레이스홀더로 표기(평문 금지). NCR 자격은 `Jenkins/.ncr`(레지스트리·access·secret).

## 전체 플로우

```
[Gitea test-app] ──git push──▶ [Jenkins(cicd)] ──빌드 중 Nexus 패키지 다운로드──▶ [Nexus]
       │  (SCM 폴링 자동빌드)          │
       │                              └── 이미지 빌드 → [NCR] push (ee74342f-kr1.../acme-poc/test-app:TAG)
       ▼
[Gitea config-repo] ◀──image tag 커밋── Jenkins
       │
       ▼  (ArgoCD가 Gitea config-repo 를 직접 HTTPS 감시)
[ArgoCD(NKS infra노드)] ──sync──▶ [NKS] dev/prd 노드에 배포 (NCR 에서 pull)
```

- **CI = Jenkins**(빌드·NCR push·config-repo 태그 커밋). **CD = ArgoCD**(config-repo 감시 → NKS 동기화).
- 노드 격리: `role=infra`(8GB, taint 없음 → ArgoCD·모니터링), `env=dev`/`env=prd`(4GB, `NoSchedule` taint).

## 환경 사실 (이 검증 시점)

| 항목 | 값 |
|---|---|
| NKS 노드 | `...default-worker-node-0`(<NKS_NODE_IP>, m2.c2m4)=dev, `...default-worker-node-1`(<NKS_NODE_IP>, m2.c2m4)=prd, `...node-02-node-0`(<NKS_NODE_IP>, r2.c2m8)=infra |
| NKS 노드 서브넷 | `<NKS_NODE_CIDR>` (SG 출발지로 사용) |
| NKS 파드 네트워크 | `<POD_CIDR>` (Calico) |
| NCR 레지스트리 | `<NCR_REGISTRY_HOST>/acme-poc` (**kr1**) |
| Gitea | `<GITEA_IP>` (nginx 443, git-ssh 2222) |
| bastion | 공인 `<BASTION_PUBLIC_IP>` / 사설 `<BASTION_PRIVATE_IP>` |
| cicd(Jenkins) | `<CICD_IP>` |

---

## ★ Security Group(SG) 설정 — 이 플로우의 핵심 전제

폐쇄망 POC VM 망(`<POC_VM_SUBNET>`)과 클라우드 NKS(`<NKS_NODE_SUBNET>`)는 서로 다른 네트워크다. 기본적으로
NKS ↔ POC 는 **단절**되어 있고 NKS 는 **인터넷 egress 만** 가능하다(그래서 NCR pull 은 되지만 Gitea 는
안 됨). ArgoCD(NKS)가 Gitea config-repo 를 감시하려면 아래 SG 인바운드 1건이 필요하다.

### (채택) NKS 노드 CIDR → Gitea SG 인바운드 허용  ← NAT 미사용 환경

| 대상 SG | 방향 | 프로토콜/포트 | 출발지(Source) | 용도 |
|---|---|---|---|---|
| **Gitea VM 의 SG** | Ingress | TCP **443** | **`<NKS_NODE_CIDR>`** (NKS 노드 서브넷) | ArgoCD → Gitea(config-repo) HTTPS |

- NAT 게이트웨이를 쓰지 않으므로 파드→Gitea 트래픽은 **노드 IP 로 SNAT** 되어 나간다 → 출발지 = **노드 CIDR**.
  따라서 Gitea SG 에 **NKS 노드 서브넷(`<NKS_NODE_CIDR>`)** 을 열면 NKS→Gitea:443 직접 도달이 된다.
- **공인 노출 없음**(사설망 내 통신). git-ssh(2222)는 불필요(HTTPS 로 clone) — 443만 열면 됨.
- 확인: NKS 파드에서 `nc -z -w5 <GITEA_IP> 443` → OK.

> **참고: NCR 방향은 SG 작업 불필요.** NKS→NCR(`...container.nhncloud.com:443`)은 인터넷 egress 로 도달
> (`nc -z ... 443` OK). cicd→NCR push 도 egress 로 됨.

> **(대안, 미채택) bastion 공인 브리지**: NAT 를 써서 NKS egress 가 단일 공인 IP 라면, bastion SG 에
> `그 IP/32 → bastion:PORT` 인바운드를 열고 bastion 에서 `ssh -L 0.0.0.0:PORT:localhost:443 gitea` 포워드
> 후 ArgoCD 가 `https://<bastion공인>:PORT`(insecure)로 접근하는 방법도 있다. 본 검증에선 노드 CIDR 직접
> 방식이 더 깔끔해 채택하지 않았고, 임시로 만들었던 bastion 브리지/키는 제거했다.

---

## 1. NKS 노드 라벨 + taint (환경 격리)

```bash
# 8GB=infra(라벨만, taint 없음 → 시스템 애드온/ArgoCD/모니터링 수용), 4GB×2=dev/prd(NoSchedule)
kubectl label node <infra-node> role=infra --overwrite
kubectl label node <dev-node>   env=dev   --overwrite
kubectl label node <prd-node>   env=prd   --overwrite
kubectl taint node <dev-node> env=dev:NoSchedule --overwrite
kubectl taint node <prd-node> env=prd:NoSchedule --overwrite
```
> **infra 노드는 taint 를 걸지 않는다.** NKS 관리형 시스템 애드온(CoreDNS·calico-typha·konnectivity 등)이
> 워커에 떠 있어, 3노드 전부 `NoSchedule` 로 막으면 재스케줄 시 갈 곳이 없어 DNS 등이 깨질 수 있다.
> dev/prd 만 taint 하면, taint 없는 infra 로 시스템 파드·ArgoCD·모니터링이 자연히 모인다.

## 2. Jenkins — NCR 자격증명 + 파이프라인(build → NCR push → config-repo 갱신)

### 2-1. NCR 자격증명 등록 (`ncr-cred`, usernamePassword)
`Jenkins/.ncr` 의 access/secret 으로 Jenkins Credentials 를 만든다(Script Console). username=access key,
password=secret key, id=`ncr-cred`.

```groovy
// Manage Jenkins → Script Console (또는 REST /scriptText)
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
def store = SystemCredentialsProvider.getInstance().getStore(); def dom = Domain.global()
store.getCredentials(dom).findAll{ it.id == "ncr-cred" }.each { store.removeCredentials(dom, it) }
store.addCredentials(dom, new UsernamePasswordCredentialsImpl(
  CredentialsScope.GLOBAL, "ncr-cred", "NHN NCR (kr1) push", "<NCR_ACCESS_KEY>", "<NCR_SECRET_KEY>"))
```

### 2-2. 빌드 스크립트 `ci-build-ncr.sh` (jenkins_home 에 배치)
빌드(중 Nexus 패키지 다운로드) → NCR push → config-repo 의 **dev·prd deployment 이미지 태그** 갱신.
파일: [`../Jenkins/test/ci-build-ncr.sh`](../Jenkins/test/ci-build-ncr.sh). 핵심:

```bash
TAG=b${BUILD_NUMBER}-$(git rev-parse --short HEAD)
IMG=<NCR_REGISTRY_HOST>/acme-poc/test-app
docker build --no-cache --network host --build-arg NEXUS_URL=https://localhost:8443 \
  --build-arg NEXUS_AUTH_B64=$(printf 'ci:%s' "$NEXUS_PW" | base64 | tr -d '\n') -t "$IMG:$TAG" .
echo "$NCR_PSW" | docker login "$REG" -u "$NCR_USR" --password-stdin && docker push "$IMG:$TAG"
# config-repo 클론 후 dev·prd 양쪽 deployment 이미지 갱신 → commit/push
sed -i "s|image: .*/acme-poc/test-app:.*|image: ${IMG}:${TAG}|" \
  apps/test-app/deployment.yaml apps/test-app-prd/deployment.yaml
```

### 2-3. 잡(Freestyle, Git SCM + 폴링) — `ncr-cred` 바인딩
- SCM: `ssh://git@host.docker.internal:2222/admin/test-app.git`(cicd 의 gitea-tunnel), 폴링 `* * * * *`.
- 빌드 환경: `NEXUS_PW` 주입 + **credentials-binding** 으로 `ncr-cred` → `NCR_USR`/`NCR_PSW`.
- 잡 정의: [`../Jenkins/test/job-config-ncr.xml`](../Jenkins/test/job-config-ncr.xml).
- REST `createItem` 으로 만든 잡은 **SCMTrigger 를 수동 start** 해야 폴링이 돈다(Script Console `t.start(job,true)`).

> 상세·함정은 [`../Jenkins/test/test.md`](../Jenkins/test/test.md)(폴링·플러그인) 참고.

## 3. NKS — NCR imagePullSecret + 네임스페이스

```bash
for E in dev prd; do
  kubectl create namespace acme-app-$E --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ncr-cred \
    --docker-server=<NCR_REGISTRY_HOST> \
    --docker-username='<NCR_ACCESS_KEY>' --docker-password='<NCR_SECRET_KEY>' \
    -n acme-app-$E --dry-run=client -o yaml | kubectl apply -f -
done
```
- 각 Deployment 는 `imagePullSecrets: [{name: ncr-cred}]` + `nodeSelector {env: <e>}` + `tolerations env=<e>`.

## 4. config-repo 구조 — **환경별 브랜치**(ArgoCD 감시 대상, Gitea)

환경별로 **브랜치를 분리**한다. 각 env 브랜치는 동일 경로 `apps/test-app/` 에 그 환경용 매니페스트를 갖는다.

```
config-repo (branches)
├── dev   : apps/test-app/{deployment,service}.yaml  (ns=acme-app-dev,  env=dev)
├── test  : apps/test-app/{deployment,service}.yaml  (ns=acme-app-test, env=test)
├── prd   : apps/test-app/{deployment,service}.yaml  (ns=acme-app-prd,  env=prd)
└── main  : README(브랜치 모델 문서) — 배포 대상 아님
```
- ArgoCD Application: `targetRevision=<env 브랜치>`, `path=apps/test-app`. dev/test 자동, **prd 수동 승인**.
- **CI(Jenkins)** 는 **dev 브랜치**의 `apps/test-app/deployment.yaml` 이미지 태그만 갱신 → dev 자동배포.
- **승격(dev→test→prd)**: 브랜치별 ns/env 가 달라 git merge 대신 **이미지 태그만 반영**한다
  (헬퍼: [`../tools/promote-image.sh`](../tools/promote-image.sh)). prd 는 반영 후 ArgoCD 수동 Sync.

## 5. ArgoCD 설치 + repo + Application (dev/prd)

### 5-1. 설치 (infra 노드에 자동 배치 — taint 없는 유일 노드)
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# CRD 크기 이슈 시: 위 명령을 --server-side 로 1회 더
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d   # admin 초기비번
```

### 5-2. Gitea repo 등록 (직접 HTTPS, self-signed → insecure)
```yaml
apiVersion: v1
kind: Secret
metadata: { name: config-repo, namespace: argocd, labels: { argocd.argoproj.io/secret-type: repository } }
stringData:
  type: git
  url: https://<GITEA_IP>/admin/config-repo.git
  username: admin
  password: <GITEA_ADMIN_PW>
  insecure: "true"        # Gitea 자체서명 인증서
```
> `insecure: "true"` 는 self-signed 우회(사설/테스트). 운영 전 사설 CA 신뢰 또는 정식 인증서 권장.

### 5-3. Application 2개 (dev/prd) — 자동 동기화
```yaml
# dev (prd 는 name=test-app-prd, path=apps/test-app-prd, namespace=acme-app-prd 로 동일 구조)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: test-app, namespace: argocd }
spec:
  project: default
  source: { repoURL: https://<GITEA_IP>/admin/config-repo.git, targetRevision: main, path: apps/test-app, directory: { recurse: true } }
  destination: { server: https://kubernetes.default.svc, namespace: acme-app-dev }
  syncPolicy: { automated: { prune: true, selfHeal: true }, syncOptions: [ CreateNamespace=true ] }
```

## 6. 모니터링 (Prometheus + Grafana) — infra 노드 고정

kube-prometheus-stack(helm)을 `monitoring` ns 에 설치. prometheus/grafana/kube-state-metrics/operator 는
`nodeSelector role=infra`, **node-exporter(DaemonSet)는 전 노드 커버 위해 `tolerations: [{operator: Exists}]`**.
alertmanager 비활성·저자원. 기본 StorageClass 없어 Prometheus 는 emptyDir(테스트). values: [`../gitops/monitoring/values.yaml`](monitoring/values.yaml).

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring/values.yaml
# 접근(포트포워드): kubectl -n monitoring port-forward svc/kps-grafana 3000:80  (admin/<GRAFANA_PW>)
#                  kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
```

---

## 검증 결과 요약 (실측)

| 단계 | 확인 | 기대/결과 |
|---|---|---|
| SG | NKS 파드 → `<GITEA_IP>:443` | 도달 OK(노드 CIDR 허용 후) |
| CI | test-app push → Jenkins 폴링 빌드 | `Started by an SCM change`, SUCCESS |
| NCR | 빌드 로그 `docker push ...test-app:b<N>-<sha>` | `digest: sha256:...` |
| config-repo | dev·prd deployment `image:` | 새 태그로 커밋 |
| ArgoCD | `kubectl get app -n argocd` | dev/prd 모두 **Synced/Healthy** |
| **노드 격리** | dev 앱→dev 노드(env=dev), prd 앱→prd 노드(env=prd) | ✅ 각 env 노드에 정확히 배치 |
| 서빙 | `curl http://test-app`(각 ns) | `acme build dependency payload...`(Nexus 패키지) |
| 모니터링 | grafana/prometheus/ksm/operator=infra, node-exporter=3/3 | Prometheus 타깃 up, Grafana health 200 |

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| ArgoCD repo `Unable to connect`/timeout | Gitea SG 에 NKS 노드 CIDR(443) 미허용. 위 SG 표 참고. 파드에서 `nc -z <GITEA_IP> 443` 확인 |
| ArgoCD repo `x509: certificate signed by unknown authority` | repo secret `insecure: "true"` 누락(Gitea self-signed) |
| 파드 `ImagePullBackOff`(NCR) | 네임스페이스에 `ncr-cred` imagePullSecret 없음 / 레지스트리 오타(fr1 아님, **kr1**) |
| Jenkins 빌드 Nexus `401` | 잡 `NEXUS_PW` 미설정/오설정(placeholder 치환 실패). ci 자격 확인 |
| 앱 파드 `Pending` | env taint 대응 `tolerations`/`nodeSelector` 누락, 또는 해당 env 노드 없음 |
| node-exporter 일부 노드 누락 | DaemonSet `tolerations: [{operator: Exists}]` 없어 dev/prd(taint) 미배치 |
| CoreDNS 등 시스템 파드 Pending | infra 노드까지 `NoSchedule` taint 를 걸어버림 → infra 는 taint 금지 |
