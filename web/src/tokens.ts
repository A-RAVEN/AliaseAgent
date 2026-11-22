// 设计 tokens（change `web-chat-screen` 任务 1.1 / design D1~D6、D9、D12）。
//
// **单一事实源的数值/字符串这里给；CSS 侧在 `index.css` 的 `@theme`**，两处的
// 颜色 / 字阶 / 圆角 / elevation 必须一致 —— `src/tokens.test.ts` 解析两份逐项比对
// （改一处不改另一处会红）。
//
// 可配参数（重连四参数 + 贴底阈值）走 Vite 环境变量：默认值在下面导出为常量，
// 取值范围是"正数"（毫秒/像素），配错不静默 —— 回退默认值并在控制台说明。
// 用户文档键表见 `Docs/user-guide/web-core-shim.md` 的「完整聊天屏参数」一节，
// `test/unit/web_chat_docs_test.dart` 把文档行与这些常量绑死。

/** 中性 ramp + 单一 sky accent + 语义色（design D2）。组件禁裸 hex。 */
export const palette = {
  bg: '#0b0f19',
  surface: '#111726',
  surface2: '#1b2333',
  border: '#2a3346',
  muted: '#8b93a7',
  text: '#e6e9ef',
  accent: '#38bdf8',
  success: '#34d399',
  warning: '#fbbf24',
  danger: '#f87171',
} as const;

/** 五档字阶（design D3）：12/14/16 沿用既有档，20/25 从 16 按 1.25 延伸。 */
export const typeScale = {
  xs: 12,
  sm: 14,
  base: 16,
  xl: 20,
  xxl: 25,
} as const;

/** 行高（px）：正文 16×1.5=24；折叠卡固定行高也是 24（design D7）。 */
export const lineHeights = {
  xs: 16,
  sm: 20,
  base: 24,
  xl: 24,
  xxl: 32,
  /** 折叠态工具卡/思考卡的固定单行高度（= 正文行高，puppeteer 断言用它）。 */
  card: 24,
} as const;

/** 间距 scale（design D4）：所有 padding/margin/gap 只能取这些值。 */
export const spacingScale = [4, 8, 12, 16, 24, 32, 48, 64] as const;

/** 圆角（design D5）：单圆角 8px，大表面 12px 一档。 */
export const radii = {
  card: 8,
  panel: 12,
} as const;

/** 两级 elevation（design D5）。 */
export const elevation = {
  e1: '0 1px 2px rgb(0 0 0 / 0.35)',
  e2: '0 8px 24px rgb(0 0 0 / 0.45)',
} as const;

/** 图标集（design D5）：只用 lucide-react，禁 emoji 当图标。 */
export const icons = {
  chevronDown: 'ChevronDown',
} as const;

// ---------------------------------------------------------------------------
// 可配参数（配置项出处分支：默认值 + 范围 + 用户文档键表）
// ---------------------------------------------------------------------------

/** 贴底阈值 px。出处：design D9 —— 间距 scale 的 24 步长 = 正文行高 16×1.5。 */
export const kDefaultBottomThresholdPx = 24;
/** 重连退避基数 ms。出处：产品先例 kimi_search 的 429 重试 1s 起步。 */
export const kDefaultReconnectBaseMs = 1000;
/** 重连退避上限 ms（助手定的默认可配）。 */
export const kDefaultReconnectCapMs = 30000;
/** 心跳发送周期 ms（助手定的默认可配）。 */
export const kDefaultHeartbeatPeriodMs = 15000;
/** 心跳等待回应上限 ms，超时判死触发重连（助手定的默认可配）。 */
export const kDefaultHeartbeatTimeoutMs = 5000;

export const kBottomThresholdEnvKey = 'VITE_BOTTOM_THRESHOLD_PX';
export const kReconnectBaseEnvKey = 'VITE_RECONNECT_BASE_MS';
export const kReconnectCapEnvKey = 'VITE_RECONNECT_CAP_MS';
export const kHeartbeatPeriodEnvKey = 'VITE_HEARTBEAT_PERIOD_MS';
export const kHeartbeatTimeoutEnvKey = 'VITE_HEARTBEAT_TIMEOUT_MS';

/** 可配参数快照（RpcClient / 消息列表滚动判定都从这里取，不各自写数字）。 */
export interface LayoutConfig {
  bottomThresholdPx: number;
  reconnectBaseMs: number;
  reconnectCapMs: number;
  heartbeatPeriodMs: number;
  heartbeatTimeoutMs: number;
}

/** 读一个"正数"配置项：未设置 → 默认值；配错 → 默认值 + 控制台说明（不静默）。 */
function readPositive(
  env: Record<string, unknown>,
  key: string,
  fallback: number,
  warnings: string[],
): number {
  const raw = env[key];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    warnings.push(`${key}=${String(raw)} 不是正数，回退默认值 ${fallback}`);
    return fallback;
  }
  return parsed;
}

/**
 * 从环境变量读可配参数（纯函数，便于单测；浏览器里用 [layoutConfig]）。
 *
 * 范围：各项必须是正数（毫秒/像素）。退化情形只有一种，且可见：
 * `cap < base` 时把 cap 抬到 base（否则"指数退避"的间隔会小于基数），并告警。
 */
export function readLayoutConfig(
  env: Record<string, unknown> = {},
  onWarning: (message: string) => void = (message) => console.warn(`[tokens] ${message}`),
): LayoutConfig {
  const warnings: string[] = [];
  const config: LayoutConfig = {
    bottomThresholdPx: readPositive(
      env, kBottomThresholdEnvKey, kDefaultBottomThresholdPx, warnings),
    reconnectBaseMs: readPositive(
      env, kReconnectBaseEnvKey, kDefaultReconnectBaseMs, warnings),
    reconnectCapMs: readPositive(
      env, kReconnectCapEnvKey, kDefaultReconnectCapMs, warnings),
    heartbeatPeriodMs: readPositive(
      env, kHeartbeatPeriodEnvKey, kDefaultHeartbeatPeriodMs, warnings),
    heartbeatTimeoutMs: readPositive(
      env, kHeartbeatTimeoutEnvKey, kDefaultHeartbeatTimeoutMs, warnings),
  };
  if (config.reconnectCapMs < config.reconnectBaseMs) {
    warnings.push(
      `${kReconnectCapEnvKey}=${config.reconnectCapMs} 小于 ${kReconnectBaseEnvKey}=` +
        `${config.reconnectBaseMs}，cap 抬到 base`,
    );
    config.reconnectCapMs = config.reconnectBaseMs;
  }
  for (const warning of warnings) onWarning(warning);
  return config;
}

/** 浏览器/构建期生效的一份（`import.meta.env` 里的 VITE_* 键）。 */
export const layoutConfig: LayoutConfig = readLayoutConfig(
  (import.meta as unknown as { env?: Record<string, unknown> }).env ?? {},
);
