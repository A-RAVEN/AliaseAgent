// 应用壳层的主区判定与会话类型文案（change `group-chat-layout` 任务 0.1 / design D2）。
//
// 纯逻辑：`workspaceMode` 决定主区渲染哪一块（群聊 / 单聊 / 空聊天屏），
// `sessionKindLabel` / `sessionKindBadge` 是会话列表与详情的**唯一**类型文案来源，
// 避免列表与详情各写一套字符串。
import { describe, expect, it } from 'vitest';

import { sessionKindBadge, sessionKindLabel, workspaceMode } from './model';

function obs(label: string, value: unknown): void {
  console.log(`[layout] ${label}: ${JSON.stringify(value)}`);
}

describe('workspaceMode：按选中会话的类型切主区', () => {
  it('没有选中会话 ⇒ empty（空聊天屏，不是群聊/单聊）', () => {
    obs('workspaceMode(null)', workspaceMode(null));
    obs('workspaceMode(undefined)', workspaceMode(undefined));
    expect(workspaceMode(null)).toBe('empty');
    expect(workspaceMode(undefined)).toBe('empty');
  });

  it('kind=single ⇒ chat', () => {
    obs('workspaceMode(single)', workspaceMode({ kind: 'single' }));
    expect(workspaceMode({ kind: 'single' })).toBe('chat');
  });

  it('kind=group ⇒ group', () => {
    obs('workspaceMode(group)', workspaceMode({ kind: 'group' }));
    expect(workspaceMode({ kind: 'group' })).toBe('group');
  });

  it('运行时脏值（未知 kind）按单聊处理，不制造第三种空页面', () => {
    const dirty = { kind: 'weird' } as unknown as { kind: 'single' | 'group' };
    obs('workspaceMode(脏值)', workspaceMode(dirty));
    expect(workspaceMode(dirty)).toBe('chat');
  });
});

describe('会话类型文案：列表与详情共用一套', () => {
  it('sessionKindLabel 给完整类型名', () => {
    obs('group label', sessionKindLabel({ kind: 'group' }));
    obs('single label', sessionKindLabel({ kind: 'single' }));
    expect(sessionKindLabel({ kind: 'group' })).toBe('群聊');
    expect(sessionKindLabel({ kind: 'single' })).toBe('单聊');
  });

  it('sessionKindBadge 只给群聊行返回可见标记', () => {
    obs('group badge', sessionKindBadge({ kind: 'group' }));
    obs('single badge', sessionKindBadge({ kind: 'single' }));
    expect(sessionKindBadge({ kind: 'group' })).toBe('群');
    expect(sessionKindBadge({ kind: 'single' })).toBeNull();
  });
});
