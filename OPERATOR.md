# 운영자 통합 매뉴얼 (Operator)

구축 완료된 인프라의 **일상 운영**(계정·저장소·배포·모니터링·백업·게이트). 각 서비스 상세는 `ADMIN.md`,
클러스터는 `nks/`·`gitops/` 참조.

## 접속 (GUI)

- **VM(Gitea/Jenkins/Nexus)**: 로컬에서 SSH 터널로 브라우저 접근(잘 안 쓰는 포트). `tools/gui/gui-up.sh`
  → `https://localhost:46173`(Gitea)·`46271`(Jenkins)·`46379`(Nexus). 상세: [`tools/gui/README.md`](tools/gui/README.md).
- **NKS 운영(온콜)**: Ingress + 공인 LB(`<LB_IP>`), 자체서명 TLS.
  - Grafana `https://grafana.<LB_IP>.nip.io` (자체 로그인)
  - Prometheus `https://prometheus.<LB_IP>.nip.io` (basic-auth: `oncall`)
  - ArgoCD `https://argocd.<LB_IP>.nip.io` (admin/RBAC 계정)
  - `<LB_IP>` 확인: `kubectl get svc -n ingress-nginx ingress-nginx-controller`

## 서비스별 운영

| 서비스 | 주요 운영 | 문서 |
|---|---|---|
| Gitea | 사용자 온보딩(SSH 키 추가), 저장소 생성/권한, 백업 | [`GitServer/ADMIN.md`](GitServer/ADMIN.md) |
| Nexus | 계정(ci) 조회/생성/비번, 저장소 점검, 패키지 적재 | [`Nexus/ADMIN.md`](Nexus/ADMIN.md) |
| Jenkins | Job/자격/플러그인 관리, 빌드 확인 | [`Jenkins/ADMIN.md`](Jenkins/ADMIN.md) |

- Nexus 패키지 적재(폐쇄망, bastion 경유): [`Nexus/Test.md`](Nexus/Test.md).
- Jenkins CI 동작 확인(폴링→빌드→NCR→config-repo): [`Jenkins/test/test.md`](Jenkins/test/test.md).

## 배포 운영 (GitOps / ArgoCD)

**흐름**: 개발자 push → Jenkins 빌드 → NCR → **config-repo `dev` 브랜치** → ArgoCD dev **자동배포**.
test/prd 는 **승격**으로 올린다.

```bash
# 상태
kubectl get applications -n argocd
# 승격: 대상 env 브랜치에 이미지 태그 반영(dev→test→prd)
CONFIG_REPO_URL=acme-gitea:admin/config-repo.git ./tools/promote-image.sh test <TAG>
CONFIG_REPO_URL=acme-gitea:admin/config-repo.git ./tools/promote-image.sh prd  <TAG>
```
- **prd 는 수동 게이트**: 승격(태그 반영) 후 ArgoCD 에서 **수동 Sync**(release-manager 권한).
  - CLI: `argocd app sync test-app-prd` / UI: prd 앱 → Sync.
- prd 승격 권한(3중 게이트): (a) config-repo `prd` 브랜치 보호(직접 push=릴리스만/PR+승인),
  (b) ArgoCD RBAC(`releasemgr` 만 prd sync), (c) prd Application 수동 Sync.

**RBAC 계정**: `developer`(dev/test sync), `releasemgr`(prd 포함). 비번 변경:
`argocd account update-password --account <name> --new-password '<...>'`. 정책: [`gitops/argocd/install/argocd-rbac-cm.yaml`].

## 모니터링 / 온콜

- Grafana 대시보드(Prometheus 데이터소스 연동)로 대응. node-exporter(전 노드)·kube-state-metrics.
- Prometheus UI 는 basic-auth 뒤. 구성/재현: [`gitops/monitoring/README.md`](gitops/monitoring/README.md).
- 알림(Alertmanager)은 기본 비활성 — 필요 시 활성화 후 수신경로 구성.

## 노드/스케줄

- taint 는 **앱 배포 격리 전용**(dev/test/prd `NoSchedule`). ops 는 taint 없음(ArgoCD·모니터링·시스템).
- 노드 추가/교체 시 라벨/taint 재적용: `nks/scripts/01-label-taint-nodes.sh`. 사양: [`gitops/cluster/nodepools.nks.md`].

## 백업 / 업그레이드

- Gitea/Nexus/Jenkins: 각 `ADMIN.md` 의 백업 절(데이터 볼륨·설정). 이미지 태그 업그레이드는 `.env` 변경 후
  `01→02→03→(재)start` 재수행.
- ArgoCD/모니터링/ingress: helm 릴리스(`kps`,`argocd`,`ingress-nginx`) — 값 변경 후 `helm upgrade`.

## 장애 대응 빠른 참조

| 증상 | 확인/조치 |
|---|---|
| ArgoCD 앱 `Unknown/OutOfSync` | repo 도달(Gitea SG 노드CIDR→443), `insecure` repo, 수동 Sync 필요 여부 |
| 이미지 `ImagePullBackOff` | 네임스페이스 `ncr-cred` 유무, 레지스트리(kr1) 정확성 |
| 앱 파드 `Pending` | env taint 대응 `nodeSelector/tolerations`, 해당 env 노드 유무 |
| Jenkins 플러그인 미로드 | 코어≥2.504.3, plugins 넣고 **재기동** |
| 시스템 파드 Pending(DNS 등) | ops 노드에 taint 걸지 말 것(무-taint 유지) |

- 사용자 온보딩/개발 흐름: [`USER.md`](USER.md) · 구축 재현: [`BUILDER.md`](BUILDER.md)
