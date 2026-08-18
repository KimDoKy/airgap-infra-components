#!/usr/bin/env bash
# [로컬/kubectl] 노드에 환경 label (+ 테스트 시 taint) 적용. 멱등.
#   각 노드에 env=<e>:NoSchedule taint 로 워크로드 격리. **ops 도 taint** — 전용 플랫폼 노드다.
#     - dev/test/prd : 해당 env 앱만(앱 매니페스트 nodeSelector/tolerations env=<e>).
#     - ops          : ArgoCD/모니터링/Ingress 만(차트에 nodeSelector env=ops + toleration env=ops).
#   ★ taint 적용 주체(APPLY_TAINT):
#     - 테스트(기본, APPLY_TAINT=true): 이 스크립트가 dev/test/prd/ops 에 env=<e>:NoSchedule taint 를 건다.
#     - 운영(APPLY_TAINT=false): taint 는 **NKS 노드그룹 생성 시** 지정(노드 교체/오토스케일에도 유지) → 스크립트는 라벨만.
#   ⚠ ops 를 taint 하면 NKS 관리형 애드온(CoreDNS/calico 등)이 갈 곳이 필요하다. 대부분(CoreDNS·calico-typha·
#     konnectivity)은 모든 taint 를 tolerate(op=Exists)해 문제없으나, blanket toleration 이 없는 것(예:
#     calico-kube-controllers)은 **untainted 시스템 nodepool** 을 두거나 해당 애드온에 ops toleration 을 추가해야 한다.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
: "${APPLY_TAINT:=true}"   # 테스트=true(스크립트 taint), 운영=false(노드그룹 생성 시 taint)

echo ">> 컨텍스트: $(kctx)  (APPLY_TAINT=${APPLY_TAINT})"
apply_one() {  # env node
  local e="$1" n="$2"
  kubectl get node "$n" >/dev/null 2>&1 || { echo "  !! 노드 없음: $n (스킵)"; return 0; }
  kubectl label node "$n" "${ENV_KEY}=${e}" --overwrite >/dev/null
  if [ "$APPLY_TAINT" = "true" ]; then
    kubectl taint node "$n" "${ENV_KEY}=${e}:NoSchedule" --overwrite >/dev/null
    echo "  ✓ $n  label+taint ${ENV_KEY}=${e}:NoSchedule"
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
