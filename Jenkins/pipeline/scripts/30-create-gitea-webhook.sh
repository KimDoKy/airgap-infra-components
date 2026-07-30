#!/usr/bin/env bash
# (대안 트리거) Gitea 저장소에 push webhook 을 REST API 로 생성 — GUI 불필요.
# 전제: SG 에 gitea→cicd:443 인바운드 규칙이 열려 있어야 webhook 이 도달함(현재 차단).
#       Jenkins 는 generic-webhook-trigger 또는 gitea 플러그인 엔드포인트를 수신하도록 구성.
# 실행 위치: Gitea 에 접근 가능한 곳(예: 운영자 PC 에서 22 터널, 또는 Gitea VM 로컬).
# 필요 env: GITEA_URL(예 https://<GITEA_IP>), GITEA_TOKEN(admin/owner 토큰), REPO(owner/name),
#           JENKINS_WEBHOOK_URL(예 https://<CICD_IP>/generic-webhook-trigger/invoke?token=<t>),
#           WEBHOOK_SECRET, GITEA_CACERT(자체서명 검증용)
set -euo pipefail
: "${GITEA_URL:?}"; : "${GITEA_TOKEN:?}"; : "${REPO:?owner/name}"; : "${JENKINS_WEBHOOK_URL:?}"
CACERT="${GITEA_CACERT:+--cacert $GITEA_CACERT}"
SECRET="${WEBHOOK_SECRET:-changeme}"

curl -sf $CACERT -H "Authorization: token ${GITEA_TOKEN}" -H 'Content-Type: application/json' \
  -X POST "${GITEA_URL}/api/v1/repos/${REPO}/hooks" -d "{
    \"type\": \"gitea\",
    \"active\": true,
    \"events\": [\"push\", \"create\"],
    \"config\": {
      \"url\": \"${JENKINS_WEBHOOK_URL}\",
      \"content_type\": \"json\",
      \"secret\": \"${SECRET}\"
    }
  }" -w '\nhook http=%{http_code}\n'
echo ">> events=push,create 로 webhook 생성. (create = 브랜치/태그 생성 트리거)"
