#!/usr/bin/env bash
# [로컬/kubectl] 노드에 환경 label + taint 적용. 멱등.
#   taint 목적 = **앱 배포 격리 전용** → dev/test/prd 만 NoSchedule taint.
#   ops 는 **라벨만**(taint 없음): ArgoCD/모니터링/Ingress + NKS 시스템 애드온(CoreDNS 등)이 taint 영향 없이 스케줄.
#   label env=<e> → 앱/플랫폼 nodeSelector 매칭 / taint env=<e>:NoSchedule → 대응 toleration 없는 pod 배제.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo ">> 컨텍스트: $(kctx)"
apply_one() {  # env node
  local e="$1" n="$2"
  kubectl get node "$n" >/dev/null 2>&1 || { echo "  !! 노드 없음: $n (스킵)"; return 0; }
  kubectl label node "$n" "${ENV_KEY}=${e}" --overwrite >/dev/null
  if [ "$e" = "ops" ]; then
    # ops = 라벨만. 혹시 남아있을 수 있는 env=ops taint 는 제거(앱 전용 원칙).
    kubectl taint node "$n" "${ENV_KEY}=${e}:NoSchedule" - >/dev/null 2>&1 || true
    echo "  ✓ $n  label ${ENV_KEY}=${e} (taint 없음 — 플랫폼/시스템 영향 없음)"
  else
    kubectl taint node "$n" "${ENV_KEY}=${e}:NoSchedule" --overwrite >/dev/null
    echo "  ✓ $n  label+taint ${ENV_KEY}=${e}:NoSchedule (앱 격리)"
  fi
}

any=0
for e in dev test prd ops; do
  for n in $(nodes_for "$e"); do apply_one "$e" "$n"; any=1; done
done
[ "$any" = 1 ] || { echo "!! NODE_DEV/TEST/PRD/OPS 가 모두 비어있음. .env 를 채우세요."; exit 1; }

echo ">> 현재 노드 상태:"
kubectl get nodes -L "$ENV_KEY" -o custom-columns='NODE:.metadata.name,ENV:.metadata.labels.'"$ENV_KEY"',TAINTS:.spec.taints[*].key' 2>/dev/null
