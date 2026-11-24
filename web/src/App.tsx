// web 客户端入口装配（change `web-chat-screen`）：RPC ↔ 聊天视图状态 ↔ 壳层。
//
// 分工：
//   - 事件归约在 `chat/events.ts`（纯函数，vitest 覆盖流式语义与归一）；
//   - 渲染在 `chat/render.ts`（纯函数，修空气泡/去重）；
//   - 布局/滚动在 `components/MessageList.tsx`（puppeteer 覆盖）；
//   - 主区判定在 `layout/model.ts`（vitest）；
//   - 这里只做"接线"：连 WS、拉会话/分页、把事件塞进归约、把状态交给组件。
//
// change `group-chat-layout`：会话列表的宿主上提到 `ChatShell`（常驻左列），主区
// 按选中会话的 `kind` 切换；群加载带代次守卫，激活会话按统一清单重置旧状态。
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
import { ChatShell } from './components/ChatShell';
import { SessionList } from './components/SessionList';
import { UserAvatarBlock } from './components/UserAvatarBlock';
import type { AvatarData } from './components/Avatar';
import { GroupView } from './group/GroupView';
import { loadingMemberSnapshot, splitGroupMessages, type MemberSnapshotState } from './group/model';
import { workspaceMode } from './layout/model';
import { ProvidersPage } from './components/ProvidersPage';
import { TemplatesPage } from './components/TemplatesPage';
import { Wizard } from './components/Wizard';
import { parseAgentSwitchError, type AgentSwitchFailure } from './manage/logic';
import { resolveAvatar } from './avatars/resolve';
import {
  RpcClient,
  type AgentEvent,
  type ConfigGetResult,
  type ConnectionStatus,
  type Profile,
  type Session,
  type GroupListResult,
  type GroupChainResult,
  type GroupSummary,
  type GroupViewResult,
  type Message,
  type SessionResult,
  type SessionSwitchResult,
  type SnapshotEventData,
  type TemplateListResult,
  type TemplateSummary,
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

/**
 * 群聊主区占位（change `group-chat-layout` D2）：摘要或首屏消息未齐时显示。
 *
 * `message.query` 失败时占位保留、错误可归因；不得用空时间线冒充加载完成。
 */
function GroupLoading({ error }: { error: string | null }) {
  return (
    <div className="flex h-full min-h-0 flex-col bg-bg text-fg">
      {error && (
        <div
          data-testid="group-loading-error"
          className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
        >
          {error}
        </div>
      )}
      <div
        data-testid="group-loading"
        className="flex min-h-0 flex-1 items-center justify-center px-4 py-3 text-sm text-muted"
      >
        正在加载群聊…
      </div>
    </div>
  );
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
  // 用户资料与模板摘要（change `chat-bubbles-avatars`）：头像路径从这两处来。
  const [profile, setProfile] = useState<Profile | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [templateSummaries, setTemplateSummaries] = useState<TemplateSummary[]>([]);
  const [panel, setPanel] = useState<'providers' | 'templates' | null>(null);
  const [configMissing, setConfigMissing] = useState(false);
  // 群视图状态（change `agent-group-chat`）：组成员、**原始消息列表**（分页的单一来源）、
  // 成员快照。时间线与成员视图由 `splitGroupMessages` 从同一份列表派生 —— 上翻补页时
  // 两处同步补、按 author/visibility 归位、不丢不重。
  const [groupSummary, setGroupSummary] = useState<GroupSummary | null>(null);
  const [groupMessages, setGroupMessages] = useState<Message[]>([]);
  const [groupEarlierCursor, setGroupEarlierCursor] = useState<number | null>(null);
  const [groupLoadingEarlier, setGroupLoadingEarlier] = useState(false);
  const [groupSnapshots, setGroupSnapshots] = useState<Record<string, MemberSnapshotState>>({});
  // 首屏消息是否已就绪：与 `groupSummary` 一起提交，占位以它为准（D2）。
  const [groupFirstPageReady, setGroupFirstPageReady] = useState(false);
  const [groupToolNames, setGroupToolNames] = useState<string[]>([]);
  const [groupEfforts, setGroupEfforts] = useState<string[]>([]);
  // 正在流式的成员 id（change `group-reactive-mode` D10）：`agent.streaming` 事件按
  // `memberId` 记，驱动成员卡片的「正在反应…」与取消按钮的可用性。断线重连后它清空，
  // 但 `group.list` 的 `busy` / `runningMemberId` 仍能恢复「链在跑」的判断。
  const [groupStreamingMembers, setGroupStreamingMembers] = useState<string[]>([]);
  // 当前 / 最近一条链（change `group-reactive-mode` R.4）：`group.chain` 重拉 + 事件驱动。
  // 它让「发送态」在 `started` 后立即解除，同时仍能显示「链在跑」并启用取消。
  const [groupChain, setGroupChain] = useState<GroupChainResult | null>(null);
  // `group.chain.completed` 事件计数：只在事件到达时给一次性提示（刷新不显示）。
  const [groupChainCompletedTick, setGroupChainCompletedTick] = useState(0);
  const currentSessionIdRef = useRef<string | null>(null);
  // 群加载请求代次（D2）：每次 `loadGroup` 自增，过期响应在每个 await 后丢弃。
  const loadGenerationRef = useRef(0);
  const requestedAttachments = useRef<Set<string>>(new Set());

  currentSessionIdRef.current = currentSessionId;

  /** 配置文件是否存在：不存在 ⇒ 打开首启向导（design D2 / D11）。 */
  const checkConfig = useCallback(async () => {
    try {
      const result = await client.request<ConfigGetResult>('config.get');
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
        const result = await client.request<ConfigGetResult>('config.get');
        const raw = result.agentTypes[agentType]?.input_modalities;
        const modalities = Array.isArray(raw)
          ? raw.filter((value): value is string => typeof value === 'string')
          : [];
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
      const result = await client.request<TemplateListResult>('template.list');
      setTemplates(result.templates.map((template) => template.name));
      // 模板摘要留着建"模板 → 上传头像路径"映射（design D2：头像数据来源不改 RPC）。
      setTemplateSummaries(result.templates);
    } catch (templateError: unknown) {
      setTemplates([]);
      setTemplateSummaries([]);
      setNotice(`模板列表不可用：${errorText(templateError)}`);
    }
  }, [client]);

  /**
   * 用户资料（`config.get` 的 `profile`）。
   *
   * 失败**必须可见**（侧栏用户头像块显示「头像资料读取失败：…」并可重试，D8），
   * 但不得挡住聊天屏 / 群视图 —— 这里只记错误文本，不抛给上层。
   */
  const loadProfile = useCallback(async () => {
    try {
      const result = await client.request<ConfigGetResult>('config.get');
      setProfile(result.profile ?? null);
      setProfileError(null);
    } catch (profileLoadError: unknown) {
      setProfile(null);
      setProfileError(errorText(profileLoadError));
    }
  }, [client]);

  /** 首屏锚定最新一页（design D10：anchor=tail，不是最旧页）。 */
  const loadLatestPage = useCallback(
    async (sessionId: string) => {
      try {
        const page = await loadInitialPage(
          (method, params) => client.request(method, params),
          sessionId,
          HISTORY_PAGE_SIZE,
        );
        // 切会话竞态：晚到的旧页不得挂到新会话下（change `group-chat-layout` D2）。
        if (currentSessionIdRef.current !== sessionId) return;
        setView({ ...emptyChatView, messages: page.messages });
        setEarlierCursor(page.earlierCursor);
        setLoadingEarlier(false);
      } catch (loadError: unknown) {
        // R.1：加载失败必须有可归因出口（不能变成 unhandled rejection 或静默空白）。
        // catch 里同样核对当前会话：旧会话的失败不得挂到新会话。
        if (currentSessionIdRef.current !== sessionId) return;
        setError(`加载会话失败：${errorText(loadError)}`);
      }
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
      if (currentSessionIdRef.current !== sessionId) return;
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

  const groupSplit = useMemo(
    () => splitGroupMessages(groupMessages, groupSummary?.members ?? []),
    [groupMessages, groupSummary],
  );

  /**
   * 拉一个组的全部视图数据（成员 / 尾锚一页原始消息 / 每成员快照 / 链状态）。
   *
   * change `group-chat-layout` D2：请求代次 + `currentSessionIdRef` 双重守卫，
   * 每个 await 之后核对，过期结果直接丢弃；`group.list` 与首屏 `message.query`
   * 成功后一次性提交摘要/消息/游标 + 全部成员的 `loading` 快照，随后逐成员提交。
   */
  const loadGroup = useCallback(
    async (
      sessionId: string,
      options: { preserveLoadedContent?: boolean } = {},
    ): Promise<boolean> => {
      // R.2：入口先判归属，再自增代次。旧群 `onReload` 的续体（以及
      // `refreshAfterReconnect` 用旧 sessionId 发起的加载）在切走后进入这里时
      // 必须直接返回 —— 否则它会把新群在途加载的代次顶掉，新群永久占位。
      if (currentSessionIdRef.current !== sessionId) return false;
      const preserveLoadedContent = options.preserveLoadedContent === true;
      const generation = ++loadGenerationRef.current;
      const isCurrent = () =>
        generation === loadGenerationRef.current &&
        currentSessionIdRef.current === sessionId;
      try {
        // 成功拉到组数据前先清掉上一次的错误横幅（组模式下它是唯一错误出口）。
        setError(null);
        const list = await client.request<GroupListResult>('group.list');
        if (!isCurrent()) return false;
        const summary = list.groups.find((entry) => entry.id === sessionId) ?? null;
        const page = await loadInitialPage(
          (method, params) => client.request(method, params),
          sessionId,
          HISTORY_PAGE_SIZE,
        );
        if (!isCurrent()) return false;
        // 分段提交（D2）：摘要只在首屏消息成功后提交，占位以 firstPageReady 为准。
        setGroupSummary(summary);
        setGroupMessages(page.messages as Message[]);
        setGroupEarlierCursor(page.earlierCursor);
        const snapshots: Record<string, MemberSnapshotState> = {};
        for (const member of summary?.members ?? []) {
          snapshots[member.id] = loadingMemberSnapshot();
        }
        setGroupSnapshots(snapshots);
        setGroupFirstPageReady(true);
        // 逐成员快照：成功/失败各自守卫提交该成员的状态，不阻断首屏。
        for (const member of summary?.members ?? []) {
          try {
            const memberView = await client.request<GroupViewResult>('group.view', {
              groupId: sessionId,
              memberId: member.id,
            });
            if (!isCurrent()) return false;
            setGroupSnapshots((previous) => ({
              ...previous,
              [member.id]: memberView.snapshot
                ? { status: 'ok', snapshot: memberView.snapshot, error: null }
                : { status: 'empty', snapshot: null, error: null },
            }));
          } catch (viewError: unknown) {
            if (!isCurrent()) return false;
            setGroupSnapshots((previous) => ({
              ...previous,
              [member.id]: {
                status: 'error',
                snapshot: null,
                error: errorText(viewError),
              },
            }));
          }
        }
        // 链状态（R.4 / D10）：重连后本地 `sending` 已丢，靠 `group.chain` 恢复
        // 「链在跑」与取消按钮；核心重启后它是 `idle`（既定语义）。
        try {
          const chain = await client.request<GroupChainResult>('group.chain', {
            groupId: sessionId,
          });
          if (!isCurrent()) return false;
          setGroupChain(chain);
        } catch {
          if (!isCurrent()) return false;
          setGroupChain(null);
        }
        return true;
      } catch (groupError: unknown) {
        if (!isCurrent()) return false;
        setError(`加载组视图失败：${errorText(groupError)}`);
        // R.4 / R.8：重载失败（以及首屏失败）都清链与流式状态，防止旧链让取消按钮
        // 误启用、成员卡片显示假的「正在反应…」。
        setGroupChain(null);
        setGroupStreamingMembers([]);
        if (!preserveLoadedContent) {
          // 首屏首次失败：清空并保留 GroupLoading 占位（不得用空时间线冒充完成）。
          setGroupSummary(null);
          setGroupMessages([]);
          setGroupEarlierCursor(null);
          setGroupSnapshots({});
          setGroupFirstPageReady(false);
        }
        // 重载失败：时间线 / 成员 / 游标 / 快照原样保留，只显示错误。
        return false;
      }
    },
    [client],
  );

  /** 只重拉一个成员的快照（成员视图的「重试」，不重载整条时间线）。 */
  const reloadMemberSnapshot = useCallback(
    async (memberId: string) => {
      const sessionId = currentSessionIdRef.current;
      if (!sessionId) return;
      const generation = loadGenerationRef.current;
      const isCurrent = () =>
        generation === loadGenerationRef.current &&
        currentSessionIdRef.current === sessionId;
      setGroupSnapshots((previous) => ({
        ...previous,
        [memberId]: loadingMemberSnapshot(),
      }));
      try {
        const memberView = await client.request<GroupViewResult>('group.view', {
          groupId: sessionId,
          memberId,
        });
        if (!isCurrent()) return;
        setGroupSnapshots((previous) => ({
          ...previous,
          [memberId]: memberView.snapshot
            ? { status: 'ok', snapshot: memberView.snapshot, error: null }
            : { status: 'empty', snapshot: null, error: null },
        }));
      } catch (viewError: unknown) {
        if (!isCurrent()) return;
        setGroupSnapshots((previous) => ({
          ...previous,
          [memberId]: {
            status: 'error',
            snapshot: null,
            error: errorText(viewError),
          },
        }));
      }
    },
    [client],
  );

  /** 组视图上翻：复用聊天屏同一套 `before`/`prevCursor` 分页，补更早一页。 */
  const loadGroupEarlier = useCallback(async () => {
    const sessionId = currentSessionIdRef.current;
    if (!sessionId || groupEarlierCursor === null || groupLoadingEarlier) return;
    setGroupLoadingEarlier(true);
    try {
      const page = await loadEarlierPage(
        (method, params) => client.request(method, params),
        sessionId,
        HISTORY_PAGE_SIZE,
        groupEarlierCursor,
      );
      if (currentSessionIdRef.current !== sessionId) return;
      setGroupMessages(
        (previous) => prependOlder(previous, page.messages) as Message[],
      );
      setGroupEarlierCursor(page.earlierCursor);
    } catch (loadError: unknown) {
      setError(`加载更早消息失败：${errorText(loadError)}`);
    } finally {
      setGroupLoadingEarlier(false);
    }
  }, [client, groupEarlierCursor, groupLoadingEarlier]);

  /**
   * 激活一个会话（D2 的统一重置清单；选中 / 首屏自动选中 / 删除后下一条都用它）。
   *
   * 清空上一条会话的聊天视图、快照、计量、技能失败、提示、群流式与群链状态；
   * **不重置** `groupChainCompletedTick`（它必须单调，否则一次性提示会卡住）。
   * 按传入 `session` 的 `kind` 分支加载，禁止按上一条的类型猜。
   */
  const activateSession = useCallback(
    async (session: Session | null) => {
      // 先同步写 ref，再写 state：守卫读的是 ref，不能读到旧 id。
      currentSessionIdRef.current = session?.id ?? null;
      setCurrentSessionId(session?.id ?? null);
      loadGenerationRef.current += 1; // 让在途的单聊/群聊加载全部过期
      // 聊天侧
      setView(emptyChatView);
      setEarlierCursor(null);
      setLoadingEarlier(false);
      setSnapshot(null);
      setSkillFailures([]);
      setMetering(null);
      setError(null);
      setNotice(null);
      // 群侧
      setGroupStreamingMembers([]);
      setGroupChain(null);
      setGroupSummary(null);
      setGroupMessages([]);
      setGroupEarlierCursor(null);
      setGroupLoadingEarlier(false);
      setGroupSnapshots({});
      setGroupFirstPageReady(false);
      if (!session) return;
      try {
        if (session.kind === 'group') {
          await loadGroup(session.id);
        } else {
          await loadLatestPage(session.id);
        }
      } catch (activateError: unknown) {
        // R.1：激活函数**不向调用方抛错**（`void createSession/deleteSession/selectSession`
        // 不能产生 unhandled rejection）。加载函数自己已 catch 并 setError，这里是兜底。
        if (currentSessionIdRef.current === session.id) {
          setError(`加载会话失败：${errorText(activateError)}`);
        }
      }
    },
    [loadGroup, loadLatestPage],
  );

  const loadSessions = useCallback(async () => {
    const result = await client.request<{ sessions: Session[] }>('session.list');
    setSessions(result.sessions);
    if (result.sessions.length === 0) {
      await activateSession(null);
      setNotice('还没有会话：点左侧的 + 新建一个。');
      return;
    }
    setNotice(null);
    await activateSession(result.sessions[0]);
  }, [client, activateSession]);

  /** 模板 / 工具目录 / 思考档位（覆盖层编辑器用）。 */
  const loadGroupOptions = useCallback(async () => {
    try {
      const result = await client.request<{
        tools: string[];
        thinkingEfforts: string[];
      }>('template.list');
      setGroupToolNames(result.tools ?? []);
      setGroupEfforts(result.thinkingEfforts ?? []);
    } catch {
      setGroupToolNames([]);
      setGroupEfforts([]);
    }
  }, [client]);

  const onEvent = useCallback((event: AgentEvent) => {
    if (event.sessionId !== currentSessionIdRef.current) return;
    const data = event.data ?? {};
    // 标题事件同时更新列表与当前群摘要（change `group-chat-layout` D2）：群的
    // 第一条用户消息自动命名也走这条，群主区标题不许停在旧值。
    if (event.type === 'session.title') {
      const title = String(data.title ?? '');
      setSessions((previous) =>
        previous.map((session) =>
          session.id === event.sessionId ? { ...session, title } : session,
        ),
      );
      setGroupSummary((previous) =>
        previous && previous.id === event.sessionId ? { ...previous, title } : previous,
      );
      return;
    }
    // 组事件按 payload（groupId/memberId）归位：消息类事件到达时重拉组数据，
    // 不依赖 DOM 选中的标签（design D11 的 payload 判据）。
    if (event.groupId && event.groupId === currentSessionIdRef.current) {
      if (event.type === 'agent.streaming') {
        // 流式指示按 `memberId` 归位（change `group-reactive-mode` D10）：
        // 它不是"消息事件"，不需要重拉数据，但决定"谁正在反应"。
        const memberId = event.memberId;
        if (memberId) {
          const streaming = (event.data ?? {}).streaming === true;
          setGroupStreamingMembers((previous) => {
            const next = new Set(previous);
            if (streaming) next.add(memberId);
            else next.delete(memberId);
            return [...next];
          });
        }
        return;
      }
      if (event.type === 'group.chain.completed') {
        // 链进入终态：重拉组数据 + `group.chain`（steps 在后者里），并让组视图给
        // 一次性提示（`round_cap` / `forced_pass`）。refresh 之后再 bump tick，
        // 保证提示读到的 `chain` 是本次终态（change `group-reactive-mode` R.4）。
        const groupId = event.groupId;
        void (async () => {
          const loaded = await loadGroup(groupId, { preserveLoadedContent: true });
          // R.8：只有「这次重拉成功」且「用户还停在这个群」才 bump 提示游标；
          // 过期/失败的重载不得让别的群或重挂后的视图误触发一次性提示。
          if (loaded && currentSessionIdRef.current === groupId) {
            setGroupChainCompletedTick((tick) => tick + 1);
          }
        })();
        return;
      }
      if (
        event.type === 'user.message' ||
        event.type === 'assistant.message' ||
        event.type === 'turn.completed'
      ) {
        void loadGroup(event.groupId, { preserveLoadedContent: true });
      }
      return;
    }
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
      // 组会话：重拉组数据恢复 `busy` / `runningMemberId`（本地 `sending` 与
      // `streamingMembers` 在断线时都丢了，取消按钮靠核心的只读状态恢复可用）。
      const current = sessionsResult.sessions.find((session) => session.id === sessionId);
      if (current?.kind === 'group') {
        setGroupStreamingMembers([]);
        await loadGroup(sessionId, { preserveLoadedContent: true });
        return;
      }
      const page = await loadInitialPage(
        (method, params) => client.request(method, params),
        sessionId,
        HISTORY_PAGE_SIZE,
      );
      if (currentSessionIdRef.current !== sessionId) return;
      setView((previous) => ({
        ...previous,
        messages: restoreMessages(previous.messages, page.messages),
      }));
    } catch (refreshError: unknown) {
      setError(errorText(refreshError));
    }
  }, [client, loadGroup]);

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
        // 模板与用户资料先于会话加载：头像映射要在群/单聊首帧之前就绪，否则第一帧会
        // 画身份图案再"闪"成上传图（change `chat-bubbles-avatars` D2）。
        await loadTemplates();
        await loadProfile();
        await loadSessions();
        await loadGroupOptions();
        await checkConfig();
      })
      .catch((connectError: unknown) => setError(errorText(connectError)));
    return () => {
      offStatus();
      offEvent();
      offReconnected();
      client.close();
    };
  }, [client, loadSessions, loadTemplates, loadProfile, checkConfig, onEvent, refreshAfterReconnect]);

  const selectSession = async (sessionId: string) => {
    const selected = sessions.find((session) => session.id === sessionId) ?? null;
    if (!selected) return;
    setPanel(null);
    await activateSession(selected);
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
  // 会话管理（change `web-management-ui` 任务 1.3 / design D7；
  // change `group-chat-layout` D2/D8：按 kind 删除、删除后按 kind 激活）
  // ---------------------------------------------------------------------------

  const reloadSessions = useCallback(async (): Promise<Session[]> => {
    const result = await client.request<{ sessions: Session[] }>('session.list');
    setSessions(result.sessions);
    return result.sessions;
  }, [client]);

  const createSession = async () => {
    setError(null);
    setSwitchFailure(null);
    setPanel(null);
    let created: SessionResult;
    try {
      // 操作 try **只包操作 RPC**（R.1）：加载失败/列表刷新失败不得被误报成「新建失败」。
      created = await client.request<SessionResult>('session.create', {});
    } catch (createError: unknown) {
      setError(`新建会话失败：${errorText(createError)}`);
      return;
    }
    // 列表刷新单独报错（R.1）：session.list 挂了不影响激活新会话。
    let listError: string | null = null;
    try {
      await reloadSessions();
    } catch (refreshError: unknown) {
      listError = `列表刷新失败：${errorText(refreshError)}`;
    }
    await activateSession(created.session);
    if (listError !== null) setError(listError);
  };

  /** 新建组（会话列表的「＋ 组」入口）。 */
  const createGroup = async () => {
    setError(null);
    setSwitchFailure(null);
    setPanel(null);
    let created: { group: Session };
    try {
      created = await client.request<{ group: Session }>('group.create', {});
    } catch (createError: unknown) {
      setError(`新建组失败：${errorText(createError)}`);
      return;
    }
    let listError: string | null = null;
    try {
      await reloadSessions();
    } catch (refreshError: unknown) {
      listError = `列表刷新失败：${errorText(refreshError)}`;
    }
    await activateSession(created.group);
    if (listError !== null) setError(listError);
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
      // 当前群的主区标题同步（D2）：否则行已改名、主区还是旧标题。
      setGroupSummary((previous) =>
        previous && previous.id === sessionId
          ? { ...previous, title: result.session.title }
          : previous,
      );
    } catch (renameError: unknown) {
      setError(`重命名失败：${errorText(renameError)}`);
    }
  };

  /** 删除会话：群行走 `group.delete`，单聊行走 `session.delete`（D2 / D8）。 */
  const deleteSession = async (session: Session) => {
    setError(null);
    setSwitchFailure(null);
    try {
      // 操作 try **只包操作 RPC**（R.1）：删除成功后的加载失败不得误报成「删除失败」。
      if (session.kind === 'group') {
        await client.request('group.delete', { groupId: session.id });
      } else {
        await client.request('session.delete', { sessionId: session.id });
      }
    } catch (deleteError: unknown) {
      setError(`删除会话失败：${errorText(deleteError)}`);
      return;
    }
    // R.10：删除**成功**分支关管理面板（失败分支已 return，保留面板与错误）。
    setPanel(null);
    let remaining: Session[] | null = null;
    let listError: string | null = null;
    try {
      remaining = await reloadSessions();
    } catch (refreshError: unknown) {
      listError = `列表刷新失败：${errorText(refreshError)}`;
    }
    if (currentSessionIdRef.current === session.id) {
      // 删除后按**下一条会话**的 kind 激活；列表刷新失败时退到本地已知顺序。
      const pool = remaining ?? sessions.filter((entry) => entry.id !== session.id);
      await activateSession(pool.length > 0 ? pool[0] : null);
    }
    if (listError !== null) setError(listError);
  };

  const switchTemplate = async (templateName: string) => {
    const sessionId = currentSessionIdRef.current;
    if (!sessionId) return;
    // 群聊模板由各成员决定：界面已禁用，这里再兜一层，绝不对群发切换（D8）。
    const current = sessions.find((session) => session.id === sessionId);
    if (current?.kind === 'group') return;
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

  const currentSession = sessions.find((session) => session.id === currentSessionId) ?? null;
  const currentAgentType = currentSession?.agentType ?? null;
  const mode = workspaceMode(currentSession);

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

  // ---------------------------------------------------------------------------
  // 头像（change `chat-bubbles-avatars` design D2）
  //
  // 只读来源：模板头像 = `template.list` 的 `avatar_path`，用户头像 = `config.get` 的
  // `profile.avatar_path`。字节统一走与聊天图片同一份**去重缓存**（`attachmentDataUrls`
  // + `requestedAttachments`），组件层只收 dataUrl（MUST NOT 给 `<img>` 绝对路径）。
  // ---------------------------------------------------------------------------

  /** 模板名 → 上传头像路径。 */
  const templateAvatarPaths = useMemo(() => {
    const map: Record<string, string> = {};
    for (const template of templateSummaries) {
      if (typeof template.avatar_path === 'string' && template.avatar_path.length > 0) {
        map[template.name] = template.avatar_path;
      }
    }
    return map;
  }, [templateSummaries]);

  /** 当前需要字节的头像路径（用户 + 所有模板 + 群成员所属模板）；失败缓存 null。 */
  const avatarPaths = useMemo(() => {
    const paths = new Set<string>();
    const add = (path: string | null | undefined) => {
      if (typeof path === 'string' && path.length > 0) paths.add(path);
    };
    add(profile?.avatarPath);
    for (const path of Object.values(templateAvatarPaths)) add(path);
    for (const member of groupSummary?.members ?? []) add(templateAvatarPaths[member.template]);
    return [...paths];
  }, [profile, templateAvatarPaths, groupSummary]);

  useEffect(() => {
    if (avatarPaths.length > 0) void resolveAttachments(avatarPaths);
  }, [avatarPaths, resolveAttachments]);

  /** 一张头像的渲染数据：上传图取到字节才用，否则身份图案（种子原样）。 */
  const avatarFor = useCallback(
    (entityId: string, uploadedPath: string | null | undefined): AvatarData => {
      const resolved = resolveAvatar({ entityId, uploadedPath });
      const dataUrl =
        resolved.uploadedPath !== null
          ? attachmentDataUrls[resolved.uploadedPath] ?? null
          : null;
      if (resolved.source === 'upload' && dataUrl !== null) {
        return { dataUrl, source: 'upload', seed: resolved.seed };
      }
      return { dataUrl: null, source: 'identicon', seed: resolved.seed };
    },
    [attachmentDataUrls],
  );

  const userAvatar = avatarFor(profile?.identitySeed ?? '', profile?.avatarPath);
  const agentAvatar = avatarFor(
    currentSessionId ?? '',
    currentAgentType !== null ? templateAvatarPaths[currentAgentType] : null,
  );

  if (configMissing) {
    return (
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
    );
  }

  return (
    <ChatShell
      sidebar={
        <SessionList
          sessions={sessions}
          currentSessionId={currentSessionId}
          onSelect={(sessionId) => void selectSession(sessionId)}
          onCreate={() => void createSession()}
          onCreateGroup={() => void createGroup()}
          onRename={(sessionId, title) => void renameSession(sessionId, title)}
          onDelete={(session) => void deleteSession(session)}
          templates={templates}
          currentAgentType={currentAgentType}
          onSwitchTemplate={(templateName) => void switchTemplate(templateName)}
          switchFailure={switchFailure}
          disabled={status !== 'open'}
        />
      }
      sidebarFooter={
        <UserAvatarBlock
          client={client}
          profile={profile}
          avatar={userAvatar}
          error={profileError}
          onUpdated={(next) => {
            // 成功后就地更新（不整页刷新）；新路径的字节交给共用缓存去取。
            setProfile(next);
            setProfileError(null);
            if (next.avatarPath !== null) void resolveAttachments([next.avatarPath]);
          }}
          onRetry={() => void loadProfile()}
        />
      }
      overlay={
        panel === 'providers' ? (
          <ProvidersPage
            client={client}
            onClose={() => setPanel(null)}
            onChanged={() => {
              void loadTemplates();
              void loadImagesSupported(currentAgentType);
            }}
          />
        ) : panel === 'templates' ? (
          <TemplatesPage
            client={client}
            onClose={() => setPanel(null)}
            avatarDataUrls={attachmentDataUrls}
            onResolveAvatar={(paths) => void resolveAttachments(paths)}
            onChanged={() => {
              void loadTemplates();
              void loadImagesSupported(currentAgentType);
            }}
          />
        ) : null
      }
    >
      {mode === 'group' ? (
        groupSummary !== null && groupFirstPageReady ? (
          <GroupView
            // 换群重置由 `groupFirstPageReady` 门保证：`activateSession` 会先把它置假，
            // 主区经 GroupLoading 卸载再重挂（R.8：`key` 是冗余的，且不是重放修复手段）。
            client={client}
            group={groupSummary}
            members={groupSummary.members}
            timeline={groupSplit.timeline}
            lanes={groupSplit.lanes}
            hasEarlier={groupEarlierCursor !== null}
            loadingEarlier={groupLoadingEarlier}
            onLoadEarlier={() => void loadGroupEarlier()}
            snapshots={groupSnapshots}
            templates={templates}
            thinkingEfforts={groupEfforts}
            toolNames={groupToolNames}
            streamingMembers={groupStreamingMembers}
            chain={groupChain}
            chainCompletedTick={groupChainCompletedTick}
            error={error}
            onReload={() => loadGroup(groupSummary.id, { preserveLoadedContent: true })}
            onReloadMemberSnapshot={(memberId) => void reloadMemberSnapshot(memberId)}
            onError={(message) => setError(message)}
            userAvatar={userAvatar}
            memberAvatars={Object.fromEntries(
              (groupSummary.members ?? []).map((member) => [
                member.id,
                avatarFor(member.id, templateAvatarPaths[member.template]),
              ]),
            )}
          />
        ) : (
          <GroupLoading error={error} />
        )
      ) : (
        <ChatScreen
          status={status}
          sessionTitle={currentSession?.title ?? null}
          sessionSelected={mode === 'chat'}
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
          userAvatar={userAvatar}
          agentAvatar={agentAvatar}
          onOpenProviders={() => setPanel('providers')}
          onOpenTemplates={() => setPanel('templates')}
        />
      )}
    </ChatShell>
  );
}
