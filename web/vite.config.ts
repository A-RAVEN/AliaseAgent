import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// 生产：核心进程直接 serve `dist/`，页面与 WS 同源（`/ws`）。
// 开发：`npm run dev` 起 Vite；把核心启动时回显的 URL 放进 `VITE_CORE_ORIGIN`
// （例如 `VITE_CORE_ORIGIN=http://127.0.0.1:54321`），Vite 把 `/ws` 代理到核心。
// 这里不写任何默认端口：没有来源的数字就是魔数。
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '');
  const coreOrigin = env.VITE_CORE_ORIGIN;
  return {
    plugins: [react(), tailwindcss()],
    server: coreOrigin
      ? {
          proxy: {
            '/ws': {
              target: coreOrigin,
              ws: true,
            },
          },
        }
      : undefined,
    // 纯逻辑单测走 vitest（node 环境，无 DOM）：renderMessages 归一/去重、
    // protocol 重连状态机、分页请求形状、tokens 一致性。**布局/滚动断言不在这里**
    // ——jsdom 没有布局引擎，那些走 `e2e/layout.mjs` 的 puppeteer 真实渲染。
    test: {
      environment: 'node',
      include: ['src/**/*.test.ts'],
      reporters: ['default'],
    },
  };
});
