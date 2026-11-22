// 渲染层：修空气泡 + 每工具一张卡 + 按 id 去重 + live/history 一致
// （change `web-chat-screen` 任务 3.1 / design D7）。
//
// 纯函数断言：这里只验"渲染出哪些 item、形状是否一致"，不量像素高度
// （折叠单行高度/展开态是 puppeteer 的活，见 e2e/layout.mjs）。
import { describe, expect, it } from 'vitest';

import { applyAgentEvent } from './events';
import type { RawMessage } from './model';
import { emptyChatView, renderMessages, type ChatItem } from './render';

function obs(label: string, value: unknown): void {
  console.log(`[渲染] ${label}: ${JSON.stringify(value)}`);
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

/** 只比较"看得见的东西"：卡片种类、正文、工具名/状态，不比较内部 key。 */
function project(items: ChatItem[]): string[] {
  return items.map((item) => {
    switch (item.kind) {
      case 'tool':
        return `tool:${item.tool!.toolName}:${item.tool!.status}`;
      case 'thinking':
        return `thinking:${item.thinking!.text}`;
      case 'assistant':
      case 'user':
      case 'streaming':
        return `${item.kind}:${item.text}`;
      case 'indicator':
        return 'indicator';
      default:
        return item.kind;
    }
  });
}

const historyToolTurn: RawMessage = {
  id: 'm-tool',
  role: 'assistant',
  content: '',
  toolCalls: [
    enrichedTool('t1', 'read_file', { path: 'a.txt' }, 'done', '文件内容'),
    enrichedTool('t2', 'grep_file', { pattern: 'x' }, 'done', '命中 2 行'),
  ],
  thinking: [{ type: 'thinking', thinking: '先看文件' }],
};

const historyFinal: RawMessage = {
  id: 'm-final',
  role: 'assistant',
  content: '结论：有两个工具在干活。',
  // 最终消息聚合整轮 toolCalls（allTurnToolCalls 并集），与中间消息完全重叠。
  toolCalls: [
    enrichedTool('t1', 'read_file', { path: 'a.txt' }, 'done', '文件内容'),
    enrichedTool('t2', 'grep_file', { pattern: 'x' }, 'done', '命中 2 行'),
  ],
  thinking: [],
};

describe('空气泡修复（design D7 / known-bugs「web 验证页」）', () => {
  it('空正文工具轮消息：不产生助手气泡，每个 toolCall 一张卡', () => {
    const items = renderMessages({
      ...emptyChatView,
      messages: [historyToolTurn],
    });
    obs('空正文工具轮的 items', project(items));
    expect(items.filter((item) => item.kind === 'assistant')).toHaveLength(0);
    expect(items.filter((item) => item.kind === 'tool')).toHaveLength(2);
    expect(project(items)).toEqual([
      'thinking:先看文件',
      'tool:read_file:done',
      'tool:grep_file:done',
    ]);
  });

  it('多工具消息折叠态每个工具各有一张卡（不是一卡只露一个）', () => {
    const items = renderMessages({ ...emptyChatView, messages: [historyToolTurn] });
    const toolNames = items
      .filter((item) => item.kind === 'tool')
      .map((item) => item.tool!.toolName);
    obs('折叠态可见的工具卡', toolNames);
    expect(toolNames).toEqual(['read_file', 'grep_file']);
  });

  it('真回复可见且工具卡不重复（最终消息的聚合 toolCalls 被去重）', () => {
    const items = renderMessages({
      ...emptyChatView,
      messages: [historyToolTurn, historyFinal],
    });
    obs('含最终回复的 items', project(items));
    const assistant = items.filter((item) => item.kind === 'assistant');
    expect(assistant.map((item) => item.text)).toEqual(['结论：有两个工具在干活。']);
    expect(items.filter((item) => item.kind === 'tool')).toHaveLength(2);
  });
});

describe('live 与 history 归一后同形状（design D7）', () => {
  it('live：tool.call → assistant.message(原始形状) → tool.result 后与 history 一致', () => {
    let view = emptyChatView;
    const events = [
      { type: 'assistant.chunk', data: { text: '让我看看文件' } },
      {
        type: 'tool.call',
        data: { id: 't1', toolName: 'read_file', input: { path: 'a.txt' }, status: 'executing' },
      },
      {
        type: 'tool.call',
        data: { id: 't2', toolName: 'grep_file', input: { pattern: 'x' }, status: 'executing' },
      },
      {
        type: 'assistant.message',
        // 中间轮落库形状：toolCalls 是原始 {type,id,name,input}，thinking 无 index。
        data: {
          id: 'm-tool',
          role: 'assistant',
          content: '',
          toolCalls: [rawTool('t1', 'read_file', { path: 'a.txt' }), rawTool('t2', 'grep_file', { pattern: 'x' })],
          thinking: [{ type: 'thinking', thinking: '先看文件' }],
          isFinal: false,
        },
      },
      {
        type: 'tool.result',
        data: {
          id: 't1',
          toolName: 'read_file',
          input: { path: 'a.txt' },
          status: 'done',
          result: '文件内容',
          resultPreview: '文件内容',
        },
      },
      {
        type: 'tool.result',
        data: {
          id: 't2',
          toolName: 'grep_file',
          input: { pattern: 'x' },
          status: 'done',
          result: '命中 2 行',
          resultPreview: '命中 2 行',
        },
      },
      { type: 'assistant.chunk', data: { text: '结论：有两个工具在干活。' } },
      {
        type: 'assistant.message',
        data: {
          id: 'm-final',
          role: 'assistant',
          content: '结论：有两个工具在干活。',
          toolCalls: [enrichedTool('t1', 'read_file', { path: 'a.txt' }, 'done', '文件内容'), enrichedTool('t2', 'grep_file', { pattern: 'x' }, 'done', '命中 2 行')],
          thinking: [],
          isFinal: true,
        },
      },
    ];
    for (const event of events) view = applyAgentEvent(view, event);

    const liveItems = renderMessages(view);
    const historyItems = renderMessages({
      ...emptyChatView,
      messages: [historyToolTurn, historyFinal],
    });
    obs('live items', project(liveItems));
    obs('history items', project(historyItems));
    expect(project(liveItems)).toEqual(project(historyItems));
    // live 工具卡不得永停 executing（tool.result 必须合并进消息里的 toolCalls）。
    const liveTools = liveItems.filter((item) => item.kind === 'tool').map((item) => item.tool!);
    obs('live 工具卡状态', liveTools.map((tool) => `${tool.toolName}:${tool.status}`));
    expect(liveTools.map((tool) => tool.status)).toEqual(['done', 'done']);
    expect(liveTools.map((tool) => tool.result)).toEqual(['文件内容', '命中 2 行']);
  });
});

describe('流式 item（design D8：assistant.chunk 累积、assistant.message 落定清缓冲）', () => {
  it('流式文本作为末尾 item；落定后变成正式气泡', () => {
    let view = emptyChatView;
    view = applyAgentEvent(view, { type: 'agent.streaming', data: { streaming: true } });
    view = applyAgentEvent(view, { type: 'assistant.chunk', data: { text: '正在' } });
    view = applyAgentEvent(view, { type: 'assistant.chunk', data: { text: '写结论' } });
    let items = renderMessages(view);
    obs('流式中的 items', project(items));
    expect(project(items)).toEqual(['streaming:正在写结论']);

    view = applyAgentEvent(view, {
      type: 'assistant.message',
      data: { id: 'm1', role: 'assistant', content: '正在写结论', toolCalls: null, thinking: null, isFinal: true },
    });
    items = renderMessages(view);
    obs('落定后的 items', project(items));
    // 整轮流式态仍为 true（agent.streaming 还没收到 false）→ 指示还在：它是整轮态，
    // 不随单条消息落定而消失（design D8）。
    expect(project(items)).toEqual(['assistant:正在写结论', 'indicator']);

    view = applyAgentEvent(view, { type: 'agent.streaming', data: { streaming: false } });
    items = renderMessages(view);
    obs('整轮结束后的 items', project(items));
    expect(project(items)).toEqual(['assistant:正在写结论']);
  });

  it('整轮还在生成但没有可显示文本时给"正在生成"指示', () => {
    let view = emptyChatView;
    view = applyAgentEvent(view, { type: 'agent.streaming', data: { streaming: true } });
    const items = renderMessages(view);
    obs('无文本的 streaming items', project(items));
    expect(project(items)).toEqual(['indicator']);
  });
});

