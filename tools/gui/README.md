# GUI 접근 (추가 옵션)

기존 폐쇄망 셋업(headless, CLI/REST, nginx TLS 사이드카)은 **그대로 유지**한다. 이 도구는 운영자가
브라우저로 각 서비스 UI 를 볼 수 있게 하는 **추가 접근 경로만** 로컬에 띄운다. 서버 구성은 바꾸지 않는다.

> **모니터링(Grafana/Prometheus)의 운영/온콜 접근은 이 로컬 도구가 아니라 Ingress(외부·인증)** 를 쓴다 →
> [`../../gitops/monitoring/README.md`](../../gitops/monitoring/README.md). 여기 로컬 port-forward 는
> 보조 수단이며 기본 off(`GUI_MON_LOCAL=1` 로 opt-in). VM 3종(Gitea/Jenkins/Nexus)은 폐쇄망이라 SSH 터널로 접근.

- **VM 3종(Gitea/Jenkins/Nexus)**: 각 VM 에 이미 있는 nginx 웹 UI(로컬 `443`)로 **SSH 터널**(로컬 → bastion
  ProxyJump → VM `localhost:443`). HTTPS(자체서명 → 브라우저 경고 수락).
- **NKS 2종(Grafana/Prometheus)**: ClusterIP 서비스를 **`kubectl port-forward`** 로 로컬 접속. HTTP.
- 모두 **`127.0.0.1`(로컬 전용) 바인딩** — 공개 노출 없음. **잘 안 쓰는 포트** 사용.

## 사용

```bash
cd infra/tools/gui
./gui-up.sh      # 터널/포워드 기동
./gui-down.sh    # 종료
```
> 전제: 로컬 `~/.ssh/config` 에 `acme-git`/`acme-cicd`/`acme-nexus`(ProxyJump `acme-bastion`) 별칭,
> 그리고 `kubectl` 이 NKS 컨텍스트로 설정돼 있을 것.

## 포트 / URL

| 서비스 | URL | 포트 | 프로토콜 | 경유 |
|---|---|---|---|---|
| Gitea | https://localhost:46173 | 46173 | HTTPS(self-signed) | SSH 터널 → acme-git:443 |
| Jenkins | https://localhost:46271 | 46271 | HTTPS(self-signed) | SSH 터널 → acme-cicd:443 |
| Nexus | https://localhost:46379 | 46379 | HTTPS(self-signed) | SSH 터널 → acme-nexus:443 |
| Grafana | **http**://localhost:46411 | 46411 | **HTTP** | port-forward → svc/kps-grafana:80 |
| Prometheus | **http**://localhost:46533 | 46533 | **HTTP** | port-forward → svc/kps-...-prometheus:9090 |

> ⚠️ **VM 3종은 `https://`, NKS 2종(Grafana/Prometheus)은 `http://` 다.** Grafana/Prometheus 를 `https://`
> 로 열면 TLS 불일치로 접속이 안 된다(브라우저 "연결할 수 없음"). 반드시 `http://localhost:4641x` 로 접속.

포트를 바꾸려면 환경변수로 재정의: `GITEA_PORT=51987 ./gui-up.sh` (JENKINS_PORT/NEXUS_PORT/GRAFANA_PORT/PROM_PORT).

## 로그인

| 서비스 | 계정 | 비밀번호 |
|---|---|---|
| Gitea | `admin` | `<GITEA_ADMIN_PW>` |
| Jenkins | `admin` | `<JENKINS_ADMIN_PW>` |
| Nexus | `admin` (또는 `ci`) | `<ADMIN_PW>` / `<CI_PW>` |
| Grafana | `admin` | `<GRAFANA_PW>` (helm values 의 adminPassword) |
| Prometheus | (인증 없음) | — |

> 자체서명 인증서라 브라우저가 경고를 낸다(계속 진행). Prometheus 는 인증이 없으므로 로컬 포워드로만 접근할 것.

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| Grafana/Prometheus 가 안 열림 | **`https://` 로 접속했을 것.** 이 둘은 **HTTP** → `http://localhost:46411`, `http://localhost:46533` |
| VM(Gitea/Jenkins/Nexus) 가 안 열림 | `https://` 로 접속. `~/.ssh/config` 에 `acme-*` 별칭/ProxyJump 확인, `./gui-up.sh` 재실행 |
| 잠시 뒤 GUI 끊김 | port-forward 는 `gui-up.sh` 가 **자동재시작 래퍼**로 띄운다(파드 재시작에도 복구). 완전 종료는 `./gui-down.sh` |
| `bind: address already in use` | 이미 `gui-up.sh` 로 떠 있음. `./gui-down.sh` 후 재기동 |

## 상시 실행(선택)

`gui-up.sh` 는 세션 종료 후에도 유지되도록 SSH 는 `-f`(백그라운드), port-forward 는 `nohup` 으로 띄운다.
재부팅에도 유지하려면 각 명령을 systemd **user** 서비스로 감싸면 된다(예: `~/.config/systemd/user/acme-gui-gitea.service`).
이 도구는 **로컬 접근 편의**용이며, 서버측 폐쇄망 구성/보안 정책과는 독립적이다.
