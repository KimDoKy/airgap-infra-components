#!/usr/bin/env bash
# [폴백] 이미 떠 있는 노드에 env label + taint 적용 (멱등). ops=라벨만(무-taint), dev/prd=taint(앱 격리).
#   활성 경로는 nks/scripts/01-label-taint-nodes.sh (권장). 이 스크립트는 명령형 폴백 — 노드 교체 시 재실행.
#   NKS: 노드풀 생성 시 label 미리 지정(+ 지원 시 dev/prd taint). (nodepools.nks.md)
#   (참고: gitops/cluster/nodegroups.eksctl.yaml 은 과거 EKS 검토용 레거시.)
set -euo pipefail

# 역할 → 적용할 label/taint key=value (ops=플랫폼(무-taint), dev/prd=앱(taint))
declare -A ROLE_KV=( [ops]="env=ops" [dev]="env=dev" [prd]="env=prd" )
# 노드 선택: (label) 이미 걸린 label 로 선택 / 못 찾으면 (name) 노드풀명 접두어로 폴백 선택
SELECT_BY="${SELECT_BY:-label}"
declare -A POOL_PREFIX=( [ops]="acme-ops" [dev]="acme-dev" [prd]="acme-prd" )

apply() {
  local role="$1" kv="${ROLE_KV[$1]}"
  local key="${kv%%=*}" val="${kv#*=}" nodes=""
  [ "$SELECT_BY" = "label" ] && nodes=$(kubectl get nodes -l "${key}=${val}" -o name 2>/dev/null || true)
  # label 로 못 찾았으면(최초) 노드풀명 접두어로 폴백 선택
  [ -z "$nodes" ] && nodes=$(kubectl get nodes -o name | grep -i "${POOL_PREFIX[$role]}" || true)
  if [ -z "$nodes" ]; then
    echo "!! ${role}: 대상 노드 없음 (label ${key}=${val} / 이름 '${POOL_PREFIX[$role]}' 미매칭). 건너뜀." >&2
    return 0
  fi
  for N in $nodes; do
    kubectl label "$N" "${key}=${val}" --overwrite
    if [ "$role" = "ops" ]; then
      # ops = 플랫폼 노드: 라벨만(taint 없음). 혹시 남은 taint 는 제거.
      kubectl taint "$N" "${key}=${val}:NoSchedule" - >/dev/null 2>&1 || true
      echo ">> ${role}: ${N} <- label ${key}=${val} (taint 없음)"
    else
      kubectl taint "$N" "${key}=${val}:NoSchedule" --overwrite   # 앱 격리
      echo ">> ${role}: ${N} <- label+taint ${key}=${val}"
    fi
  done
}

for R in ops dev prd; do apply "$R"; done
