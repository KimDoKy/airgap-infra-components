# Nexus 패키지 업로드 검증 (hands-on)

폐쇄망 경로로 **로컬 PC → bastion → Nexus** 에 패키지를 적재하고, Nexus 에서 적재를 확인하는 실습.
아래를 순서대로 따라 하면 동일하게 재현됩니다. (실측 통과: 2026-07-30)

## 시나리오

```
[로컬 PC] ──scp(22)──▶ [bastion] ──scp(22)──▶ [Nexus VM] ──curl(localhost:443)──▶ Nexus(raw-hosted)
   ①패키지 생성           ②전달                     ③적재                          ④확인/정리
```
- bastion→Nexus 는 **22만** 열려 있어(443 차단), 파일을 nexus VM 으로 relay 한 뒤 **VM 내부 localhost:443**(loopback)로 적재합니다.
- Nexus 인증서는 VM 의 `/home/ubuntu/Nexus/certs/server.crt` 를 그 자리에서 쓰므로 **인증서 복사 불필요**.

## 사전 준비

1. 로컬 `~/.ssh/config` 에 `acme-bastion`, `acme-nexus`(ProxyJump acme-bastion) 별칭 + `acme-poc-svr.pem`.
2. **SSH 에이전트에 pem 로드** (아래 ②에서 bastion→nexus 접속에 에이전트 포워딩을 씀):
   ```bash
   ssh-add ~/.ssh/acme-poc-svr.pem      # ssh-add -l 로 로드 확인
   ```
   > bastion 에는 VM 접속 키를 두지 않습니다(보안). pem 을 bastion 에 복사하지 말고 `ssh -A`(에이전트 포워딩)로 빌려줍니다.
3. Nexus 에 **`raw-hosted` 저장소**가 있어야 합니다(없으면 `ADMIN.md` 2절로 생성). 계정은 CI 계정 `ci`(또는 `admin`).
   - `<CI_PW>` = Nexus `ci` 계정 비밀번호(문서에 평문 금지 — 각자 대입).

---

## ① [로컬 PC] 임의 패키지 생성 + bastion 업로드

```bash
# 임의 패키지 생성 + 로컬 체크섬 (뒤에서 비교)
mkdir -p /tmp/demo-pkg/bin
echo "acme demo payload $(date -u +%FT%TZ)" > /tmp/demo-pkg/README.txt
printf '#!/bin/sh\necho hello-acme\n' > /tmp/demo-pkg/bin/run.sh
tar czf /tmp/demo-pkg-1.0.0.tgz -C /tmp/demo-pkg .
sha256sum /tmp/demo-pkg-1.0.0.tgz          # ← 이 값을 기록(④에서 비교)

# bastion 으로 업로드
ssh acme-bastion 'mkdir -p ~/stage'
scp /tmp/demo-pkg-1.0.0.tgz acme-bastion:~/stage/
ssh acme-bastion 'ls -l ~/stage/demo-pkg-1.0.0.tgz'
```
기대: `scp` 성공, bastion 에 파일 존재. 로컬 sha256 예: `bccbdc67…a0f73d`.

---

## ② [bastion] nexus 로 전달 + Nexus 에 적재

에이전트 포워딩으로 bastion 에 접속한 뒤, bastion 셸에서 실행:
```bash
ssh -A acme-bastion          # ← -A 로 pem 을 bastion 에 빌려줌
```
```bash
# (bastion 셸)  nexus VM 으로 전달 → nexus 에서 Nexus 에 적재
NEX=ubuntu@<NEXUS_IP>
scp ~/stage/demo-pkg-1.0.0.tgz $NEX:/tmp/demo-pkg-1.0.0.tgz

ssh $NEX "curl -s -o /dev/null -w 'upload http=%{http_code}\n' \
  --cacert /home/ubuntu/Nexus/certs/server.crt -u 'ci:<CI_PW>' \
  --upload-file /tmp/demo-pkg-1.0.0.tgz \
  https://localhost/repository/raw-hosted/staged/demo-pkg-1.0.0.tgz"
```
기대: `upload http=201` (신규 적재). 이미 있으면 재적재도 201(raw-hosted writePolicy=ALLOW).

---

## ③ [Nexus] 적재 확인 (bastion 셸에서 이어서)

```bash
NEX=ubuntu@<NEXUS_IP>
# (3a) 컴포넌트 목록에 보이는지
ssh $NEX "curl -s --cacert /home/ubuntu/Nexus/certs/server.crt -u 'ci:<CI_PW>' \
  'https://localhost/service/rest/v1/components?repository=raw-hosted' \
  | grep -o '\"name\" : \"staged/[^\"]*\"'"

# (3b) 재다운로드 후 sha256 (①의 로컬 값과 같아야 무결성 OK)
ssh $NEX "curl -s --cacert /home/ubuntu/Nexus/certs/server.crt -u 'ci:<CI_PW>' \
  'https://localhost/repository/raw-hosted/staged/demo-pkg-1.0.0.tgz' -o /tmp/dl.tgz \
  -w 'download http=%{http_code}\n'; sha256sum /tmp/dl.tgz"
```
기대:
- `"name" : "staged/demo-pkg-1.0.0.tgz"` (목록에 존재)
- `download http=200`, sha256 = **①에서 기록한 로컬 값과 동일** → 업로드/다운로드 무결성 PASS.

> 웹 UI 없이도 확인됩니다. (브라우저로 보려면 운영자가 `ssh -L`로 443 터널 후 접속 — ADMIN.md 참고)

---

## ④ [정리] (선택)

```bash
NEX=ubuntu@<NEXUS_IP>
# Nexus 에서 테스트 아티팩트 삭제
ssh $NEX "curl -s -o /dev/null -w 'delete http=%{http_code}\n' \
  --cacert /home/ubuntu/Nexus/certs/server.crt -u 'ci:<CI_PW>' \
  -X DELETE https://localhost/repository/raw-hosted/staged/demo-pkg-1.0.0.tgz; \
  rm -f /tmp/demo-pkg-1.0.0.tgz /tmp/dl.tgz"
# 임시파일 정리
exit                                   # bastion 셸 종료 (로컬로 복귀)
ssh acme-bastion 'rm -rf ~/stage'
rm -f /tmp/demo-pkg-1.0.0.tgz; rm -rf /tmp/demo-pkg
```
기대: `delete http=204`, 재조회 시 `staged/demo-pkg` 잔존 0.

---

## 기대 결과 요약

| 단계 | 명령/확인 | 기대 |
|---|---|---|
| ① | `scp … acme-bastion` | 성공, bastion 에 파일 |
| ② | Nexus 적재 `curl --upload-file` | `upload http=201` |
| ③a | 컴포넌트 목록 | `staged/demo-pkg-1.0.0.tgz` 표시 |
| ③b | 재다운로드 + sha256 | `download http=200`, sha256 = 로컬 원본과 **일치** |
| ④ | 삭제 | `delete http=204`, 잔존 0 |

## 문제 해결

| 증상 | 원인/조치 |
|---|---|
| ② scp 시 `Permission denied (publickey)` | `ssh -A` 미사용 또는 에이전트에 pem 미로드. `ssh-add ~/.ssh/acme-poc-svr.pem` 후 `ssh -A` |
| `upload http=401` | `ci` 자격/비번 오류. `-u 'ci:<CI_PW>'` 확인 (또는 `admin:<ADMIN_PASSWORD>`) |
| `upload http=404` | `raw-hosted` 저장소 없음. ADMIN.md 2절로 생성 |
| `curl SSL certificate problem` | VM 로컬 실행이므로 `--cacert /home/ubuntu/Nexus/certs/server.crt` 경로 확인, 접속 주소가 `localhost`인지 |
| sha256 불일치 | 전송 중 손상/다른 파일. 재수행. (raw 는 재적재 허용이라 그대로 다시 올리면 됨) |
