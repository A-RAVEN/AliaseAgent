// 占用环的纯几何（change `web-management-ui` 任务 2.3 / design D13）。
//
// 复用 Dart 侧 `ContextBreakdown.ringSegments` 的同一套口径：
//   - 三段顺序固定：二级摘要 → 一级摘要 → 原文；
//   - 每段 sweep = tokens / window * 2π；
//   - **整圈钳制**：按顺序累加，到整圈为止；超出部分不画，但 tokens 数字保留原值
//     （数字与面板读 tokens，不读弧度）。
import { describe, expect, it } from 'vitest';

import { arcPath, kFullTurn, ringSegments } from './ring';

describe('ringSegments', () => {
  it('三段按 token 占比排布，顺序固定为 二级 → 一级 → 原文', () => {
    const segments = ringSegments({
      level2Tokens: 100,
      level1Tokens: 200,
      rawTokens: 300,
      windowTokens: 1000,
    });
    console.log('[三瓣]', JSON.stringify(segments));
    expect(segments.map((segment) => segment.tokens)).toEqual([100, 200, 300]);
    expect(segments[0].sweepRadians).toBeCloseTo((100 / 1000) * kFullTurn, 10);
    expect(segments[1].sweepRadians).toBeCloseTo((200 / 1000) * kFullTurn, 10);
    expect(segments[2].sweepRadians).toBeCloseTo((300 / 1000) * kFullTurn, 10);
  });

  it('整圈钳制：三段之和超窗口时累加到整圈为止、超出不画、tokens 保留原值', () => {
    const segments = ringSegments({
      level2Tokens: 80,
      level1Tokens: 80,
      rawTokens: 80,
      windowTokens: 100,
    });
    console.log('[钳制]', JSON.stringify(segments));
    const used = segments.reduce((sum, segment) => sum + segment.sweepRadians, 0);
    console.log('[钳制] 弧度之和', used, '2π =', kFullTurn);
    expect(used).toBeCloseTo(kFullTurn, 10);
    expect(used).toBeLessThanOrEqual(kFullTurn + 1e-9);
    expect(segments.map((segment) => segment.tokens)).toEqual([80, 80, 80]);
    // 与 Dart `ringSegments` 逐条一致：第一段 80/100 仍在整圈内（不截），第二段被截到
    // 剩余弧度，第三段为 0。
    expect(segments[0].sweepRadians).toBeCloseTo((80 / 100) * kFullTurn, 10);
    expect(segments[1].sweepRadians).toBeCloseTo(kFullTurn - (80 / 100) * kFullTurn, 10);
    expect(segments[2].sweepRadians).toBe(0);
  });

  it('部分超出：按顺序填满整圈，剩下一段为 0', () => {
    const segments = ringSegments({
      level2Tokens: 40,
      level1Tokens: 80,
      rawTokens: 10,
      windowTokens: 100,
    });
    console.log('[部分超出]', JSON.stringify(segments));
    const used = segments.reduce((sum, segment) => sum + segment.sweepRadians, 0);
    expect(used).toBeCloseTo(kFullTurn, 10);
    // 40 + 80 = 120 > 100 ⇒ 一级被截到剩 60，原文为 0。
    expect(segments[2].sweepRadians).toBe(0);
    expect(segments[1].sweepRadians).toBeCloseTo((60 / 100) * kFullTurn, 10);
  });

  it('窗口未知（<= 0）时返回空列表，不画环', () => {
    expect(
      ringSegments({ level2Tokens: 1, level1Tokens: 2, rawTokens: 3, windowTokens: 0 }),
    ).toEqual([]);
  });
});

describe('arcPath', () => {
  it('整圈段画成完整扇形路径（不是空字符串）', () => {
    const path = arcPath({ center: 60, radius: 50, startAngle: 0, sweep: kFullTurn });
    console.log('[整圈路径]', path.slice(0, 80));
    expect(path.startsWith('M ')).toBe(true);
    expect(path.includes('A')).toBe(true);
    expect(path.trim().endsWith('Z')).toBe(true);
  });

  it('零弧度段返回空路径（不画）', () => {
    expect(arcPath({ center: 60, radius: 50, startAngle: 0, sweep: 0 })).toBe('');
  });
});
