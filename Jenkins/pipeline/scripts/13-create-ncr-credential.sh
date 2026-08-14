#!/usr/bin/env bash
# [로컬] Jenkins 에 NCR 자격증명(ncr-cred, usernamePassword)을 생성. Jenkins/.ncr(레지스트리/access/secret) 사용.
# .ncr 형식(3줄): 1=레지스트리/프로젝트, 2=access key, 3=secret key.  (커밋 금지 — .gitignore 처리됨)
# 사용: JENKINS_URL=... JENKINS_AUTH=admin:<pw> ./13-create-ncr-credential.sh
#   (Jenkins 컨테이너에서 실행하려면 REST /scriptText 로 아래 groovy 를 전달)
set -euo pipefail
NCR_FILE="${NCR_FILE:-$(dirname "$0")/../../.ncr}"
[ -f "$NCR_FILE" ] || { echo "!! .ncr 없음: $NCR_FILE (Jenkins/.ncr 에 레지스트리/access/secret 작성)"; exit 1; }
: "${JENKINS_URL:?JENKINS_URL 필요(예: http://localhost:8080)}"; : "${JENKINS_AUTH:?admin:pw 필요}"
ACCESS=$(sed -n '2p' "$NCR_FILE"); SECRET=$(sed -n '3p' "$NCR_FILE")

read -r -d '' GROOVY <<GVY || true
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
def store = SystemCredentialsProvider.getInstance().getStore(); def dom = Domain.global()
store.getCredentials(dom).findAll{ it.id == "ncr-cred" }.each { store.removeCredentials(dom, it) }
store.addCredentials(dom, new UsernamePasswordCredentialsImpl(
  CredentialsScope.GLOBAL, "ncr-cred", "NHN NCR push", "${ACCESS}", "${SECRET}"))
println("ncr-cred created")
GVY
CJ=$(curl -s -c /tmp/jcj -u "$JENKINS_AUTH" "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
curl -s -b /tmp/jcj -u "$JENKINS_AUTH" -H "$CJ" --data-urlencode "script=$GROOVY" "$JENKINS_URL/scriptText"
