// 群聊双标签与成员选择的状态机（change `group-chat-layout` 任务 0.2 / design D4）。
//
// 规则（design D4）：
//   1. 已选成员只要**仍在成员表**里（含 `removedAt !== null` 的软删成员）就保持选中；
//   2. 成员 id 从表里消失才回退到第一个未移除成员；
//   3. 没有未移除成员 ⇒ 取第一个成员（已移除成员的历史私有行仍可查）；
//   4. 没有成员 ⇒ `null`；
//   5. 切回「群聊」标签不丢已选成员（标签切换不重建 GroupView）。
import { describe, expect, it } from 'vitest';

import type { GroupMemberSummary } from '../protocol';
import {
  initialGroupPanelState,
  resolveSelectedMemberId,
  selectGroupMember,
  switchGroupTab,
} from './panel';

function obs(label: string, value: unknown): void {
  console.log(`[group.panel] ${label}: ${JSON.stringify(value)}`);
}

function member(
  id: string,
  name: string,
  removedAt: number | null = null,
): GroupMemberSummary {
  return {
    id,
    name,
    template: 'general',
    removedAt,
    overrides: null,
    effective: null,
  };
}

const members: GroupMemberSummary[] = [
  member('a', '甲'),
  member('b', '乙', 1000),
  member('c', '丙'),
];

describe('初始状态', () => {
  it('初始是「群聊」标签且没有选中成员', () => {
    const state = initialGroupPanelState();
    obs('初始状态', state);
    expect(state).toEqual({ tab: 'chat', memberId: null });
  });
});

describe('resolveSelectedMemberId：成员选择的保持与回退', () => {
  it('没有已选成员 ⇒ 第一个未移除成员', () => {
    obs('null → ', resolveSelectedMemberId(members, null));
    expect(resolveSelectedMemberId(members, null)).toBe('a');
  });

  it('已选成员是软删成员（removedAt 非空）但仍在表里 ⇒ 保持选中，不自动跳走', () => {
    obs('b（已移除）→ ', resolveSelectedMemberId(members, 'b'));
    expect(resolveSelectedMemberId(members, 'b')).toBe('b');
  });

  it('已选成员 id 从成员表消失 ⇒ 回退到第一个未移除成员', () => {
    obs('gone → ', resolveSelectedMemberId(members, 'gone'));
    expect(resolveSelectedMemberId(members, 'gone')).toBe('a');
  });

  it('只剩已移除成员 ⇒ 选第一个（历史私有行仍可查）', () => {
    const onlyRemoved = [member('b', '乙', 1000), member('d', '丁', 2000)];
    obs('只剩已移除 → ', resolveSelectedMemberId(onlyRemoved, null));
    expect(resolveSelectedMemberId(onlyRemoved, null)).toBe('b');
  });

  it('没有成员 ⇒ null', () => {
    obs('空成员表 → ', resolveSelectedMemberId([], null));
    expect(resolveSelectedMemberId([], null)).toBeNull();
  });

  it('首成员已软删、第二成员活动 ⇒ 默认选第二成员（[软删, 活动] 夹具，R.12）', () => {
    const softDeletedFirst = [member('a', '甲', 1000), member('b', '乙')];
    obs('[软删, 活动] 且 selectedId=null → ', resolveSelectedMemberId(softDeletedFirst, null));
    expect(resolveSelectedMemberId(softDeletedFirst, null)).toBe('b');
  });

  it('已选软删首成员 ⇒ 保持它（不因为它是第一个就跳走）', () => {
    const softDeletedFirst = [member('a', '甲', 1000), member('b', '乙')];
    obs('[软删, 活动] 且已选 a → ', resolveSelectedMemberId(softDeletedFirst, 'a'));
    expect(resolveSelectedMemberId(softDeletedFirst, 'a')).toBe('a');
  });
});

describe('标签切换与选择动作', () => {
  it('进入「成员视图」自动选第一个未移除成员', () => {
    const state = switchGroupTab(initialGroupPanelState(), 'members', members);
    obs('切到成员视图', state);
    expect(state).toEqual({ tab: 'members', memberId: 'a' });
  });

  it('切回「群聊」不丢已选成员', () => {
    const onMembers = switchGroupTab(initialGroupPanelState(), 'members', members);
    const selected = selectGroupMember(onMembers, 'c', members);
    const back = switchGroupTab(selected, 'chat', members);
    obs('切回群聊', back);
    expect(back).toEqual({ tab: 'chat', memberId: 'c' });
    const again = switchGroupTab(back, 'members', members);
    expect(again.memberId).toBe('c');
  });

  it('选中软删成员后保持（切换标签也保持）', () => {
    const onMembers = switchGroupTab(initialGroupPanelState(), 'members', members);
    const selected = selectGroupMember(onMembers, 'b', members);
    obs('选中软删成员', selected);
    expect(selected.memberId).toBe('b');
    expect(switchGroupTab(selected, 'chat', members).memberId).toBe('b');
  });

  it('选中一个已从成员表消失的 id ⇒ 回退到默认成员（防御脏值）', () => {
    const onMembers = switchGroupTab(initialGroupPanelState(), 'members', members);
    const selected = selectGroupMember(onMembers, 'ghost', members);
    obs('选中未知 id', selected);
    expect(selected.memberId).toBe('a');
  });
});
