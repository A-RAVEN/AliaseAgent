// `agent.event` → 聊天视图状态的纯归约（change `web-chat-screen` 任务 3.1 / 3.3，
// design D7/D8）。
//
// 为什么单独一层纯函数：流式语义（D8）是"每条 assistant.message 落定当轮文本、
// 整轮流式态只信 agent.streaming"这类时序断言，用 vitest 直接对事件序列断言比在
// React 里绕 useState 稳定得多；App 只负责把事件交进来、把状态渲染出去。
import {
  dropToolsMergedIntoMessages,
  mergeMessages,
  normalizeToolCalls,
  updateToolInMessages,
  type ChatView,
  type RawMessage,
  type ThinkingCardModel,
} from './model';

export interface AgentEventLike {
  type: string;
  data?: Record<string, unknown> | null;
  sessionId?: string;
}

function mergeThinking(
  blocks: ThinkingCardModel[],
  incoming: ThinkingCardModel,
  append: boolean,
): ThinkingCardModel[] {
  const next = blocks.slice();
  const position = next.findIndex((block) => block.index === incoming.index);
  if (position < 0) {
    next.push(incoming);
  } else if (append) {
    next[position] = { ...next[position], text: next[position].text + incoming.text };
  } else {
    // `thinking.block` 带的是该 index 的**完整**文本（agent 先发 delta 再发 block），
    // 所以这里是替换而不是累加。
    next[position] = incoming;
  }
  return next.sort((a, b) => a.index - b.index);
}

/**
 * 把一个 `agent.event` 应用到视图状态。
 *
 * 关键时序（design D8）：
 *   - `assistant.message`（含中间轮 isFinal=false）：该轮文本**落定**成消息、清空
 *     流式缓冲与当前轮 live 思考（内容已随消息到达）；
 *   - `turn.completed`：每次 API 请求结束就发（工具轮后面还会再发），**故意不消费**
 *     ——整轮流式态由 `agent.streaming` 决定，用 turn.completed 会把"工具执行中"
 *     误判成"生成结束"；
 *   - `tool.call`/`tool.result`：按 id 先尝试并进已有消息（中间消息含原始 toolCalls），
 *     并不进去才作为 live 卡片暂存。
 */
export function applyAgentEvent(view: ChatView, event: AgentEventLike): ChatView {
  const data = (event.data ?? {}) as Record<string, unknown>;
  switch (event.type) {
    case 'user.message':
    case 'assistant.message': {
      const message = data as unknown as RawMessage;
      if (!message || typeof message.id !== 'string') return view;
      const messages = mergeMessages(view.messages, [message]);
      return {
        ...view,
        messages,
        streamingText: '',
        liveThinking: [],
        tools: dropToolsMergedIntoMessages(view.tools, messages),
      };
    }
    case 'assistant.chunk': {
      const text = typeof data.text === 'string' ? data.text : '';
      return { ...view, streamingText: view.streamingText + text };
    }
    case 'tool.call':
    case 'tool.result': {
      const [tool] = normalizeToolCalls([data]);
      if (!tool) return view;
      const updatedMessages = updateToolInMessages(view.messages, tool);
      if (updatedMessages) {
        return { ...view, messages: updatedMessages };
      }
      return { ...view, tools: { ...view.tools, [tool.id]: tool } };
    }
    case 'thinking.delta': {
      const index = typeof data.index === 'number' ? data.index : 0;
      const text = typeof data.delta === 'string' ? data.delta : '';
      return {
        ...view,
        liveThinking: mergeThinking(view.liveThinking, { index, text }, true),
      };
    }
    case 'thinking.block': {
      const index = typeof data.index === 'number' ? data.index : 0;
      const text = typeof data.thinking === 'string' ? data.thinking : '';
      return {
        ...view,
        liveThinking: mergeThinking(
          view.liveThinking,
          { index, text, signature: typeof data.signature === 'string' ? data.signature : null },
          false,
        ),
      };
    }
    case 'agent.streaming': {
      return { ...view, isStreaming: Boolean(data.streaming) };
    }
    case 'turn.failed': {
      // 整轮失败 → 不再生成；已落定的消息保留（失败原因由 App 的错误横幅展示）。
      return { ...view, isStreaming: false };
    }
    default:
      // `turn.completed` 等"每次请求"事件不改变整轮状态（见上）。
      return view;
  }
}
