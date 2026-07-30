# Nexus Repository — 폐쇄망 아티팩트 저장소

bastion 뒤 private subnet VM 에 Nexus(nexus3)를 Docker 로 올린 구성. **CICD 서버 전용**으로 쓰며
사람이 브라우저로 쓰지 않습니다. 관리·업로드는 REST API(curl)로만 합니다.

## 아키텍처

```
[운영자 PC] ──ssh22──▶ bastion ──22 터널(ssh -L)──▶ Nexus VM(<NEXUS_IP>) nginx:443 ──▶ nexus:8081
[CICD 서버 VM] ───── private subnet, https 443 직접 ─────▶ Nexus VM        (SG: CICD→nexus:443 규칙 필요)
```
- 인터넷 프록시 불가(폐쇄망) → CI 가 빌드 산출물을 **hosted 저장소에 직접 publish/consume**.
- nginx 가 TLS(자체서명) 종료, Nexus(8081)는 컨테이너 내부만. 익명 접근 비활성.

## 빠른 사실

| 항목 | 값 |
|---|---|
| Nexus VM | `<NEXUS_IP>` (private, `ssh acme-nexus` bastion 경유) |
| 소비자 | **CICD 서버**(예정, 같은 private subnet VM) — 유일 사용처 |
| 접근 | nginx TLS 443(VM 로컬). 운영자=bastion 22 터널 / CICD=private 직접(권장) |
| 이미지 | `sonatype/nexus3:3.70.1` + `nginx:1.27-alpine` (amd64) |
| 관리자 | `admin` / `.env` 의 `ADMIN_PASSWORD` (CI 는 전용 계정 사용) |
| 데이터(백업) | `/home/ubuntu/Nexus/nexus-data/` |
| SG | bastion→nexus **22만**. CICD→nexus **443** 은 CICD 구축 시 별도 규칙 |

## 문서 (역할별)

| 역할 | 문서 | 내용 |
|---|---|---|
| **서버 구축자** | [BUILD.md](BUILD.md) | 이미지 오프라인 배포·기동·초기화, SG |
| **관리자** | [ADMIN.md](ADMIN.md) | CI 서비스 계정 발급, 저장소 관리, 운영·백업 |
| **사용자(CICD 서버)** | [USER.md](USER.md) | 연결 경로(직접/터널), 자격증명, 업로드/다운로드 |
