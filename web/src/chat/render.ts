// `ChatView` → 屏幕 item 的纯渲染函数（change `web-chat-screen` 任务 3.1 / design D7）。
//
// 规则（修空气泡 + 折叠不聚合 + 去重）：
//   1. 用户消息 → 气泡；
//   2. 助手消息：thinking 块各一张卡 → 正文**非空**才出气泡（空气泡就死在这一步）→
//      该消息的 toolCalls 各一张卡；
//   3. 工具 id **全局去重**：最终消息聚合的整轮 toolCalls 与中间消息重叠，第二次出现
//      直接跳过 —— 于是"最终消息只渲染正文"自然成立，且不需要识别 isFinal；
//   4. 当前轮的 live 思考 / live 工具（还没并进消息的）排在消息之后；
//   5. 最后是流式文本气泡；整轮在生成但没有可显示文本时给"正在生成"指示。
import {
  normalizeMessage,
  type ChatView,
  type ThinkingCardModel,
  type ToolCardModel,
} from './model';

export { emptyChatView } from './model';
export type { ChatView } from './model';

export type ChatItemKind =
  | 'user'
  | 'assistant'
  | 'tool'
  | 'thinking'
  | 'streaming'
  | 'indicator';

export interface ChatItem {
  /** 稳定 key（React list 用；虚拟滚动按 key 取回 item）。 */
  key: string;
  kind: ChatItemKind;
  text?: string;
  tool?: ToolCardModel;
  thinking?: ThinkingCardModel;
  /** 用户消息的附件路径（change `web-management-ui` 2.2）。 */
  attachments?: string[];
}

export function renderMessages(view: ChatView): ChatItem[] {
  const items: ChatItem[] = [];
  const renderedToolIds = new Set<string>();

  for (const raw of view.messages) {
    const message = normalizeMessage(raw);
    if (message.role === 'user') {
      items.push({
        key: `user:${message.id}`,
        kind: 'user',
        text: message.content,
        attachments: message.attachments,
      });
      continue;
    }
    for (const block of message.thinking) {
      items.push({
        key: `thinking:${message.id}:${block.index}`,
        kind: 'thinking',
        thinking: block,
      });
    }
    if (message.content.trim().length > 0) {
      items.push({ key: `assistant:${message.id}`, kind: 'assistant', text: message.content });
    }
    for (const tool of message.toolCalls) {
      if (renderedToolIds.has(tool.id)) continue;
      renderedToolIds.add(tool.id);
      items.push({ key: `tool:${tool.id}`, kind: 'tool', tool });
    }
  }

  for (const block of view.liveThinking) {
    items.push({ key: `live-thinking:${block.index}`, kind: 'thinking', thinking: block });
  }
  for (const tool of Object.values(view.tools)) {
    if (renderedToolIds.has(tool.id)) continue;
    renderedToolIds.add(tool.id);
    items.push({ key: `tool:${tool.id}`, kind: 'tool', tool });
  }

  if (view.streamingText.length > 0) {
    items.push({ key: 'streaming', kind: 'streaming', text: view.streamingText });
  } else if (view.isStreaming) {
    items.push({ key: 'streaming-indicator', kind: 'indicator' });
  }

  return items;
}
