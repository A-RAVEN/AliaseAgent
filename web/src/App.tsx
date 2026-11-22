// web 客户端入口装配（change `web-chat-screen`）：RPC ↔ 聊天视图状态 ↔ ChatScreen。
//
// 分工：
//   - 事件归约在 `chat/events.ts`（纯函数，vitest 覆盖流式语义与归一）；
//   - 渲染在 `chat/render.ts`（纯函数，修空气泡/去重）；
//   - 布局/滚动在 `components/MessageList.tsx`（puppeteer 覆盖）；
//   - 这里只做"接线"：连 WS、拉会话/分页、把事件塞进归约、把状态交给组件。
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { applyAgentEvent, type AgentEventLike } from './chat/events';
import type { PendingImage } from './chat/attachments';
import {
  loadEarlierPage,
  loadInitialPage,
  prependOlder,
  restoreMessages,
} from './chat/paging';
import { emptyChatView, type ChatView } from './chat/render';
import { ChatScreen } from './components/ChatScreen';
import { ProvidersPage } from './components/ProvidersPage';
import { TemplatesPage } from './components/TemplatesPage';
import { Wizard } from './components/Wizard';
import { parseAgentSwitchError, type AgentSwitchFailure } from './manage/logic';
import {
  RpcClient,
  type AgentEvent,
  type ConnectionStatus,
  type Session,
  type SessionResult,
  type SessionSwitchResult,
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
  const [templates, setTemplates] = useState<string[]>([]);
  const [switchFailure, setSwitchFailure] = useState<AgentSwitchFailure | null>(null);
  const [attachmentDataUrls, setAttachmentDataUrls] = useState<Record<string, string | null>>({});
  const [imagesSupported, setImagesSupported] = useState<boolean | null>(null);
  const [panel, setPanel] = useState<'providers' | 'templates' | null>(null);
  const [configMissing, setConfigMissing] = useState(false);
  const currentSessionIdRef = useRef<string | null>(null);
  const requestedAttachments = useRef<Set<string>>(new Set());

  currentSessionIdRef.current = currentSessionId;

  /** 配置文件是否存在：不存在 ⇒ 打开首启向导（design D2 / D11）。 */
  const checkConfig = useCallback(async () => {
    try {
      const result = await client.request<{ missing: boolean }>('config.get');
      setConfigMissing(result.missing === true);
    } catch {
      setConfigMissing(false);
    }
  }, [client]);

  /** 当前模板是否声明 image 模态（决定「图片未发送」提示行；未知时不乱提示）。 */
  const loadImagesSupported = useCallback(
    async (agentType: string | null) => {
      if (!agentType) {
        setImagesSupported(null);
        return;
      }
      try {
        const result = await client.request<{
          agentTypes: Record<string, { input_modalities?: string[] }>;
        }>('config.get');
        const modalities = result.agentTypes[agentType]?.input_modalities ?? [];
        setImagesSupported(modalities.includes('image'));
      } catch {
        setImagesSupported(null);
      }
    },
    [client],
  );

  /** 历史附件：逐条 `attachment.read` 取字节（文件丢失记为 null ⇒ 显示「图片已丢失」）。 */
  const resolveAttachments = useCallback(
    async (paths: string[]) => {
      for (const path of paths) {
        if (!path || requestedAttachments.current.has(path)) continue;
        requestedAttachments.current.add(path);
        try {
          const result = await client.request<{ base64: string; mediaType: string }>(
            'attachment.read',
            { path },
          );
          const dataUrl = `data:${result.mediaType};base64,${result.base64}`;
          setAttachmentDataUrls((previous) => ({ ...previous, [path]: dataUrl }));
        } catch {
          setAttachmentDataUrls((previous) => ({ ...previous, [path]: null }));
        }
      }
    },
    [client],
  );

  /** 模板名列表（会话侧栏的切换下拉用）；核心没提供 `template.list` 时明确提示。 */
  const loadTemplates = useCallback(async () => {
    try {
      const result = await client.request<{ templates: { name: string }[] }>('template.list');
      setTemplates(result.templates.map((template) => template.name));
    } catch (templateError: unknown) {
      setTemplates([]);
      setNotice(`模板列表不可用：${errorText(templateError)}`);
    }
  }, [client]);

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
      setNotice('还没有会话：点左侧的 + 新建一个。');
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
      .then(async () => {
        await loadSessions();
        await loadTemplates();
        await checkConfig();
      })
      .catch((connectError: unknown) => setError(errorText(connectError)));
    return () => {
      offStatus();
      offEvent();
      offReconnected();
      client.close();
    };
  }, [client, loadSessions, loadTemplates, checkConfig, onEvent, refreshAfterReconnect]);

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

  const send = async (text: string, images: PendingImage[] = []) => {
    const sessionId = currentSessionIdRef.current;
    if (!sessionId) return;
    if (!text && images.length === 0) return;
    setError(null);
    setNotice(null);
    try {
      // 图片先经 `attachment.upload` 落盘（核心校验上限与文件头魔数），再把路径交给
      // `agent.send` 的 attachments —— 消息里只存路径（与 Flutter 侧同一形状）。
      const attachments: string[] = [];
      for (const image of images) {
        const uploaded = await client.request<{ path: string }>('attachment.upload', {
          filename: image.name,
          base64: image.base64,
        });
        attachments.push(uploaded.path);
        requestedAttachments.current.add(uploaded.path);
        setAttachmentDataUrls((previous) => ({ ...previous, [uploaded.path]: image.dataUrl }));
      }
      await client.request('agent.send', { sessionId, text, attachments });
    } catch (sendError: unknown) {
      setError(errorText(sendError));
    }
  };

  // ---------------------------------------------------------------------------
  // 会话管理（change `web-management-ui` 任务 1.3 / design D7）
  // ---------------------------------------------------------------------------

  const reloadSessions = useCallback(async (): Promise<Session[]> => {
    const result = await client.request<{ sessions: Session[] }>('session.list');
    setSessions(result.sessions);
    return result.sessions;
  }, [client]);

  const createSession = async () => {
    setError(null);
    setSwitchFailure(null);
    try {
      const created = await client.request<SessionResult>('session.create', {});
      await reloadSessions();
      setCurrentSessionId(created.session.id);
      setView(emptyChatView);
      setEarlierCursor(null);
      setSnapshot(null);
      setSkillFailures([]);
      setMetering(null);
      setNotice(null);
    } catch (createError: unknown) {
      setError(`新建会话失败：${errorText(createError)}`);
    }
  };

  const renameSession = async (sessionId: string, title: string) => {
    setError(null);
    try {
      const result = await client.request<SessionResult>('session.rename', {
        sessionId,
        title,
      });
      setSessions((previous) =>
        previous.map((session) => (session.id === sessionId ? result.session : session)),
      );
    } catch (renameError: unknown) {
      setError(`重命名失败：${errorText(renameError)}`);
    }
  };

  const deleteSession = async (sessionId: string) => {
    setError(null);
    setSwitchFailure(null);
    try {
      await client.request('session.delete', { sessionId });
      const remaining = await reloadSessions();
      if (currentSessionIdRef.current === sessionId) {
        const next = remaining.length > 0 ? remaining[0] : null;
        setCurrentSessionId(next?.id ?? null);
        setView(emptyChatView);
        setEarlierCursor(null);
        setSnapshot(null);
        setSkillFailures([]);
        setMetering(null);
        if (next) await loadLatestPage(next.id);
      }
    } catch (deleteError: unknown) {
      setError(`删除会话失败：${errorText(deleteError)}`);
    }
  };

  const switchTemplate = async (templateName: string) => {
    const sessionId = currentSessionIdRef.current;
    if (!sessionId) return;
    setSwitchFailure(null);
    setError(null);
    try {
      const result = await client.request<SessionSwitchResult>('session.switchTemplate', {
        sessionId,
        templateName,
      });
      setSessions((previous) =>
        previous.map((session) =>
          session.id === sessionId ? { ...session, agentType: result.agentType } : session,
        ),
      );
    } catch (switchError: unknown) {
      // 显示**阶段 + 候选名**：只说"切换失败"用户无法判断卡在哪一步（design D4）。
      setSwitchFailure(parseAgentSwitchError(errorText(switchError)));
    }
  };

  const currentAgentType =
    sessions.find((session) => session.id === currentSessionId)?.agentType ?? null;

  // 图片模态（决定「图片未发送」提示）随当前模板变化重查；附件字节随消息补取。
  useEffect(() => {
    void loadImagesSupported(currentAgentType);
  }, [currentAgentType, loadImagesSupported]);

  useEffect(() => {
    const paths: string[] = [];
    for (const message of view.messages) {
      if (message.role !== 'user') continue;
      for (const path of message.attachments ?? []) paths.push(path);
    }
    if (paths.length > 0) void resolveAttachments(paths);
  }, [view.messages, resolveAttachments]);

  return (
    <div className="relative h-full">
      {configMissing ? (
        <Wizard
          client={client}
          onDone={() => {
            setConfigMissing(false);
            void (async () => {
              await loadSessions();
              await loadTemplates();
            })();
          }}
        />
      ) : (
        <ChatScreen
      status={status}
      sessions={sessions}
      currentSessionId={currentSessionId}
      onSelectSession={(sessionId) => void selectSession(sessionId)}
      onCreateSession={() => void createSession()}
      onRenameSession={(sessionId, title) => void renameSession(sessionId, title)}
      onDeleteSession={(sessionId) => void deleteSession(sessionId)}
      templates={templates}
      currentAgentType={currentAgentType}
      onSwitchTemplate={(templateName) => void switchTemplate(templateName)}
      switchFailure={switchFailure}
      view={view}
      hasEarlier={earlierCursor !== null}
      loadingEarlier={loadingEarlier}
      onLoadEarlier={() => void loadEarlier()}
      error={error}
      notice={notice}
      skillFailures={skillFailures}
      snapshot={snapshot}
      metering={metering}
      onSend={(text, images) => void send(text, images)}
      attachments={attachmentDataUrls}
      imagesSupported={imagesSupported}
      onOpenProviders={() => setPanel('providers')}
      onOpenTemplates={() => setPanel('templates')}
    />
      )}
      {panel === 'providers' && (
        <div className="absolute inset-0 z-20 bg-bg">
          <ProvidersPage
            client={client}
            onClose={() => setPanel(null)}
            onChanged={() => {
              void loadTemplates();
              void loadImagesSupported(currentAgentType);
            }}
          />
        </div>
      )}
      {panel === 'templates' && (
        <div className="absolute inset-0 z-20 bg-bg">
          <TemplatesPage
            client={client}
            onClose={() => setPanel(null)}
            onChanged={() => {
              void loadTemplates();
              void loadImagesSupported(currentAgentType);
            }}
          />
        </div>
      )}
    </div>
  );
}
