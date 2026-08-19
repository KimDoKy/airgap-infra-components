#!/usr/bin/env bash
# [로컬] 구축물을 "구축 이전" 상태로 초기화한다. 목적: 구축/초기화 반복 연습(학습).
#   대상:
#     - GitServer(Gitea)·Nexus·Jenkins VM  : 컨테이너/데이터/원격 디렉터리 제거 (Docker 런타임은 전제라 유지)
#     - NKS                                 : **우리가 추가한 것만** 제거(ArgoCD·모니터링·ingress·워크로드 ns·노드 라벨/taint·CRD).
#                                             NKS 클러스터/시스템 애드온(CoreDNS·calico 등)은 건드리지 않는다.
#     - NCR                                 : 기본 제외(RESET_NCR=1 로만 수행).
#
# 안전장치: CONFIRM=RESET 없으면 **dry-run**(무엇이 지워질지만 출력).
#   실행:   CONFIRM=RESET ./tools/reset-all.sh
#   연습:            ./tools/reset-all.sh            # dry-run
#
# 값은 각 서비스 .env(VM_SSH_HOST 등)에서 읽는다(스크립트에 비밀/IP 없음). NKS 는 현재 kubectl 컨텍스트 사용.
#
# 옵션(env):
#   CONFIRM=RESET        실제 실행(필수). 없으면 dry-run.
#   SKIP_VMS=1           VM 초기화 건너뜀.
#   SKIP_NKS=1           NKS 초기화 건너뜀.
#   RESET_NCR=1          NCR 이미지도 삭제(기본 미수행).
#   KEEP_REMOTE_DIR=1    원격 서비스 디렉터리를 지우지 않고 상태(data/certs 등)만 비움(빠른 반복).
#   KEEP_IMAGES=1        VM 의 서비스 도커 이미지를 rmi 하지 않음(03-load 생략 → 더 빠름).
#   KEEP_CRDS=1          NKS 의 argoproj/monitoring CRD 를 남겨둠(재설치는 CRD 있어도 동작).
#   NCR_REPOS="test-app" (RESET_NCR=1 시) 비울 NCR 리포(공백 구분).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # repo 루트
: "${SKIP_VMS:=0}"; : "${SKIP_NKS:=0}"; : "${RESET_NCR:=0}"; : "${PURGE_DOCKER:=0}"
: "${KEEP_REMOTE_DIR:=0}"; : "${KEEP_IMAGES:=0}"; : "${KEEP_CRDS:=0}"; : "${NCR_REPOS:=test-app}"
# 워크로드 네임스페이스 prefix: nks/.env override → 없으면 nks 스크립트 기본(_lib.sh: acme-app)
NS_PREFIX=$(grep -E '^APP_NS_PREFIX=' nks/.env 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
: "${NS_PREFIX:=acme-app}"
NKS_NS="argocd monitoring ingress-nginx ${NS_PREFIX}-dev ${NS_PREFIX}-test ${NS_PREFIX}-prd"
DRY=1; [ "${CONFIRM:-}" = "RESET" ] && DRY=0

say(){ printf '%s\n' "$*"; }
hr(){ printf '%s\n' "────────────────────────────────────────────────────────"; }
run(){ if [ "$DRY" = 1 ]; then say "    [dry-run] $*"; else eval "$@"; fi; }

# 필드: 이름 ; .env경로 ; 컨테이너들 ; 추가로 rmi 할 이미지 정규식(compose 외, grep -iE)
SERVICES=(
  "GitServer;GitServer/.env;gitea gitea-nginx;"
  "Nexus;Nexus/.env;nexus nexus-nginx;"
  "Jenkins;Jenkins/.env;jenkins jenkins-nginx;ci-agent|test-app|jenkins/jenkins"
)

hr; say "▶ 초기화  (모드: $([ "$DRY" = 1 ] && echo 'DRY-RUN — CONFIRM=RESET 로 실제 실행' || echo '★ 실제 실행 ★'))"; hr
say "  VM : $([ "$SKIP_VMS" = 1 ] && echo 건너뜀 || echo 'GitServer/Nexus/Jenkins')  (디렉터리 $([ "$KEEP_REMOTE_DIR" = 1 ] && echo 유지 || echo 삭제) · 이미지 $([ "$KEEP_IMAGES" = 1 ] && echo 유지 || echo rmi) · Docker런타임 $([ "$PURGE_DOCKER" = 1 ] && echo '★제거' || echo 유지))"
say "  NKS: $([ "$SKIP_NKS" = 1 ] && echo 건너뜀 || echo '우리 추가분 제거(ArgoCD/모니터링/ingress/워크로드 ns/노드 라벨·taint'"$([ "$KEEP_CRDS" = 1 ] && echo '' || echo '/CRD')"')')  컨텍스트=$(kubectl config current-context 2>/dev/null)"
say "  NCR: $([ "$RESET_NCR" = 1 ] && echo "$NCR_REPOS" || echo '건너뜀(RESET_NCR=1 로 활성)')"
say "  (Docker 런타임 · NKS 클러스터/시스템 애드온은 유지)"

# ── 1. VM 초기화 ─────────────────────────────────────────
if [ "$SKIP_VMS" != 1 ]; then
  for spec in "${SERVICES[@]}"; do
    IFS=';' read -r NAME ENVF CNAMES IMGPAT <<<"$spec"
    hr; say "▶ [$NAME] VM 초기화"
    [ -f "$ENVF" ] || { say "  !! $ENVF 없음 — 건너뜀"; continue; }
    HOST=$(grep -E '^VM_SSH_HOST=' "$ENVF" | cut -d= -f2- | tr -d '"'\''')
    DIR=$(grep -E '^VM_REMOTE_DIR=' "$ENVF" | cut -d= -f2- | tr -d '"'\''')
    [ -n "$HOST" ] && [ -n "$DIR" ] || { say "  !! VM_SSH_HOST/VM_REMOTE_DIR 미설정 — 건너뜀"; continue; }
    say "  대상: $HOST:$DIR  컨테이너: $CNAMES"
    if [ "$DRY" = 1 ]; then
      say "    [dry-run] ssh $HOST → compose down -v · rm -f 컨테이너 · prune · $([ "$KEEP_IMAGES" = 1 ] && echo 'rmi 생략' || echo 'rmi 이미지') · $([ "$KEEP_REMOTE_DIR" = 1 ] && echo '상태 삭제' || echo "rm -rf $DIR")"
      [ "$PURGE_DOCKER" = 1 ] && say "    [dry-run] ssh $HOST → Docker 제거: systemctl disable --now docker · rm /usr/bin/{docker,dockerd,containerd,...} · rm -rf /var/lib/docker /usr/local/lib/docker /etc/docker · groupdel docker · rm -rf ~/Docker"
      continue
    fi
    timeout 120 ssh -o BatchMode=yes "$HOST" bash -s -- "$DIR" "$KEEP_REMOTE_DIR" "$KEEP_IMAGES" "$CNAMES" "$IMGPAT" <<'EOSSH'
      set -u
      DIR="$1"; KEEP_DIR="$2"; KEEP_IMG="$3"; CNAMES="$4"; IMGPAT="$5"; IMAGES=""
      if [ -d "$DIR" ] && [ -f "$DIR/docker-compose.yml" ]; then
        IMAGES=$(cd "$DIR" && docker compose config --images 2>/dev/null || true)
        OVR=""; [ -f "$DIR/docker-compose.override.yml" ] && OVR="-f docker-compose.override.yml"
        (cd "$DIR" && docker compose -f docker-compose.yml $OVR down -v --remove-orphans >/dev/null 2>&1) || true
      fi
      for c in $CNAMES; do docker rm -f "$c" >/dev/null 2>&1 || true; done
      docker container prune -f >/dev/null 2>&1 || true          # 잔여 종료 컨테이너(빌드 에이전트 등)
      if [ "$KEEP_IMG" != "1" ]; then
        for i in $IMAGES; do docker rmi -f "$i" >/dev/null 2>&1 || true; done
        if [ -n "$IMGPAT" ] && command -v docker >/dev/null 2>&1; then
          docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "$IMGPAT" | while read -r i; do docker rmi -f "$i" >/dev/null 2>&1 || true; done
        fi
      fi
      # 데이터 디렉터리는 컨테이너 UID(예: nexus 200) 소유라 sudo 필요할 수 있음
      if [ "$KEEP_DIR" = "1" ]; then
        for d in data nexus-data jenkins_home certs config/init.groovy.d; do sudo -n rm -rf "$DIR/$d" 2>/dev/null || rm -rf "$DIR/$d" 2>/dev/null || true; done
        rm -f "$DIR/docker-compose.override.yml" 2>/dev/null || true
      else
        sudo -n rm -rf "$DIR" 2>/dev/null || rm -rf "$DIR" 2>/dev/null || true
      fi
      echo "  ✓ [$(hostname)] 남은 컨테이너 $(docker ps -aq 2>/dev/null | wc -l)개 · DIR존재:$([ -d "$DIR" ] && echo yes || echo no)"
EOSSH
    # Docker 런타임 제거(설치의 역순: Docker/scripts/03-install.sh) — 옵션
    if [ "$PURGE_DOCKER" = 1 ]; then
      say "  · [$NAME] Docker 런타임 제거"
      timeout 150 ssh -o BatchMode=yes "$HOST" 'bash -s' <<'EOD'
        set -u; export DEBIAN_FRONTEND=noninteractive
        # 1) 서비스 정지/비활성 (유닛은 아직 유지 — apt prerm 이 stop 가능하도록 먼저 정지만)
        sudo systemctl stop    docker.socket docker.service containerd >/dev/null 2>&1 || true
        sudo systemctl disable docker.socket docker.service containerd >/dev/null 2>&1 || true
        # 2) apt 설치분 purge (배포판 docker.io / docker-ce 계열). prerm 실패 시 maintainer 스크립트 무력화 후 강제 purge.
        if command -v dpkg >/dev/null 2>&1; then
          PKGS=$(dpkg -l 2>/dev/null | awk '{print $2}' | grep -iE '^(docker|containerd|runc)' || true)
          if [ -n "$PKGS" ]; then
            sudo apt-get purge -y $PKGS >/dev/null 2>&1 || true
            STILL=$(dpkg -l 2>/dev/null | awk '{print $2}' | grep -iE '^(docker|containerd|runc)' || true)
            for p in $STILL; do for s in prerm postrm preinst postinst; do
              f=/var/lib/dpkg/info/$p.$s; [ -f "$f" ] && { printf '#!/bin/sh\nexit 0\n' | sudo tee "$f" >/dev/null; sudo chmod +x "$f"; }
            done; done
            [ -n "$STILL" ] && sudo dpkg --purge --force-all $STILL >/dev/null 2>&1 || true
            sudo apt-get autoremove -y --purge >/dev/null 2>&1 || true
          fi
        fi
        # 3) 정적 바이너리 설치분 제거
        sudo rm -f /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/bin/containerd-stress /usr/bin/ctr \
                   /usr/bin/docker /usr/bin/docker-init /usr/bin/docker-proxy /usr/bin/dockerd \
                   /usr/bin/runc /usr/sbin/runc /usr/local/bin/docker-compose 2>/dev/null || true
        # 4) 잔여 유닛/플러그인/데이터/그룹/전송 디렉터리
        sudo rm -f /etc/systemd/system/docker.service /lib/systemd/system/docker.service /lib/systemd/system/docker.socket \
                   /lib/systemd/system/containerd.service /usr/lib/systemd/system/docker.service \
                   /usr/lib/systemd/system/docker.socket /usr/lib/systemd/system/containerd.service 2>/dev/null || true
        sudo find /etc/systemd/system -name 'docker.*' -delete 2>/dev/null || true
        sudo rm -f /etc/systemd/system/multi-user.target.wants/containerd.service 2>/dev/null || true
        sudo rm -rf /usr/local/lib/docker /var/lib/docker /var/lib/containerd /etc/docker /run/docker.sock /run/containerd 2>/dev/null || true
        sudo systemctl daemon-reload >/dev/null 2>&1 || true; sudo systemctl reset-failed >/dev/null 2>&1 || true
        sudo groupdel docker >/dev/null 2>&1 || true
        sudo rm -rf "$HOME/Docker" 2>/dev/null || true
        echo "  ✓ [$(hostname)] docker바이너리=$(command -v docker >/dev/null 2>&1 && echo 남음 || echo 제거) · 유닛=$(systemctl list-unit-files 2>/dev/null | grep -icE 'docker|containerd')개 · apt패키지=$(dpkg -l 2>/dev/null | grep -icE 'docker|containerd|runc')개 · /var/lib/docker=$([ -d /var/lib/docker ] && echo yes || echo no) · ~/Docker=$([ -d "$HOME/Docker" ] && echo yes || echo no)"
EOD
    fi
  done
fi

# ── 2. NKS 초기화 (우리가 추가한 것만) ───────────────────
if [ "$SKIP_NKS" != 1 ]; then
  hr; say "▶ [NKS] 우리 추가분 제거  (컨텍스트: $(kubectl config current-context 2>/dev/null))"
  K="kubectl"
  # 2-1) ArgoCD Application: finalizer 제거 후 삭제(먼저 CD 중단 → 재동기화 방지)
  say "  · ArgoCD Applications/Projects 제거(finalizer 해제)"
  if [ "$DRY" = 0 ]; then
    for a in $($K -n argocd get applications -o name 2>/dev/null); do
      $K -n argocd patch "$a" -p '{"metadata":{"finalizers":null}}' --type merge >/dev/null 2>&1 || true
    done
    $K -n argocd delete applications --all --ignore-not-found >/dev/null 2>&1 || true
    $K -n argocd delete appprojects --all --ignore-not-found >/dev/null 2>&1 || true
  else say "    [dry-run] patch finalizer=null → delete applications/appprojects --all (argocd ns)"; fi
  # 2-2) helm 릴리스 uninstall (모니터링/ingress)
  say "  · helm uninstall: kps(monitoring), ingress-nginx"
  run "helm uninstall kps -n monitoring --wait --timeout 3m >/dev/null 2>&1 || true"
  run "helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 3m >/dev/null 2>&1 || true"
  # 2-3) 네임스페이스 삭제(ArgoCD raw manifest·워크로드·모니터링·ingress)
  say "  · 네임스페이스 삭제: $NKS_NS"
  run "$K delete ns $NKS_NS --ignore-not-found --wait=false >/dev/null 2>&1 || true"
  # 2-4) ArgoCD 클러스터 스코프 RBAC 잔재
  say "  · ArgoCD ClusterRole/Binding(part-of=argocd) 제거"
  run "$K delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=argocd --ignore-not-found >/dev/null 2>&1 || true"
  # 2-5) CRD (argoproj.io + monitoring.coreos.com) — 우리가 들여온 것
  if [ "$KEEP_CRDS" != 1 ]; then
    say "  · CRD 삭제: argoproj.io / monitoring.coreos.com"
    if [ "$DRY" = 0 ]; then
      $K get crd -o name 2>/dev/null | grep -E 'argoproj\.io|monitoring\.coreos\.com' | xargs -r $K delete --ignore-not-found >/dev/null 2>&1 || true
    else say "    [dry-run] delete crd (argoproj.io / monitoring.coreos.com)"; fi
  else say "  · CRD 유지(KEEP_CRDS=1)"; fi
  # 2-6) 노드 env 라벨/taint 제거(모든 노드)
  say "  · 노드 env 라벨/taint 제거(dev/prd/ops)"
  if [ "$DRY" = 0 ]; then
    for n in $($K get nodes -o name 2>/dev/null); do
      nm=${n#node/}
      $K label node "$nm" env- >/dev/null 2>&1 || true
      $K taint node "$nm" env- >/dev/null 2>&1 || true
    done
  else say "    [dry-run] 각 노드: label env- · taint env-"; fi
fi

# ── 3. NCR 초기화 (옵션) ─────────────────────────────────
if [ "$RESET_NCR" = 1 ]; then
  hr; say "▶ [NCR] 이미지 삭제"
  if [ ! -f Jenkins/.ncr ]; then say "  !! Jenkins/.ncr 없음 — 건너뜀"; else
    mapfile -t NCR < Jenkins/.ncr
    REGFULL="${NCR[0]}"; REG="${REGFULL%%/*}"; NS="${REGFULL#*/}"; ACC="${NCR[1]}"; SEC="${NCR[2]}"
    ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
    for repo in $NCR_REPOS; do
      path="$NS/$repo"
      tags=$(curl -s -u "$ACC:$SEC" "https://$REG/v2/$path/tags/list" 2>/dev/null | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin).get("tags") or []))' 2>/dev/null)
      [ -z "$tags" ] && { say "  [$repo] 태그 없음"; continue; }
      say "  [$repo] 태그: $(echo "$tags" | tr '\n' ' ')"
      for t in $tags; do
        dig=$(curl -s -I -u "$ACC:$SEC" -H "Accept: $ACCEPT" "https://$REG/v2/$path/manifests/$t" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
        [ -z "$dig" ] && { say "    - $t digest 실패(스킵)"; continue; }
        if [ "$DRY" = 1 ]; then say "    [dry-run] DELETE $t ($dig)";
        else code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -u "$ACC:$SEC" "https://$REG/v2/$path/manifests/$dig" 2>/dev/null); say "    - $t 삭제 → http=$code"; fi
      done
    done
  fi
fi
hr
if [ "$DRY" = 1 ]; then say "✔ DRY-RUN 완료. 실제 실행: CONFIRM=RESET $0"
else say "✔ 초기화 완료. 재구축 연습: VM=각 서비스 01→06, NKS=nks/scripts 01→07."; fi
