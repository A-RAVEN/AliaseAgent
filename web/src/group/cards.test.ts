// 成员卡片与紧凑环的纯逻辑（change `chat-bubbles-avatars` 任务 5.1 / design D5、D6）。
//
// 红靶：模块不存在（或行为写进组件 JSX、无法单测）时本文件红。
// 这里钉死四件事：
//   ① 成员工作状态的判定（含断线重连后的 `runningMemberId` 回退、成员间隙不猜）；
//   ② 快照四态 → 环状态（只有 ok 且有 breakdown 才画三瓣；ok 且三段全 0 仍画轨道）；
//   ③ 环几何的**比例**（120 与 32 两种尺寸的"外径 / 容器边长"差 ≤ 1px，P0-3 的红靶）；
//   ④ 齿轮面板的字段清单与"已移除成员只读"的控件态。
import { describe, expect, it } from 'vitest';

import { ringSegments } from '../chat/ring';
import type { SnapshotEventData } from '../protocol';
import type { MemberSnapshotState } from './model';
import {
  kMemberPanelFields,
  memberPanelControls,
  memberRingState,
  memberRunState,
  RING_BASE_SIZE,
  RING_PADDING,
  ringGeometry,
} from './cards';

function snapshotWith(breakdown: SnapshotEventData['breakdown']): SnapshotEventData {
  return {
    sessionId: 'g-1',
    model: 'm',
    thinkingMode: 'disabled',
    thinkingEffort: '',
    capturedAt: '2026-11-24T00:00:00.000Z',
    windowTokens: 1000000,
    agentType: 'general',
    breakdown,
    messages: [],
    skillFailures: [],
    skillFailureNotice: null,
  };
}

const zeroBreakdown = {
  level2Tokens: 0,
  level1Tokens: 0,
  rawTokens: 0,
  fixedOverheadTokens: 100,
  windowTokens: 1000000,
  usedTokens: 100,
  conversationTokens: 0,
};

const someBreakdown = {
  level2Tokens: 100,
  level1Tokens: 200,
  rawTokens: 300,
  fixedOverheadTokens: 100,
  windowTokens: 1000,
  usedTokens: 700,
  conversationTokens: 600,
};

const okState = (breakdown: SnapshotEventData['breakdown']): MemberSnapshotState => ({
  status: 'ok',
  snapshot: snapshotWith(breakdown),
  error: null,
});

describe('成员工作状态', () => {
  it('streamingMembers 含该成员 ⇒ running', () => {
    const state = memberRunState({
      memberId: 'm-a',
      streamingMembers: ['m-a'],
      runningMemberId: null,
    });
    console.log('[成员状态] streaming 命中', state);
    expect(state).toBe('running');
  });

  it('streamingMembers 为空且 runningMemberId === id ⇒ running（断线重连回退）', () => {
    const state = memberRunState({
      memberId: 'm-a',
      streamingMembers: [],
      runningMemberId: 'm-a',
    });
    console.log('[成员状态] runningMemberId 回退', state);
    expect(state).toBe('running');
  });

  it('两者都没有 ⇒ idle（成员间隙不猜；别的成员流式时自己是 idle）', () => {
    const none = memberRunState({
      memberId: 'm-a',
      streamingMembers: [],
      runningMemberId: null,
    });
    const other = memberRunState({
      memberId: 'm-b',
      streamingMembers: ['m-a'],
      runningMemberId: null,
    });
    console.log('[成员状态] 都没有', none, '别的成员在跑', other);
    expect(none).toBe('idle');
    expect(other).toBe('idle');
  });
});

describe('快照四态 → 紧凑环状态', () => {
  it('loading / empty / error 只给占位，不画环也不画三瓣', () => {
    const loading = memberRingState({
      status: 'loading',
      snapshot: null,
      error: null,
    });
    const empty = memberRingState({ status: 'empty', snapshot: null, error: null });
    const error = memberRingState({
      status: 'error',
      snapshot: null,
      error: 'boom',
    });
    const missing = memberRingState(undefined);
    console.log('[环状态] 占位三态', { loading, empty, error, missing });
    for (const state of [loading, empty, error, missing]) {
      expect(state.drawSlices).toBe(false);
      expect(state.drawTrack).toBe(false);
    }
    expect(loading.kind).toBe('loading');
    expect(empty.kind).toBe('empty');
    expect(error.kind).toBe('error');
    expect(missing.kind).toBe('loading');
  });

  it('ok 且 breakdown 非空 ⇒ 画三瓣 + 常驻轨道', () => {
    const ok = memberRingState(okState(someBreakdown));
    console.log('[环状态] ok', ok);
    expect(ok.kind).toBe('ok');
    expect(ok.drawSlices).toBe(true);
    expect(ok.drawTrack).toBe(true);
    expect(ringSegments(someBreakdown).map((segment) => segment.tokens)).toEqual([100, 200, 300]);
  });

  it('ok 且三段全为 0 ⇒ 不画三瓣但**仍画轨道**（不是空白盒）', () => {
    const zero = memberRingState(okState(zeroBreakdown));
    console.log('[环状态] 三段全 0', zero, '三瓣', ringSegments(zeroBreakdown));
    expect(zero.kind).toBe('ok');
    expect(zero.drawTrack).toBe(true);
    expect(ringSegments(zeroBreakdown).every((segment) => segment.sweepRadians === 0)).toBe(
      true,
    );
  });
});

describe('环几何：两种尺寸同一比例（P0-3 红靶）', () => {
  it('120 环外径 = 2×50；32 环的半径 / 描边按同一比例派生', () => {
    const big = ringGeometry(RING_BASE_SIZE);
    console.log('[环几何] 120', big);
    expect(big.padding).toBe(RING_PADDING);
    expect(big.strokeWidth).toBe(10);
    // 中心线半径 = 60 − 10 − 5 = 45；外缘 = 45 + 5 = 50（= 现状 120 环的半径）⇒ 外径 2×50。
    expect(big.radius).toBe(45);
    expect(big.radius + big.strokeWidth / 2).toBe(50);
    expect(big.outerDiameter).toBe(100);

    const compact = ringGeometry(32);
    console.log('[环几何] 32', compact);
    expect(compact.padding).toBeCloseTo((32 * RING_PADDING) / RING_BASE_SIZE, 10);
    expect(compact.strokeWidth).toBeCloseTo((32 * 10) / RING_BASE_SIZE, 10);
    expect(compact.radius).toBeCloseTo(12, 10);
    expect(compact.outerDiameter).toBeCloseTo(26.6666666667, 6);
  });

  it('"外径 / 容器边长"两种尺寸的差 ≤ 1px（不是两套硬编码几何）', () => {
    const big = ringGeometry(RING_BASE_SIZE);
    const compact = ringGeometry(32);
    const bigRatio = big.outerDiameter / RING_BASE_SIZE;
    const compactRatio = compact.outerDiameter / 32;
    // 把 32 环按同一容器边长放大到 120 后比较外径差（px）。
    const scaledDifference = Math.abs(big.outerDiameter - compact.outerDiameter * (RING_BASE_SIZE / 32));
    console.log('[环几何] 比例', { bigRatio, compactRatio, scaledDifference });
    expect(Math.abs(bigRatio - compactRatio)).toBeLessThan(0.001);
    expect(scaledDifference).toBeLessThanOrEqual(1);
  });
});

describe('齿轮面板：字段清单与已移除成员的只读态', () => {
  it('面板字段恰好是模板 / 工具子集 / 提示词追加 / 思考强度 / 生效结果 / 保存 / 移除七项', () => {
    console.log('[面板] 字段清单', kMemberPanelFields);
    expect([...kMemberPanelFields]).toEqual([
      'template',
      'toolsSubset',
      'systemPromptAppend',
      'thinkingEffort',
      'effective',
      'save',
      'remove',
    ]);
    expect(kMemberPanelFields).toHaveLength(7);
  });

  it('已移除成员：面板仍可开，保存与移除为禁用（不发写请求）', () => {
    const active = memberPanelControls({ removed: false });
    const removed = memberPanelControls({ removed: true });
    console.log('[面板] 控件态', { active, removed });
    expect(active.canOpen).toBe(true);
    expect(active.saveDisabled).toBe(false);
    expect(active.removeDisabled).toBe(false);
    expect(active.controlsDisabled).toBe(false);

    expect(removed.canOpen).toBe(true);
    expect(removed.controlsDisabled).toBe(true);
    expect(removed.saveDisabled).toBe(true);
    expect(removed.removeDisabled).toBe(true);
  });
});
