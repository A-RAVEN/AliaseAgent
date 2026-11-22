// 消息分页的请求形状与合并规则（change `web-chat-screen` 任务 5.2 / design D10）。
//
// 为什么单独测请求形状：`message.query` 的尾锚/反向游标是本 change 对核心的
// additive 扩展（`web-core-shim` MODIFIED delta）。UI 只要漏传 `anchor: 'tail'`
// 就会退回"最旧页开场"（扩展前的行为），而这种退化在界面上很隐蔽——
// 用户看到的是"打开会话先看到很早以前的消息"，不是报错。这里把参数钉死。
import { describe, expect, it } from 'vitest';

import type { RawMessage } from './model';
import {
  loadEarlierPage,
  loadInitialPage,
  mergeLatest,
  prependOlder,
  restoreMessages,
  type MessagePageResult,
  type RequestFn,
} from './paging';

function obs(label: string, value: unknown): void {
  console.log(`[分页] ${label}: ${JSON.stringify(value)}`);
}

interface Call {
  method: string;
  params: Record<string, unknown>;
}

function fakeRequest(result: MessagePageResult): { request: RequestFn; calls: Call[] } {
  const calls: Call[] = [];
  const request: RequestFn = async <T,>(method: string, params: Record<string, unknown> = {}) => {
    calls.push({ method, params });
    return result as T;
  };
  return { request, calls };
}

function message(id: string, seq: number, content = id): RawMessage {
  return { id, seq, role: 'assistant', content };
}

describe('首屏：尾锚取最新一页', () => {
  it('发 anchor=tail + pageSize，earlierCursor 取 prevCursor', async () => {
    const { request, calls } = fakeRequest({
      messages: [message('m-31', 31), message('m-32', 32)],
      nextCursor: null,
      prevCursor: 31,
    });
    const page = await loadInitialPage(request, 'session-1', 30);
    obs('请求参数', calls);
    obs('返回窗口', page);
    expect(calls).toEqual([
      { method: 'message.query', params: { sessionId: 'session-1', pageSize: 30, anchor: 'tail' } },
    ]);
    expect(page.messages.map((item) => item.id)).toEqual(['m-31', 'm-32']);
    expect(page.earlierCursor).toBe(31);
    expect(page.hasEarlier).toBe(true);
  });

  it('prevCursor 为 null 时 hasEarlier=false（没有更早页可翻）', async () => {
    const { request } = fakeRequest({
      messages: [message('m-1', 1)],
      nextCursor: null,
      prevCursor: null,
    });
    const page = await loadInitialPage(request, 'session-1', 30);
    obs('hasEarlier', page.hasEarlier);
    expect(page.earlierCursor).toBeNull();
    expect(page.hasEarlier).toBe(false);
  });
});

describe('上翻：反向游标加载更早一页', () => {
  it('发 before=prevCursor（不发 anchor/cursor），返回新 prevCursor', async () => {
    const { request, calls } = fakeRequest({
      messages: [message('m-1', 1), message('m-2', 2)],
      nextCursor: 2,
      prevCursor: 1,
    });
    const page = await loadEarlierPage(request, 'session-1', 30, 3);
    obs('请求参数', calls);
    obs('返回窗口', page);
    expect(calls).toEqual([
      { method: 'message.query', params: { sessionId: 'session-1', pageSize: 30, before: 3 } },
    ]);
    expect(page.earlierCursor).toBe(1);
    expect(page.hasEarlier).toBe(true);
  });
});

describe('合并：去重 + 顺序', () => {
  it('更早页插到最前，按 id 去重（不重叠时全部保留）', () => {
    const existing = [message('m-3', 3), message('m-4', 4)];
    const older = [message('m-1', 1), message('m-2', 2)];
    const merged = prependOlder(existing, older);
    obs('合并结果', merged.map((item) => item.id));
    expect(merged.map((item) => item.id)).toEqual(['m-1', 'm-2', 'm-3', 'm-4']);
  });

  it('与已加载页重叠的消息不重复渲染', () => {
    const existing = [message('m-3', 3), message('m-4', 4)];
    const older = [message('m-2', 2), message('m-3', 3)];
    const merged = prependOlder(existing, older);
    obs('重叠时的合并结果', merged.map((item) => item.id));
    expect(merged.map((item) => item.id)).toEqual(['m-2', 'm-3', 'm-4']);
    expect(merged).toHaveLength(3);
  });

  it('重连重拉：按 id 更新已存在消息、追加新消息（不产生重复）', () => {
    const existing = [message('m-3', 3, '旧文本'), message('m-4', 4)];
    const latest = [message('m-3', 3, '新文本'), message('m-5', 5)];
    const merged = mergeLatest(existing, latest);
    obs('重连合并结果', merged.map((item) => `${item.id}:${item.content}`));
    expect(merged.map((item) => item.id)).toEqual(['m-3', 'm-4', 'm-5']);
    expect(merged[0].content).toBe('新文本');
  });
});

describe('重连恢复当前页（design D12：重拉当前页 + 核心广播，无 ensure RPC）', () => {
  it('重拉尾锚页并与已加载页合并：旧页不丢、新消息追加', async () => {
    const { request, calls } = fakeRequest({
      messages: [message('m-31', 31, '新版本'), message('m-32', 32)],
      nextCursor: null,
      prevCursor: 31,
    });
    const existing = [message('m-1', 1), message('m-31', 31, '旧版本')];
    const page = await loadInitialPage(request, 'session-1', 30);
    const restored = restoreMessages(existing, page.messages);
    obs('恢复请求参数', calls);
    obs('恢复后的消息', restored.map((item) => `${item.id}:${item.content}`));
    expect(calls).toEqual([
      { method: 'message.query', params: { sessionId: 'session-1', pageSize: 30, anchor: 'tail' } },
    ]);
    expect(restored.map((item) => item.id)).toEqual(['m-1', 'm-31', 'm-32']);
    expect(restored[1].content).toBe('新版本');
  });
});
