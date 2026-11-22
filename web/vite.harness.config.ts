// 布局/滚动测试 harness 的构建配置（change `web-chat-screen` 任务 2.1）。
//
// 独立入口 + 独立输出目录：`web/dist-test/`（gitignore）。生产构建 `vite build`
// 不包含 harness，harness 也不进核心 serve 的 `web/dist`。
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  root: 'test/harness',
  base: './',
  plugins: [react(), tailwindcss()],
  build: {
    outDir: '../../dist-test',
    emptyOutDir: true,
  },
});
