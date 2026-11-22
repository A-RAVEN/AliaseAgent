// 消息 / 工具 / 思考的**归一**层（change `web-chat-screen` 任务 3.1 / design D7）。
//
// live 与 history 拿到的形状不同（见 design D7）：
//   - live 的 tool.call/tool.result 是 `ToolCallActivity.toJson()`：`toolName/status/
//     result/resultPreview`，状态缺省 `executing`；
//   - 中间助手消息落库时 toolCalls 是原始 `{type,id,name,input}`（工具还没跑），
//     工具结果回来后富化写库但**不再发 assistant.message**；
//   - 最终助手消息的 toolCalls 是整轮并集（与中间消息重叠）；
//   - thinking 在 live 事件里带 index，在 history 的 thinkingJson 里没有 index。
//
// 这里只做"把两种形状变成同一种"，不渲染（渲染在 `render.ts`）。不丢内容：
// 解析不出的字段保留原值/占位，不静默抹掉。

export type ToolStatus = 'executing' | 'done' | 'error';

export interface ToolCardModel {
  id: string;
  toolName: string;
  input: Record<string, unknown>;
  status: ToolStatus;
  result: string | null;
  resultPreview: string | null;
}

export interface ThinkingCardModel {
  index: number;
  text: string;
  signature?: string | null;
}

/** 线上消息形状（`serializeMessage`：驼峰，toolCalls/thinking 已解码）。 */
export interface RawMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  seq?: number | null;
  sessionId?: string;
  toolCalls?: unknown;
  thinking?: unknown;
  createdAt?: number;
  isFinal?: boolean;
  /** 附件路径（change `web-management-ui` 2.2）：渲染缩略图要靠 `attachment.read`。 */
  attachments?: string[];
}

export interface NormalizedMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  seq: number | null;
  toolCalls: ToolCardModel[];
  thinking: ThinkingCardModel[];
  attachments: string[];
}

export interface ChatView {
  /** 已落定的消息（history 页 + live 的 user.message/assistant.message）。 */
  messages: RawMessage[];
  /** live 工具事件（还没并进任何消息的那些，按 id）。 */
  tools: Record<string, ToolCardModel>;
  /** 当前轮的 live 思考块（带 index，按 index 合并/累加）。 */
  liveThinking: ThinkingCardModel[];
  /** 当前轮的流式文本缓冲（每条 assistant.message 落定时清空）。 */
  streamingText: string;
  /** 整轮流式态（只信 agent.streaming，不用 turn.completed）。 */
  isStreaming: boolean;
}

export const emptyChatView: ChatView = {
  messages: [],
  tools: {},
  liveThinking: [],
  streamingText: '',
  isStreaming: false,
};

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asToolStatus(value: unknown): ToolStatus {
  return value === 'done' || value === 'error' ? value : 'executing';
}

function asStringOrNull(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

/**
 * toolCalls → 工具卡模型（`name` → `toolName`，缺 status 补 `executing`，按 id 去重）。
 *
 * 去重规则：同一个 id 后出现的版本覆盖前面的版本（富化信息比原始形状新）。
 */
export function normalizeToolCalls(raw: unknown): ToolCardModel[] {
  if (!Array.isArray(raw)) return [];
  const byId = new Map<string, ToolCardModel>();
  raw.forEach((entry, index) => {
    const record = asRecord(entry);
    if (!record) return;
    const rawId = record.id;
    const id = typeof rawId === 'string' && rawId.length > 0 ? rawId : `tool-${index}`;
    const name = record.toolName ?? record.name;
    const tool: ToolCardModel = {
      id,
      toolName: typeof name === 'string' && name.length > 0 ? name : 'unknown',
      input: asRecord(record.input) ?? {},
      status: asToolStatus(record.status),
      result: asStringOrNull(record.result),
      resultPreview: asStringOrNull(record.resultPreview) ?? asStringOrNull(record.result),
    };
    byId.set(id, tool);
  });
  return [...byId.values()];
}

/** thinking 块 → 模型（index 缺省按数组位置派生，`thinking`/`text` 两种字段都认）。 */
export function normalizeThinking(raw: unknown): ThinkingCardModel[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry, position) => {
    const record = asRecord(entry);
    if (!record) return [];
    const rawIndex = record.index;
    const index = typeof rawIndex === 'number' ? rawIndex : position;
    const text = record.thinking ?? record.text;
    return [
      {
        index,
        text: typeof text === 'string' ? text : '',
        signature: asStringOrNull(record.signature),
      },
    ];
  });
}

export function normalizeMessage(raw: RawMessage): NormalizedMessage {
  return {
    id: raw.id,
    role: raw.role,
    content: typeof raw.content === 'string' ? raw.content : '',
    seq: typeof raw.seq === 'number' ? raw.seq : null,
    toolCalls: normalizeToolCalls(raw.toolCalls),
    thinking: normalizeThinking(raw.thinking),
    attachments: Array.isArray(raw.attachments)
      ? raw.attachments.filter((path): path is string => typeof path === 'string')
      : [],
  };
}

/**
 * 按 id 合并消息：已存在的用新版本替换（保留原位置），新消息追加到末尾。
 *
 * 分页（上翻插到前面由调用方处理顺序）、重连重拉、live 追加都走这一份规则，
 * 避免同一 id 渲染两遍。
 */
export function mergeMessages(existing: RawMessage[], incoming: RawMessage[]): RawMessage[] {
  const positions = new Map<string, number>();
  const merged = existing.slice();
  merged.forEach((message, index) => positions.set(message.id, index));
  for (const message of incoming) {
    const position = positions.get(message.id);
    if (position === undefined) {
      positions.set(message.id, merged.length);
      merged.push(message);
    } else {
      merged[position] = message;
    }
  }
  return merged;
}

/** 把一条工具事件合并进消息里同 id 的 toolCall；没有匹配则返回 null。 */
export function updateToolInMessages(
  messages: RawMessage[],
  tool: ToolCardModel,
): RawMessage[] | null {
  let changed = false;
  const next = messages.map((message) => {
    if (!Array.isArray(message.toolCalls)) return message;
    let messageChanged = false;
    const toolCalls = message.toolCalls.map((entry) => {
      const record = asRecord(entry);
      if (!record) return entry;
      const id = typeof record.id === 'string' ? record.id : '';
      if (id !== tool.id) return entry;
      messageChanged = true;
      return {
        ...record,
        // 统一成富化形状，历史与 live 落到同一个 toolCalls 形状上。
        toolName: tool.toolName,
        status: tool.status,
        result: tool.result,
        resultPreview: tool.resultPreview,
      };
    });
    if (!messageChanged) return message;
    changed = true;
    return { ...message, toolCalls };
  });
  return changed ? next : null;
}

/** 消息里已经带上这些工具 id 时，把 live 的孤儿工具卡丢掉（否则重复渲染）。 */
export function dropToolsMergedIntoMessages(
  tools: Record<string, ToolCardModel>,
  messages: RawMessage[],
): Record<string, ToolCardModel> {
  const mergedIds = new Set<string>();
  for (const message of messages) {
    for (const tool of normalizeToolCalls(message.toolCalls)) mergedIds.add(tool.id);
  }
  const remaining: Record<string, ToolCardModel> = {};
  for (const [id, tool] of Object.entries(tools)) {
    if (!mergedIds.has(id)) remaining[id] = tool;
  }
  return remaining;
}
