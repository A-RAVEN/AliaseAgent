// 无头核心的线上契约（与 `lib/core/event_serialization.dart` /
// `lib/core/headless_core.dart` 的序列化形状一一对应）。
//
// 只覆盖 web 客户端用到的字段；未知字段一律按 unknown 处理（不假装知道）。
//
// change `web-chat-screen` 任务 6.1 增：**断开自动重连（指数退避）+ 心跳
// （周期 core.ping，超时判死）**。四个参数取 `tokens.ts` 的可配常量，不在本文件
// 里写数字（design D12）；重连成功由 `onReconnected` 通知 App 重拉当前页。
import { layoutConfig, type LayoutConfig } from './tokens';

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface JsonRpcResponse<T = unknown> {
  jsonrpc: '2.0';
  id: number | string | null;
  result?: T;
  error?: JsonRpcError;
}

export interface Session {
  id: string;
  title: string;
  agentType: string;
  parentSessionId: string | null;
  createdAt: number;
  updatedAt: number;
  /** single / group（change gent-group-chat）：客户端据此分流。 */
  kind: 'single' | 'group';
  /** 会话级覆盖层（没有覆盖时是 null）。 */
  overrides: InstanceOverrides | null;
  /**
   * 组的自发反应开关（change `group-reactive-mode` D1 / D9）。
   *
   * 组的**持久属性**（`sessions.reactions_enabled`，不是 config.json 键）：新建组默认
   * true，v9→v10 迁移把既有组回填 false。单会话也写该字段，但客户端只对组使用。
   */
  reactionsEnabled: boolean;
  /**
   * 组的**反应轮数上限**（change `group-reactive-mode` R.4 / D13）。
   *
   * `sessions.max_reaction_rounds`（不是 config.json 键）；`null` = 用产品默认
   * （`kDefaultMaxReactionRounds`），界面以默认值占位显示。单会话也写该字段。
   */
  maxRounds: number | null;
}

/**
 * 管理屏只依赖这个最小请求接口（change `web-management-ui` design D14）。
 *
 * `RpcClient` 满足它；puppeteer harness / vitest 注入假实现，于是管理屏的交互测试
 * 不需要起核心进程。
 */
export interface CoreClient {
  request<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
}

/** `session.create` / `session.rename` 的结果形状（与核心 handler 一致）。 */
export interface SessionResult {
  session: Session;
}

/** `session.delete` 的结果形状。 */
export interface SessionDeleteResult {
  sessionId: string;
  deleted: boolean;
}

/** `session.switchTemplate` 的结果形状。 */
export interface SessionSwitchResult {
  sessionId: string;
  agentType: string;
  templateName: string;
}

export interface Message {
  id: string;
  seq: number | null;
  sessionId: string;
  role: 'user' | 'assistant';
  content: string;
  toolCalls: unknown;
  thinking: unknown;
  tokenCount: number | null;
  outputTokenCount: number | null;
  createdAt: number;
  attachments: string[];
  /** 稳定成员 id（用户消息为 null）。 */
  author: string | null;
  /** public / private-to-author。 */
  visibility: 'public' | 'private-to-author';
}

export interface ContextBreakdown {
  level2Tokens: number;
  level1Tokens: number;
  rawTokens: number;
  fixedOverheadTokens: number;
  windowTokens: number;
  usedTokens: number;
  conversationTokens: number;
}

export interface ToolActivity {
  id: string;
  toolName: string;
  input: Record<string, unknown>;
  status: 'executing' | 'done' | 'error';
  result?: string | null;
  resultPreview?: string | null;
}

export interface SnapshotEventData {
  sessionId: string;
  model: string;
  thinkingMode: string;
  thinkingEffort: string;
  capturedAt: string;
  windowTokens: number;
  agentType: string;
  breakdown: ContextBreakdown | null;
  messages: unknown[];
  /** `ContextSnapshot.toRawJson()` 的 system（change `web-management-ui` 2.3）。 */
  system?: string;
  /** `ContextSnapshot.toRawJson()` 的 tools（工具定义的 JSON 字符串）。 */
  tools?: string;
  skillFailures: string[];
  skillFailureNotice: string | null;
}

export interface AgentEvent {
  sessionId: string;
  /** 组事件的身份（单会话事件没有这两个字段）。 */
  groupId?: string;
  memberId?: string;
  type: string;
  data: Record<string, unknown>;
}

export type ConnectionStatus = 'connecting' | 'open' | 'reconnecting' | 'closed';

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
};

export interface RpcClientOptions {
  /** 重连/心跳参数（默认取 tokens 的 `layoutConfig`，测试可注入小值）。 */
  config?: LayoutConfig;
  /** WebSocket 构造（默认浏览器全局；vitest 里注入 `ws` 的实现）。 */
  webSocketFactory?: (url: string) => WebSocket;
}

/** WHATWG WebSocket 的 OPEN 常量（平台值，不是业务魔数）。 */
const SOCKET_OPEN = 1;

export class RpcClient {
  constructor(options: RpcClientOptions = {}) {
    this.config = options.config ?? layoutConfig;
    this.createSocket =
      options.webSocketFactory ?? ((url: string) => new WebSocket(url));
  }

  private readonly config: LayoutConfig;
  private readonly createSocket: (url: string) => WebSocket;
  private socket: WebSocket | null = null;
  private url: string | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly eventHandlers = new Set<(event: AgentEvent) => void>();
  private readonly statusHandlers = new Set<(status: ConnectionStatus) => void>();
  private readonly reconnectedHandlers = new Set<() => void>();

  /** 已成功连上一次：之后的成功连接都算"重连"（要触发状态恢复）。 */
  private hasConnectedBefore = false;
  /** 用户主动 close()：不再自动重连。 */
  private closedByUser = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatInFlight = false;

  onEvent(handler: (event: AgentEvent) => void): () => void {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onStatus(handler: (status: ConnectionStatus) => void): () => void {
    this.statusHandlers.add(handler);
    return () => this.statusHandlers.delete(handler);
  }

  /** 重连成功（不是首次连接）时回调：App 用它重拉当前页恢复状态（design D12）。 */
  onReconnected(handler: () => void): () => void {
    this.reconnectedHandlers.add(handler);
    return () => this.reconnectedHandlers.delete(handler);
  }

  connect(url: string): Promise<void> {
    this.url = url;
    this.closedByUser = false;
    this.emitStatus(this.hasConnectedBefore ? 'reconnecting' : 'connecting');
    return this.openSocket();
  }

  request<T = unknown>(
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== SOCKET_OPEN) {
      return Promise.reject(new Error('WebSocket 未连接'));
    }
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
      });
      socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }

  close(): void {
    this.closedByUser = true;
    this.clearReconnectTimer();
    this.stopHeartbeat();
    const socket = this.socket;
    this.socket = null;
    if (socket) {
      try {
        socket.close();
      } catch {
        // 关闭失败不影响状态收尾。
      }
    }
    this.rejectPending(new Error('WebSocket 已关闭'));
    this.emitStatus('closed');
  }

  // -------------------------------------------------------------------------
  // 连接 / 重连
  // -------------------------------------------------------------------------

  private openSocket(): Promise<void> {
    const url = this.url;
    if (!url) return Promise.reject(new Error('没有 WebSocket 地址'));
    return new Promise((resolve, reject) => {
      let settled = false;
      const socket = this.createSocket(url);
      this.socket = socket;

      socket.onopen = () => {
        this.emitStatus('open');
        this.reconnectAttempt = 0;
        this.startHeartbeat();
        const isReconnect = this.hasConnectedBefore;
        this.hasConnectedBefore = true;
        settled = true;
        resolve();
        if (isReconnect) {
          for (const handler of this.reconnectedHandlers) handler();
        }
      };
      socket.onerror = () => {
        if (settled) return;
        settled = true;
        reject(new Error(`无法连接核心 WebSocket：${url}`));
      };
      socket.onclose = () => {
        this.stopHeartbeat();
        this.rejectPending(new Error('WebSocket 已断开'));
        if (this.socket === socket) this.socket = null;
        if (!settled) {
          settled = true;
          reject(new Error(`无法连接核心 WebSocket：${url}`));
        }
        this.scheduleReconnect();
      };
      socket.onmessage = (message) => this.handleMessage(message.data);
    });
  }

  /** 指数退避：base × 2^attempt，封顶 cap；用户主动关闭后不再重连。 */
  private scheduleReconnect(): void {
    if (this.closedByUser) {
      this.emitStatus('closed');
      return;
    }
    this.emitStatus('reconnecting');
    const delay = Math.min(
      this.config.reconnectCapMs,
      this.config.reconnectBaseMs * 2 ** this.reconnectAttempt,
    );
    this.reconnectAttempt += 1;
    this.clearReconnectTimer();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.closedByUser) return;
      this.openSocket().catch(() => {
        // 失败由 onclose 继续排下一次（不吞掉重连链）。
      });
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  // -------------------------------------------------------------------------
  // 心跳：周期 core.ping；超时未回判死 → 关连接 → 触发重连
  // -------------------------------------------------------------------------

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => this.sendHeartbeat(), this.config.heartbeatPeriodMs);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.heartbeatInFlight = false;
  }

  private sendHeartbeat(): void {
    if (this.heartbeatInFlight) return;
    const socket = this.socket;
    if (!socket || socket.readyState !== SOCKET_OPEN) return;
    this.heartbeatInFlight = true;
    let settled = false;
    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      this.heartbeatInFlight = false;
      // 超时判死：主动关连接，onclose 会走退避重连。
      this.markDead();
    }, this.config.heartbeatTimeoutMs);
    this.request('core.ping').then(
      () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        this.heartbeatInFlight = false;
      },
      () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        this.heartbeatInFlight = false;
      },
    );
  }

  private markDead(): void {
    this.stopHeartbeat();
    this.rejectPending(new Error('心跳超时：判定连接已死'));
    const socket = this.socket;
    if (!socket) {
      this.scheduleReconnect();
      return;
    }
    this.socket = null;
    try {
      // 关连接后由 onclose 走同一条退避重连路径（只排一次，避免双倍退避）。
      socket.close();
    } catch {
      this.scheduleReconnect();
    }
  }

  // -------------------------------------------------------------------------
  // 收消息
  // -------------------------------------------------------------------------

  private emitStatus(status: ConnectionStatus): void {
    for (const handler of this.statusHandlers) handler(status);
  }

  private rejectPending(error: Error): void {
    for (const [, pending] of this.pending) pending.reject(error);
    this.pending.clear();
  }

  private handleMessage(raw: unknown): void {
    if (typeof raw !== 'string') return;
    let decoded: Record<string, unknown>;
    try {
      decoded = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }
    if (decoded.method === 'agent.event' && decoded.params) {
      for (const handler of this.eventHandlers) {
        handler(decoded.params as AgentEvent);
      }
      return;
    }
    const response = decoded as unknown as JsonRpcResponse;
    if (typeof response.id !== 'number') return;
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (response.error) {
      const error = new Error(
        `[${response.error.code}] ${response.error.message}`,
      );
      pending.reject(error);
    } else {
      pending.resolve(response.result);
    }
  }
}
// ---------------------------------------------------------------------------
// 群聊（change `agent-group-chat`）
// ---------------------------------------------------------------------------

/** 覆盖层三字段（与核心 `AgentInstanceOverrides` 同一格式）。 */
export interface InstanceOverrides {
  toolsSubset?: string[] | null;
  systemPromptAppend?: string | null;
  thinkingEffort?: string | null;
}

/** 成员的生效配置（`group.list` 的 `effective`）：覆盖层"真的生效"在界面上可核。 */
export interface EffectiveMemberConfig {
  tools?: string[];
  systemPrompt?: string;
  thinkingMode?: string;
  thinkingEffort?: string;
  model?: string;
  maxContextTokens?: number;
  error?: string;
}

export interface GroupMemberSummary {
  id: string;
  name: string;
  template: string;
  /** 已移除成员的软删标记（毫秒）；null = 仍在组里。 */
  removedAt: number | null;
  overrides: InstanceOverrides | null;
  effective: EffectiveMemberConfig | null;
}

export interface GroupSummary extends Session {
  members: GroupMemberSummary[];
  /**
   * 组级单运行门当前是否被占用（change `group-reactive-mode` D7 / D9）。
   *
   * 断线重连后本地 `sending` 会丢，web 靠它（+ `runningMemberId`）恢复"链在跑"
   * 的显示并启用取消按钮。
   */
  busy: boolean;
  /** 当前正在运行的成员 id（链在成员间隙时为 null）。 */
  runningMemberId: string | null;
}

/** `group.list` 的结果形状。 */
export interface GroupListResult {
  groups: GroupSummary[];
}

/** `group.create` 的结果形状。 */
export interface GroupCreateResult {
  group: Session;
}

/** 反应链 step 的来源（封闭枚举，与核心 `kReactionStepSources` 一致）。 */
export type GroupSendStepSource = 'speaker' | 'mention' | 'reaction';

/** 反应链 step 的状态（封闭枚举，与核心 `kReactionStepStatuses` 一致）。 */
export type GroupSendStepStatus =
  | 'replied'
  | 'passed'
  | 'forced_pass'
  | 'forced_empty'
  | 'empty'
  | 'failed'
  | 'cancelled';

/** 反应链的一步（`group.chain` 的 `steps` 项；只是观察，不是第二套消息存储）。 */
export interface GroupSendStep {
  memberId: string;
  source: GroupSendStepSource;
  status: GroupSendStepStatus;
  /** 这一步回应的是哪条公开消息的 seq（安静态定向轮可为 null）。 */
  triggerSeq: number | null;
  /** 这一步产生的公开行 seq（`replied` 时非空）。 */
  publicSeq: number | null;
  finalText?: string | null;
  error?: string | null;
}

/**
 * `group.send` 的**同步回包**（change `group-reactive-mode` R.4/R.8 / D9）。
 *
 * 异步契约：`started` = 用户消息（若有）已写入、请求已入执行器队列并在后台跑。
 * **`group.send` 永不返回 busy**：执行器在跑时新请求照常入队/被吸收。**不再携带**
 * `steps` / `rounds` / `finalText` / `memberId` —— 链进度只从 `GroupChainResult` 与
 * `group.chain.completed` 事件读。
 */
export interface GroupSendResult {
  groupId: string;
  sessionId: string;
  /** 恒为 `started`（没有 busy 分支）。 */
  status: 'started';
  /** 带文本时 = 用户消息 seq；speaker-only 时为 null（由链状态更新）。 */
  triggerSeq: number | null;
}

/**
 * `group.chain` 的结果形状：当前 / 最近一条链的只读状态（change
 * `group-reactive-mode` R.4 / D9）。核心重启后为 `idle`。
 */
export interface GroupChainResult {
  groupId: string;
  sessionId: string;
  /** idle / running / completed / cancelled / failed。 */
  status: string;
  triggerSeq: number | null;
  /** 只计反应轮。 */
  rounds: number;
  /** 运行中为 null；终态 ∈ {all_passed, round_cap, cancelled, failed, no_members}。 */
  stopReason: string | null;
  /**
   * 失败真因（change `group-chat-layout` R.15）：`failed` 时非空且含可归因文本；
   * 其余状态为 null。界面以独立提示 `group-chain-error` 显示，一过性（下次发送清除）。
   */
  error?: string | null;
  steps: GroupSendStep[];
}

/** `group.view` 的结果形状：本次运行内没发过言时 `snapshot` 为 null。 */
export interface GroupViewResult {
  groupId: string;
  memberId: string;
  snapshot: SnapshotEventData | null;
}

/** `agent.cancel` 在组会话上的结果形状。 */
export interface GroupCancelResult {
  sessionId: string;
  groupId?: string;
  cancelled: boolean;
  reason: string;
  memberId?: string | null;
}

/** 群聊 RPC 方法名（与核心 `kCoreRpcMethodNames` 的群聊段一一对应）。 */
export const GROUP_RPC_METHODS = [
  'group.create',
  'group.update',
  'group.chain',
  'group.list',
  'group.delete',
  'group.member.add',
  'group.member.remove',
  'group.member.update',
  'group.send',
  'group.view',
] as const;