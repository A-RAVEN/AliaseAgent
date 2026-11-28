// 群视图（change `agent-group-chat` 任务 8.3~8.7；change `group-chat-layout` 2.1~2.5 布局重构）。
//
// 真实应用里的组屏幕：**两行头部 + `[群聊 | 成员视图]` 双标签**。
//   - 群聊标签：公开时间线 + 发送区（中）+ 成员名单（右；< xl 时是抽屉）；
//   - 成员视图：成员选择器 + 该成员私有过程行 + 真实上下文 + 占用环（分母是该成员自己的窗口）。
// 底部「成员私有分栏」已删除（design D3/D4/D5）。
//
// 组件是**纯展示 + 动作**：数据由 App 注入（它在真实 WS 上拉 group.list /
// message.query / group.view），动作直接走 `group.*` RPC 再让 App 重拉。
import { useEffect, useRef, useState } from 'react';
import { Settings } from 'lucide-react';

import type {
  CoreClient,
  GroupChainResult,
  GroupMemberSummary,
  GroupSendResult,
  GroupSummary,
  InstanceOverrides,
} from '../protocol';
import type { GroupLane, GroupTimelineItem, MemberSnapshotState } from './model';
import {
  chainIsRunning,
  kDefaultMaxReactionRounds,
  kMaxMaxReactionRounds,
  kMinMaxReactionRounds,
  parseMaxRoundsInput,
  ringDenominator,
  validateSpeaker,
} from './model';
import { memberPanelControls, memberRunState } from './cards';
import {
  initialGroupPanelState,
  selectGroupMember,
  switchGroupTab,
  resolveSelectedMemberId,
  type GroupPanelState,
} from './panel';
import type { AvatarData } from '../components/Avatar';
import { Avatar } from '../components/Avatar';
import { ContextRing, MemberRing } from '../components/ContextRing';
import { FolderPickerDialog } from '../components/FolderPickerDialog';
import { MessageBubble } from '../components/MessageBubble';
import { RealContextView } from '../components/RealContextView';
import { avatarSizes } from '../tokens';
import { workspaceLabel } from '../workspace/model';
import {
  pickerStartPath,
  workspaceDirsParams,
  type WorkspaceDirsResult,
} from '../workspace/picker';

/** 没传成员头像时的兜底：身份图案（种子 = 成员 id，不阻断渲染）。 */
function fallbackAvatar(seed: string): AvatarData {
  return { dataUrl: null, source: 'identicon', seed };
}

export interface GroupViewProps {
  client: CoreClient;
  group: GroupSummary;
  members: GroupMemberSummary[];
  timeline: GroupTimelineItem[];
  lanes: GroupLane[];
  snapshots: Record<string, MemberSnapshotState>;
  templates: string[];
  thinkingEfforts: string[];
  toolNames: string[];
  /**
   * 正在流式的成员 id（App 从 `agent.streaming` 事件按 `memberId` 累出来的，
   * change `group-reactive-mode` D10）。链断线重连后它是空的，但 `group.busy` /
   * `chain.status` 仍在 ⇒ 取消按钮照样可用。
   */
  streamingMembers: string[];
  /** 当前 / 最近一条链的只读状态（`group.chain`；断线重连后由 App 重拉）。 */
  chain: GroupChainResult | null;
  /**
   * `group.chain.completed` 事件计数。界面只在**事件**到达时提示一次
   * `round_cap` / `forced_pass`（刷新后不再显示，因为历史里没有这些提示）。
   */
  chainCompletedTick: number;
  /** 还有更早的消息（= 上一页的 prevCursor 非空）。 */
  hasEarlier: boolean;
  loadingEarlier: boolean;
  /** 当前错误横幅文本（App 的 `error`）；组模式下没有 ChatScreen 承载它。 */
  error?: string | null;
  onLoadEarlier: () => void;
  /** 重拉组数据（`loadGroup` 的返回值 = 成功/失败，供 R.8 的 tick bump 判断）。 */
  onReload: () => Promise<boolean> | void;
  /** 只重拉一个成员的快照（成员视图的「重试」，不重载整条时间线）。 */
  onReloadMemberSnapshot: (memberId: string) => void;
  onError: (message: string) => void;
  /** 成员头像（App 层按「成员 id + 所属模板的 avatar_path」+ 字节缓存算出，D2）。 */
  memberAvatars?: Record<string, AvatarData>;
  /** 用户头像（`profile.avatar_path`，没有则身份图案）。 */
  userAvatar?: AvatarData;
}

export function GroupView({
  client,
  group,
  members,
  timeline,
  lanes,
  snapshots,
  templates,
  thinkingEfforts,
  toolNames,
  streamingMembers,
  chain,
  chainCompletedTick,
  hasEarlier,
  loadingEarlier,
  error,
  onLoadEarlier,
  onReload,
  onReloadMemberSnapshot,
  onError,
  memberAvatars = {},
  userAvatar = fallbackAvatar(''),
}: GroupViewProps) {
  const [newName, setNewName] = useState('');
  const [newTemplate, setNewTemplate] = useState(templates[0] ?? 'general');
  const [speaker, setSpeaker] = useState<string>('');
  const [draft, setDraft] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [subset, setSubset] = useState<Record<string, string[]>>({});
  const [append, setAppend] = useState<Record<string, string>>({});
  const [effort, setEffort] = useState<Record<string, string>>({});
  // 齿轮面板里的模板草稿（D5：改模板后保存必须把 templateName 发给核心）。
  const [templateDraft, setTemplateDraft] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  // `group.send` 的**同步阶段**状态（design D10）：收到 `started` 即解除，不等链结束。
  const [sending, setSending] = useState(false);
  // `forced_pass` / `forced_empty` 的可归因提示：只在**本次链结束事件**后存在，
  // 刷新后不再显示（没有对应公开行，design D7）。也不走 turn.failed。
  const [forcedNotice, setForcedNotice] = useState<string | null>(null);
  // 达每组轮数上限的提示（`stopReason = round_cap`；design D10 / D13）。
  const [roundCapNotice, setRoundCapNotice] = useState<string | null>(null);
  // R.15：链 `failed` 的真因（`group.chain.error`）。独立于加载/视图错误横幅，一过性：
  // 下次发送即清（不做常驻告警，也不复用 group-view-error / group-loading-error）。
  const [chainError, setChainError] = useState<string | null>(null);
  const [togglingReactions, setTogglingReactions] = useState(false);
  // 「反应轮数上限」输入框的草稿：`''` = 留空（保存时发 `maxRounds: null`）。
  const [roundCapDraft, setRoundCapDraft] = useState(
    group.maxRounds === null ? '' : String(group.maxRounds),
  );
  const [savingRoundCap, setSavingRoundCap] = useState(false);
  // 群工作路径栏（change `custom-workspace` D9；返工 12.6 改成文件夹选择对话框）：
  // 「切换」弹框点选目录，不再就地手输。未设置工作区时栏里显示「缺省（应用主目录）」
  // —— 文案常量 `kDefaultWorkspaceLabel` 在 `web/src/workspace/model.ts`（与单聊
  // 标题旁共用同一份，不在组件里另写一份）。
  const [workspacePickerOpen, setWorkspacePickerOpen] = useState(false);
  // R.8：一次性提示游标的**挂载基线**是挂载时的 tick，不是 0。否则换群重挂后
  // 旧的 `chainCompletedTick`（全局单调）会立刻越过 0，把上一次链的提示重放一遍。
  const lastCompletedTick = useRef(chainCompletedTick);
  // 双标签与成员选择（change `group-chat-layout` D3/D4）：切换只改本地状态。
  const [panelState, setPanelState] = useState<GroupPanelState>(initialGroupPanelState);
  // 窄屏（< xl）成员名单抽屉的开关（D5）。
  const [membersOpen, setMembersOpen] = useState(false);
  const membersPanelRef = useRef<HTMLElement | null>(null);
  const membersToggleRef = useRef<HTMLButtonElement | null>(null);
  // 成员视图激活时链终态提示的未读点（D3）。
  const [chatUnread, setChatUnread] = useState(false);
  const tabRef = useRef(panelState.tab);
  tabRef.current = panelState.tab;
  // 时间线滚动位置的存档：未激活面板用 display:none 隐藏（design D3），而浏览器
  // 在盒子被销毁时会把 scrollTop 归零 —— 切回群聊时按存档恢复（见下方 effect）。
  const timelineRef = useRef<HTMLElement | null>(null);
  const timelineScrollRef = useRef(0);
  // R.9：成员视图与成员名单的滚动存档（时间线之外的两个滚动容器）。
  const memberViewRef = useRef<HTMLDivElement | null>(null);
  const memberViewScrollRef = useRef(0);
  const membersScrollRef = useRef(0);

  const activeMembers = members.filter((member) => member.removedAt === null);
  const chainRunning = chainIsRunning({
    busy: group.busy,
    chainStatus: chain?.status ?? null,
    streamingMembers: streamingMembers.length,
    sending,
  });
  const cancelEnabled = chainRunning;

  // 群工作路径栏（change `custom-workspace` D9 / 返工 12.6）：点「切换」弹文件夹选择框
  // （`workspace.listDirs` 列子目录，起点 = 组的设置值；未设置 ⇒ 省略 path，核心用主
  // 目录）。确认走 `group.setWorkspace`，成功后重拉组数据；失败把可归因文本交回框内
  // （框不关、已保存路径不变）。
  const listWorkspaceDirs = async (path: string | null): Promise<WorkspaceDirsResult> =>
    client.request<WorkspaceDirsResult>('workspace.listDirs', workspaceDirsParams(path));

  const applyWorkspace = async (path: string): Promise<string | null> => {
    try {
      await client.request('group.setWorkspace', {
        groupId: group.id,
        workspace: path,
      });
    } catch (error) {
      return `保存工作路径失败：${error instanceof Error ? error.message : String(error)}`;
    }
    // 写成功才重拉；重拉失败走组级错误横幅（不再把已成功的写说成失败）。
    try {
      await onReload();
    } catch (reloadError) {
      onError(
        `工作路径已切换，但重拉组数据失败：${
          reloadError instanceof Error ? reloadError.message : String(reloadError)
        }`,
      );
    }
    return null;
  };

  // 上限值随重拉更新（`group.update` 成功后 App 会重拉 group.list）。
  useEffect(() => {
    setRoundCapDraft(group.maxRounds === null ? '' : String(group.maxRounds));
  }, [group.maxRounds]);

  // 成员 id 从成员表消失时回退到默认成员（软删成员仍在表里 ⇒ 保持选中，D4）。
  useEffect(() => {
    setPanelState((previous) => {
      if (previous.memberId === null) return previous;
      const resolved = resolveSelectedMemberId(members, previous.memberId);
      if (resolved === previous.memberId) return previous;
      return { ...previous, memberId: resolved };
    });
  }, [members]);

  // 链结束事件到达：按终态/步骤给一次性提示（刷新后不再显示）。
  useEffect(() => {
    if (chainCompletedTick <= lastCompletedTick.current) return;
    lastCompletedTick.current = chainCompletedTick;
    const steps = chain?.steps ?? [];
    const rejected = steps.filter(
      (step) => step.status === 'forced_pass' || step.status === 'forced_empty',
    );
    const nextForcedNotice =
      rejected.length > 0
        ? '被点名的成员没有回应（返回 pass=true / 空 message）'
        : null;
    const nextRoundCapNotice =
      chain?.stopReason === 'round_cap'
        ? '已达轮数上限（反应已停止；可继续点名，或调大该组的反应轮数上限）'
        : null;
    setForcedNotice(nextForcedNotice);
    setRoundCapNotice(nextRoundCapNotice);
    // 提示产生时用户正在成员视图：群聊标签置未读点，避免提示在隐藏面板里静默丢失。
    if (tabRef.current === 'members' && (nextForcedNotice !== null || nextRoundCapNotice !== null)) {
      setChatUnread(true);
    }
  }, [chainCompletedTick, chain]);

  // R.15：链失败真因跟随当前 `group.chain` —— 只有 failed 且有 error 时显示；
  // completed / cancelled / running / idle 一律清掉（旧错不许残留）。
  useEffect(() => {
    if (chain?.status === 'failed' && chain.error) {
      setChainError(chain.error);
      return;
    }
    setChainError(null);
  }, [chain]);

  const toggleReactions = async (next: boolean) => {
    setTogglingReactions(true);
    try {
      await client.request('group.update', {
        groupId: group.id,
        reactionsEnabled: next,
      });
      await onReload();
    } catch (error) {
      onError(`切换自发反应失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setTogglingReactions(false);
    }
  };

  // 保存上限：留空 ⇒ `maxRounds: null`（恢复默认）；1..50 ⇒ 整数。越界不静默改正。
  const saveRoundCap = async () => {
    if (savingRoundCap) return;
    const parsed = parseMaxRoundsInput(roundCapDraft);
    if ('error' in parsed) {
      onError(parsed.error);
      return;
    }
    setSavingRoundCap(true);
    try {
      await client.request('group.update', {
        groupId: group.id,
        maxRounds: parsed.value,
      });
      await onReload();
    } catch (error) {
      onError(
        `保存反应轮数上限失败：${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      setSavingRoundCap(false);
    }
  };

  const cancelChain = async () => {
    try {
      await client.request('agent.cancel', { sessionId: group.id });
      await onReload();
    } catch (error) {
      onError(`取消失败：${error instanceof Error ? error.message : String(error)}`);
    }
  };

  const addMember = async () => {
    const name = newName.trim();
    if (!name) {
      onError('成员名不能为空');
      return;
    }
    setBusy(true);
    try {
      await client.request('group.member.add', {
        groupId: group.id,
        name,
        templateName: newTemplate,
      });
      setNewName('');
      await onReload();
    } catch (error) {
      onError(`加入成员失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const beginEdit = (member: GroupMemberSummary) => {
    setEditing(member.id);
    setSubset((previous) => ({
      ...previous,
      [member.id]: member.overrides?.toolsSubset ?? toolNames,
    }));
    setAppend((previous) => ({
      ...previous,
      [member.id]: member.overrides?.systemPromptAppend ?? '',
    }));
    setEffort((previous) => ({
      ...previous,
      [member.id]: member.overrides?.thinkingEffort ?? '',
    }));
    setTemplateDraft((previous) => ({
      ...previous,
      [member.id]: member.template,
    }));
  };

  const saveOverrides = async (member: GroupMemberSummary) => {
    // 已移除成员的面板是只读的：保存不发任何写请求（D5）。
    if (member.removedAt !== null) return;
    const overrides: InstanceOverrides = {
      toolsSubset: subset[member.id] ?? [],
      systemPromptAppend: append[member.id] ?? '',
    };
    const effortValue = effort[member.id] ?? '';
    if (effortValue !== '') overrides.thinkingEffort = effortValue;
    setBusy(true);
    try {
      await client.request('group.member.update', {
        groupId: group.id,
        memberId: member.id,
        // 面板里换模板也要真的提交（只改本地状态会让下拉成摆设，D5）。
        templateName: templateDraft[member.id] ?? member.template,
        overrides,
      });
      // **保存后不自动收起面板**：用户要能立刻看到新的生效工具与思考强度（既有 8.4 也依赖）。
      await onReload();
    } catch (error) {
      onError(`保存覆盖层失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const removeMember = async (member: GroupMemberSummary) => {
    // 已移除成员的面板只读：移除按钮标 aria-disabled 且点击不发请求（D5）。
    if (member.removedAt !== null) return;
    setBusy(true);
    try {
      await client.request('group.member.remove', {
        groupId: group.id,
        memberId: member.id,
      });
      await onReload();
    } catch (error) {
      onError(`移除成员失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const send = async () => {
    // 本地校验按开关分流（design D10）：开启态发言人可选（空 + 有文本 = 纯触发）；
    // 关闭态含 `@` 允许空发言人（有效性由核心裁决，前端不复制 mention 解析规则）。
    const error = validateSpeaker({
      speaker: speaker.length > 0 ? speaker : null,
      text: draft,
      viewMessages: [],
      reactionsEnabled: group.reactionsEnabled,
    });
    // 选了发言人且不带文本时的两个退化前置门由核心裁决（本地没有该成员视图，
    // 不能凭空调 viewMessages 之外的判断）；这里只拦截"必填项缺失"。
    if (error && (error.code === 'no_speaker' || error.code === 'no_trigger')) {
      onError(error.message);
      return;
    }
    setSending(true);
    setForcedNotice(null);
    setRoundCapNotice(null);
    // R.15：失败真因是一过性的，下次发送即清（若这次链也失败，会拿到新的 error）。
    setChainError(null);
    try {
      const params: Record<string, unknown> = {
        groupId: group.id,
        text: draft,
      };
      if (speaker.length > 0) params.speaker = speaker;
      await client.request<GroupSendResult>('group.send', params);
      // R.8：`group.send` **永不返回 busy**（链运行中也照常接受，新消息由执行器
      // 吸收/排队）；这里不再有「发送未开始」分支。
      // **`started` 即解除发送态**（design D10 / R.4）：链在后台跑，发送态不等链结束。
      // 链活动/取消由 `chain.status` + `group.busy` + 流式成员 + 事件驱动。
      setDraft('');
      await onReload();
    } catch (sendError) {
      onError(`发送失败：${sendError instanceof Error ? sendError.message : String(sendError)}`);
    } finally {
      setSending(false);
    }
  };

  /** 关抽屉并把焦点还给触发按钮（背景 / 关闭按钮 / Escape 三条路径共用）。 */
  const closeMembersDrawer = () => {
    // R.9：关抽屉前存成员名单的滚动位置（再打开时恢复）。
    membersScrollRef.current = membersPanelRef.current?.scrollTop ?? 0;
    setMembersOpen(false);
    membersToggleRef.current?.focus();
  };

  // R.5：断点监听 —— Tailwind v4 的 xl 是 80rem；跨到 xl 时收起抽屉（否则打开态
  // 会留下关不掉的 absolute 浮层）。监听器必须在卸载时移除（换群重挂 / StrictMode）。
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return undefined;
    const query = window.matchMedia('(min-width: 80rem)');
    const onChange = () => {
      // 只在跨到 xl 时收抽屉；缩回窄屏时保持关闭（不自行重开）。
      if (query.matches) setMembersOpen(false);
    };
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);

  // R.5：抽屉打开时的对话框语义：焦点进入抽屉、Escape 关闭并回到触发按钮。
  useEffect(() => {
    if (!membersOpen) return undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      closeMembersDrawer();
    };
    document.addEventListener('keydown', onKeyDown);
    membersPanelRef.current?.focus();
    return () => document.removeEventListener('keydown', onKeyDown);
    // `closeMembersDrawer` 每帧重建，但它只读写 ref / setter；跟随 membersOpen 订阅即可。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [membersOpen]);

  const tab = panelState.tab;
  const selectedMemberId = panelState.memberId;
  const selectedMember =
    members.find((member) => member.id === selectedMemberId) ?? null;
  const selectedLane =
    selectedMemberId === null
      ? null
      : lanes.find((lane) => lane.memberId === selectedMemberId) ?? null;
  const memberIds = new Set(members.map((member) => member.id));
  const unknownLanes = lanes.filter((lane) => !memberIds.has(lane.memberId));
  const snapshotState =
    selectedMemberId === null ? undefined : snapshots[selectedMemberId];

  // 头部反应指示：追加正在流式的成员名；成员间隙用 `runningMemberId` 回退。
  // 这样 < xl 抽屉关着也能看到「谁在反应」（design D3）。
  const streamingNames = streamingMembers
    .map((memberId) => members.find((member) => member.id === memberId)?.name ?? memberId)
    .filter((name) => name.length > 0);
  const fallbackName =
    streamingNames.length === 0 && group.runningMemberId !== null
      ? members.find((member) => member.id === group.runningMemberId)?.name ?? null
      : null;
  const reactingNames =
    streamingNames.length > 0 ? streamingNames : fallbackName !== null ? [fallbackName] : [];
  const reactionText =
    reactingNames.length > 0
      ? `反应链进行中…（正在反应：${reactingNames.join('、')}）`
      : '反应链进行中…（可取消）';

  const switchTab = (nextTab: 'chat' | 'members') => {
    if (panelState.tab === 'chat' && nextTab === 'members') {
      timelineScrollRef.current = timelineRef.current?.scrollTop ?? 0;
      // 离开群聊标签会隐藏成员名单（< xl 抽屉 / xl 静态列都在面板内）：先存一份。
      membersScrollRef.current = membersPanelRef.current?.scrollTop ?? 0;
    }
    if (panelState.tab === 'members' && nextTab === 'chat') {
      memberViewScrollRef.current = memberViewRef.current?.scrollTop ?? 0;
    }
    setPanelState((previous) => switchGroupTab(previous, nextTab, members));
    // R.3：切标签一律收起窄屏抽屉 —— 否则切回群聊时它自行重开，且背景/按钮状态说谎。
    setMembersOpen(false);
    if (nextTab === 'chat') setChatUnread(false);
  };

  // 切回群聊后恢复时间线滚动位置（display:none 期间 scrollTop 会被重置）。
  useEffect(() => {
    if (tab !== 'chat') return;
    if (timelineRef.current && timelineRef.current.scrollTop !== timelineScrollRef.current) {
      timelineRef.current.scrollTop = timelineScrollRef.current;
    }
  }, [tab]);

  // R.9：成员视图 / 成员名单的滚动恢复必须在容器**可见后**写回（同一 tick 写入会被
  // display:none 忽略或清掉）。
  useEffect(() => {
    if (tab !== 'members') return;
    const view = memberViewRef.current;
    if (view !== null && view.scrollTop !== memberViewScrollRef.current) {
      view.scrollTop = memberViewScrollRef.current;
    }
  }, [tab]);

  useEffect(() => {
    if (tab !== 'chat') return;
    const panel = membersPanelRef.current;
    if (panel !== null && panel.scrollTop !== membersScrollRef.current) {
      panel.scrollTop = membersScrollRef.current;
    }
  }, [tab]);

  useEffect(() => {
    if (!membersOpen) return;
    const panel = membersPanelRef.current;
    if (panel !== null) panel.scrollTop = membersScrollRef.current;
  }, [membersOpen]);

  return (
    <div
      className="relative flex h-full min-h-0 flex-col bg-bg text-fg"
      data-testid="group-view"
      data-active-tab={tab}
    >
      <header className="relative z-30 border-b border-line px-4 py-3">
        {/* 第一行：身份与全局动作（窄屏可换行，不为宽屏再写一套） */}
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0">
            <h1 className="truncate text-xl font-semibold">组视图 · {group.title}</h1>
            <p className="text-xs text-muted">
              成员共享一份原文；每个成员只看得到自己的私有过程。
            </p>
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            {chainRunning && (
              <span className="text-xs text-accent" data-testid="reaction-active">
                {reactionText}
              </span>
            )}
            <button
              type="button"
              data-testid="group-cancel"
              disabled={!cancelEnabled}
              onClick={() => void cancelChain()}
              className="min-h-6 rounded-card border border-danger/40 px-2 py-1 text-xs text-danger/80 hover:text-danger disabled:opacity-40"
            >
              取消反应链
            </button>
            <span className="text-xs text-muted" data-testid="group-kind">
              kind={group.kind}
            </span>
            {/* R.7：「成员」按钮只在群聊标签渲染/可用（成员视图里抽屉没有意义，
                `aria-expanded` 也只会说谎）。 */}
            {tab === 'chat' && (
              <button
                type="button"
                ref={membersToggleRef}
                data-testid="group-members-toggle"
                aria-expanded={membersOpen}
                aria-controls="group-members"
                onClick={() => setMembersOpen((previous) => !previous)}
                className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg xl:hidden"
              >
                成员
              </button>
            )}
          </div>
        </div>
        {/* 第二行：标签 + 组设置 */}
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <div role="tablist" aria-label="群聊视图" className="flex items-center gap-1">
            <button
              type="button"
              role="tab"
              id="group-tab-chat"
              aria-controls="group-chat-panel"
              aria-selected={tab === 'chat'}
              data-testid="group-tab-chat"
              data-unread={chatUnread ? 'true' : undefined}
              onClick={() => switchTab('chat')}
              className={
                tab === 'chat'
                  ? 'flex min-h-6 items-center gap-1 rounded-card border border-accent bg-surface-2 px-2 py-1 text-xs text-fg'
                  : 'flex min-h-6 items-center gap-1 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg'
              }
            >
              群聊
              {chatUnread && (
                <span
                  data-testid="group-tab-unread"
                  className="text-accent"
                  aria-label="有新提示"
                >
                  ●
                </span>
              )}
            </button>
            <button
              type="button"
              role="tab"
              id="group-tab-members"
              aria-controls="member-view"
              aria-selected={tab === 'members'}
              data-testid="group-tab-members"
              onClick={() => switchTab('members')}
              className={
                tab === 'members'
                  ? 'min-h-6 rounded-card border border-accent bg-surface-2 px-2 py-1 text-xs text-fg'
                  : 'min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg'
              }
            >
              成员视图
            </button>
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-3">
            {/* 自发反应开关（change `group-reactive-mode` D10）：链运行中禁用。 */}
            <label className="flex items-center gap-1 text-xs text-muted">
              <input
                type="checkbox"
                data-testid="reactions-toggle"
                checked={group.reactionsEnabled}
                disabled={chainRunning || togglingReactions}
                onChange={(event) => void toggleReactions(event.target.checked)}
              />
              自发反应（默认开）
            </label>
            {/* 反应轮数上限（change `group-reactive-mode` R.4 / D13）：null = 默认占位；
                留空保存 ⇒ maxRounds: null（恢复默认）；链运行中禁用。 */}
            <label className="flex items-center gap-1 text-xs text-muted">
              反应轮数上限
              <input
                type="number"
                min={kMinMaxReactionRounds}
                max={kMaxMaxReactionRounds}
                data-testid="group-round-cap"
                value={roundCapDraft}
                placeholder={`默认 ${kDefaultMaxReactionRounds}`}
                disabled={chainRunning || savingRoundCap}
                onChange={(event) => setRoundCapDraft(event.target.value)}
                onBlur={() => void saveRoundCap()}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') event.currentTarget.blur();
                }}
                className="h-7 w-16 rounded-card border border-line bg-surface px-1 text-xs"
              />
            </label>
          </div>
        </div>
      </header>

      {error !== null && error !== undefined && (
        <div
          data-testid="group-view-error"
          className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
        >
          {error}
        </div>
      )}

      {/* R.15：链失败真因（独立 testid，不复用加载/视图错误；一过性，下次发送清）。 */}
      {chainError !== null && (
        <div
          data-testid="group-chain-error"
          role="alert"
          className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
        >
          反应链失败：{chainError}
        </div>
      )}

      {/* 群聊标签：公开时间线 + 发送区（中） + 成员名单（右，< xl 抽屉）。
          这一层必须是 `relative`：抽屉背景的包含块在此（R.3），只覆盖时间线/发送区，
          不得以 group-view 根为包含块盖住头部标签。 */}
      <div
        id="group-chat-panel"
        role="tabpanel"
        aria-labelledby="group-tab-chat"
        data-testid="group-chat-panel"
        aria-hidden={tab !== 'chat' ? 'true' : undefined}
        className={tab === 'chat' ? 'relative flex min-h-0 flex-1' : 'relative hidden'}
      >
        {/* R.6：主地标由 `ChatShell` 提供，这里用 section（时间线列不写 main）。 */}
        <section className="flex min-w-0 flex-1 flex-col">
          <section
            ref={timelineRef}
            className="min-h-0 flex-1 overflow-y-auto px-4 py-3"
            data-testid="group-timeline"
          >
            <div className="mb-2 flex items-center justify-between gap-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted">
                公开时间线
              </h2>
              {hasEarlier && (
                <button
                  type="button"
                  data-testid="group-load-earlier"
                  disabled={loadingEarlier}
                  onClick={onLoadEarlier}
                  className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
                >
                  {loadingEarlier ? '正在加载更早的消息…' : '加载更早的消息'}
                </button>
              )}
            </div>
            {timeline.length === 0 && (
              <p className="text-sm text-muted" data-testid="timeline-empty">
                还没有公开消息：选一个发言人开始。
              </p>
            )}
            <ul className="space-y-2">
              {timeline.map((item, index) => {
                const author = item.author;
                const isUser = author === null;
                const avatar = isUser
                  ? userAvatar
                  : memberAvatars[author] ?? fallbackAvatar(author);
                return (
                  <li
                    key={`${item.seq ?? index}-${index}`}
                    data-testid="timeline-item"
                    data-seq={item.seq ?? ''}
                    data-bubble-side={isUser ? 'user' : 'member'}
                  >
                    <MessageBubble
                      side={isUser ? 'user' : 'member'}
                      avatar={avatar}
                      avatarSize={avatarSizes.bubble}
                      testId={isUser ? 'timeline-user-message' : 'timeline-member-message'}
                      name={isUser ? null : item.authorName}
                    >
                      <div className="whitespace-pre-wrap text-sm">{item.content}</div>
                    </MessageBubble>
                  </li>
                );
              })}
            </ul>
          </section>

          <div className="border-t border-line px-4 py-2">
            {forcedNotice !== null && (
              <p className="mb-1 text-xs text-warn" data-testid="forced-notice">
                {forcedNotice}
              </p>
            )}
            {roundCapNotice !== null && (
              <p className="mb-1 text-xs text-warn" data-testid="round-cap-notice">
                {roundCapNotice}
              </p>
            )}
            <div className="flex items-center gap-2">
              <label className="flex items-center gap-1 text-xs text-muted">
                发言人
                <select
                  data-testid="speaker-select"
                  value={speaker}
                  onChange={(event) => setSpeaker(event.target.value)}
                  className="h-7 rounded-card border border-line bg-surface px-1 text-xs"
                >
                  <option value="">
                    {group.reactionsEnabled ? '（不点名，仅触发反应）' : '（未选择）'}
                  </option>
                  {activeMembers.map((member) => (
                    <option key={member.id} value={member.id}>
                      {member.name}
                    </option>
                  ))}
                </select>
              </label>
              <textarea
                data-testid="group-input"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                placeholder={
                  group.reactionsEnabled
                    ? '说点什么：所有公开消息都会触发成员反应（可留空仅点名）'
                    : '给点名成员的一句话（可留空：不带文本的点名不写空用户行）'
                }
                className="h-10 min-w-0 flex-1 resize-none rounded-card border border-line bg-surface px-2 py-1 text-sm"
              />
              <button
                type="button"
                data-testid="group-send"
                disabled={sending}
                onClick={() => void send()}
                className="rounded-card bg-accent px-3 py-2 text-sm font-semibold text-bg disabled:opacity-40"
              >
                {sending ? '发送中…' : '发送'}
              </button>
            </div>
          </div>
        </section>

        {/* 成员名单（右置；< xl 时同一份 DOM 变成右侧抽屉） */}
        {membersOpen && (
          <div
            data-testid="group-members-backdrop"
            aria-hidden="true"
            onClick={closeMembersDrawer}
            className="absolute inset-0 z-10 bg-bg/60 xl:hidden"
          />
        )}
        <aside
          ref={membersPanelRef}
          id="group-members"
          data-testid="group-members"
          role={membersOpen ? 'dialog' : undefined}
          aria-modal={membersOpen ? 'true' : undefined}
          aria-label={membersOpen ? '成员名单' : undefined}
          tabIndex={membersOpen ? -1 : undefined}
          className={
            membersOpen
              ? 'absolute inset-y-0 right-0 z-20 flex w-72 flex-col overflow-y-auto border-l border-line bg-surface px-3 py-3 xl:static xl:flex'
              : 'hidden w-72 shrink-0 flex-col overflow-y-auto border-l border-line bg-surface px-3 py-3 xl:static xl:flex'
          }
        >
          <div
            data-testid="group-workspace"
            className="mb-2 rounded-card border border-line bg-bg/40 p-2"
          >
            <div className="flex items-center justify-between gap-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted">
                群工作路径
              </h2>
              <button
                type="button"
                data-testid="group-workspace-edit"
                disabled={chainRunning}
                aria-disabled={chainRunning ? 'true' : undefined}
                title={
                  chainRunning
                    ? '链运行中：不能切换工作路径（先取消，或等链结束）'
                    : '打开文件夹选择框'
                }
                onClick={() => setWorkspacePickerOpen(true)}
                className="min-h-6 shrink-0 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
              >
                切换
              </button>
            </div>
            <p
              className="mt-1 truncate text-xs text-muted"
              data-testid="group-workspace-path"
              title={workspaceLabel(group.workspace)}
            >
              {workspaceLabel(group.workspace)}
            </p>
          </div>
          <div className="mb-2 flex items-center justify-between gap-2">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-muted">成员</h2>
            <button
              type="button"
              data-testid="group-members-close"
              onClick={closeMembersDrawer}
              className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg xl:hidden"
            >
              关闭
            </button>
          </div>
          <ul className="space-y-2" data-testid="group-members-list">
            {members.map((member) => {
              const runState = memberRunState({
                memberId: member.id,
                streamingMembers,
                runningMemberId: group.runningMemberId,
              });
              const controls = memberPanelControls({ removed: member.removedAt !== null });
              const avatar = memberAvatars[member.id] ?? fallbackAvatar(member.id);
              return (
                <li
                  key={member.id}
                  aria-label={`成员卡片：${member.name}`}
                  className="rounded-card border border-line bg-bg/40 p-2"
                >
                  <div className="flex items-center gap-2">
                    <Avatar
                      {...avatar}
                      size={avatarSizes.member}
                      label={`${member.name}的头像`}
                      testId={`member-avatar-${member.id}`}
                    />
                    <div className="min-w-0 flex-1">
                      <div className="flex min-w-0 items-center gap-1">
                        <span
                          className="min-w-0 truncate text-sm"
                          data-testid={`member-name-${member.id}`}
                        >
                          {member.name}
                          {member.removedAt !== null && (
                            <span
                              className="ml-1 text-warn"
                              data-testid={`member-removed-${member.id}`}
                            >
                              （已移除）
                            </span>
                          )}
                        </span>
                        {/* 状态点：running 绿点带脉冲 / idle 灰点；运行中不只靠颜色表达。 */}
                        <span
                          data-testid={`member-status-${member.id}`}
                          data-state={runState}
                          title={runState === 'running' ? '运行中' : '空闲'}
                          aria-label={runState === 'running' ? '运行中' : '空闲'}
                          className={
                            runState === 'running'
                              ? 'status-dot-running inline-block h-2 w-2 shrink-0 rounded-full bg-ok animate-pulse'
                              : 'inline-block h-2 w-2 shrink-0 rounded-full bg-muted'
                          }
                        />
                        {runState === 'running' && (
                          <span className="sr-only" data-testid={`member-streaming-${member.id}`}>
                            正在反应…
                          </span>
                        )}
                      </div>
                    </div>
                    <MemberRing memberId={member.id} snapshot={snapshots[member.id]} />
                    <button
                      type="button"
                      data-testid={`member-edit-${member.id}`}
                      aria-expanded={editing === member.id}
                      aria-controls={`override-editor-${member.id}`}
                      onClick={() => (editing === member.id ? setEditing(null) : beginEdit(member))}
                      className="flex min-h-6 min-w-6 shrink-0 items-center justify-center rounded-card border border-line px-1 text-muted hover:text-fg"
                      title="成员设置"
                      aria-label={`${member.name}的成员设置`}
                    >
                      <Settings size={16} aria-hidden="true" />
                    </button>
                  </div>
                  {editing === member.id && (
                    <div
                      id={`override-editor-${member.id}`}
                      className="mt-2 space-y-1 text-xs"
                      data-testid={`override-editor-${member.id}`}
                    >
                      <label className="block">
                        模板
                        <select
                          data-testid={`member-template-${member.id}`}
                          value={templateDraft[member.id] ?? member.template}
                          disabled={busy || controls.controlsDisabled}
                          onChange={(event) =>
                            setTemplateDraft((previous) => ({
                              ...previous,
                              [member.id]: event.target.value,
                            }))
                          }
                          className="mt-1 h-7 w-full rounded-card border border-line bg-surface px-1 text-xs"
                        >
                          {templates.map((template) => (
                            <option key={template} value={template}>
                              {template}
                            </option>
                          ))}
                        </select>
                      </label>
                      <div className="font-semibold text-muted">工具子集（只能收紧）</div>
                      {toolNames.map((tool) => (
                        <label key={tool} className="flex items-center gap-1">
                          <input
                            type="checkbox"
                            data-testid={`tool-${member.id}-${tool}`}
                            checked={(subset[member.id] ?? []).includes(tool)}
                            disabled={busy || controls.controlsDisabled}
                            onChange={(event) => {
                              const next = new Set(subset[member.id] ?? []);
                              if (event.target.checked) next.add(tool);
                              else next.delete(tool);
                              setSubset((previous) => ({
                                ...previous,
                                [member.id]: [...next],
                              }));
                            }}
                          />
                          <span>{tool}</span>
                        </label>
                      ))}
                      <label className="block">
                        提示词追加
                        <input
                          type="text"
                          data-testid={`append-${member.id}`}
                          value={append[member.id] ?? ''}
                          disabled={busy || controls.controlsDisabled}
                          onChange={(event) =>
                            setAppend((previous) => ({
                              ...previous,
                              [member.id]: event.target.value,
                            }))
                          }
                          className="mt-1 h-7 w-full rounded-card border border-line bg-surface px-2 text-xs"
                        />
                      </label>
                      <label className="block">
                        思考强度
                        <select
                          data-testid={`effort-${member.id}`}
                          value={effort[member.id] ?? ''}
                          disabled={busy || controls.controlsDisabled}
                          onChange={(event) =>
                            setEffort((previous) => ({
                              ...previous,
                              [member.id]: event.target.value,
                            }))
                          }
                          className="mt-1 h-7 w-full rounded-card border border-line bg-surface px-1 text-xs"
                        >
                          <option value="">（无覆盖）</option>
                          <option value="">关闭思考（空串）</option>
                          {thinkingEfforts.map((value) => (
                            <option key={value} value={value}>
                              {value}
                            </option>
                          ))}
                        </select>
                      </label>
                      {/* 生效结果只在面板里（卡面不再摊开长列表）。已移除成员也保留它。 */}
                      <div className="font-semibold text-muted">生效结果</div>
                      <p className="text-muted" data-testid={`effective-${member.id}`}>
                        生效工具：
                        {(member.effective?.tools ?? []).join('、') || '（无）'} · 思考：
                        {member.effective?.thinkingMode ?? 'disabled'}
                        {member.effective?.thinkingEffort
                          ? `/${member.effective.thinkingEffort}`
                          : ''}
                      </p>
                      <div className="flex gap-2">
                        <button
                          type="button"
                          data-testid={`member-save-${member.id}`}
                          disabled={busy || controls.saveDisabled}
                          aria-disabled={controls.saveDisabled ? 'true' : undefined}
                          onClick={() => void saveOverrides(member)}
                          className="min-h-6 rounded-card border border-accent px-2 py-1 text-accent disabled:opacity-40"
                        >
                          保存（重建实例）
                        </button>
                        <button
                          type="button"
                          data-testid={`member-remove-${member.id}`}
                          disabled={busy || controls.removeDisabled}
                          aria-disabled={controls.removeDisabled ? 'true' : undefined}
                          onClick={() => void removeMember(member)}
                          className="min-h-6 rounded-card border border-danger/40 px-2 py-1 text-danger/80 hover:text-danger disabled:opacity-40"
                        >
                          移除
                        </button>
                      </div>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>

          <div className="mt-4 space-y-1 border-t border-line pt-3 text-xs">
            <h2 className="font-semibold uppercase tracking-wide text-muted">加入成员</h2>
            <input
              data-testid="member-name-input"
              value={newName}
              onChange={(event) => setNewName(event.target.value)}
              placeholder="显示名"
              className="h-7 w-full rounded-card border border-line bg-bg px-2"
            />
            <select
              data-testid="member-template-select"
              value={newTemplate}
              onChange={(event) => setNewTemplate(event.target.value)}
              className="h-7 w-full rounded-card border border-line bg-bg px-1"
            >
              {templates.map((template) => (
                <option key={template} value={template}>
                  {template}
                </option>
              ))}
            </select>
            <button
              type="button"
              data-testid="member-add"
              disabled={busy}
              onClick={() => void addMember()}
              className="w-full rounded-card border border-accent px-2 py-1 text-accent disabled:opacity-40"
            >
              加入
            </button>
          </div>
        </aside>
      </div>

      {/* 成员视图标签：选择器 + 私有过程 + 真实上下文 + 占用环（单列滚动）。 */}
      <div
        ref={memberViewRef}
        id="member-view"
        role="tabpanel"
        aria-labelledby="group-tab-members"
        data-testid="member-view"
        aria-hidden={tab !== 'members' ? 'true' : undefined}
        className={tab === 'members' ? 'min-h-0 flex-1 overflow-y-auto px-4 py-3' : 'hidden'}
      >
        <div role="group" aria-label="选择成员" className="flex flex-wrap gap-2">
          {members.length === 0 && (
            <p className="text-sm text-muted" data-testid="member-view-empty">
              群里还没有成员：先在「群聊」标签右侧的成员名单里加入成员。
            </p>
          )}
          {members.map((member) => (
            <button
              key={member.id}
              type="button"
              data-testid={`member-select-${member.id}`}
              aria-pressed={selectedMemberId === member.id}
              onClick={() =>
                setPanelState((previous) => selectGroupMember(previous, member.id, members))
              }
              className={
                selectedMemberId === member.id
                  ? 'flex min-h-6 items-center gap-1 rounded-card border border-accent bg-surface-2 px-2 py-1 text-xs text-fg'
                  : 'flex min-h-6 items-center gap-1 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg'
              }
            >
              {member.name}
              {member.removedAt !== null && (
                <span className="text-warn">（已移除）</span>
              )}
              {streamingMembers.includes(member.id) && (
                <span className="text-accent">正在反应…</span>
              )}
            </button>
          ))}
        </div>

        {unknownLanes.length > 0 && (
          <div
            data-testid="member-unknown-authors"
            className="mt-3 rounded-card border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn"
          >
            未知作者私有行（不在成员表里，只读）：
            {unknownLanes
              .map((lane) => `${lane.name}（${lane.messages.length} 行）`)
              .join('、')}
          </div>
        )}

        {selectedMember && (
          <>
            <section data-testid="member-context-section" className="mt-4">
              <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                真实上下文与占用
              </h2>
              {snapshotState === undefined || snapshotState.status === 'loading' ? (
                <p className="text-sm text-muted" data-testid="member-snapshot-loading">
                  正在加载该成员的上下文…
                </p>
              ) : snapshotState.status === 'error' ? (
                <div className="rounded-card border border-danger/40 bg-danger/10 px-3 py-2 text-xs text-danger">
                  <p data-testid="member-snapshot-error">读取失败：{snapshotState.error}</p>
                  <button
                    type="button"
                    data-testid="member-snapshot-retry"
                    onClick={() => onReloadMemberSnapshot(selectedMember.id)}
                    className="mt-2 min-h-6 rounded-card border border-danger/40 px-2 py-1 text-xs text-danger hover:text-fg"
                  >
                    重试
                  </button>
                </div>
              ) : snapshotState.status === 'empty' ? (
                <p className="text-sm text-muted" data-testid="member-no-snapshot">
                  本次运行内没发过言（重启后为空是既定语义）。
                </p>
              ) : (
                <div className="rounded-card border border-line bg-surface px-3 py-2">
                  <p className="text-xs text-muted" data-testid="member-window">
                    窗口 {ringDenominator(snapshotState.snapshot)} tokens
                  </p>
                  {snapshotState.snapshot.breakdown ? (
                    <div className="mt-2">
                      <ContextRing breakdown={snapshotState.snapshot.breakdown} />
                    </div>
                  ) : (
                    <p className="mt-2 text-xs text-warn" data-testid="member-no-breakdown">
                      没有占用拆分数据：不渲染环（不静默当成 0）。
                    </p>
                  )}
                  <RealContextView snapshot={snapshotState.snapshot} />
                </div>
              )}
            </section>

            <section data-testid="member-private-section" className="mt-4">
              <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                私有过程（仅该成员可见）
              </h2>
              <ul data-testid="member-private-rows" className="space-y-1">
                {(selectedLane?.messages ?? []).map((message, index) => (
                  <li
                    key={`${message.id}-${index}`}
                    data-testid="member-private-row"
                    data-seq={message.seq ?? ''}
                    // R.13：作者必须取 `message.author`（不能写 lane.memberId，否则恒真自证）。
                    data-author={message.author ?? ''}
                    className="rounded-card border border-line/60 bg-surface px-3 py-2 text-xs text-muted"
                  >
                    {message.content.trim().length > 0
                      ? message.content
                      : '（私有过程：思考 / 工具调用）'}
                  </li>
                ))}
              </ul>
              {(selectedLane?.messages.length ?? 0) === 0 && (
                <p className="text-sm text-muted" data-testid="member-private-empty">
                  本次已加载页里没有私有行
                </p>
              )}
              {hasEarlier && (
                <button
                  type="button"
                  data-testid="member-load-earlier"
                  disabled={loadingEarlier}
                  onClick={onLoadEarlier}
                  className="mt-2 min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
                >
                  {loadingEarlier ? '正在加载更早的消息…' : '加载更早的消息'}
                </button>
              )}
            </section>
          </>
        )}
      </div>

      {/* 文件夹选择对话框（返工 12.6）：模态、`z-50` 盖住本视图顶栏（z-30）与管理页
          覆盖层（z-40）；确认走 `group.setWorkspace`（传播到所有在册成员）。 */}
      {workspacePickerOpen && (
        <FolderPickerDialog
          title="选择群工作路径"
          initialPath={pickerStartPath(group.workspace)}
          listDirs={listWorkspaceDirs}
          onConfirm={applyWorkspace}
          onClose={() => setWorkspacePickerOpen(false)}
        />
      )}
    </div>
  );
}
