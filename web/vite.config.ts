import { defineConfig, loadEnv } from 'vite';
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
  };
});
