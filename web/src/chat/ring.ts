// 占用环的纯几何（change `web-management-ui` 任务 2.3 / design D13）。
//
// 与 Dart 侧 `lib/models/context_breakdown.dart` 的 `ringSegments` **同一套口径**
// （那正是 spec 要求的"复用 ringSegments"）：
//   - 三段顺序固定：二级摘要 → 一级摘要 → 原文；
//   - sweep = tokens / windowTokens × 2π；
//   - 整圈钳制：按顺序累加到整圈为止，超出部分**不画**；`tokens` 保留原值。

/** 一整圈弧度。 */
export const kFullTurn = Math.PI * 2;

export interface RingSegment {
  /** 该瓣的真实 token 数（钳制后仍保留原值）。 */
  tokens: number;
  /** 该瓣扫过的弧度（整圈钳制后的值）。 */
  sweepRadians: number;
}

export interface RingBreakdown {
  level2Tokens: number;
  level1Tokens: number;
  rawTokens: number;
  windowTokens: number;
}

/** 三段在环上的排布（与核心 `ContextBreakdown.ringSegments` 逐条对应）。 */
export function ringSegments(breakdown: RingBreakdown): RingSegment[] {
  const { level2Tokens, level1Tokens, rawTokens, windowTokens } = breakdown;
  if (!(windowTokens > 0)) return [];
  let used = 0;
  const out: RingSegment[] = [];
  for (const tokens of [level2Tokens, level1Tokens, rawTokens]) {
    let sweep = (tokens / windowTokens) * kFullTurn;
    if (used + sweep > kFullTurn) sweep = kFullTurn - used;
    if (sweep < 0) sweep = 0;
    out.push({ tokens, sweepRadians: sweep });
    used += sweep;
  }
  return out;
}

/**
 * 一段扇形（pie slice）的 SVG path。
 *
 * 起始角在 12 点方向（`-π/2`），顺时针为正向 —— 与 Flutter 侧画环的起点/方向一致。
 * 零弧度返回空串（调用方据此不画）。
 */
export function arcPath(options: {
  center: number;
  radius: number;
  startAngle: number;
  sweep: number;
}): string {
  const { center, radius, startAngle, sweep } = options;
  if (!(sweep > 0)) return '';
  const cx = center;
  const cy = center;
  const base = -Math.PI / 2;
  const from = base + startAngle;
  const to = from + sweep;
  const x1 = cx + radius * Math.cos(from);
  const y1 = cy + radius * Math.sin(from);
  // 扫过整圈时终点与起点重合：用两段半圆拼出完整扇形（单段 A 命令画不出 360°）。
  if (sweep >= kFullTurn - 1e-9) {
    const xMid = cx + radius * Math.cos(from + Math.PI);
    const yMid = cy + radius * Math.sin(from + Math.PI);
    return [
      `M ${cx} ${cy}`,
      `L ${x1} ${y1}`,
      `A ${radius} ${radius} 0 1 1 ${xMid} ${yMid}`,
      `A ${radius} ${radius} 0 1 1 ${x1} ${y1}`,
      'Z',
    ].join(' ');
  }
  const x2 = cx + radius * Math.cos(to);
  const y2 = cy + radius * Math.sin(to);
  const largeArc = sweep > Math.PI ? 1 : 0;
  return [
    `M ${cx} ${cy}`,
    `L ${x1} ${y1}`,
    `A ${radius} ${radius} 0 ${largeArc} 1 ${x2} ${y2}`,
    'Z',
  ].join(' ');
}
