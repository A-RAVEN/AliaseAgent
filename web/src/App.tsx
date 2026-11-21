import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
} from 'react';
import ReactMarkdown from 'react-markdown';
import {
  type AgentEvent,
  type ConnectionStatus,
  type Message,
  type Session,
  type SnapshotEventData,
  type ToolActivity,
  RpcClient,
} from './protocol';

// 最小验证页只证明「发一条消息 → 流式回复 → 工具卡片」这条链路。它不是完整聊天屏：
// 没有卡片折叠 / 自动贴底 / 跳底按钮 / 会话管理，这些是后续 change。

// 验证页一次向核心要多少条历史。这是**调用方的显示选择**（pageSize 由请求方必填，
// 核心不提供默认值），不是核心的隐藏默认页大小。
const HISTORY_PAGE_SIZE = 30;

const coreWsUrl: string =
  (import.meta.env.VITE_CORE_WS as string | undefined) ??
  `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export default function App() {
  const client = useMemo(() => new RpcClient(), []);
  const [status, setStatus] = useState<ConnectionStatus>('connecting');
  const [sessions, setSessions] = useState<Session[]>([]);
  const [currentSessionId, setCurrentSessionId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [streamingText, setStreamingText] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [tools, setTools] = useState<Record<string, ToolActivity>>({});
  const [snapshot, setSnapshot] = useState<SnapshotEventData | null>(null);
  const [skillFailures, setSkillFailures] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [input, setInput] = useState('');
  const [metering, setMetering] = useState<Record<string, unknown> | null>(null);
  const currentSessionIdRef = useRef<string | null>(null);

  currentSessionIdRef.current = currentSessionId;

  const loadMessages = useCallback(
    async (sessionId: string) => {
      const result = await client.request<{ messages: Message[] }>(
        'message.query',
        { sessionId, pageSize: HISTORY_PAGE_SIZE },
      );
      setMessages(result.messages);
    },
    [client],
  );

  const loadSessions = useCallback(async () => {
    const result = await client.request<{ sessions: Session[] }>('session.list');
    setSessions(result.sessions);
    if (result.sessions.length === 0) {
      setCurrentSessionId(null);
      setNotice('还没有会话：先用 Flutter 应用创建会话（无头核心与 Flutter 共用同一个数据库）。');
      return;
    }
    setNotice(null);
    const first = result.sessions[0];
    setCurrentSessionId(first.id);
    await loadMessages(first.id);
  }, [client, loadMessages]);

  const onEvent = useCallback((event: AgentEvent) => {
    if (event.sessionId !== currentSessionIdRef.current) return;
    const data = event.data ?? {};
    switch (event.type) {
      case 'user.message': {
        const message = data as unknown as Message;
        setMessages((previous) => [...previous, message]);
        break;
      }
      case 'assistant.chunk': {
        setIsStreaming(true);
        setStreamingText((previous) => previous + String(data.text ?? ''));
        break;
      }
      case 'assistant.message': {
        const message = data as unknown as Message & { isFinal?: boolean };
        if ((message.content ?? '').length > 0) {
          setMessages((previous) => [...previous, message]);
        }
        setStreamingText('');
        break;
      }
      case 'tool.call':
      case 'tool.result': {
        const activity = data as unknown as ToolActivity;
        setTools((previous) => ({ ...previous, [activity.id]: activity }));
        break;
      }
      case 'agent.streaming': {
        setIsStreaming(Boolean(data.streaming));
        break;
      }
      case 'turn.completed': {
        setIsStreaming(false);
        break;
      }
      case 'context.snapshot': {
        const snapshotData = data as unknown as SnapshotEventData;
        setSnapshot(snapshotData);
        setSkillFailures(snapshotData.skillFailures ?? []);
        break;
      }
      case 'agent.metering': {
        setMetering(data);
        break;
      }
      case 'session.title': {
        const title = String(data.title ?? '');
        setSessions((previous) =>
          previous.map((session) =>
            session.id === event.sessionId ? { ...session, title } : session,
          ),
        );
        break;
      }
      case 'turn.failed': {
        setError(`整轮失败：${String(data.error ?? '(没有错误文本)')}`);
        setIsStreaming(false);
        break;
      }
      case 'compaction.status': {
        if (data.isIdle === false) {
          setNotice(String(data.label ?? '正在压缩…'));
        } else {
          setNotice(null);
        }
        break;
      }
      default:
        // 最小验证页不消费的事件（thinking / 标题之外的元数据等）直接忽略；
        // 事件本身仍在通道里可见。
        break;
    }
  }, []);

  useEffect(() => {
    const offStatus = client.onStatus(setStatus);
    const offEvent = client.onEvent(onEvent);
    client
      .connect(coreWsUrl)
      .then(loadSessions)
      .catch((connectError: unknown) => setError(errorText(connectError)));
    return () => {
      offStatus();
      offEvent();
      client.close();
    };
  }, [client, loadSessions, onEvent]);

  const selectSession = async (sessionId: string) => {
    setCurrentSessionId(sessionId);
    setMessages([]);
    setStreamingText('');
    setTools({});
    setSnapshot(null);
    setSkillFailures([]);
    setError(null);
    try {
      await loadMessages(sessionId);
    } catch (loadError: unknown) {
      setError(errorText(loadError));
    }
  };

  const send = async () => {
    const text = input.trim();
    const sessionId = currentSessionIdRef.current;
    if (!text || !sessionId) return;
    setInput('');
    setError(null);
    setNotice(null);
    try {
      await client.request('agent.send', { sessionId, text });
    } catch (sendError: unknown) {
      setError(errorText(sendError));
    }
  };

  const onComposerKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      void send();
    }
  };

  const statusLabel: Record<ConnectionStatus, string> = {
    connecting: '连接中…',
    open: '已连接',
    closed: '已断开',
  };

  const breakdownRows: { label: string; value: number }[] = snapshot?.breakdown
    ? [
        { label: '二级摘要', value: snapshot.breakdown.level2Tokens },
        { label: '一级摘要', value: snapshot.breakdown.level1Tokens },
        { label: '原文', value: snapshot.breakdown.rawTokens },
        { label: '系统+工具', value: snapshot.breakdown.fixedOverheadTokens },
      ]
    : [];

  return (
    <div
      className="flex h-full flex-col bg-[#0b0f19] text-slate-100"
      data-streaming={isStreaming ? 'true' : 'false'}
    >
      <header className="flex items-center justify-between border-b border-slate-800 px-5 py-3">
        <div>
          <h1 className="text-base font-semibold">AliasAgent · web 验证页</h1>
          <p className="text-xs text-slate-400">
            最小验证页：发一条消息 → 流式回复 → 工具卡片（非完整体验）
          </p>
        </div>
        <div className="flex items-center gap-3 text-xs">
          <span
            data-testid="connection-status"
            className={
              status === 'open'
                ? 'rounded bg-emerald-500/15 px-2 py-1 text-emerald-300'
                : 'rounded bg-amber-500/15 px-2 py-1 text-amber-300'
            }
          >
            {statusLabel[status]}
          </span>
          {metering && (
            <span className="text-slate-400">
              in {String(metering.input_tokens ?? 0)} / out{' '}
              {String(metering.output_tokens ?? 0)} tokens
            </span>
          )}
        </div>
      </header>

      <div className="flex min-h-0 flex-1">
        <aside className="w-56 shrink-0 overflow-y-auto border-r border-slate-800 p-3">
          <h2 className="mb-2 text-xs font-semibold tracking-wide text-slate-400">
            会话
          </h2>
          <ul data-testid="session-list" className="space-y-1 text-sm">
            {sessions.map((session) => (
              <li key={session.id}>
                <button
                  type="button"
                  onClick={() => void selectSession(session.id)}
                  className={
                    session.id === currentSessionId
                      ? 'w-full truncate rounded bg-slate-700/70 px-2 py-1.5 text-left'
                      : 'w-full truncate rounded px-2 py-1.5 text-left text-slate-300 hover:bg-slate-800'
                  }
                >
                  {session.title}
                </button>
              </li>
            ))}
          </ul>
        </aside>

        <main className="flex min-w-0 flex-1 flex-col">
          {error && (
            <div
              data-testid="error-banner"
              className="border-b border-red-900/60 bg-red-950/60 px-4 py-2 text-sm text-red-200"
            >
              {error}
            </div>
          )}
          {notice && (
            <div className="border-b border-slate-800 bg-slate-900/60 px-4 py-2 text-xs text-slate-300">
              {notice}
            </div>
          )}
          {skillFailures.length > 0 && (
            <div
              data-testid="skill-failures"
              className="border-b border-amber-900/60 bg-amber-950/40 px-4 py-2 text-xs text-amber-200"
            >
              <div className="font-semibold">有技能未生效：</div>
              <ul className="list-inside list-disc">
                {skillFailures.map((line) => (
                  <li key={line}>{line}</li>
                ))}
              </ul>
            </div>
          )}

          <section
            data-testid="message-list"
            className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4"
          >
            {messages.length === 0 && !streamingText && (
              <p className="text-sm text-slate-500">
                还没有消息。在下面输入一句话并按 Enter（或点发送）。
              </p>
            )}
            {messages.map((message) => (
              <article
                key={message.id}
                data-testid={
                  message.role === 'assistant'
                    ? 'assistant-message'
                    : 'user-message'
                }
                className={
                  message.role === 'user'
                    ? 'ml-auto max-w-[80%] rounded-lg bg-sky-600/20 px-3 py-2'
                    : 'max-w-[85%] rounded-lg bg-slate-800/70 px-3 py-2'
                }
              >
                <div className="mb-1 text-[11px] uppercase tracking-wide text-slate-400">
                  {message.role === 'user' ? 'You' : 'Assistant'}
                </div>
                <div className="markdown-body text-sm leading-relaxed">
                  <ReactMarkdown>{message.content}</ReactMarkdown>
                </div>
              </article>
            ))}
            {streamingText.length > 0 && (
              <article
                data-testid="streaming-message"
                className="max-w-[85%] rounded-lg border border-sky-900/60 bg-slate-800/40 px-3 py-2"
              >
                <div className="mb-1 text-[11px] uppercase tracking-wide text-sky-300">
                  Assistant · 流式
                </div>
                <div className="markdown-body text-sm leading-relaxed">
                  <ReactMarkdown>{streamingText}</ReactMarkdown>
                </div>
              </article>
            )}
            {Object.values(tools).map((tool) => (
              <article
                key={tool.id}
                data-testid="tool-card"
                className="max-w-[85%] rounded-lg border border-slate-700 bg-slate-900/70 px-3 py-2 text-sm"
              >
                <div className="flex items-center justify-between">
                  <span className="font-mono text-xs text-slate-300">
                    工具 · {tool.toolName}
                  </span>
                  <span
                    className={
                      tool.status === 'done'
                        ? 'text-xs text-emerald-300'
                        : tool.status === 'error'
                          ? 'text-xs text-red-300'
                          : 'text-xs text-amber-300'
                    }
                  >
                    {tool.status}
                  </span>
                </div>
                <pre className="mt-1 max-h-32 overflow-auto rounded bg-black/40 p-2 text-[11px] text-slate-300">
                  {JSON.stringify(tool.input, null, 2)}
                </pre>
                {(tool.resultPreview ?? tool.result) && (
                  <pre className="mt-1 max-h-32 overflow-auto whitespace-pre-wrap rounded bg-black/40 p-2 text-[11px] text-slate-400">
                    {tool.resultPreview ?? tool.result}
                  </pre>
                )}
              </article>
            ))}
            {isStreaming && streamingText.length === 0 && (
              <p data-testid="streaming-indicator" className="text-xs text-sky-300">
                正在生成…
              </p>
            )}
          </section>

          {snapshot && (
            <section
              data-testid="context-snapshot"
              className="border-t border-slate-800 px-5 py-2 text-xs text-slate-400"
            >
              上下文窗口 {snapshot.windowTokens} tokens · 模板 {snapshot.agentType}
              {breakdownRows.length > 0 && (
                <span className="ml-2 space-x-2">
                  {breakdownRows.map((row) => (
                    <span key={row.label}>
                      {row.label} {row.value}
                    </span>
                  ))}
                </span>
              )}
            </section>
          )}

          <footer className="border-t border-slate-800 p-3">
            <div className="flex items-end gap-2">
              <textarea
                data-testid="composer"
                value={input}
                onChange={(event) => setInput(event.target.value)}
                onKeyDown={onComposerKeyDown}
                placeholder="输入一句话，Enter 发送（Shift+Enter 换行）"
                rows={2}
                className="min-h-[44px] flex-1 resize-none rounded-lg border border-slate-700 bg-slate-900 px-3 py-2 text-sm outline-none focus:border-sky-600"
              />
              <button
                type="button"
                data-testid="send"
                onClick={() => void send()}
                disabled={status !== 'open' || !currentSessionId || !input.trim()}
                className="rounded-lg bg-sky-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:opacity-40"
              >
                发送
              </button>
            </div>
          </footer>
        </main>
      </div>
    </div>
  );
}
