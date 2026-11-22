// 布局/滚动测试的 harness 入口（change `web-chat-screen` 任务 2.1 / design D13）。
//
// 为什么单独一个入口：puppeteer 要的是**真实布局引擎**（jsdom 的
// getBoundingClientRect 恒 0，量不出折叠卡单行高度 / 滚动位置），但真实聊天屏
// 依赖核心 WS + 数据库。这个 harness 只挂聊天屏组件、用可编程的假数据源驱动，
// 由 `e2e/layout.mjs` 在 headless Edge 里跑断言。
//
// 两种模式：
//   - 不注入 `window.__HARNESS_SCENARIO__`：渲染 canary（基建自检：真实布局引擎
//     可量 24px 单行高度、滚动真的会动）；
//   - 注入 scenario：渲染真实 `ChatScreen`，并通过 `window.__harness` 暴露
//     "推消息 / 推流式增量 / 上翻加载更早一页"这些驱动入口。
import { StrictMode, useCallback, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';

import '../../src/index.css';
import { applyAgentEvent, type AgentEventLike } from '../../src/chat/events';
import type { RawMessage } from '../../src/chat/model';
import { emptyChatView, type ChatView } from '../../src/chat/render';
import { ChatScreen } from '../../src/components/ChatScreen';
import { ProvidersPage } from '../../src/components/ProvidersPage';
import { TemplatesPage } from '../../src/components/TemplatesPage';
import { Wizard } from '../../src/components/Wizard';
import {
  parseAgentSwitchError,
  type AgentSwitchFailure,
} from '../../src/manage/logic';
import type {
  ConnectionStatus,
  CoreClient,
  Session,
  SnapshotEventData,
} from '../../src/protocol';

/** 管理屏场景的假核心状态（只够驱动页面；规则真相在 Dart 侧集成测试）。 */
interface FakeCoreState {
  config: {
    missing: boolean;
    configPath: string;
    providers: Record<
      string,
      {
        baseUrl: string;
        hasApiKey: boolean;
        models: { id?: string; display_name?: string; context_window?: number; modalities?: { input?: string[] } }[];
        discoveredAt: string | null;
      }
    >;
    agentTypes: Record<string, Record<string, unknown>>;
    tools: string[];
  };
  templates: {
    templates: Record<string, unknown>[];
    tools: string[];
    providers: string[];
    defaultTools: string[];
    thinkingEfforts: string[];
    allowedModalities: string[];
    effectiveNote: string;
  };
  /** provider.probe 按 provider 名的返回。 */
  probeResults?: Record<string, Record<string, unknown>>;
  /** provider.probeFetch 依次弹出。 */
  probeFetchQueue?: Record<string, unknown>[];
}

interface HarnessScenario {
  /** 挂哪个屏；缺省 = 聊天屏。 */
  mode?: 'providers' | 'templates' | 'wizard';
  fake?: Partial<FakeCoreState>;
  sessions?: Session[];
  messages?: RawMessage[];
  streamingText?: string;
  isStreaming?: boolean;
  hasEarlier?: boolean;
  /** 每次"上翻加载更早"返回一批（先进后出：`shift()`）。 */
  earlierChunks?: RawMessage[][];
  /** 模拟网络延迟（ms）：让"加载中"态可见。 */
  earlierDelayMs?: number;
  error?: string | null;
  notice?: string | null;
  snapshot?: SnapshotEventData | null;
  /** 会话侧栏（change `web-management-ui` 1.3）：可选模板名。 */
  templates?: string[];
  /** 切换这个模板时返回失败（消息按核心格式给，界面必须解析出阶段+候选名）。 */
  switchFailure?: { templateName: string; message: string };
  /** 图片模态（false ⇒ 用户消息要显示「图片未发送」提示行）。 */
  imagesSupported?: boolean | null;
  /** 附件路径 → data URL（null = 文件丢失）。 */
  attachments?: Record<string, string | null>;
}

interface HarnessApi {
  pushEvent(event: AgentEventLike): void;
  pushMessage(message: RawMessage): void;
  pushChunk(text: string): void;
  setStreaming(streaming: boolean): void;
  remainingEarlierChunks(): number;
  messageCount(): number;
  /** 会话管理交互记录（`session.create` / `session.rename:<id>:<title>` 等）。 */
  calls(): string[];
  sessionTitles(): string[];
  switchFailure(): AgentSwitchFailure | null;
}

declare global {
  interface Window {
    __HARNESS_SCENARIO__?: HarnessScenario;
    __harness?: HarnessApi;
  }
}

function Canary() {
  return (
    <div>
      <div
        data-testid="canary-single-line"
        style={{
          height: 24,
          lineHeight: '24px',
          overflow: 'hidden',
          whiteSpace: 'nowrap',
          textOverflow: 'ellipsis',
          width: 200,
        }}
      >
        这一行必须被量成 24px 高（真实布局引擎）
      </div>
      <div
        data-testid="canary-scroll"
        style={{ height: 200, overflowY: 'auto', marginTop: 8 }}
      >
        <div data-testid="canary-tall" style={{ height: 2000 }}>
          很高的内容
        </div>
      </div>
    </div>
  );
}

function makeSessions(count: number): Session[] {
  return Array.from({ length: count }, (_, index) => ({
    id: `s-${index}`,
    title: `会话 ${index}`,
    agentType: 'general',
    parentSessionId: null,
    createdAt: index,
    updatedAt: index,
    kind: 'single' as const,
    overrides: null,
  }));
}

/** 假核心：按方法名回放状态；每次请求都记进 `calls`（e2e 断言 payload）。 */
function makeFakeClient(
  state: FakeCoreState,
  calls: string[],
): CoreClient {
  return {
    async request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      calls.push(`${method}:${JSON.stringify(params)}`);
      switch (method) {
        case 'config.get':
          return state.config as unknown as T;
        case 'config.save': {
          const table = (params.providers ?? {}) as Record<
            string,
            {
              base_url: string;
              api_key?: string;
              models?: unknown[];
              rename_from?: string;
            }
          >;
          // 引用守卫（核心行为的最小镜像，仅用于页面展示断言）。
          const referenced = [
            ...new Set(
              Object.values(state.config.agentTypes)
                .map((template) => template.provider)
                .filter((provider): provider is string => typeof provider === 'string'),
            ),
          ];
          for (const existing of Object.keys(state.config.providers)) {
            if (table[existing] === undefined && referenced.includes(existing)) {
              throw new Error(`provider "${existing}" 被 general 引用，不能删除`);
            }
          }
          const nextProviders: Record<string, FakeCoreState['config']['providers'][string]> = {};
          for (const [name, spec] of Object.entries(table)) {
            const before = state.config.providers[spec.rename_from ?? name];
            nextProviders[name] = {
              baseUrl: spec.base_url,
              hasApiKey:
                spec.api_key !== undefined
                  ? spec.api_key.length > 0
                  : (before?.hasApiKey ?? false),
              models:
                spec.models !== undefined
                  ? (spec.models as FakeCoreState['config']['providers'][string]['models'])
                  : (before?.models ?? []),
              discoveredAt: spec.models !== undefined ? '2026-11-22T00:00:00Z' : (before?.discoveredAt ?? null),
            };
          }
          state.config.providers = nextProviders;
          state.templates.providers = Object.keys(nextProviders);
          return { config: state.config } as unknown as T;
        }
        case 'provider.probe': {
          const name = String(params.providerName ?? '');
          const result = state.probeResults?.[name] ?? {
            ok: true,
            providerName: name,
            entries: [],
            added: 0,
            updated: 0,
            removed: 0,
            dropped: 0,
            discoveredAt: '2026-11-22T00:00:00Z',
            error: null,
          };
          return result as unknown as T;
        }
        case 'provider.probeFetch': {
          const result = state.probeFetchQueue?.shift();
          if (!result) throw new Error('没有预置的 probeFetch 结果');
          return result as unknown as T;
        }
        case 'template.list':
          return state.templates as unknown as T;
        case 'template.save': {
          const name = String(params.name ?? '');
          if (name === 'general' && state.templates.templates.some((t) => t.name === 'general')) {
            // 允许修改 general；这里只记录（删除守卫由 template.delete 负责）。
          }
          const existing = state.templates.templates.findIndex((t) => t.name === name);
          const saved = { ...params, name };
          if (existing >= 0) state.templates.templates[existing] = saved;
          else state.templates.templates.push(saved);
          return { template: saved, created: existing < 0 } as unknown as T;
        }
        case 'template.delete': {
          const name = String(params.templateName ?? '');
          if (name === 'general') {
            throw new Error('general 模板不可删：SessionRepository.create 默认用它');
          }
          state.templates.templates = state.templates.templates.filter(
            (template) => template.name !== name,
          );
          return { templateName: name, deleted: true } as unknown as T;
        }
        default:
          throw new Error(`假核心未实现的方法：${method}`);
      }
    },
  };
}

/** 管理屏 harness：真实组件 + 假核心（布局/交互断言在 e2e）。 */
function ManagementHarness({ scenario }: { scenario: HarnessScenario }) {
  const callsRef = useRef<string[]>([]);
  const stateRef = useRef<FakeCoreState>({
    config: {
      missing: false,
      configPath: 'C:\\tmp\\config.json',
      providers: {},
      agentTypes: {},
      tools: [],
      ...(scenario.fake?.config ?? {}),
    },
    templates: {
      templates: [],
      tools: [],
      providers: [],
      defaultTools: [],
      thinkingEfforts: [],
      allowedModalities: ['text', 'image'],
      effectiveNote: '',
      ...(scenario.fake?.templates ?? {}),
    },
    probeResults: scenario.fake?.probeResults,
    probeFetchQueue: [...(scenario.fake?.probeFetchQueue ?? [])],
  });
  const client = useMemo(() => makeFakeClient(stateRef.current, callsRef.current), []);

  useMemo(() => {
    window.__harness = {
      calls: () => [...callsRef.current],
    } as unknown as HarnessApi;
  }, []);

  return (
    <div className="h-full bg-bg text-fg">
      {scenario.mode === 'providers' && (
        <ProvidersPage
          client={client}
          onClose={() => callsRef.current.push('panel.close')}
          onChanged={() => callsRef.current.push('panel.changed')}
        />
      )}
      {scenario.mode === 'templates' && (
        <TemplatesPage
          client={client}
          onClose={() => callsRef.current.push('panel.close')}
          onChanged={() => callsRef.current.push('panel.changed')}
        />
      )}
      {scenario.mode === 'wizard' && (
        <Wizard
          client={client}
          onDone={() => callsRef.current.push('wizard.done')}
        />
      )}
    </div>
  );
}

function Harness({ scenario }: { scenario: HarnessScenario }) {
  const [sessions, setSessions] = useState<Session[]>(
    () => scenario.sessions ?? makeSessions(1),
  );
  const [currentSessionId, setCurrentSessionId] = useState<string | null>(
    sessions[0]?.id ?? null,
  );
  const [switchFailure, setSwitchFailure] = useState<AgentSwitchFailure | null>(null);
  const [attachmentDataUrls, setAttachmentDataUrls] = useState<Record<string, string | null>>(
    () => scenario.attachments ?? {},
  );
  const callsRef = useRef<string[]>([]);
  const createdCount = useRef(0);
  const [view, setView] = useState<ChatView>(() => ({
    ...emptyChatView,
    messages: scenario.messages ?? [],
    streamingText: scenario.streamingText ?? '',
    isStreaming: scenario.isStreaming ?? false,
  }));
  const [hasEarlier, setHasEarlier] = useState(scenario.hasEarlier ?? false);
  const [loadingEarlier, setLoadingEarlier] = useState(false);
  const [error] = useState<string | null>(scenario.error ?? null);
  const [notice] = useState<string | null>(scenario.notice ?? null);
  const chunksRef = useRef<RawMessage[][]>(scenario.earlierChunks ?? []);

  const onCreate = useCallback(() => {
    callsRef.current.push('session.create');
    createdCount.current += 1;
    const created: Session = {
      id: `s-created-${createdCount.current}`,
      title: `新建会话 ${createdCount.current}`,
      agentType: 'general',
      parentSessionId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      kind: 'single',
      overrides: null,
    };
    setSessions((previous) => [created, ...previous]);
    setCurrentSessionId(created.id);
    setSwitchFailure(null);
  }, []);

  const onRename = useCallback((sessionId: string, title: string) => {
    callsRef.current.push(`session.rename:${sessionId}:${title}`);
    setSessions((previous) =>
      previous.map((session) => (session.id === sessionId ? { ...session, title } : session)),
    );
  }, []);

  const onDelete = useCallback((sessionId: string) => {
    callsRef.current.push(`session.delete:${sessionId}`);
    setSessions((previous) => {
      const remaining = previous.filter((session) => session.id !== sessionId);
      setCurrentSessionId((current) => (current === sessionId ? remaining[0]?.id ?? null : current));
      return remaining;
    });
  }, []);

  const onSwitchTemplate = useCallback(
    (templateName: string) => {
      callsRef.current.push(`session.switchTemplate:${templateName}`);
      const failing = scenario.switchFailure;
      if (failing && failing.templateName === templateName) {
        setSwitchFailure(parseAgentSwitchError(failing.message));
        return;
      }
      setSwitchFailure(null);
      setSessions((previous) =>
        previous.map((session) =>
          session.id === currentSessionId ? { ...session, agentType: templateName } : session,
        ),
      );
    },
    [currentSessionId, scenario.switchFailure],
  );

  const loadEarlier = useCallback(() => {
    const chunk = chunksRef.current.shift();
    if (!chunk) {
      setHasEarlier(false);
      return;
    }
    setLoadingEarlier(true);
    const delay = scenario.earlierDelayMs ?? 60;
    window.setTimeout(() => {
      setView((previous) => ({
        ...previous,
        messages: [...chunk, ...previous.messages],
      }));
      setHasEarlier(chunksRef.current.length > 0);
      setLoadingEarlier(false);
    }, delay);
  }, [scenario.earlierDelayMs]);

  useMemo(() => {
    window.__harness = {
      pushEvent: (event) => setView((previous) => applyAgentEvent(previous, event)),
      pushMessage: (message) =>
        setView((previous) =>
          applyAgentEvent(previous, {
            type: message.role === 'user' ? 'user.message' : 'assistant.message',
            data: message as unknown as Record<string, unknown>,
          }),
        ),
      pushChunk: (text) =>
        setView((previous) => applyAgentEvent(previous, { type: 'assistant.chunk', data: { text } })),
      setStreaming: (streaming) =>
        setView((previous) =>
          applyAgentEvent(previous, { type: 'agent.streaming', data: { streaming } }),
        ),
      remainingEarlierChunks: () => chunksRef.current.length,
      messageCount: () => view.messages.length,
      calls: () => [...callsRef.current],
      sessionTitles: () => sessions.map((session) => session.title),
      switchFailure: () => switchFailure,
    };
  }, [view.messages.length, sessions, switchFailure]);

  const status: ConnectionStatus = 'open';
  return (
    <ChatScreen
      status={status}
      sessions={sessions}
      currentSessionId={currentSessionId}
      onSelectSession={setCurrentSessionId}
      onCreateSession={onCreate}
      onRenameSession={onRename}
      onDeleteSession={onDelete}
      templates={scenario.templates ?? []}
      currentAgentType={sessions.find((session) => session.id === currentSessionId)?.agentType ?? null}
      onSwitchTemplate={onSwitchTemplate}
      switchFailure={switchFailure}
      view={view}
      hasEarlier={hasEarlier}
      loadingEarlier={loadingEarlier}
      onLoadEarlier={loadEarlier}
      error={error}
      notice={notice}
      skillFailures={[]}
      snapshot={scenario.snapshot ?? null}
      metering={null}
      attachments={attachmentDataUrls}
      imagesSupported={scenario.imagesSupported ?? null}
      onSend={(text, images = []) => {
        callsRef.current.push(`agent.send:${text}:${images.length}`);
        const paths = images.map((image) => ({
          path: `pending/${image.name}`,
          dataUrl: image.dataUrl,
        }));
        setAttachmentDataUrls((previous) => {
          const next = { ...previous };
          for (const item of paths) next[item.path] = item.dataUrl;
          return next;
        });
        window.__harness?.pushMessage({
          id: `sent-${Date.now()}`,
          role: 'user',
          content: text,
          attachments: paths.map((item) => item.path),
        });
      }}
    />
  );
}

const scenario = window.__HARNESS_SCENARIO__;
const managementMode =
  scenario?.mode === 'providers' || scenario?.mode === 'templates' || scenario?.mode === 'wizard';
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {managementMode ? (
      <ManagementHarness scenario={scenario!} />
    ) : scenario ? (
      <Harness scenario={scenario} />
    ) : (
      <Canary />
    )}
  </StrictMode>,
);
