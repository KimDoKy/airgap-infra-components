#!/usr/bin/env bash
# acme GUI 접근 종료 — gui-up.sh 로 띄운 SSH 터널/포워드를 정리한다.
set -u
GITEA_PORT="${GITEA_PORT:-46173}"
JENKINS_PORT="${JENKINS_PORT:-46271}"
NEXUS_PORT="${NEXUS_PORT:-46379}"
GRAFANA_PORT="${GRAFANA_PORT:-46411}"
PROM_PORT="${PROM_PORT:-46533}"
RUN="${ACME_GUI_RUN:-${TMPDIR:-/tmp}/acme-gui}"

# SSH 터널: 해당 로컬포트 포워드 프로세스만 종료(패턴이 argv 에 없어 자기 자신 매치 안 됨)
for p in "$GITEA_PORT" "$JENKINS_PORT" "$NEXUS_PORT"; do
  pkill -f "127.0.0.1:$p:localhost:443" 2>/dev/null && echo "✓ SSH 터널 종료 :$p" || echo "· :$p 없음"
done
# port-forward: 래퍼 루프(pidfile) + 실제 kubectl(포트패턴) 모두 종료
for pair in "grafana:$GRAFANA_PORT" "prometheus:$PROM_PORT"; do
  n="${pair%%:*}"; p="${pair##*:}"
  [ -f "$RUN/$n.pid" ] && { kill "$(cat "$RUN/$n.pid")" 2>/dev/null; rm -f "$RUN/$n.pid"; }
  pkill -f "port-forward --address 127.0.0.1 svc/.* $p:" 2>/dev/null && echo "✓ port-forward 종료 $n :$p" || echo "· $n :$p 없음"
done
