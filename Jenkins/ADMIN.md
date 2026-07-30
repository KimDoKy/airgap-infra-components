# Jenkins 관리자 가이드

운영 중인 Jenkins(**CI 서버**) 관리. **GUI 미사용** — Job·자격은 **JCasC(코드)**, 런타임은 **Jenkins CLI**,
플러그인은 **오프라인 반입**으로 처리합니다. (배포=CD는 ArgoCD가 담당 → gitops)

접속: `ssh acme-cicd` (운영자 pem, bastion 경유) → `cd /home/ubuntu/Jenkins`
`<PW>` = `.env` 의 `JENKINS_ADMIN_PASSWORD`.

## 1. Job · 자격 (JCasC — GUI 없이 코드로)

`pipeline/jcasc/jenkins.yaml` 이 **자격 2개 + 멀티브랜치 Job(폴링)** 을 정의합니다. 비밀은 컨테이너 env 로 주입:

```bash
# jenkins_home/casc 에 jenkins.yaml 이 마운트되도록 override 적용(BUILD.md 참고) 후:
export NEXUS_CI_USER=ci
export NEXUS_CI_PASSWORD='<nexus ci 비번>'
export GITEA_SSH_PRIVATE_KEY="$(cat /path/jenkins_gitea_key)"
docker compose up -d           # JCasC 가 ${...} 치환해 자격/Job 생성 (재적용도 동일)
```
- `nexus-ci`(npm 자격), `gitea-ssh`(clone 키) 가 생성됨. Job = `acme-app` 멀티브랜치(3분 폴링).
- **파일에 비밀 평문 금지** — env 로만. Job 정의를 바꾸려면 `jenkins.yaml` 수정 후 `up -d`.

Gitea 쪽 준비: `jenkins` 계정 SSH **공개키**를 Gitea 에 등록(API), 그 개인키를 위 `GITEA_SSH_PRIVATE_KEY` 로.
이 `jenkins` 계정은 **app 저장소 clone + gitops 저장소 push**(이미지 태그 커밋) 둘 다 권한이 필요합니다
(`gitea-ssh` 자격을 sshagent 로 재사용). Nexus 쪽 준비: CI 계정 `ci` 발급(Nexus ADMIN.md).

## 2. 플러그인 (오프라인)

폐쇄망이라 온라인 설치 불가. 로컬(인터넷)에서 받아 반입:
```bash
# [로컬] pipeline/plugins.txt 기준으로 .hpi 다운로드 → 전송(jenkins_home/plugins/)
pipeline/scripts/11-download-jenkins-plugins.sh
pipeline/scripts/12-transfer-pipeline.sh
docker compose restart jenkins
```

## 3. 파이프라인 설정 채우기

`pipeline/pipeline.env` 의 `<AWS_ACCOUNT_ID>`·`ECR_*`·`GITEA_SSH_URL`·`GITOPS_REPO_URL`·`NEXUS_NPM_REGISTRY`
를 실제 값으로. AWS 는 CLI 없이 **ECR 인증만** REST(SigV4, `pipeline/scripts/lib-awssigv4.sh`) —
cicd VM 에 **ECR 권한 IAM 인스턴스 프로파일** 필요(EKS 권한은 불필요, 배포는 ArgoCD).
배포 매니페스트(Helm·ArgoCD)는 [gitops/](../gitops/README.md) 참고.

## 4. 운영

```bash
docker ps --filter name=jenkins                  # jenkins, jenkins-nginx Up
docker logs -f jenkins                            # 로그
docker compose restart                            # 재시작
./scripts/06-stop.sh                              # 중지(데이터 보존) / 재기동: docker compose up -d

# 상태 확인
curl -s -o /dev/null -w '%{http_code}\n' --cacert certs/server.crt https://localhost/login   # 200/403
docker exec jenkins java -jar /var/jenkins_home/war/WEB-INF/lib/cli-*.jar \
  -s http://localhost:8080/ -auth admin:<PW> who-am-i
```

**백업/복구** (대상: `./jenkins_home/` = Job·자격·설정 전부):
```bash
./scripts/06-stop.sh
tar czf jenkins-home-$(date +%F).tar.gz jenkins_home/ certs/
docker compose up -d
```

## 5. 앱 · GitOps 저장소 온보딩

1. **앱 저장소**(`acme/acme-app`) 생성, 루트에 `frontend/ backend/ Jenkinsfile pipeline/` 배치(USER.md).
2. **GitOps 저장소**(`acme/acme-gitops`) 생성, 레포의 `gitops/` 내용을 루트로 push. ArgoCD 가 이 repo 를 watch.
3. `jenkins` 계정 공개키를 Gitea 에 등록 → **두 저장소에 각각 clone/push 권한** 부여.
4. JCasC Job 의 app repo URL, `pipeline.env` 의 `GITOPS_REPO_URL` 확인.
5. dev 브랜치에 작은 커밋 → 폴링 → 빌드·ECR push·gitops 태그 커밋 → (ArgoCD가) 배포까지 1회 확인.

## 6. 메모

- **웹 UI 는 사용하지 않습니다.** 필요한 관리는 JCasC/CLI 로 충분하며, 인바운드(webhook)를 열지 않습니다
  (트리거=폴링). 굳이 브라우저로 봐야 하면 `ssh -L 9443:localhost:443 acme-cicd` 임시 터널.
- nginx(로컬 443)는 CLI/헬스체크·(임시) 터널 용도로 유지.
