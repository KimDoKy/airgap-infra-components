# 프론트엔드 이미지 — 멀티스테이지: (1) Node 로 vite 빌드(의존성은 Nexus), (2) nginx 로 정적 서빙.
# CI 가 빌드 컨텍스트에 .npmrc(Nexus 레지스트리+CI 자격)를 렌더링해 두면 COPY 되어 사용됨.
FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
COPY .npmrc* ./
RUN npm install && rm -f .npmrc
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
