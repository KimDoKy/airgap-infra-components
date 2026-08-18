# 인프라 구축자 통합 매뉴얼 (Builder)

폐쇄망 CI/CD 인프라(GitServer·Nexus·Jenkins) + 클라우드 CD(NKS/ArgoCD)를 **처음부터 순서대로** 구축한다.
각 서비스의 상세는 해당 디렉터리 `BUILD.md`/`MANUAL.md` 를 참조하고, 여기서는 **전체 순서 · 실행 스크립트 ·
정상 출력 확인**을 통합해 제공한다.

> 값(IP/비밀번호)은 각 디렉터리 `.env`(=`.env.example` 복사 후 채움)에만 두고, 아래는 별칭/플레이스홀더로 표기.
> 스크립트 주석의 `[로컬]`=인터넷 되는 작업 PC, `[VM]`=대상 폐쇄망 VM 에서 실행.

## 구축 의존 순서 (요약)

```
0. 사전준비(SSH 별칭·SG·.env)
1. Docker            (모든 VM: GitServer/Nexus/Jenkins VM 각각)
2. GitServer(Gitea)  ─┐  (Jenkins CI 가 clone·config-repo push 대상)
3. Nexus             ─┼─▶ 4. Jenkins(서버+CI 파이프라인)
                      │        (Nexus=npm, Gitea=clone, NCR=push)
5. NKS(ArgoCD/모니터링) ◀── config-repo(Gitea) 필요
6. 보안 게이트(prd 브랜치 보호 + ArgoCD RBAC)
```
- **Docker 가 모든 것의 선행**(각 VM). **GitServer·Nexus 는 Jenkins 파이프라인보다 먼저.**
- **NKS/ArgoCD 는 GitServer(config-repo) 준비 후.** NCR 자격(`Jenkins/.ncr`)은 Jenkins 파이프라인·NKS pull 에 필요.

---

## 0. 사전 준비

1. **SSH 별칭**(`~/.ssh/config`): `acme-bastion`(공인, pem) + `acme-git`/`acme-nexus`/`acme-cicd`
   (각 `ProxyJump acme-bastion`). → `ssh acme-git` 등이 bastion 경유로 접속되면 OK.
2. **SG(보안그룹)**: 초기엔 호스트 간 **22만** 개방. 이후 단계에서 필요한 규칙을 추가(각 BUILD.md/본문 표 참고).
3. **각 서비스 `.env`**: `cp .env.example .env` 후 `VM_SSH_HOST`(별칭)·비밀번호·`TLS_DOMAIN` 등 채움.

---

## 1. Docker 설치 (모든 VM)

`GitServer`/`Nexus`/`Jenkins` **각 VM 마다** 반복. (`Docker/.env` 의 `VM_SSH_HOST` 를 대상 VM 별칭으로 바꿔가며)

```bash
cd Docker
./scripts/01-download.sh          # [로컬] 정적 바이너리 다운로드 → packages/
./scripts/02-transfer-to-vm.sh    # [로컬] VM 으로 전송
ssh <대상VM> 'cd ~/Docker && ./scripts/03-install.sh'   # [VM] 설치(systemd 등록)
# docker 그룹 반영 위해 재로그인 후:
ssh <대상VM> 'cd ~/Docker && ./scripts/04-verify.sh'    # [VM] 검증
```
**정상 확인**: `04-verify.sh` 가 `docker version`(Client+**Server** 모두), `docker compose version` 을 출력.
`docker ps` 가 권한오류 없이 실행되면 그룹 반영 완료. (상세: [`Docker/MANUAL.md`](Docker/MANUAL.md))

---

## 2. GitServer (Gitea) 구축

```bash
cd GitServer
./scripts/00-generate-secrets.sh  # [로컬] SECRET_KEY/INTERNAL_TOKEN 생성(.env 채움, 없으면 05가 자동)
./scripts/01-pull-and-save-image.sh   # [로컬] gitea/nginx 이미지 pull+save (빌드PC=amd64=VM, 플랫폼강제 불필요)
./scripts/02-transfer-to-vm.sh        # [로컬] → VM
# [VM] ssh acme-git; cd ~/GitServer
./scripts/03-load-image.sh
./scripts/04-generate-tls-cert.sh     # 자체서명 TLS
./scripts/05-start.sh                 # compose up + admin 계정 CLI 생성
```
**정상 확인**:
- `docker ps` 에 `gitea`, `gitea-nginx` 두 컨테이너 **Up**.
- `docker exec -u <USER_UID> gitea gitea admin user list` 에 admin(Is Admin=**true**).
- `curl -k https://localhost/ -o /dev/null -w '%{http_code}\n'` → **200**.

이어서 **SSH 게이트웨이**(사용자가 pem 없이 bastion:22 로 clone) 구축 — `gitfwd`(VM)/`gitgw`(bastion) 계정 +
`tunnel_key`. 상세·검증: [`GitServer/BUILD.md`](GitServer/BUILD.md) **3~4절**. 온보딩(키 추가)은 [`GitServer/ADMIN.md`](GitServer/ADMIN.md).

> config-repo·test-app 저장소는 5절(NKS/CI)에서 생성한다(Gitea API 또는 UI).

---

## 3. Nexus 구축

```bash
cd Nexus
./scripts/01-pull-and-save-image.sh   # [로컬]
./scripts/02-transfer-to-vm.sh        # [로컬] → VM
# [VM] ssh acme-nexus; cd ~/Nexus
./scripts/03-load-image.sh
./scripts/04-generate-tls-cert.sh
./scripts/05-start.sh                 # compose up (Nexus 초기 기동은 1~2분 소요)
./scripts/06-configure.sh             # admin 비번 변경 + 익명 차단 + 저장소 생성
```
**정상 확인**:
- `docker ps` 에 `nexus`, `nexus-nginx` **Up**. (초기 기동 대기: `/service/rest/v1/status/writable` 200)
- `06-configure.sh` 후: 익명 접근 차단(`anon http=401`), `raw-hosted`·`npm` 저장소 생성됨.
- `curl -k -u admin:<pw> https://localhost/service/rest/v1/repositories` 에 `raw-hosted`/npm 표시.

패키지 업로드 검증(bastion 경유): [`Nexus/Test.md`](Nexus/Test.md). 계정/저장소 운영: [`Nexus/ADMIN.md`](Nexus/ADMIN.md).

---

## 4. Jenkins (서버 + CI 파이프라인)

### 4-1. Jenkins 서버 기동
```bash
cd Jenkins
./scripts/01-pull-and-save-image.sh   # [로컬] (JENKINS_IMAGE=jenkins/jenkins:2.541.3-lts-jdk17 이상 필수)
./scripts/02-transfer-to-vm.sh        # [로컬] → VM
# [VM] ssh acme-cicd; cd ~/Jenkins
./scripts/03-load-image.sh
./scripts/04-generate-tls-cert.sh
./scripts/05-start.sh                 # 설치마법사 없이 init.groovy 로 admin 생성
```
**정상 확인**: `docker ps` 에 `jenkins`, `jenkins-nginx` **Up**. `curl -k https://localhost/login` → **200**.
> ⚠ 코어 **≥ 2.504.3** 필수(구 2.479.2 는 git/파이프라인 플러그인 미로드). 상세: [`Jenkins/BUILD.md`](Jenkins/BUILD.md) §1 경고.

### 4-2. CI 파이프라인 자산 반입 + 배선
```bash
# [로컬]
pipeline/scripts/10-build-ci-agent-image.sh    # CI 에이전트 이미지(node/docker/git)
pipeline/scripts/11-download-jenkins-plugins.sh # 플러그인(git 포함) 다운로드
pipeline/scripts/12-transfer-pipeline.sh        # pipeline/ + 이미지 + 플러그인 → cicd
# [VM] DooD override 적용 후 재기동 → 플러그인 로드
cp pipeline/docker-compose.override.yml docker-compose.override.yml
docker compose up -d && docker compose restart jenkins   # ★ 재기동해야 플러그인 로드
# NCR 자격 생성(.ncr 기반)
JENKINS_URL=http://localhost:8080 JENKINS_AUTH=admin:<pw> pipeline/scripts/13-create-ncr-credential.sh
```
**정상 확인**: 플러그인 로드 수 > 0
(`curl -s -u admin:<pw> http://localhost:8080/pluginManager/api/json?depth=1 | grep -c shortName`),
`ncr-cred` 자격 생성.

### 4-3. CI 연동 배선 + 검증 (터널·git키·SCM 폴링 잡)
cicd 로컬 터널(gitea `host.docker.internal:2222`, nexus `localhost:8443`), Jenkins git 키 Gitea 등록,
SCM 폴링 잡 생성·실행까지 **hands-on 절차와 정상 출력**은 [`Jenkins/test/test.md`](Jenkins/test/test.md).
**정상 확인(핵심)**: 잡 빌드 로그에 `Started by an SCM change` → `NCR push` → `config-repo(dev) 갱신` → `SUCCESS`.

---

## 5. NKS (ArgoCD / 모니터링 / 외부접근)

> 전제: NKS 클러스터(노드 3+개) 생성 완료, 로컬 `kubectl` 이 해당 컨텍스트, **Gitea SG 인바운드에 NKS 노드
> CIDR → TCP 443** 허용(ArgoCD→config-repo). 상세: [`gitops/nks-deploy-flow.md`](gitops/nks-deploy-flow.md).
>
> **★ 노드 taint 정책(운영 vs 테스트)** — dev/test/prd/**ops 모두** `env=<e>:NoSchedule`:
> - **운영**: taint 는 **NKS 노드그룹 생성 시** 지정(노드 교체·오토스케일에도 유지). `.env` 에
>   **`APPLY_TAINT=false`** → `01-label-taint-nodes.sh` 는 **라벨만** 적용.
> - **테스트**: `APPLY_TAINT=true`(기본) → 스크립트가 dev/test/prd/ops 전부에 taint.
> - **ops = 전용 플랫폼 노드**: ArgoCD/모니터링/Ingress 는 `nodeSelector env=ops` + **`toleration env=ops`** 로 배치.
> - ⚠ ops taint 시 NKS 관리형 애드온이 갈 곳 필요 — CoreDNS·calico-typha·konnectivity 는 all-taint tolerate(OK),
>   `calico-kube-controllers` 처럼 아닌 것은 **untainted 시스템 nodepool** 또는 ops toleration 추가.

```bash
# (사전) config-repo 환경 브랜치 초기화 — Gitea 준비(2절) 후 1회
CONFIG_REPO_URL=acme-gitea:admin/config-repo.git NCR_REGISTRY=<host> \
  ./gitops/config-repo-init.sh

cd nks && cp .env.example .env && vi .env   # 노드 이름/NCR/Gitea/비번/APPLY_TAINT 채움
./scripts/01-label-taint-nodes.sh   # 노드 label + taint (dev/test/prd + ops; 운영은 노드그룹 지정)
./scripts/02-ncr-pull-secret.sh     # 워크로드 ns + NCR imagePullSecret
./scripts/03-install-ingress.sh     # ingress-nginx(LB) → LB 공인 IP(.env 자동기록)
./scripts/04-install-argocd.sh      # ArgoCD(ops) + repo + env AppProject/Application(prd 수동) + RBAC
./scripts/05-install-monitoring.sh  # kube-prometheus-stack(ops)
./scripts/06-expose-monitoring.sh   # Grafana/Prometheus Ingress + TLS
./scripts/07-expose-argocd.sh       # ArgoCD Ingress
./scripts/99-verify.sh              # 통합 검증
```
**정상 확인**(`99-verify.sh`):
- 노드: dev/prd/ops 모두 `env=<e>:NoSchedule` taint. 플랫폼은 ops toleration 으로 ops 배치. 앱 파드가 각 env 노드에 배치.
- ArgoCD Applications `Synced/Healthy`(prd 는 자동 아님=수동). node-exporter DS `3/3`.
- Ingress LB 공인 IP + `https://grafana.<LB>.nip.io` / `.../prometheus...` / `.../argocd...`.

---

## 6. 보안 게이트 (prd 릴리스)

```bash
# prd 브랜치 보호(직접 push=릴리스만, 그 외 PR+승인)
GITEA_URL=https://localhost GITEA_AUTH=admin:<pw> GITEA_CACERT=certs/server.crt \
  REPO=admin/config-repo ./tools/gitea-protect-prd.sh        # (Gitea VM 에서)
# ArgoCD RBAC 은 nks/scripts/04 가 적용(developer=dev/test, releasemgr=prd). 계정 비번:
argocd account update-password --account developer  --new-password '<...>'
argocd account update-password --account releasemgr --new-password '<...>'
```
**정상 확인**: prd 브랜치 보호 `http=201/200`. developer 로 prd sync 시 **permission denied**, releasemgr 는 허용.

---

## 최종 점검 체크리스트

| # | 확인 | 기대 |
|---|---|---|
| 1 | 각 VM `docker version` | Client+Server |
| 2 | Gitea/Nexus/Jenkins 웹 | `https://localhost/...` 200 (VM 로컬) |
| 3 | Jenkins 잡 1회 | SUCCESS, NCR push, config-repo(dev) 갱신 |
| 4 | `nks/scripts/99-verify.sh` | 노드격리·ArgoCD Synced·모니터링·Ingress |
| 5 | prd 게이트 | 브랜치 보호 + RBAC(developer prd 거부) |

- 운영 인수: [`OPERATOR.md`](OPERATOR.md) · 사용자 온보딩: [`USER.md`](USER.md)
- 아키텍처 전반: [`ARCHITECTURE.md`](ARCHITECTURE.md)
