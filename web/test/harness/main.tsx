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
import { StrictMode, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';

import '../../src/index.css';
import { resolveAvatar } from '../../src/avatars/resolve';
import { applyAgentEvent, type AgentEventLike } from '../../src/chat/events';
import type { RawMessage } from '../../src/chat/model';
import { emptyChatView, type ChatView } from '../../src/chat/render';
import type { AvatarData } from '../../src/components/Avatar';
import { ChatScreen } from '../../src/components/ChatScreen';
import { ChatShell } from '../../src/components/ChatShell';
import { SessionList } from '../../src/components/SessionList';
import { ProvidersPage } from '../../src/components/ProvidersPage';
import { TemplatesPage } from '../../src/components/TemplatesPage';
import { UserAvatarBlock } from '../../src/components/UserAvatarBlock';
import { Wizard } from '../../src/components/Wizard';
import {
  parseAgentSwitchError,
  type AgentSwitchFailure,
} from '../../src/manage/logic';
import type {
  ConfigGetResult,
  ConnectionStatus,
  CoreClient,
  Profile,
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
  /** ChatScreen 的「有技能未生效」提示行（change `group-chat-layout` 1.1）。 */
  skillFailures?: string[];
  snapshot?: SnapshotEventData | null;
  /** 会话侧栏（change `web-management-ui` 1.3）：可选模板名。 */
  templates?: string[];
  /** 切换这个模板时返回失败（消息按核心格式给，界面必须解析出阶段+候选名）。 */
  switchFailure?: { templateName: string; message: string };
  /** 图片模态（false ⇒ 用户消息要显示「图片未发送」提示行）。 */
  imagesSupported?: boolean | null;
  /** 附件路径 → data URL（null = 文件丢失）。 */
  attachments?: Record<string, string | null>;
  // ---- change `chat-bubbles-avatars`：头像夹具（假核心） ----
  /** 用户资料（`config.get` 的 `profile`）；缺省 = 常量种子的空资料。 */
  profile?: Profile | null;
  /** true ⇒ `config.get` 回错（造「头像资料读取失败」的可见出口）。 */
  profileFail?: boolean;
  /** 模板名 → 上传头像路径（`template.list` 的 `avatar_path`）。 */
  templateAvatars?: Record<string, string>;
  /** 头像路径 → 可读的 data URL；值为 null（或键缺失）= `attachment.read` 回错。 */
  avatarReads?: Record<string, string | null>;
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
    reactionsEnabled: true,
    maxRounds: null,
  }));
}

/**
 * 假核心：按方法名回放状态；每次请求都记进 `calls`（e2e 断言 payload）。
 *
 * change `chat-bubbles-avatars`：补 `attachment.upload` / `attachment.read` /
 * `profile.save` 三个假分支（模板页与侧栏头像用；返回值只够驱动界面）。
 */
function makeFakeClient(
  state: FakeCoreState,
  calls: string[],
  profileRef: { current: Profile },
  uploaded: Record<string, string>,
): CoreClient {
  return {
    async request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      calls.push(`${method}:${JSON.stringify(params)}`);
      switch (method) {
        case 'config.get':
          return { ...state.config, profile: profileRef.current } as unknown as T;
        case 'attachment.upload': {
          const filename = String(params.filename ?? 'avatar.png');
          const path = `uploaded/${filename}`;
          uploaded[path] = `data:image/png;base64,${String(params.base64 ?? '')}`;
          return {
            path,
            bytes: 0,
            format: 'png',
            mediaType: 'image/png',
            width: 1,
            height: 1,
          } as unknown as T;
        }
        case 'attachment.read': {
          const path = String(params.path ?? '');
          const dataUrl = uploaded[path];
          if (!dataUrl) throw new Error(`图片已丢失（e2e 注入）：${path}`);
          const comma = dataUrl.indexOf(',');
          return {
            path,
            bytes: 0,
            base64: comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl,
            mediaType: 'image/png',
          } as unknown as T;
        }
        case 'profile.save': {
          const avatarPath = params.avatarPath;
          if (typeof avatarPath !== 'string') {
            throw new Error('profile.save 的 avatarPath 必须是字符串（"" = 清除）');
          }
          profileRef.current = {
            ...profileRef.current,
            avatarPath: avatarPath.length > 0 ? avatarPath : null,
          };
          return { profile: profileRef.current } as unknown as T;
        }
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
          const existing = state.templates.templates.findIndex((t) => t.name === name);
          const before = existing >= 0 ? state.templates.templates[existing] : null;
          const saved: Record<string, unknown> = { ...params, name };
          // 头像三态（design D3）：省略 = 沿用、'' = 清除、非空 = 设。
          if (typeof params.avatarPath === 'string') {
            if (params.avatarPath.length > 0) saved.avatar_path = params.avatarPath;
            else delete saved.avatar_path;
          } else if (before && before.avatar_path !== undefined) {
            saved.avatar_path = before.avatar_path;
          }
          delete saved.avatarPath;
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

/** 聊天 harness 的假核心（change `chat-bubbles-avatars`）：只够驱动头像与 profile 流程。 */
function makeChatFakeClient(options: {
  scenario: HarnessScenario;
  calls: string[];
  uploaded: Record<string, string>;
  profileRef: { current: Profile };
}): CoreClient {
  const { scenario, calls, uploaded, profileRef } = options;
  return {
    async request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      calls.push(`${method}:${JSON.stringify(params)}`);
      switch (method) {
        case 'config.get': {
          if (scenario.profileFail) {
            throw new Error('config.get 失败（e2e 注入）');
          }
          return {
            missing: false,
            configPath: 'C:/tmp/config.json',
            providers: {},
            agentTypes: { general: { input_modalities: ['text'] } },
            tools: [],
            profile: profileRef.current,
          } as unknown as T;
        }
        case 'template.list': {
          const templates = Object.entries(scenario.templateAvatars ?? {}).map(
            ([name, avatarPath]) => ({ name, avatar_path: avatarPath }),
          );
          return {
            templates,
            tools: [],
            providers: [],
            defaultTools: [],
            thinkingEfforts: [],
            allowedModalities: ['text', 'image'],
            effectiveNote: '',
          } as unknown as T;
        }
        case 'attachment.upload': {
          const filename = String(params.filename ?? 'avatar.png');
          const path = `uploaded/${filename}`;
          uploaded[path] = `data:image/png;base64,${String(params.base64 ?? '')}`;
          return {
            path,
            bytes: 0,
            format: 'png',
            mediaType: 'image/png',
            width: 1,
            height: 1,
          } as unknown as T;
        }
        case 'attachment.read': {
          const path = String(params.path ?? '');
          const dataUrl = uploaded[path] ?? scenario.avatarReads?.[path] ?? null;
          if (dataUrl === null) throw new Error(`图片已丢失（e2e 注入）：${path}`);
          const comma = dataUrl.indexOf(',');
          return {
            path,
            bytes: 0,
            base64: comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl,
            mediaType: 'image/png',
          } as unknown as T;
        }
        case 'profile.save': {
          const avatarPath = params.avatarPath;
          if (typeof avatarPath !== 'string') {
            throw new Error('profile.save 的 avatarPath 必须是字符串（"" = 清除）');
          }
          profileRef.current = {
            ...profileRef.current,
            avatarPath: avatarPath.length > 0 ? avatarPath : null,
          };
          return { profile: profileRef.current } as unknown as T;
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
  const profileRef = useRef<Profile>({
    avatarPath: null,
    userId: null,
    identitySeed: 'local-user',
  });
  const uploadedRef = useRef<Record<string, string>>({});
  const client = useMemo(
    () => makeFakeClient(stateRef.current, callsRef.current, profileRef, uploadedRef.current),
    [],
  );
  // 头字节节走与 App 同一模式：路径 → data URL 的共用去重缓存（design D2）。
  const [avatarDataUrls, setAvatarDataUrls] = useState<Record<string, string | null>>({});
  const requestedAvatarPaths = useRef<Set<string>>(new Set());
  const resolveAvatarPaths = useCallback(
    (paths: string[]) => {
      for (const path of paths) {
        if (!path || requestedAvatarPaths.current.has(path)) continue;
        requestedAvatarPaths.current.add(path);
        void (async () => {
          try {
            const result = await client.request<{ base64: string; mediaType: string }>(
              'attachment.read',
              { path },
            );
            setAvatarDataUrls((previous) => ({
              ...previous,
              [path]: `data:${result.mediaType};base64,${result.base64}`,
            }));
          } catch {
            setAvatarDataUrls((previous) => ({ ...previous, [path]: null }));
          }
        })();
      }
    },
    [client],
  );

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
          avatarDataUrls={avatarDataUrls}
          onResolveAvatar={resolveAvatarPaths}
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
  const uploadedRef = useRef<Record<string, string>>({});
  const profileRef = useRef<Profile>(
    scenario.profile ?? { avatarPath: null, userId: null, identitySeed: 'local-user' },
  );
  const client = useMemo(
    () =>
      makeChatFakeClient({
        scenario,
        calls: callsRef.current,
        uploaded: uploadedRef.current,
        profileRef,
      }),
    [scenario],
  );
  // 头像：config.get 读 profile、attachment.read 取字节（与 App 同一份去重缓存模式）。
  const [profile, setProfile] = useState<Profile | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [avatarDataUrls, setAvatarDataUrls] = useState<Record<string, string | null>>({});
  const requestedAvatarPaths = useRef<Set<string>>(new Set());
  const templateAvatars = useMemo(() => scenario.templateAvatars ?? {}, [scenario]);

  const loadProfile = useCallback(async () => {
    try {
      const result = await client.request<ConfigGetResult>('config.get');
      setProfile(result.profile);
      setProfileError(null);
    } catch (profileFailure: unknown) {
      setProfile(null);
      setProfileError(
        profileFailure instanceof Error ? profileFailure.message : String(profileFailure),
      );
    }
  }, [client]);

  const resolveAvatarPaths = useCallback(
    (paths: string[]) => {
      for (const path of paths) {
        if (!path || requestedAvatarPaths.current.has(path)) continue;
        requestedAvatarPaths.current.add(path);
        void (async () => {
          try {
            const result = await client.request<{ base64: string; mediaType: string }>(
              'attachment.read',
              { path },
            );
            setAvatarDataUrls((previous) => ({
              ...previous,
              [path]: `data:${result.mediaType};base64,${result.base64}`,
            }));
          } catch {
            setAvatarDataUrls((previous) => ({ ...previous, [path]: null }));
          }
        })();
      }
    },
    [client],
  );
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

  useEffect(() => {
    void loadProfile();
  }, [loadProfile]);

  const avatarPaths = useMemo(() => {
    const paths = new Set<string>();
    if (profile?.avatarPath) paths.add(profile.avatarPath);
    const agentType = sessions.find((session) => session.id === currentSessionId)?.agentType;
    const templatePath = agentType ? templateAvatars[agentType] : undefined;
    if (templatePath) paths.add(templatePath);
    return [...paths];
  }, [profile, sessions, currentSessionId, templateAvatars]);

  useEffect(() => {
    if (avatarPaths.length > 0) resolveAvatarPaths(avatarPaths);
  }, [avatarPaths, resolveAvatarPaths]);

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
      reactionsEnabled: true,
      maxRounds: null,
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

  const onDelete = useCallback((session: Session) => {
    callsRef.current.push(
      `${session.kind === 'group' ? 'group.delete' : 'session.delete'}:${session.id}`,
    );
    setSessions((previous) => {
      const remaining = previous.filter((entry) => entry.id !== session.id);
      setCurrentSessionId((current) => (current === session.id ? remaining[0]?.id ?? null : current));
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
  const currentSession = sessions.find((session) => session.id === currentSessionId) ?? null;

  const avatarFor = (entityId: string, uploadedPath: string | null | undefined): AvatarData => {
    const resolved = resolveAvatar({ entityId, uploadedPath });
    const dataUrl =
      resolved.uploadedPath !== null ? avatarDataUrls[resolved.uploadedPath] ?? null : null;
    if (resolved.source === 'upload' && dataUrl !== null) {
      return { dataUrl, source: 'upload', seed: resolved.seed };
    }
    return { dataUrl: null, source: 'identicon', seed: resolved.seed };
  };
  const userAvatar = avatarFor(profile?.identitySeed ?? '', profile?.avatarPath ?? null);
  const agentAvatar = avatarFor(
    currentSessionId ?? '',
    currentSession?.agentType ? templateAvatars[currentSession.agentType] ?? null : null,
  );
  return (
    <ChatShell
      sidebarFooter={
        <UserAvatarBlock
          client={client}
          profile={profile}
          avatar={userAvatar}
          error={profileError}
          onUpdated={(next) => {
            setProfile(next);
            setProfileError(null);
            if (next.avatarPath !== null) resolveAvatarPaths([next.avatarPath]);
          }}
          onRetry={() => void loadProfile()}
        />
      }
      sidebar={
        <SessionList
          sessions={sessions}
          currentSessionId={currentSessionId}
          onSelect={setCurrentSessionId}
          onCreate={onCreate}
          onRename={onRename}
          onDelete={onDelete}
          templates={scenario.templates ?? []}
          currentAgentType={currentSession?.agentType ?? null}
          onSwitchTemplate={onSwitchTemplate}
          switchFailure={switchFailure}
        />
      }
    >
      <ChatScreen
        status={status}
        sessionTitle={currentSession?.title ?? null}
        sessionSelected={currentSession !== null}
        view={view}
        hasEarlier={hasEarlier}
        loadingEarlier={loadingEarlier}
        onLoadEarlier={loadEarlier}
        error={error}
        notice={notice}
        skillFailures={scenario.skillFailures ?? []}
        snapshot={scenario.snapshot ?? null}
        metering={null}
        attachments={attachmentDataUrls}
        imagesSupported={scenario.imagesSupported ?? null}
        userAvatar={userAvatar}
        agentAvatar={agentAvatar}
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
    </ChatShell>
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
