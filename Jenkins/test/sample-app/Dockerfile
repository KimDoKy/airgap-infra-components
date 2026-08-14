# 테스트용 샘플 앱 — 빌드 과정에서 Nexus(raw-hosted)의 패키지를 다운로드해 이미지에 포함.
# 폐쇄망: Nexus 는 cicd 에서 직접 못 붙으므로(443 차단) cicd 의 로컬 터널(localhost:8443 → nexus:443)로 접근.
#   빌드 시: docker build --network host --build-arg NEXUS_AUTH_B64=$(base64 ci:pw) ...
FROM alpine:3.20
ARG NEXUS_URL=https://localhost:8443
ARG NEXUS_AUTH_B64=""
RUN apk add --no-cache curl
# ── (핵심) 빌드 중 Nexus 에서 필요한 패키지 다운로드 ──
RUN curl -fsSL -k -H "Authorization: Basic ${NEXUS_AUTH_B64}" \
      "${NEXUS_URL}/repository/raw-hosted/staged/demo-pkg-1.0.0.tgz" -o /tmp/pkg.tgz \
 && mkdir -p /opt/app && tar xzf /tmp/pkg.tgz -C /opt/app && rm /tmp/pkg.tgz \
 && echo "packaged:" && cat /opt/app/README.txt
CMD ["sh","-c","echo 'acme test-app'; cat /opt/app/README.txt"]
