// 流式语义（change `web-chat-screen` 任务 3.3 / design D8）。
//
// D8 的两条硬时序：
//   ① 每条 `assistant.message`（含中间工具轮 isFinal=false）**落定当轮**的流式文本、
//      清空缓冲 —— 下一轮的 chunk 不许再累积进上一轮残留文本；
//   ② 整轮流式态只信 `agent.streaming` —— `turn.completed` 是"每次 API 请求结束"
//      就发（工具轮后面还会再发一次），拿它判整轮会在工具执行期间把"正在生成"误关。
import { describe, expect, it } from 'vitest';

import { applyAgentEvent } from './events';
import type { ChatView } from './model';
import { emptyChatView, renderMessages } from './render';

function obs(label: string, value: unknown): void {
  console.log(`[流式] ${label}: ${JSON.stringify(value)}`);
}

function applyAll(events: { type: string; data?: Record<string, unknown> }[]): ChatView {
  return events.reduce<ChatView>((view, event) => applyAgentEvent(view, event), emptyChatView);
}

function texts(view: ChatView): string[] {
  return renderMessages(view)
    .filter((item) => item.kind === 'assistant' || item.kind === 'streaming')
    .map((item) => `${item.kind}:${item.text}`);
}

describe('assistant.message 落定当轮（不串轮）', () => {
  it('中间轮落定后清空缓冲，下一轮 chunk 不累积进上一轮', () => {
    const view = applyAll([
      { type: 'agent.streaming', data: { streaming: true } },
      { type: 'assistant.chunk', data: { text: '第一轮：我先读文件' } },
      {
        type: 'assistant.message',
        data: {
          id: 'm-intermediate',
          role: 'assistant',
          content: '第一轮：我先读文件',
          toolCalls: null,
          thinking: null,
          isFinal: false,
        },
      },
      { type: 'assistant.chunk', data: { text: '第二轮：结论' } },
    ]);
    obs('流式缓冲', view.streamingText);
    obs('渲染出的文本 item', texts(view));
    expect(view.streamingText).toBe('第二轮：结论');
    expect(texts(view)).toEqual([
      'assistant:第一轮：我先读文件',
      'streaming:第二轮：结论',
    ]);
  });

  it('两个中间轮各自落定成独立气泡（不合并成一条）', () => {
    const view = applyAll([
      { type: 'assistant.chunk', data: { text: '第一轮' } },
      {
        type: 'assistant.message',
        data: { id: 'm1', role: 'assistant', content: '第一轮', isFinal: false },
      },
      { type: 'assistant.chunk', data: { text: '第二轮' } },
      {
        type: 'assistant.message',
        data: { id: 'm2', role: 'assistant', content: '第二轮', isFinal: false },
      },
      { type: 'assistant.chunk', data: { text: '最终结论' } },
      {
        type: 'assistant.message',
        data: { id: 'm3', role: 'assistant', content: '最终结论', isFinal: true },
      },
    ]);
    obs('落定后的消息条数', view.messages.length);
    expect(view.messages.map((message) => message.content)).toEqual([
      '第一轮',
      '第二轮',
      '最终结论',
    ]);
    expect(view.streamingText).toBe('');
  });
});

describe('整轮流式态以 agent.streaming 为准（不用 turn.completed）', () => {
  it('turn.completed 到达后仍 streaming=true（工具执行期间不闪断）', () => {
    let view = applyAll([
      { type: 'agent.streaming', data: { streaming: true } },
      { type: 'assistant.chunk', data: { text: '要调工具了' } },
      { type: 'turn.completed', data: {} },
      {
        // 真实时序：turn.completed 先发，随后中间消息落库并推 assistant.message。
        type: 'assistant.message',
        data: { id: 'm1', role: 'assistant', content: '要调工具了', isFinal: false },
      },
      {
        type: 'tool.call',
        data: { id: 't1', toolName: 'read_file', input: { path: 'a.txt' }, status: 'executing' },
      },
    ]);
    obs('turn.completed + tool.call 之后 isStreaming', view.isStreaming);
    expect(view.isStreaming).toBe(true);
    // 工具执行期间（无文本）应显示"正在生成"而不是"已结束"。
    expect(renderMessages(view).some((item) => item.kind === 'indicator')).toBe(true);

    view = applyAgentEvent(view, { type: 'agent.streaming', data: { streaming: false } });
    obs('agent.streaming=false 之后 isStreaming', view.isStreaming);
    expect(view.isStreaming).toBe(false);
  });
});

describe('live 思考 / live 工具并进消息后不重复', () => {
  it('思考块与工具卡在中间消息落定后各只出现一次', () => {
    const view = applyAll([
      { type: 'thinking.delta', data: { index: 0, delta: '先读' } },
      { type: 'thinking.block', data: { index: 0, thinking: '先读文件', signature: 'sig' } },
      {
        type: 'tool.call',
        data: { id: 't1', toolName: 'read_file', input: { path: 'a.txt' }, status: 'executing' },
      },
      {
        type: 'assistant.message',
        data: {
          id: 'm1',
          role: 'assistant',
          content: '',
          toolCalls: [{ type: 'tool_use', id: 't1', name: 'read_file', input: { path: 'a.txt' } }],
          thinking: [{ type: 'thinking', thinking: '先读文件', signature: 'sig' }],
          isFinal: false,
        },
      },
    ]);
    const kinds = renderMessages(view).map((item) => item.kind);
    obs('渲染 item 种类', kinds);
    expect(kinds).toEqual(['thinking', 'tool']);
    expect(view.liveThinking).toEqual([]);
    expect(Object.keys(view.tools)).toEqual([]);
  });
});
