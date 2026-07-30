# CI 빌드 에이전트 — node + docker(cli) + git + (SigV4용) openssl/jq/curl
# Jenkins=CI만: 빌드·이미지·ECR push·GitOps 태그 커밋만 하므로 kubectl/helm 불필요(배포는 ArgoCD).
# aws CLI 는 정책상 미포함 — ECR 인증은 REST(SigV4)로 처리(scripts/lib-awssigv4.sh).
# 로컬(인터넷 가능) PC 에서 빌드해 tar 저장 후 폐쇄망 cicd VM 으로 반입.
#   scripts/10-build-ci-agent-image.sh (docker build → docker save). 실행(폐쇄망)에선 아무것도 안 받음.
FROM node:20-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl bash git jq openssl docker.io gettext-base; \
    rm -rf /var/lib/apt/lists/*

# 자체서명 인증서(Nexus/Gitea) 신뢰가 필요하면 여기서 COPY 후 update-ca-certificates
# COPY nexus.crt gitea.crt /usr/local/share/ca-certificates/
# RUN update-ca-certificates

WORKDIR /workspace
