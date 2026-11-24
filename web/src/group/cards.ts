// 成员卡片与紧凑环的纯逻辑（change `chat-bubbles-avatars` 任务 5.2 / design D5、D6）。
//
// 所有判定与几何都在这里算，组件只消费 —— 写进 JSX 就无法单测（本 change 的红靶之一）。
import type { MemberSnapshotState } from './model';

// ---------------------------------------------------------------------------
// 工作状态（design D5 / D8）
// ---------------------------------------------------------------------------

export type MemberRunState = 'running' | 'idle';

/**
 * running = `streamingMembers` 含该成员，或（`streamingMembers` 为空且
 * `runningMemberId === id` —— 断线重连后本地流式集合是空的，靠只读状态回退）。
 *
 * 链在成员间隙 `runningMemberId` 为 null ⇒ 全员 idle（不猜"谁可能在下一位"）。
 */
export function memberRunState(args: {
  memberId: string;
  streamingMembers: string[];
  runningMemberId: string | null;
}): MemberRunState {
  const { memberId, streamingMembers, runningMemberId } = args;
  if (streamingMembers.includes(memberId)) return 'running';
  if (streamingMembers.length === 0 && runningMemberId === memberId) return 'running';
  return 'idle';
}

// ---------------------------------------------------------------------------
// 紧凑环的状态（design D5 / D6）
// ---------------------------------------------------------------------------

export type MemberRingStateKind = 'ok' | 'loading' | 'empty' | 'error';

export interface MemberRingState {
  kind: MemberRingStateKind;
  /** 是否画三瓣：只有 ok 且 breakdown 非空才画。 */
  drawSlices: boolean;
  /** 是否画常驻铺底轨道：ok 且有 breakdown 时恒画（三段全 0 也画）。 */
  drawTrack: boolean;
}

/**
 * 快照四态 → 环状态。
 *
 * `loading` / `empty` / `error` 一律只给占位（**不许画一个空环冒充零占用**）；
 * `ok` 且 breakdown 非空才画三瓣，轨道环同时常驻（三段全 0 时只剩它）。
 */
export function memberRingState(
  snapshot: MemberSnapshotState | undefined,
): MemberRingState {
  if (snapshot === undefined || snapshot.status !== 'ok') {
    return { kind: snapshot?.status ?? 'loading', drawSlices: false, drawTrack: false };
  }
  const breakdown = snapshot.snapshot.breakdown;
  const usable = breakdown !== null && breakdown.windowTokens > 0;
  return { kind: 'ok', drawSlices: usable, drawTrack: usable };
}

// ---------------------------------------------------------------------------
// 环几何（design D6 / D7）
// ---------------------------------------------------------------------------

/**
 * 默认 120 环的留白：`120/2 − 50 = 10`（现状几何的实测比例，不是新魔数）。
 *
 * 紧凑环按 `size / 120` 等比派生 padding 与描边宽，于是两种尺寸的"外径 / 容器边长"
 * 一致（由 `cards.test.ts` 的比例断言守住）。
 */
export const RING_PADDING = 10;

/** 基准容器边长（成员视图里那只完整环）。 */
export const RING_BASE_SIZE = 120;

/** 基准描边宽（紧凑环的描边按同一比例缩放）。 */
export const RING_STROKE_WIDTH = 10;

export interface RingGeometry {
  size: number;
  padding: number;
  strokeWidth: number;
  /** donut 的中心线半径（描边画在它上面）。 */
  radius: number;
  /** 环外径 = 2 × (中心线半径 + 半个描边)。 */
  outerDiameter: number;
}

/** 按容器边长派生 donut 几何：padding / strokeWidth 都 = size × 10 / 120。 */
export function ringGeometry(size: number): RingGeometry {
  const scale = size / RING_BASE_SIZE;
  const padding = RING_PADDING * scale;
  const strokeWidth = RING_STROKE_WIDTH * scale;
  const radius = size / 2 - padding - strokeWidth / 2;
  return {
    size,
    padding,
    strokeWidth,
    radius,
    outerDiameter: 2 * (radius + strokeWidth / 2),
  };
}

// ---------------------------------------------------------------------------
// 齿轮面板（design D5）
// ---------------------------------------------------------------------------

/** 面板字段清单（顺序即渲染顺序；save / remove 是动作，不是输入控件）。 */
export const kMemberPanelFields = [
  'template',
  'toolsSubset',
  'systemPromptAppend',
  'thinkingEffort',
  'effective',
  'save',
  'remove',
] as const;

export type MemberPanelField = (typeof kMemberPanelFields)[number];

export interface MemberPanelControlState {
  /** 已移除成员的齿轮**仍可打开**（历史配置要能核对）。 */
  canOpen: boolean;
  /** 模板 / 工具 / 提示词 / 强度控件是否禁用。 */
  controlsDisabled: boolean;
  /** 保存与移除是否禁用（点击不发写请求）。 */
  saveDisabled: boolean;
  removeDisabled: boolean;
}

export function memberPanelControls(args: { removed: boolean }): MemberPanelControlState {
  return {
    canOpen: true,
    controlsDisabled: args.removed,
    saveDisabled: args.removed,
    removeDisabled: args.removed,
  };
}
