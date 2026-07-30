#!/usr/bin/env bash
# AWS SigV4 서명 헬퍼 — aws CLI 없이 REST API 만으로 ECR 인증(GetAuthorizationToken).
# 자격은 cicd VM 의 IAM 인스턴스 프로파일(IMDSv2)에서 가져온다(정적 키 없음).
# 의존: bash, curl, openssl, jq.  (ECR 미생성 상태의 무검증 참조 구현 — 연결 시 검증 필요)
set -euo pipefail

_sha256_hex() { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.* //'; }
_hmac_hex()   { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$1" | sed 's/^.* //'; }

# IMDSv2 에서 임시 자격 로드 → AWS_ACCESS_KEY_ID / SECRET / SESSION_TOKEN export
aws_load_creds_from_imds() {
  local imds=http://169.254.169.254 tok role
  tok=$(curl -sf -X PUT "$imds/latest/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  role=$(curl -sf -H "X-aws-ec2-metadata-token: $tok" "$imds/latest/meta-data/iam/security-credentials/")
  local j; j=$(curl -sf -H "X-aws-ec2-metadata-token: $tok" "$imds/latest/meta-data/iam/security-credentials/$role")
  export AWS_ACCESS_KEY_ID;  AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$j")
  export AWS_SECRET_ACCESS_KEY; AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$j")
  export AWS_SESSION_TOKEN;  AWS_SESSION_TOKEN=$(jq -r .Token <<<"$j")
}

_sigv4_signing_key() { # $1=secret $2=datestamp $3=region $4=service -> hex signing key
  local kDate kRegion kService
  kDate=$(printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt key:"AWS4$1" | sed 's/^.* //')
  kRegion=$(_hmac_hex "$kDate" "$3"); kService=$(_hmac_hex "$kRegion" "$4")
  _hmac_hex "$kService" "aws4_request"
}

# ECR GetAuthorizationToken (POST, x-amz-json-1.1) → "user:password" 출력(디코드됨)
ecr_auth_userpass() { # $1=region
  local region="$1" service=ecr host amzdate datestamp payload phash
  host="api.ecr.${region}.amazonaws.com"; payload='{}'
  amzdate=$(date -u +%Y%m%dT%H%M%SZ); datestamp=${amzdate%T*}
  phash=$(_sha256_hex "$payload")
  local ch sh cr scope sts sig authz
  ch=$(printf 'content-type:application/x-amz-json-1.1\nhost:%s\nx-amz-date:%s\nx-amz-security-token:%s\nx-amz-target:AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken\n' "$host" "$amzdate" "$AWS_SESSION_TOKEN")
  sh='content-type;host;x-amz-date;x-amz-security-token;x-amz-target'
  cr=$(printf 'POST\n/\n\n%s\n%s\n%s' "$ch" "$sh" "$phash")
  scope="${datestamp}/${region}/${service}/aws4_request"
  sts=$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' "$amzdate" "$scope" "$(_sha256_hex "$cr")")
  sig=$(_hmac_hex "$(_sigv4_signing_key "$AWS_SECRET_ACCESS_KEY" "$datestamp" "$region" "$service")" "$sts")
  authz="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${scope}, SignedHeaders=${sh}, Signature=${sig}"
  local resp; resp=$(curl -sf "https://${host}/" \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken" \
    -H "X-Amz-Date: ${amzdate}" -H "X-Amz-Security-Token: ${AWS_SESSION_TOKEN}" \
    -H "Authorization: ${authz}" --data "$payload")
  jq -r '.authorizationData[0].authorizationToken' <<<"$resp" | base64 -d   # "AWS:password"
}
# (EKS STS presign 토큰 함수는 제거됨 — 배포는 ArgoCD 가 클러스터 내부 RBAC 로 처리, CI 는 ECR 만 인증)
