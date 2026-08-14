#!/usr/bin/env bash
# [로컬/kubectl] 워크로드 네임스페이스 생성 + NCR imagePullSecret(ncr-cred) 배포. 멱등.
#   Deployment 는 imagePullSecrets:[{name: ncr-cred}] 로 NCR 에서 이미지 pull.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

: "${NCR_REGISTRY:?NCR_REGISTRY 미설정}"; : "${NCR_ACCESS_KEY:?}"; : "${NCR_SECRET_KEY:?}"

# 노드가 매핑된 워크로드 env 만 대상(ops 제외)
ENVS=""
for e in dev test prd; do [ -n "$(nodes_for "$e")" ] && ENVS="$ENVS $e"; done
[ -n "$ENVS" ] || { echo "!! 워크로드 env(dev/test/prd) 노드가 없음. 01 먼저/.env 확인"; exit 1; }

for e in $ENVS; do
  ns="${APP_NS_PREFIX}-${e}"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry ncr-cred \
    --docker-server="$NCR_REGISTRY" \
    --docker-username="$NCR_ACCESS_KEY" --docker-password="$NCR_SECRET_KEY" \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  ✓ $ns : namespace + ncr-cred"
done
