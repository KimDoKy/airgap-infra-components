#!/usr/bin/env bash
# [명령형 폴백] 이미 떠 있는 노드에 env label+taint 를 수동 적용. **권장은 nodegroups.eksctl.yaml**
# (노드그룹 정의에 선언 → 노드 교체/오토스케일에도 유지). 이 스크립트는 노드가 바뀌면 다시 실행해야 함.
#   label → helm 의 nodeSelector 매칭 / taint → 다른 env pod 배제(toleration 없으면 스케줄 불가)
set -euo pipefail
KEY="${NODE_ENV_LABEL_KEY:-env}"
for ENVV in dev stg prd; do
  for N in $(kubectl get nodes -l "eks.amazonaws.com/nodegroup=acme-eks-${ENVV}" -o name); do
    kubectl label "$N" "${KEY}=${ENVV}" --overwrite
    kubectl taint "$N" "${KEY}=${ENVV}:NoSchedule" --overwrite
  done
done
