// web 客户端入口装配（change `web-chat-screen`）：RPC ↔ 聊天视图状态 ↔ ChatScreen。
//
// 分工：
//   - 事件归约在 `chat/events.ts`（纯函数，vitest 覆盖流式语义与归一）；
//   - 渲染在 `chat/render.ts`（纯函数，修空气泡/去重）；
//   - 布局/滚动在 `components/MessageList.tsx`（puppeteer 覆盖）；
//   - 这里只做"接线"：连 WS、拉会话/分页、把事件塞进归约、把状态交给组件。
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { applyAgentEvent, type AgentEventLike } from './chat/events';
import {
  loadEarlierPage,
  loadInitialPage,
  prependOlder,
  restoreMessages,
} from './chat/paging';
import { emptyChatView, type ChatView } from './chat/render';
import { ChatScreen } from './components/ChatScreen';
import {
  RpcClient,
  type AgentEvent,
  type ConnectionStatus,
  type Session,
  type SnapshotEventData,
} from './protocol';
import { layoutConfig } from './tokens';

// 聊天屏一次向核心要多少条历史：**调用方的显示选择**（pageSize 由请求方必填，
// 核心不提供默认值），不是核心的隐藏默认页大小。
const HISTORY_PAGE_SIZE = 30;

const coreWsUrl: string =
  (import.meta.env.VITE_CORE_WS as string | undefined) ??
  `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export default function App() {
  // 重连/心跳四参数来自 tokens（可配、有文档键表），不在这里写数字。
  const client = useMemo(() => new RpcClient({ config: layoutConfig }), []);
  const [status, setStatus] = useState<ConnectionStatus>('connecting');
  const [sessions, setSessions] = useState<Session[]>([]);
  const [currentSessionId, setCurrentSessionId] = useState<string | null>(null);
  const [view, setView] = useState<ChatView>(emptyChatView);
  const [earlierCursor, setEarlierCursor] = useState<number | null>(null);
  const [loadingEarlier, setLoadingEarlier] = useState(false);
  const [snapshot, setSnapshot] = useState<SnapshotEventData | null>(null);
  const [skillFailures, setSkillFailures] = useState<string[]>([]);
  const [metering, setMetering] = useState<Record<string, unknown> | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const currentSessionIdRef = useRef<string | null>(null);

  currentSessionIdRef.current = currentSessionId;

  /** 首屏锚定最新一页（design D10：anchor=tail，不是最旧页）。 */
  const loadLatestPage = useCallback(
    async (sessionId: string) => {
      const page = await loadInitialPage(
        (method, params) => client.request(method, params),
        sessionId,
        HISTORY_PAGE_SIZE,
      );
      setView({ ...emptyChatView, messages: page.messages });
      setEarlierCursor(page.earlierCursor);
      setLoadingEarlier(false);
    },
    [client],
  );

  /** 上翻加载更早一页（反向游标 prevCursor；顺序由 MessageList 保持位置）。 */
  const loadEarlier = useCallback(async () => {
    const sessionId = currentSessionIdRef.current;
    if (!sessionId || earlierCursor === null || loadingEarlier) return;
    setLoadingEarlier(true);
    try {
      const page = await loadEarlierPage(
        (method, params) => client.request(method, params),
        sessionId,
        HISTORY_PAGE_SIZE,
        earlierCursor,
      );
      setView((previous) => ({
        ...previous,
        messages: prependOlder(previous.messages, page.messages),
      }));
      setEarlierCursor(page.earlierCursor);
    } catch (loadError: unknown) {
      setError(errorText(loadError));
    } finally {
      setLoadingEarlier(false);
    }
  }, [client, earlierCursor, loadingEarlier]);

  const loadSessions = useCallback(async () => {
    const result = await client.request<{ sessions: Session[] }>('session.list');
    setSessions(result.sessions);
    if (result.sessions.length === 0) {
      setCurrentSessionId(null);
      setView(emptyChatView);
      setEarlierCursor(null);
      setNotice('还没有会话：先用 Flutter 应用创建会话（无头核心与 Flutter 共用同一个数据库）。');
      return;
    }
    setNotice(null);
    const first = result.sessions[0];
    setCurrentSessionId(first.id);
    await loadLatestPage(first.id);
  }, [client, loadLatestPage]);

  const onEvent = useCallback((event: AgentEvent) => {
    if (event.sessionId !== currentSessionIdRef.current) return;
    const data = event.data ?? {};
    switch (event.type) {
      case 'user.message':
      case 'assistant.message':
      case 'assistant.chunk':
      case 'tool.call':
      case 'tool.result':
      case 'thinking.delta':
      case 'thinking.block':
      case 'agent.streaming': {
        setView((previous) => applyAgentEvent(previous, event as AgentEventLike));
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
        setView((previous) => applyAgentEvent(previous, event as AgentEventLike));
        break;
      }
      case 'compaction.status': {
        setNotice(data.isIdle === false ? String(data.label ?? '正在压缩…') : null);
        break;
      }
      default:
        // 未消费的事件（元数据等）忽略；事件本身仍在通道里可见。
        break;
    }
  }, []);

  /**
   * 重连成功后补状态（design D12）：重拉会话列表 + 尾锚页，并按 id 合并进现有消息
   * （断线期间落库的消息补上，已上翻加载的旧页不丢）。
   */
  const refreshAfterReconnect = useCallback(async () => {
    const sessionId = currentSessionIdRef.current;
    try {
      const sessionsResult = await client.request<{ sessions: Session[] }>('session.list');
      setSessions(sessionsResult.sessions);
      if (!sessionId) return;
      const page = await loadInitialPage(
        (method, params) => client.request(method, params),
        sessionId,
        HISTORY_PAGE_SIZE,
      );
      setView((previous) => ({
        ...previous,
        messages: restoreMessages(previous.messages, page.messages),
      }));
    } catch (refreshError: unknown) {
      setError(errorText(refreshError));
    }
  }, [client]);

  useEffect(() => {
    const offStatus = client.onStatus(setStatus);
    const offEvent = client.onEvent(onEvent);
    // 重连成功：重拉当前页 + 会话列表恢复状态（design D12）。后续事件由核心
    // `_broadcast` 直接发到当前连接（没有 ensure/subscribe RPC）。
    const offReconnected = client.onReconnected(() => {
      void refreshAfterReconnect();
    });
    client
      .connect(coreWsUrl)
      .then(loadSessions)
      .catch((connectError: unknown) => setError(errorText(connectError)));
    return () => {
      offStatus();
      offEvent();
      offReconnected();
      client.close();
    };
  }, [client, loadSessions, onEvent, refreshAfterReconnect]);

  const selectSession = async (sessionId: string) => {
    setCurrentSessionId(sessionId);
    setView(emptyChatView);
    setEarlierCursor(null);
    setSnapshot(null);
    setSkillFailures([]);
    setMetering(null);
    setError(null);
    try {
      await loadLatestPage(sessionId);
    } catch (loadError: unknown) {
      setError(errorText(loadError));
    }
  };

  const send = async (text: string) => {
    const sessionId = currentSessionIdRef.current;
    if (!text || !sessionId) return;
    setError(null);
    setNotice(null);
    try {
      await client.request('agent.send', { sessionId, text });
    } catch (sendError: unknown) {
      setError(errorText(sendError));
    }
  };

  return (
    <ChatScreen
      status={status}
      sessions={sessions}
      currentSessionId={currentSessionId}
      onSelectSession={(sessionId) => void selectSession(sessionId)}
      view={view}
      hasEarlier={earlierCursor !== null}
      loadingEarlier={loadingEarlier}
      onLoadEarlier={() => void loadEarlier()}
      error={error}
      notice={notice}
      skillFailures={skillFailures}
      snapshot={snapshot}
      metering={metering}
      onSend={(text) => void send(text)}
    />
  );
}
