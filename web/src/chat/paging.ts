// 消息分页的请求形状与合并规则（change `web-chat-screen` 任务 5.2 / design D10）。
//
// message.query 的尾锚（anchor=tail）与反向游标（before=prevCursor）是本 change 对
// 核心的 additive 扩展（web-core-shim MODIFIED delta）。UI 漏传 anchor 就会退回
// "最旧页开场"，漏传 before 就会重复取同一页 —— 两种退化在界面上都不报错，只是
// 内容不对，所以参数形状必须由测试钉住（核心侧另见 test/integration/web_core_rpc_test.dart）。
import { mergeMessages, type RawMessage } from './model';

export type RequestFn = <T = unknown>(
  method: string,
  params?: Record<string, unknown>,
) => Promise<T>;

export interface MessagePageResult {
  messages: RawMessage[];
  nextCursor: number | null;
  prevCursor: number | null;
}

/** 一页窗口：本页消息 + 更早一页的反向游标（null = 没有更早页）。 */
export interface PageWindow {
  messages: RawMessage[];
  earlierCursor: number | null;
  hasEarlier: boolean;
}

function toWindow(result: MessagePageResult): PageWindow {
  const earlierCursor = result.prevCursor ?? null;
  return {
    messages: result.messages ?? [],
    earlierCursor,
    hasEarlier: earlierCursor !== null,
  };
}

/** 首屏：尾锚取**最新一页**（不是最旧页）。 */
export async function loadInitialPage(
  request: RequestFn,
  sessionId: string,
  pageSize: number,
): Promise<PageWindow> {
  const result = await request<MessagePageResult>('message.query', {
    sessionId,
    pageSize,
    anchor: 'tail',
  });
  return toWindow(result);
}

/** 上翻：用上一页的 prevCursor 取 `seq < before` 的更早一页。 */
export async function loadEarlierPage(
  request: RequestFn,
  sessionId: string,
  pageSize: number,
  beforeSeq: number,
): Promise<PageWindow> {
  const result = await request<MessagePageResult>('message.query', {
    sessionId,
    pageSize,
    before: beforeSeq,
  });
  return toWindow(result);
}

/** 更早一页插到最前面（按 id 去重，避免与已加载页重叠时渲染两遍）。 */
export function prependOlder(existing: RawMessage[], older: RawMessage[]): RawMessage[] {
  const known = new Set(existing.map((message) => message.id));
  const fresh = older.filter((message) => !known.has(message.id));
  return [...fresh, ...existing];
}

/** 重连重拉当前页：按 id 更新已存在消息、追加新消息（不丢已上翻加载的旧页）。 */
export function mergeLatest(existing: RawMessage[], latest: RawMessage[]): RawMessage[] {
  return mergeMessages(existing, latest);
}

/**
 * 重连成功后的状态恢复（design D12）= 重拉尾锚页 + 按 id 合并：
 * 断线期间已落库的消息补进来，用户已上翻加载的旧页保留。
 *
 * 核心没有 ensure/subscribe RPC —— 重连后的后续事件靠核心 `_broadcast` 到当前
 * 订阅者（新连接）到达，这里只补"可能错过"的已落库消息。
 */
export function restoreMessages(existing: RawMessage[], latestPage: RawMessage[]): RawMessage[] {
  return mergeLatest(existing, latestPage);
}
