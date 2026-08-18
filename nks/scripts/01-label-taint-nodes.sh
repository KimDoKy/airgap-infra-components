#!/usr/bin/env bash
# [로컬/kubectl] 노드에 환경 label (+ 테스트 시 taint) 적용. 멱등.
#   taint 목적 = **앱 배포 격리 전용**(dev/test/prd). ops 는 항상 **라벨만**(taint 없음).
#   ★ taint 적용 주체(APPLY_TAINT):
#     - 테스트(기본, APPLY_TAINT=true): 이 스크립트가 dev/test/prd 에 env=<e>:NoSchedule taint 를 건다.
#     - 운영(APPLY_TAINT=false): taint 는 **NKS 노드그룹 생성 시** 지정한다(노드 교체/오토스케일에도 유지).
#       이 경우 스크립트는 **라벨만** 적용(taint 미적용). 노드그룹 taint = dev/test/prd `env=<e>:NoSchedule`, ops 없음.
#   label env=<e> → 앱/플랫폼 nodeSelector 매칭 / taint env=<e>:NoSchedule → 대응 toleration 없는 pod 배제.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
: "${APPLY_TAINT:=true}"   # 테스트=true(스크립트 taint), 운영=false(노드그룹 생성 시 taint)

echo ">> 컨텍스트: $(kctx)  (APPLY_TAINT=${APPLY_TAINT})"
apply_one() {  # env node
  local e="$1" n="$2"
  kubectl get node "$n" >/dev/null 2>&1 || { echo "  !! 노드 없음: $n (스킵)"; return 0; }
  kubectl label node "$n" "${ENV_KEY}=${e}" --overwrite >/dev/null
  if [ "$e" = "ops" ]; then
    # ops = 라벨만. 혹시 남아있을 수 있는 env=ops taint 는 제거(앱 전용 원칙).
    kubectl taint node "$n" "${ENV_KEY}=${e}:NoSchedule" - >/dev/null 2>&1 || true
    echo "  ✓ $n  label ${ENV_KEY}=${e} (ops=플랫폼, taint 없음)"
  elif [ "$APPLY_TAINT" = "true" ]; then
    kubectl taint node "$n" "${ENV_KEY}=${e}:NoSchedule" --overwrite >/dev/null
    echo "  ✓ $n  label+taint ${ENV_KEY}=${e}:NoSchedule (테스트: 스크립트 taint)"
  else
    echo "  ✓ $n  label ${ENV_KEY}=${e} (운영: taint 는 노드그룹 생성 시 지정 — 스크립트 미적용)"
  fi
}

any=0
for e in dev test prd ops; do
  for n in $(nodes_for "$e"); do apply_one "$e" "$n"; any=1; done
done
[ "$any" = 1 ] || { echo "!! NODE_DEV/TEST/PRD/OPS 가 모두 비어있음. .env 를 채우세요."; exit 1; }

echo ">> 현재 노드 상태:"
kubectl get nodes -L "$ENV_KEY" -o custom-columns='NODE:.metadata.name,ENV:.metadata.labels.'"$ENV_KEY"',TAINTS:.spec.taints[*].key' 2>/dev/null
