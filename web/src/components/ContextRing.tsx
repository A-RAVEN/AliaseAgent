// 上下文占用环（change `web-management-ui` 任务 2.3 / design D13）。
//
// 复用与 Dart 侧同一套 `ringSegments` 口径（`web/src/chat/ring.ts`，纯函数 + vitest）：
// 三段固定顺序 二级摘要 → 一级摘要 → 原文；**整圈钳制**（超窗口的超出部分不画、
// tokens 数字保留原值）。固定开销（系统提示词 + 工具定义）**不在环上**（design D5）。
import type { ContextBreakdown } from '../protocol';
import { arcPath, ringSegments } from '../chat/ring';

const RING_SIZE = 120;
const RING_CENTER = RING_SIZE / 2;
const RING_RADIUS = 50;

/** 三瓣的颜色/标签（顺序与 ringSegments 一致）。 */
const SLICE_CLASSES = ['fill-accent', 'fill-ok', 'fill-muted'] as const;
const LEGEND_CLASSES = ['text-accent', 'text-ok', 'text-muted'] as const;
const SEGMENT_LABELS = ['二级摘要', '一级摘要', '原文'] as const;

export function ContextRing({ breakdown }: { breakdown: ContextBreakdown }) {
  const segments = ringSegments(breakdown);
  if (segments.length === 0) {
    return (
      <p data-testid="ring-unavailable" className="text-xs text-muted">
        窗口未知，占用环不渲染。
      </p>
    );
  }
  let start = 0;
  const slices = segments.map((segment, index) => {
    const d = arcPath({
      center: RING_CENTER,
      radius: RING_RADIUS,
      startAngle: start,
      sweep: segment.sweepRadians,
    });
    start += segment.sweepRadians;
    return { index, d, ...segment };
  });

  return (
    <div className="flex items-center gap-3">
      <svg
        data-testid="context-ring"
        width={RING_SIZE}
        height={RING_SIZE}
        viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`}
        role="img"
        aria-label="上下文占用环"
      >
        {slices.map((slice) =>
          slice.d.length > 0 ? (
            <path
              key={slice.index}
              data-testid="ring-slice"
              data-tokens={slice.tokens}
              data-sweep={slice.sweepRadians}
              d={slice.d}
              className={SLICE_CLASSES[slice.index]}
            />
          ) : null,
        )}
      </svg>
      <div className="text-xs text-muted">
        <p data-testid="ring-total">
          对话 {breakdown.conversationTokens} / 窗口 {breakdown.windowTokens} tokens
        </p>
        <ul className="mt-1 space-y-1">
          {segments.map((segment, index) => (
            <li key={index} data-testid="ring-legend" data-tokens={segment.tokens}>
              <span className={LEGEND_CLASSES[index]}>■</span> {SEGMENT_LABELS[index]}{' '}
              {segment.tokens}
            </li>
          ))}
          <li data-testid="ring-fixed-overhead" className="text-muted">
            系统+工具（不在环上） {breakdown.fixedOverheadTokens}
          </li>
        </ul>
      </div>
    </div>
  );
}
