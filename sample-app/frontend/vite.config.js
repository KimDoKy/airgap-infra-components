import { defineConfig } from 'vite';

// hello world 정적 빌드 → dist/ (nginx 가 서빙)
export default defineConfig({
  build: { outDir: 'dist', emptyOutDir: true },
});
