// 无头核心的线上契约（与 `lib/core/event_serialization.dart` /
// `lib/core/headless_core.dart` 的序列化形状一一对应）。
//
// 只覆盖最小验证页用到的字段；未知字段一律按 unknown 处理（不假装知道）。

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
  skillFailures: string[];
  skillFailureNotice: string | null;
}

export interface AgentEvent {
  sessionId: string;
  type: string;
  data: Record<string, unknown>;
}

export type ConnectionStatus = 'connecting' | 'open' | 'closed';

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
};

export class RpcClient {
  private socket: WebSocket | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly eventHandlers = new Set<(event: AgentEvent) => void>();
  private readonly statusHandlers = new Set<(status: ConnectionStatus) => void>();

  onEvent(handler: (event: AgentEvent) => void): () => void {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onStatus(handler: (status: ConnectionStatus) => void): () => void {
    this.statusHandlers.add(handler);
    return () => this.statusHandlers.delete(handler);
  }

  connect(url: string): Promise<void> {
    this.emitStatus('connecting');
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      this.socket = socket;
      socket.onopen = () => {
        this.emitStatus('open');
        resolve();
      };
      socket.onerror = () => {
        if (socket.readyState !== WebSocket.OPEN) {
          reject(new Error(`无法连接核心 WebSocket：${url}`));
        }
      };
      socket.onclose = () => {
        this.emitStatus('closed');
        for (const [, pending] of this.pending) {
          pending.reject(new Error('WebSocket 已断开'));
        }
        this.pending.clear();
      };
      socket.onmessage = (message) => this.handleMessage(message.data);
    });
  }

  request<T = unknown>(
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
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
    this.socket?.close();
    this.socket = null;
  }

  private emitStatus(status: ConnectionStatus): void {
    for (const handler of this.statusHandlers) handler(status);
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
