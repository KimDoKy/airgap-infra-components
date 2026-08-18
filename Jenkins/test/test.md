# Jenkins CICD 연동 검증 (hands-on)

**이 테스트의 핵심 목적은 Jenkins ↔ GitServer(Gitea) ↔ Nexus 3자 연동 검증이다.**
폐쇄망 CI 서버(Jenkins)가 **GitServer 의 새 커밋을 스스로 감지(SCM 폴링)** 해 소스를 받고, 빌드 도중
Nexus 에서 패키지를 내려받아 이미지를 만들고, 그 결과(이미지 태그)를 다시 GitServer 의 config-repo 에
반영하는 전 과정을 사람이 그대로 재현할 수 있도록 정리한다. (실측 통과: 2026-07-31)

> 역할 분리: **Jenkins = CI 만** 담당(빌드까지). **CD 는 ArgoCD** 가 config-repo 를 감시해 NKS 에 배포.
> 이 문서는 CI 구간(및 config-repo 갱신까지)만 검증한다. NCR push / ArgoCD 배포는 표기만 한다.

## 시나리오

```
                    ┌──────────────── cicd VM (Jenkins, 폐쇄망) ────────────────┐
 [GitServer]        │  SCM 폴링(매분): 새 커밋 감지 → 자동 빌드                   │
  test-app ──clone──┼─▶ host.docker.internal:2222 ──(ssh22)──▶ gitea git-ssh    │
   ▲ push 이벤트     │                                                           │
                    │  docker build --network host                             │
 [Nexus]            │  ─▶ localhost:8443 ──(ssh22)──▶ nexus:443  ← 빌드 중 다운로드│
                    │                                                           │
 [GitServer]        │  ci-build-scm.sh (Freestyle+GitSCM 잡)                    │
  config-repo ◀push─┼── image.tag = b<빌드번호>-<소스SHA> 갱신 커밋                │
                    └───────────────────────────────────────────────────────────┘
          ▲ (추후) ArgoCD 가 config-repo 를 감시하여 NKS 에 배포
```

- **① GitServer 연동(입력/트리거)**: `test-app` 새 커밋을 **폴링으로 감지 → 자동 빌드**, 소스 clone.
- **② Nexus 연동**: 이미지 빌드 중 `raw-hosted/staged/demo-pkg-1.0.0.tgz` 를 다운로드해 이미지에 포함.
- **③ GitServer 연동(출력)**: 빌드 결과 이미지 태그를 `config-repo/apps/test-app/values.yaml` 에 커밋·push.
- Nexus 는 cicd 에서 443 직결이 막혀 있으므로(폐쇄망) **cicd 로컬 터널 `localhost:8443`** 로 접근하고,
  `docker build --network host` 로 빌드 컨테이너가 이 로컬 터널을 보게 한다.
- **트리거 방식 = SCM 폴링(B)**: 폐쇄망에서 GitServer→Jenkins 역방향 접근이 없어 Webhook(A) 대신 폴링 사용.
  Jenkins→GitServer 방향은 이미 열려 있어 폴링만으로 "push → 자동 빌드"가 성립한다.
- 폐쇄망 시뮬레이션에서 Docker Hub(alpine pull) 및 NCR(push) 은 실제 배포 시 사내 레지스트리/NCR 로 대체된다.

---

## 사전 조건 (Preconditions)

아래는 **한 번만** 갖춰두면 되는 인프라 준비다. (`<...>` 는 각자 값으로 대입, 비밀번호 평문 금지)

### P0. GitServer 저장소 2개 — `test-app`, **`config-repo`(신규 생성 필요)**

`config-repo` 는 ArgoCD 가 감시할 GitOps 저장소로, **이 테스트 전에 생성해 둔다.**

```bash
ssh acme-git
cd /home/ubuntu/GitServer
# config-repo 생성 (auto_init 로 main 브랜치 포함)
curl -s -o /dev/null -w 'config-repo http=%{http_code}\n' --cacert certs/server.crt \
  -u 'admin:<GITEA_ADMIN_PW>' -X POST https://localhost/api/v1/user/repos \
  -H 'Content-Type: application/json' \
  -d '{"name":"config-repo","private":true,"auto_init":true,"default_branch":"main"}'
# test-app 저장소 (없으면 생성; 소스는 ②에서 push)
curl -s -o /dev/null -w 'test-app http=%{http_code}\n' --cacert certs/server.crt \
  -u 'admin:<GITEA_ADMIN_PW>' -X POST https://localhost/api/v1/user/repos \
  -H 'Content-Type: application/json' -d '{"name":"test-app","private":true}'
exit
```
기대: `config-repo http=201`, `test-app http=201`(이미 있으면 409 무시).

`config-repo` 에 CI 가 갱신할 초기 값 파일을 넣는다 (로컬 gitea SSH 게이트웨이 별칭 `acme-gitea`):
```bash
W=$(mktemp -d); cd "$W"
git clone acme-gitea:admin/config-repo.git && cd config-repo
mkdir -p apps/test-app
cat > apps/test-app/values.yaml <<'YML'
# ArgoCD 가 감시하는 config-repo — Jenkins(CI)가 빌드 후 image.tag 를 갱신·커밋.
image:
  repository: test-app        # 실제로는 <NCR_REGISTRY_HOST>/acme-poc/test-app
  tag: "init"                 # ← CI 가 b<빌드번호>-<소스SHA> 로 갱신
YML
git add . && git commit -m "init config-repo" && git push origin main
```

### P1. Jenkins 컨테이너에 Docker 접근(DooD) + 호스트 터널 도달 설정

`~/Jenkins/docker-compose.override.yml` (cicd VM):
```yaml
services:
  jenkins:
    group_add: ["<DOCKER_GID>"]          # cicd 의 docker 그룹 GID (getent group docker | cut -d: -f3)
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./jenkins_home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/bin/docker:/usr/bin/docker:ro
```
적용: `cd ~/Jenkins && docker compose up -d`. 확인: `docker exec jenkins docker version` 이 서버까지 응답.

### P2. cicd 에 systemd 터널 2개 (Nexus, GitServer)

`/etc/systemd/system/nexus-tunnel.service` — `localhost:8443 → nexus:443`:
```ini
ExecStart=/usr/bin/ssh -NT -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new -i /home/ubuntu/.ssh/vmkey.pem \
  -L 8443:localhost:443 ubuntu@<NEXUS_IP>
```
`/etc/systemd/system/gitea-tunnel.service` — `0.0.0.0:2222 → gitea git-ssh`(컨테이너에서 도달하도록 0.0.0.0 바인딩):
```ini
ExecStart=/usr/bin/ssh -NT -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new -i /home/ubuntu/.ssh/vmkey.pem \
  -L 0.0.0.0:2222:localhost:2222 ubuntu@<GITEA_IP>
```
적용: `sudo systemctl daemon-reload && sudo systemctl enable --now nexus-tunnel gitea-tunnel`.
확인: `systemctl is-active nexus-tunnel gitea-tunnel` → active, `ss -tln | grep -E ':8443|:2222'`.

### P3. Jenkins 용 git 키 생성 + GitServer 등록 (clone/push 용)

```bash
docker exec jenkins sh -c 'mkdir -p /var/jenkins_home/.ssh && \
  [ -f /var/jenkins_home/.ssh/id_ed25519 ] || \
  ssh-keygen -q -t ed25519 -f /var/jenkins_home/.ssh/id_ed25519 -N "" -C jenkins-ci; \
  cat /var/jenkins_home/.ssh/id_ed25519.pub'
# 위 pubkey 를 GitServer(admin) 계정 키로 등록
ssh acme-git "cd /home/ubuntu/GitServer && curl -s -o /dev/null -w 'add-key http=%{http_code}\n' \
  --cacert certs/server.crt -u 'admin:<GITEA_ADMIN_PW>' -X POST https://localhost/api/v1/user/keys \
  -H 'Content-Type: application/json' -d '{\"title\":\"jenkins-ci\",\"key\":\"<PUBKEY>\"}'"
```
기대: `add-key http=201`.

### P4. Nexus `ci` 계정 + `raw-hosted` 저장소 (Nexus 문서 참고)

- `ci` 계정 비밀번호 `<CI_PW>` 준비. `raw-hosted` 저장소 존재(없으면 `Nexus/ADMIN.md`).

### P5. Jenkins 플러그인(git) + 크리덴셜 + 호스트키 — **SCM 폴링에 필수**

Git SCM/폴링을 쓰려면 `git` 플러그인이 필요하다. (본 프로젝트 오프라인 Jenkins 는 최소 플러그인만 포함)

```bash
# (cicd) git 플러그인 설치 후 재시작 → 로드
docker exec jenkins jenkins-plugin-cli --plugin-download-directory /var/jenkins_home/plugins --plugins git
cd ~/Jenkins && docker compose restart jenkins        # ★ 재시작해야 새 플러그인이 로드됨
```
> **주의:** plugins 디렉터리에 .jpi 를 넣기만 하면 안 되고 **반드시 재시작**해야 로드된다.
> `docker exec jenkins curl -s -u <admin> http://localhost:8080/pluginManager/api/json?depth=1 | grep -c shortName` 로 로드 확인.

이어서 **SSH 크리덴셜 생성 + git 호스트키 검증 완화**를 Script Console(REST `scriptText`)로 처리한다.
(CLI 는 LTS 업그레이드 후 "Jenkins URL 미설정" 으로 막힐 수 있어 REST 사용)

```bash
A="admin:<JENKINS_ADMIN_PW>"; B=http://localhost:8080
CJ=$(docker exec jenkins curl -s -c /tmp/cj -u "$A" "$B/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
cat > /tmp/setup.groovy <<'GROOVY'
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
// (1) SSH 크리덴셜 jenkins-git (user=git, key=jenkins id_ed25519)
def key = new File("/var/jenkins_home/.ssh/id_ed25519").text
def src = new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(key)
def cred = new BasicSSHUserPrivateKey(CredentialsScope.GLOBAL, "jenkins-git", "git", src, "", "jenkins git ssh key")
def store = SystemCredentialsProvider.getInstance().getStore(); def dom = Domain.global()
store.getCredentials(dom).findAll{ it.id == "jenkins-git" }.each { store.removeCredentials(dom, it) }
store.addCredentials(dom, cred); println("cred jenkins-git added")
// (2) git 호스트키 검증 -> 최초 접속 자동 수락 (플러그인 클래스라 uberClassLoader 필요)
def cl = Jenkins.instance.pluginManager.uberClassLoader
def cfg = GlobalConfiguration.all().get(cl.loadClass("org.jenkinsci.plugins.gitclient.GitHostKeyVerificationConfiguration"))
cfg.setSshHostKeyVerificationStrategy(cl.loadClass("org.jenkinsci.plugins.gitclient.verifier.AcceptFirstConnectionStrategy").newInstance())
cfg.save(); println("git hostkey = AcceptFirstConnection")
GROOVY
docker cp /tmp/setup.groovy jenkins:/tmp/setup.groovy
docker exec jenkins curl -s -b /tmp/cj -u "$A" -H "$CJ" --data-urlencode "script=$(cat /tmp/setup.groovy)" "$B/scriptText"
```
기대 출력: `cred jenkins-git added`, `git hostkey = AcceptFirstConnection`.
연동 확인: `docker exec jenkins sh -c 'GIT_SSH_COMMAND="ssh -i /var/jenkins_home/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" git ls-remote ssh://git@host.docker.internal:2222/admin/test-app.git'` → HEAD 해시.

---

## ① [Nexus 연동 준비] 패키지를 bastion 경유로 Nexus 에 적재

Nexus 테스트에서 쓴 패키지를 그대로 재사용한다. **상세 절차는 [`../../Nexus/Test.md`](../../Nexus/Test.md)** 참고.
이 테스트가 기대하는 패키지 내용(검증 grep 과 일치해야 함):
```bash
mkdir -p /tmp/demo-pkg/bin
echo "acme build dependency payload $(date -u +%FT%TZ)" > /tmp/demo-pkg/README.txt
printf '#!/bin/sh\necho hello-acme\n' > /tmp/demo-pkg/bin/run.sh
tar czf /tmp/demo-pkg-1.0.0.tgz -C /tmp/demo-pkg .
# → Nexus/Test.md ①~② 절차로 raw-hosted/staged/demo-pkg-1.0.0.tgz 업로드
```
적재 확인(cicd 터널로):
```bash
ssh acme-cicd 'curl -s -k -u "ci:<CI_PW>" \
  https://localhost:8443/repository/raw-hosted/staged/demo-pkg-1.0.0.tgz -o /dev/null -w "nexus pkg http=%{http_code}\n"'
```
기대: `nexus pkg http=200`.

---

## ② [GitServer 연동 준비] 패키지를 쓰는 샘플 앱을 GitServer 에 push

`sample-app/Dockerfile`(이 저장소)을 `test-app` 저장소로 올린다.
- [`sample-app/Dockerfile`](sample-app/Dockerfile): 빌드 중 Nexus 에서 `demo-pkg-1.0.0.tgz` 를 다운로드해
  `/opt/app` 에 풀고, 실행 시 README 를 출력한다. **← Nexus 연동의 실체.**

```bash
W=$(mktemp -d); cd "$W"
git clone acme-gitea:admin/test-app.git && cd test-app
cp <이 저장소>/infra/Jenkins/test/sample-app/Dockerfile .
git add Dockerfile && git commit -m "sample app: build pulls demo-pkg from Nexus" && git push origin main
```

---

## ③ [Jenkins] Git SCM + 폴링 잡 생성

빌드 스크립트 [`ci-build-scm.sh`](ci-build-scm.sh) 를 jenkins_home 에 배치하고, `test-app` 을 SCM 으로 두고
**매분 폴링**하는 Freestyle 잡을 만든다. (잡 정의: [`job-config-scm.xml`](job-config-scm.xml))

```bash
# 빌드 스크립트 배치
scp <이 저장소>/infra/Jenkins/test/ci-build-scm.sh acme-cicd:/tmp/ci-build-scm.sh
ssh acme-cicd 'docker cp /tmp/ci-build-scm.sh jenkins:/var/jenkins_home/ci-build-scm.sh && \
  docker exec jenkins chmod +x /var/jenkins_home/ci-build-scm.sh'

# 잡 정의에서 <CI_PW> 를 실제 값으로 바꿔 배치 후 REST(crumb+쿠키)로 생성
sed 's/<CI_PW>/<실제_CI_비밀번호>/' <이 저장소>/infra/Jenkins/test/job-config-scm.xml > /tmp/job.xml
scp /tmp/job.xml acme-cicd:/tmp/job.xml
ssh acme-cicd 'docker cp /tmp/job.xml jenkins:/tmp/job.xml
docker exec jenkins sh -c '\''
A="admin:<JENKINS_ADMIN_PW>"; B=http://localhost:8080; J=/tmp/cj
CJ=$(curl -s -c $J -u "$A" "$B/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
curl -s -b $J -o /dev/null -w "create http=%{http_code}\n" -u "$A" -H "$CJ" \
  -H "Content-Type:application/xml" --data-binary @/tmp/job.xml "$B/createItem?name=acme-cicd-verify"
'\'''
```
기대: `create http=200`.

**★ 폴링 트리거 start (중요):** REST `createItem` 으로 만든 잡은 SCMTrigger 가 **스케줄 등록(start)되지 않아**
폴링이 돌지 않는다. 아래로 트리거를 start 한다(또는 *Manage Jenkins → Reload Configuration from Disk*, 혹은 재시작).
```bash
ssh acme-cicd '
A="admin:<JENKINS_ADMIN_PW>"; B=http://localhost:8080
CJ=$(docker exec jenkins curl -s -c /tmp/cj -u "$A" "$B/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
cat > /tmp/trig.groovy <<'\''GROOVY'\''
import jenkins.model.*; import hudson.triggers.SCMTrigger
def job = Jenkins.instance.getItem("acme-cicd-verify")
def t = new SCMTrigger("* * * * *"); job.addTrigger(t); t.start(job, true); job.save()
println("SCMTrigger started: " + job.getTriggers().values())
GROOVY
docker cp /tmp/trig.groovy jenkins:/tmp/trig.groovy
docker exec jenkins curl -s -b /tmp/cj -u "$A" -H "$CJ" --data-urlencode "script=$(cat /tmp/trig.groovy)" "$B/scriptText"'
```
> 최초 1회는 "이전 빌드 없음" 기준을 세우려 곧바로 베이스라인 빌드가 돈다(정상). 이후부터 새 커밋에만 반응.

---

## ④ [핵심 검증] test-app 에 커밋 push → 폴링이 자동 빌드

```bash
# 로컬에서 test-app 에 변경을 push (실제 개발자의 push/merge 를 모사)
W=$(mktemp -d); cd "$W"; git clone acme-gitea:admin/test-app.git && cd test-app
echo 'LABEL acme.build="scm-poll-test"' >> Dockerfile
git commit -am "feat: trigger CI via SCM polling"; git push origin main
NEWSHA=$(git rev-parse --short HEAD); echo "pushed $NEWSHA"
```
1분 내 폴링이 감지해 자동 빌드된다. 최신 빌드의 원인·체크아웃 커밋을 확인:
```bash
ssh acme-cicd 'docker exec jenkins sh -c '\''
A="admin:<JENKINS_ADMIN_PW>"; B=http://localhost:8080
N=$(curl -s -u "$A" "$B/job/acme-cicd-verify/lastBuild/api/json?tree=number" | grep -o "[0-9]*")
echo "lastBuild=#$N"
curl -s -u "$A" "$B/job/acme-cicd-verify/$N/consoleText" \
  | grep -iE "Started by an SCM change|Checking out Revision|Commit message|NEXUS 패키지 포함|config-repo 갱신|Finished"
'\'''
```
기대(실측 예):
```
Started by an SCM change                          ← 폴링이 새 커밋 감지해 자동 트리거
Checking out Revision 03fa86b… (refs/remotes/origin/main)
Commit message: "feat: trigger CI via SCM polling"
NEXUS 패키지 포함 확인 OK                           ← 빌드 중 Nexus 다운로드
config-repo 갱신됨: b<N>-03fa86b                    ← GitServer config-repo push
Finished: SUCCESS
```

---

## ⑤ [확인] config-repo 갱신 결과 (ArgoCD 감시 대상)

```bash
ssh acme-git "cd /home/ubuntu/GitServer && curl -s --cacert certs/server.crt -u 'admin:<GITEA_ADMIN_PW>' \
  'https://localhost/api/v1/repos/admin/config-repo/contents/apps/test-app/values.yaml?ref=main' \
  | grep -o '\"content\":\"[^\"]*\"' | cut -d'\"' -f4 | base64 -d"
```
기대: `image.tag` 가 `b<빌드번호>-<소스SHA>` 로 바뀜 → 추후 ArgoCD 가 이 커밋을 감지해 NKS 롤아웃.
> 태그에 소스 SHA 를 넣어 **어떤 커밋이 어떤 이미지가 됐는지 추적**된다. 새 커밋마다 태그가 바뀌므로 변경도 보장.

---

## 기대 결과 요약

| 단계 | 연동 | 확인 | 기대 |
|---|---|---|---|
| ① | Nexus | 적재 확인 `curl …:8443/…/demo-pkg-1.0.0.tgz` | `http=200` |
| ② | GitServer | `test-app` push | push 성공 |
| ③ | Jenkins | `create-job`(REST) + 트리거 start | `http=200`, 베이스라인 빌드 SUCCESS |
| ④-1 | **GitServer→Jenkins** | 새 커밋 push 후 콘솔 `Started by an SCM change` | 폴링 자동 트리거 |
| ④-2 | **Jenkins→GitServer** | `Checking out Revision <새SHA>` | 새 커밋 clone |
| ④-3 | **Jenkins→Nexus** | `NEXUS 패키지 포함 확인 OK` (빌드 중 다운로드) | 다운로드 성공 |
| ④-4 | **Jenkins→GitServer** | `config-repo 갱신됨: b<N>-<SHA>` | config-repo push |
| ④ | — | `RESULT` | `SUCCESS` |
| ⑤ | GitServer | config-repo `values.yaml` | `tag: "b<N>-<SHA>"` 반영 |

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| 플러그인이 목록에 안 잡힘(활성 0) | plugins 에 .jpi 만 넣고 **재시작 안 함**. `docker compose restart jenkins` |
| `git` 플러그인 MISSING | P5 설치 누락. `jenkins-plugin-cli --plugins git` 후 재시작 |
| 커밋 push 했는데 자동 빌드 안 됨 | SCMTrigger 미start(REST 생성 시 흔함). ③의 트리거 start Groovy 실행(또는 Reload/재시작). `…/job/…/scmPollingLog` 로 폴링 로그 확인 |
| 폴링 로그 `Not Found` | 폴링이 한 번도 실행 안 됨 → 트리거 미start(위와 동일) |
| clone `Permission denied (publickey)` | jenkins 키 미등록. P3 재수행 |
| git 체크아웃 `Host key verification failed` | P5 (2) 호스트키 전략 미설정. AcceptFirstConnection 적용 |
| Step 5/6 `curl … 401/404/000` | 401=`ci` 자격, 404=패키지 미적재(①), 000=nexus-tunnel 비활성/`--network host` 누락 |
| `docker: not found`(잡 내부) | P1 override(docker.sock/`/usr/bin/docker`/`group_add`) 누락 |
| config-repo `nothing to commit` 로 실패 | 태그가 이전과 동일. `ci-build-scm.sh` 는 소스 SHA 태그 + 커밋 실패 허용으로 처리됨(변경 없으면 skip) |
| CLI `403 … Jenkins URL is not configured` | LTS 업그레이드 후 URL 미설정. 본 문서처럼 **REST** 사용(또는 Jenkins URL 설정) |

---

## 부록 A — 수동 실행(폴링 없이) 변형

폴링/플러그인 없이 "연동만" 빠르게 확인하려면 NullSCM Freestyle 잡으로도 가능하다(트리거는 수동 실행).
파일: [`ci-build.sh`](ci-build.sh)(스크립트 안에서 test-app 을 직접 clone), [`job-config.xml`](job-config.xml).
③ 대신 이 잡을 만들고 `POST …/job/acme-cicd-verify/build` 로 실행하면 ④-2~④-4 동일 결과를 얻는다.
(단 "새 커밋 → 자동 트리거"는 검증되지 않음 — 그 검증이 본문 ③~④의 SCM 폴링이다.)
