# Nexus 소비자 가이드 (CICD 서버)

이 Nexus 는 **CICD 서버에서만** 아티팩트를 올리고(publish) 내려받는(consume) 용도로 씁니다.
사람이 브라우저로 쓰지 않습니다. CICD 서버도 bastion 뒤 private subnet VM 입니다.

## 1. 연결 경로

Nexus VM(`<NEXUS_IP>`)의 서비스는 **nginx TLS 443**(VM 로컬)만 열려 있고, VM SG 는 기본적으로
bastion→nexus **22만** 허용합니다. CICD 서버가 Nexus 에 접근하는 방법은 둘 중 하나:

| 방법 | 내용 | 권장 |
|---|---|---|
| **A. private 직접** | CICD·Nexus 가 같은 subnet 이므로 CICD → `https://<NEXUS_IP>/` 직접. **Nexus SG 에 `source=CICD VM → TCP 443` 규칙 1개** 추가 필요(출발지=CI 서버로만 제한). | ✅ 서버-서버, 터널 불필요 |
| B. bastion 22 터널 | CICD 가 bastion 으로 `ssh -L 18443:localhost:443 acme-nexus` 후 `https://localhost:18443/`. SG 변경 없이 22만으로 동작하나 상시 터널 관리 필요. | 폴백 |

> 방법 A 를 권장합니다(신뢰된 단일 내부 서버 1대만 443 을 여는 것이라 위험이 낮음). 아래 예시는
> `https://<NEXUS>/` 로 표기하며, A면 `<NEXUS_IP>`, B면 `localhost:18443` 로 읽으세요.

## 2. 자격증명 · 인증서

- **CI 전용 서비스 계정**(예: `ci`)을 사용합니다. admin 계정을 CI 에 넣지 마세요 — 관리자가 발급([ADMIN.md](ADMIN.md)).
- 자체 서명 인증서 `server.crt` 를 CICD 서버에 배포해 신뢰 등록(또는 각 툴의 CA 설정에 지정).
  ```bash
  # 운영자가 Nexus VM에서 받아 CICD 서버로 전달
  scp acme-nexus:/home/ubuntu/Nexus/certs/server.crt ./nexus.crt
  ```

## 3. 업로드 / 다운로드 (폐쇄망 = hosted 저장소)

인터넷 프록시가 불가하므로 CI 가 빌드 산출물을 **hosted 저장소에 직접 publish** 하고, 필요 시 내려받습니다.

```bash
NEXUS=https://<NEXUS_IP>        # 방법 A 기준
C='--cacert nexus.crt'; AUTH='ci:<CI_PASSWORD>'

# raw hosted 업로드/다운로드 (임의 파일)
curl $C -u "$AUTH" --upload-file mytool-1.0.0.tgz $NEXUS/repository/raw-hosted/demo/mytool-1.0.0.tgz
curl $C -u "$AUTH" -O               $NEXUS/repository/raw-hosted/demo/mytool-1.0.0.tgz

# maven 배포 예 (settings.xml 의 server id 자격 + distributionManagement URL)
#   <url>https://<NEXUS_IP>/repository/maven-releases/</url>
mvn deploy -Dhttps.protocols=TLSv1.2 -Djavax.net.ssl.trustStore=...   # 사내 CA/신뢰 설정 필요
```

포맷별 클라이언트 설정 요령(공통): **엔드포인트 = `https://<NEXUS>/repository/<repo>/`**, 인증 = CI 서비스 계정,
TLS = `nexus.crt` 신뢰. npm/pypi/docker 등도 동일 원리(해당 hosted repo + 클라이언트 registry 설정).

## 4. 문제 해결

| 증상 | 조치 |
|---|---|
| 연결 안 됨(직접) | Nexus SG 에 `CICD→nexus:443` 규칙 있는지 확인(방법 A). 없으면 방법 B 터널 |
| `SSL certificate problem` | `nexus.crt` 미신뢰. `--cacert`/툴 CA 설정, 접속 주소가 인증서 SAN(`<NEXUS_IP>`/`localhost`)과 일치하는지 |
| `401` | CI 계정/비번 오류 또는 익명 차단 상태. 서비스 계정 자격 확인 |
| `413`/`504` (대용량) | nginx `client_max_body_size`(1g)/`proxy_read_timeout`(600s) 상향 후 nginx 재시작(관리자) |
