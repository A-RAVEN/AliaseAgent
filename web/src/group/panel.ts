// 群聊双标签与成员选择的状态机（change `group-chat-layout` 任务 0.2 / design D4）。
//
// 纯逻辑：标签切换只改本地状态（不重拉 RPC、不重建 GroupView），成员选择在
// 软删（`removedAt !== null`）时**保持**，只有成员 id 从表里消失才回退。
import type { GroupMemberSummary } from '../protocol';

export type GroupTab = 'chat' | 'members';

export interface GroupPanelState {
  tab: GroupTab;
  memberId: string | null;
}

/** 成分的最小形状：只需要 id 与软删标记。 */
export type SelectableMember = Pick<GroupMemberSummary, 'id' | 'removedAt'>;

export function initialGroupPanelState(): GroupPanelState {
  return { tab: 'chat', memberId: null };
}

/**
 * 解析当前应选中的成员 id（design D4 的四条规则）：
 *
 * 1. `selectedId` 仍在成员表里（**含软删成员**）⇒ 保持它；
 * 2. 否则取第一个未移除成员；
 * 3. 没有未移除成员 ⇒ 取第一个成员（已移除成员的历史私有行仍可查）；
 * 4. 没有成员 ⇒ `null`。
 */
export function resolveSelectedMemberId(
  members: readonly SelectableMember[],
  selectedId: string | null,
): string | null {
  if (selectedId !== null && members.some((member) => member.id === selectedId)) {
    return selectedId;
  }
  const active = members.find((member) => member.removedAt === null);
  if (active) return active.id;
  return members.length > 0 ? members[0].id : null;
}

/**
 * 切标签：切到「成员视图」时把 `null` 解析成默认成员；切回「群聊」保留已选成员
 * （否则再切回来会丢掉用户刚选中的人）。
 */
export function switchGroupTab(
  state: GroupPanelState,
  tab: GroupTab,
  members: readonly SelectableMember[],
): GroupPanelState {
  if (tab === 'members') {
    return { tab, memberId: resolveSelectedMemberId(members, state.memberId) };
  }
  return { ...state, tab };
}

/** 选中一个成员（id 已不在表里时回退到默认成员，防御脏值）。 */
export function selectGroupMember(
  state: GroupPanelState,
  memberId: string | null,
  members: readonly SelectableMember[],
): GroupPanelState {
  return { ...state, memberId: resolveSelectedMemberId(members, memberId) };
}
