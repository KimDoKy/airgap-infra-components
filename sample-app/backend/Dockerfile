# 백엔드 이미지 (Node.js). 의존성은 Nexus npm 레지스트리에서.
# CI 가 빌드 컨텍스트에 .npmrc(Nexus 레지스트리+CI 자격)를 렌더링해 두면 COPY 되어 사용됨.
FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
COPY .npmrc* ./
# 폐쇄망: registry 는 .npmrc 로 Nexus 지정. lockfile 있으면 `npm ci` 권장.
RUN npm install --omit=dev && rm -f .npmrc
COPY src ./src

FROM node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/src ./src
COPY package.json ./
EXPOSE 3000
USER node
CMD ["node", "src/server.js"]
