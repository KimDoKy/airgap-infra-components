#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# acme GUI 접근 (추가 옵션) — 기존 셋업은 그대로 두고, 브라우저 접근용 터널/포워드만 띄운다.
#   VM 3종(Gitea/Jenkins/Nexus): 로컬 → bastion → VM nginx(localhost:443) SSH 터널 (HTTPS, self-signed)
#   NKS 2종(Grafana/Prometheus): kubectl port-forward (HTTP)
# 공개 노출 없음(전부 127.0.0.1 바인딩). 잘 안 쓰는 포트 사용.
#   로컬에서 실행:  ./gui-up.sh     (끄기: ./gui-down.sh)
# 포트는 아래 환경변수로 재정의 가능.
# ─────────────────────────────────────────────────────────────────────────────
set -u
GITEA_PORT="${GITEA_PORT:-46173}"
JENKINS_PORT="${JENKINS_PORT:-46271}"
NEXUS_PORT="${NEXUS_PORT:-46379}"
GRAFANA_PORT="${GRAFANA_PORT:-46411}"
PROM_PORT="${PROM_PORT:-46533}"
RUN="${ACME_GUI_RUN:-${TMPDIR:-/tmp}/acme-gui}"; mkdir -p "$RUN"

# VM SSH 터널: 127.0.0.1:<port> → (bastion ProxyJump) → VM localhost:443
start_ssh() { # name port ssh-alias
  local n="$1" p="$2" a="$3"
  if ss -tln 2>/dev/null | grep -q "127.0.0.1:$p "; then echo "· $n 이미 $p 리스닝(스킵)"; return; fi
  ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=accept-new -L "127.0.0.1:$p:localhost:443" "$a" \
    && echo "✓ $n   https://localhost:$p   (via $a, self-signed)" \
    || echo "✗ $n   터널 실패 (ssh $a 확인)"
}
# NKS port-forward: 127.0.0.1:<port> → svc. 자동재시작 래퍼(파드 재시작/드롭에도 유지), setsid 로 완전 detach.
start_pf() { # name port svc targetport
  local n="$1" p="$2" svc="$3" tp="$4"
  if ss -tln 2>/dev/null | grep -q "127.0.0.1:$p "; then echo "· $n 이미 $p 리스닝(스킵)"; return; fi
  setsid bash -c "while true; do kubectl -n monitoring port-forward --address 127.0.0.1 'svc/$svc' '$p:$tp' >>'$RUN/$n.log' 2>&1; echo '[restart] '\$(date) >>'$RUN/$n.log'; sleep 2; done" >/dev/null 2>&1 &
  echo $! > "$RUN/$n.pid"
  echo "✓ $n   http://localhost:$p   (svc/$svc)  ← HTTP (https 아님!)"
}

echo "== VM GUI (SSH 터널, HTTPS) =="
start_ssh gitea   "$GITEA_PORT"   acme-git
start_ssh jenkins "$JENKINS_PORT" acme-cicd
start_ssh nexus   "$NEXUS_PORT"   acme-nexus
# 모니터링(Grafana/Prometheus)은 운영 접근 = Ingress(외부·인증) → gitops/monitoring/README.md.
# 로컬 port-forward 는 보조 수단(기본 off). 로컬 접근이 필요하면 GUI_MON_LOCAL=1 로 켠다.
if [ "${GUI_MON_LOCAL:-0}" = "1" ]; then
  echo "== NKS 모니터링 (로컬 port-forward, HTTP — 보조) =="
  start_pf  grafana    "$GRAFANA_PORT" kps-grafana 80
  start_pf  prometheus "$PROM_PORT"    kps-kube-prometheus-stack-prometheus 9090
else
  echo "== NKS 모니터링: 운영 접근은 Ingress 사용(외부·인증). 로컬 포워드는 GUI_MON_LOCAL=1 로 opt-in =="
fi
echo
echo "끄기: $(dirname "$0")/gui-down.sh"
