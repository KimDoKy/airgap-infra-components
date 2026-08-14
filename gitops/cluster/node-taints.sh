#!/usr/bin/env bash
# 노드에 role/env label + taint 적용 (멱등). NHN NKS·EKS 공통 폴백.
#   label → helm nodeSelector 매칭 / taint → 대응 toleration 없는 pod 배제(환경 격리)
#
# 권장: 노드풀(NKS)/노드그룹(EKS) 정의에 label·taint 를 선언하면 노드 교체/오토스케일에도 유지된다.
#   - NKS  : 노드풀 생성 시 label 지정(+ 지원 시 taint). 미지원이면 이 스크립트로 taint 적용. (nodepools.nks.md)
#   - EKS  : nodegroups.eksctl.yaml 참고.
# 이 스크립트는 "이미 떠 있는 노드"에 명령형으로 거는 폴백이며, 노드가 바뀌면 다시 실행해야 한다.
set -euo pipefail

# 역할 → 적용할 label/taint key=value (테스트 클러스터: infra/dev/prd 3노드)
declare -A ROLE_KV=( [infra]="role=infra" [dev]="env=dev" [prd]="env=prd" )
# 노드 선택: (label) 이미 걸린 label 로 선택 / 못 찾으면 (name) 노드풀명 접두어로 폴백 선택
SELECT_BY="${SELECT_BY:-label}"
declare -A POOL_PREFIX=( [infra]="acme-infra" [dev]="acme-dev" [prd]="acme-prd" )

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
    kubectl taint "$N" "${key}=${val}:NoSchedule" --overwrite
    echo ">> ${role}: ${N} <- label/taint ${key}=${val}"
  done
}

for R in infra dev prd; do apply "$R"; done
