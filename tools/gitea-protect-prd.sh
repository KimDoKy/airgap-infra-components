#!/usr/bin/env bash
# config-repo(Gitea)의 prd 브랜치 보호 규칙 생성/갱신 — 릴리스 게이트.
#   직접 push 는 화이트리스트(릴리스 매니저)만, 그 외는 PR + 승인 필요. force-push/삭제 차단(보호 브랜치 기본).
# 실행 위치: Gitea VM(certs/ 접근 가능) 또는 로컬(HOST/CACERT 지정).
# 사용(예):
#   GITEA_URL=https://localhost GITEA_AUTH=admin:<pw> GITEA_CACERT=certs/server.crt \
#   REPO=admin/config-repo PUSH_WHITELIST='["admin"]' APPROVALS=1 ./gitea-protect-prd.sh
set -euo pipefail
: "${GITEA_URL:?예: https://localhost}"; : "${GITEA_AUTH:?admin:pw}"; : "${REPO:?owner/name}"
CACERT="${GITEA_CACERT:-}"; BRANCH="${BRANCH:-prd}"
PUSH_WHITELIST="${PUSH_WHITELIST:-[\"admin\"]}"; APPROVALS="${APPROVALS:-1}"
C=(curl -s -u "$GITEA_AUTH"); [ -n "$CACERT" ] && C+=(--cacert "$CACERT")

BODY=$(cat <<JSON
{
  "rule_name": "${BRANCH}",
  "enable_push": true,
  "enable_push_whitelist": true,
  "push_whitelist_usernames": ${PUSH_WHITELIST},
  "required_approvals": ${APPROVALS},
  "block_on_rejected_reviews": true,
  "dismiss_stale_approvals": true,
  "block_on_outdated_branch": true,
  "require_signed_commits": false
}
JSON
)
# 이미 있으면 PATCH, 없으면 POST
if "${C[@]}" -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$REPO/branch_protections/$BRANCH" | grep -q '^200$'; then
  "${C[@]}" -o /dev/null -w "prd 보호 갱신 http=%{http_code}\n" -X PATCH \
    "$GITEA_URL/api/v1/repos/$REPO/branch_protections/$BRANCH" -H 'Content-Type: application/json' -d "$BODY"
else
  "${C[@]}" -o /dev/null -w "prd 보호 생성 http=%{http_code}\n" -X POST \
    "$GITEA_URL/api/v1/repos/$REPO/branch_protections" -H 'Content-Type: application/json' -d "$BODY"
fi
