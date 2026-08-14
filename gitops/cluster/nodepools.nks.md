# NHN Cloud NKS 노드풀 사양 (테스트 최소 구성)

이 클러스터는 **NHN Cloud NKS**(NHN Kubernetes Service)로 만든다. 테스트 목적의 **3 노드풀 = 3 노드**
최소 구성이며, 각 노드풀은 역할이 다르다. NKS 는 eksctl 이 없으므로 **콘솔(또는 NKS API/Terraform)**
로 노드풀을 만들고, 아래 label/taint 를 건다. (EKS 용 `nodegroups.eksctl.yaml` 은 참고용 레거시)

## 노드풀 사양

| 노드풀 | 역할 | vCPU | Mem | Storage(블록·루트) | NKS 플레이버(예상) |
|---|---|---:|---:|---:|---|
| `acme-infra` | ArgoCD + 관측(Prometheus/Grafana) + ingress | **2** | **8 GB** | **50 GB** | `m2.c2m8` |
| `acme-dev`   | dev 환경 앱(sample-app frontend+backend)      | **2** | **4 GB** | **50 GB** | `m2.c2m4` |
| `acme-prd`   | prod 환경 앱                                   | **2** | **4 GB** | **50 GB** | `m2.c2m4` |

**합계: 6 vCPU / 16 GB / 150 GB** · 각 노드풀 노드 수 = 1 (테스트).

> - **플레이버 이름은 리전/세대별로 다를 수 있으니** NKS 콘솔의 "노드 사양" 목록에서 실제 이름을 확인할 것.
>   NHN 플레이버는 OpenStack 표기(`m2.c<코어>m<메모리>`) — `m2.c2m8`=2코어·8GB, `m2.c2m4`=2코어·4GB.
> - **1 vCPU / 2GB 는 금지.** NKS 워커는 kubelet·CNI·kube-proxy·CoreDNS 등 시스템 예약으로 노드당
>   ~0.5~1 vCPU, ~1~1.5GB 를 먼저 잡아먹어, 2GB 노드는 앱을 거의 못 띄운다. 최소 바닥 = 2 vCPU / 4GB.
> - **Storage** 는 워커의 블록스토리지(Cinder) **루트디스크**. `acme-infra` 는 ArgoCD/관측/이미지 캐시로
>   소모가 크니 50GB 권장. dev/prd 는 30GB 도 되지만 이미지 churn 고려해 50GB 로 통일.

### 루트 스토리지 타입/크기

- **타입 = 일반 SSD**(General SSD). 루트디스크엔 `/var/lib/containerd`(이미지 레이어·writable layer),
  pod ephemeral(emptyDir), 로그가 올라가 **이미지 pull/전개 + pod I/O** 가 잦다 → SSD 권장(HDD 지양).
  - NHN 블록스토리지 타입은 대체로 **일반 SSD / 일반 HDD**(리전/세대별 고성능 옵션 존재 가능).
    노드풀 생성 화면의 "노드 디스크 타입/크기"에서 실제 선택지와 **최소 크기 하한**을 확인할 것.
- **크기 = 노드당 50GB**(3노드 공통). OS + 컨테이너 이미지/런타임 + 로그 + ephemeral 여유.
- **관측 데이터는 루트디스크에 두지 않는다.** Prometheus TSDB/Grafana 는 **별도 PVC(블록스토리지)** 로 뺀다:
  emptyDir(노드 루트)에 두면 pod 재시작·노드 교체 시 메트릭 소실 + 루트디스크 잠식.
  - NKS 기본 CSI StorageClass 로: **Prometheus ~20~30GB(SSD), Grafana ~5GB(SSD)** PVC 프로비저닝.
  - 따라서 `acme-infra` 루트도 50GB 로 고정하고, 관측 보존량은 PVC 크기로 조절한다.

## 왜 이 사이징인가

- **`acme-infra` 만 8GB**: "자원 관측 + 배포 컴포넌트"를 이 노드에 몰았다.
  - ArgoCD 풀스택(server/repo-server/application-controller/redis) 실사용 ~2GB.
  - **관측 스택(B안 확정): Prometheus + Grafana** — Prometheus 하나가 2GB+ 를 쓴다. 시스템 예약(~1.3GB)
    까지 감안하면 4GB 로는 불가 → **8GB 필요**.
  - (참고) 관측을 metrics-server 수준으로만 둘 거면 이 노드도 4GB 로 낮출 수 있으나, 본 구성은 B안.
- **dev/prd 2 vCPU/4GB**: 배포 대상이 sample-app(frontend+backend) 2 컴포넌트라 시스템 예약 후 충분.

## 노드풀 label / taint (환경 격리)

노드풀 생성 시 **label 을 미리 지정**하면 helm 의 `nodeSelector` 매칭에 바로 쓰인다. taint 는 노드풀에서
지원하면 함께 걸고, 지원하지 않는 버전이면 [`node-taints.sh`](node-taints.sh) 로 적용한다.

| 노드풀 | label | taint | 올라갈 것 |
|---|---|---|---|
| `acme-infra` | `role=infra` | `role=infra:NoSchedule` | ArgoCD(`argocd` ns), 관측(`monitoring` ns), ingress |
| `acme-dev`   | `env=dev`    | `env=dev:NoSchedule`     | `acme-app-dev` ns 앱 |
| `acme-prd`   | `env=prd`    | `env=prd:NoSchedule`     | `acme-app-prd` ns 앱 |

- **label** → helm `nodeSelector`(env=dev/prd) 및 infra 워크로드의 `nodeSelector: {role: infra}` 매칭.
- **taint** → 해당 노드엔 대응 `toleration` 을 가진 pod 만 스케줄(다른 환경 pod 배제).
  - infra 워크로드(ArgoCD/관측)는 `role=infra` toleration + `nodeSelector role=infra` 를 갖도록 설정.
  - dev/prd 앱은 helm values 의 `tolerations`/`nodeSelector`(env) 로 이미 처리(values-<env>.yaml 참고).

## 스테이징(stg) 관련

기존 gitops 는 dev/stg/prd 3환경 스캐폴드지만, **이 테스트 클러스터는 infra/dev/prod 3노드라 stg 는
스케줄 대상이 아니다.** `values-stg.yaml` / `application-stg.yaml` / stg 네임스페이스 정의는 **그대로 두되
이 클러스터엔 배포하지 않는다**(stg 노드풀이 없어 `env=stg` toleration pod 는 Pending 이 됨).

## 생성 순서(요약)

1. NKS 콘솔에서 클러스터 생성(관리형 컨트롤플레인).
2. 위 표대로 노드풀 3개 생성(플레이버·디스크·label 지정, 가능하면 taint 도).
3. taint 미지원 시: `./node-taints.sh` 로 label+taint 적용(멱등).
4. 네임스페이스: [`namespaces.yaml`](namespaces.yaml) apply(또는 ArgoCD `CreateNamespace=true`),
   `argocd`/`monitoring` 네임스페이스는 각 설치 차트에서 생성.
5. ArgoCD 설치 → [`../argocd/install/README.md`](../argocd/install/README.md).
