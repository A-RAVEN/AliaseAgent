// 归一 / 合并 / 去重层（change `web-chat-screen` 任务 3.1 / design D7）。
//
// 这一层存在的理由：live 事件与 history 加载拿到的是**两种形状**——
//   - live 的 tool.call/tool.result 是 `ToolCallActivity.toJson()`（toolName/status/result）；
//   - 中间助手消息里持久化的 toolCalls 是原始 `{type,id,name,input}`（工具执行前落库），
//     工具结果回来后富化并写库但**不再发 assistant.message**；
//   - 最终助手消息聚合整轮 toolCalls（`allTurnToolCalls` 并集），与中间消息重叠；
//   - thinking 在 live 事件里带 index，在 history 的 thinkingJson 里没有 index。
// 不先归一，同一会话在 live 与 history 下会渲染成两种样子，且工具卡会重复。
import { describe, expect, it } from 'vitest';

import {
  mergeMessages,
  normalizeMessage,
  normalizeThinking,
  normalizeToolCalls,
  type RawMessage,
} from './model';

function obs(label: string, value: unknown): void {
  console.log(`[归一] ${label}: ${JSON.stringify(value)}`);
}

function rawTool(id: string, name: string, input: Record<string, unknown> = {}) {
  return { type: 'tool_use', id, name, input };
}

function enrichedTool(
  id: string,
  name: string,
  input: Record<string, unknown>,
  status: string,
  result: string,
) {
  return { id, toolName: name, input, status, result, resultPreview: result };
}

describe('normalizeToolCalls：原始形状与富化形状归一到同一份', () => {
  it('name → toolName，缺 status 补 executing（history 中间消息的原始形状）', () => {
    const tools = normalizeToolCalls([rawTool('t1', 'read_file', { path: 'a.txt' })]);
    obs('原始形状归一结果', tools);
    expect(tools).toHaveLength(1);
    expect(tools[0]).toMatchObject({
      id: 't1',
      toolName: 'read_file',
      status: 'executing',
      input: { path: 'a.txt' },
    });
  });

  it('富化形状原样保留 status/result/resultPreview', () => {
    const tools = normalizeToolCalls([
      enrichedTool('t1', 'read_file', { path: 'a.txt' }, 'done', '文件内容'),
    ]);
    obs('富化形状归一结果', tools);
    expect(tools[0]).toMatchObject({
      id: 't1',
      toolName: 'read_file',
      status: 'done',
      result: '文件内容',
      resultPreview: '文件内容',
    });
  });

  it('按 id 去重（同一工具只留一张卡）', () => {
    const tools = normalizeToolCalls([
      rawTool('t1', 'read_file'),
      enrichedTool('t1', 'read_file', {}, 'done', 'x'),
    ]);
    obs('去重后的工具卡', tools);
    expect(tools).toHaveLength(1);
    expect(tools[0].status).toBe('done');
  });

  it('非数组 / null 归一为空数组，不抛', () => {
    expect(normalizeToolCalls(null)).toEqual([]);
    expect(normalizeToolCalls(undefined)).toEqual([]);
    expect(normalizeToolCalls('oops')).toEqual([]);
  });
});

describe('normalizeThinking：index 归一（live 带 index、history 按位置派生）', () => {
  it('history 的 thinkingJson（无 index）按数组位置派生 index', () => {
    const blocks = normalizeThinking([
      { type: 'thinking', thinking: '第一段' },
      { type: 'thinking', thinking: '第二段' },
    ]);
    obs('history 思考块', blocks);
    expect(blocks.map((block) => block.index)).toEqual([0, 1]);
    expect(blocks.map((block) => block.text)).toEqual(['第一段', '第二段']);
  });

  it('live 形状（index + thinking）保留显式 index', () => {
    const blocks = normalizeThinking([{ index: 3, thinking: '带 index 的思考' }]);
    obs('live 思考块', blocks);
    expect(blocks[0].index).toBe(3);
    expect(normalizeThinking([{ index: 0, text: '用 text 字段' }])[0].text).toBe('用 text 字段');
  });
});

describe('normalizeMessage', () => {
  it('空正文工具轮消息归一出 toolCalls 与 thinking，正文保持空', () => {
    const message = normalizeMessage({
      id: 'm1',
      role: 'assistant',
      content: '',
      toolCalls: [rawTool('t1', 'read_file'), rawTool('t2', 'grep_file')],
      thinking: [{ type: 'thinking', thinking: '先看文件' }],
    });
    obs('归一后的消息', message);
    expect(message.content).toBe('');
    expect(message.toolCalls.map((tool) => tool.toolName)).toEqual(['read_file', 'grep_file']);
    expect(message.thinking.map((block) => block.text)).toEqual(['先看文件']);
  });
});

describe('mergeMessages：按 id 去重（分页/重连/直播共用）', () => {
  it('已存在的消息用新版本替换，顺序不变；新消息追加', () => {
    const existing: RawMessage[] = [
      { id: 'a', role: 'user', content: '问' },
      { id: 'b', role: 'assistant', content: '旧回复' },
    ];
    const merged = mergeMessages(existing, [
      { id: 'b', role: 'assistant', content: '新回复' },
      { id: 'c', role: 'assistant', content: '更新的回复' },
    ]);
    obs('合并结果', merged);
    expect(merged.map((message) => message.id)).toEqual(['a', 'b', 'c']);
    expect(merged[1].content).toBe('新回复');
  });

  it('完全重复的批次不改变数组内容', () => {
    const existing: RawMessage[] = [{ id: 'a', role: 'user', content: '问' }];
    const merged = mergeMessages(existing, [{ id: 'a', role: 'user', content: '问' }]);
    obs('重复批次后的条数', merged.length);
    expect(merged).toHaveLength(1);
  });
});
