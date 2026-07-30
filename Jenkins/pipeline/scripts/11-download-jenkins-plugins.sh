#!/usr/bin/env bash
# [로컬 / 인터넷 가능 PC] 폐쇄망 Jenkins 용 플러그인(.hpi)을 의존성까지 오프라인으로 내려받는다.
# jenkins-plugin-cli(공식 이미지 내장)로 plugins.txt 를 해석 → plugins/ 에 저장 → 반입.
# jenkins_home/plugins/ 에 넣고 Jenkins 재기동하면 설치됨.
set -euo pipefail
cd "$(dirname "$0")/.."          # pipeline/
JENKINS_IMAGE="${JENKINS_IMAGE:-jenkins/jenkins:2.479.2-lts-jdk17}"

mkdir -p plugins
echo ">> $JENKINS_IMAGE 의 jenkins-plugin-cli 로 plugins.txt 해석/다운로드"
docker run --rm -v "$PWD/plugins.txt:/plugins.txt:ro" -v "$PWD/plugins:/out" \
  "$JENKINS_IMAGE" \
  jenkins-plugin-cli --plugin-file /plugins.txt --plugin-download-directory /out --latest false

ls -1 plugins | head
echo ">> 완료. 12-transfer-pipeline.sh 가 plugins/ 를 jenkins_home/plugins/ 로 반입합니다."
