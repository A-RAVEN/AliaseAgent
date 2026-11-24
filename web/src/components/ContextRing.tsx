// 上下文占用环（change `web-management-ui` 任务 2.3 / design D13；
// change `chat-bubbles-avatars` 任务 5.4 / design D6 增**紧凑环**）。
//
// 两种形态共用同一套 `ringSegments` 口径（`web/src/chat/ring.ts`，纯函数 + vitest）：
// 三段顺序固定 二级摘要 → 一级摘要 → 原文；整圈钳制；tokens 保留原值；固定开销不在环上。
//
//   - **完整环**（默认 120）：`arcPath` 实心扇形 + 旁置「对话 / 窗口 tokens」与三瓣图例
//     —— 保持现状外观，`data-testid="context-ring"`；
//   - **紧凑环**（成员卡片，32）：donut 描边环（同心 `<circle>` + `stroke-dasharray`），
//     只画环、不常驻数字，悬停 / 键盘聚焦弹 tokens 详情；`data-testid="member-ring-<id>"`，
//     **MUST NOT 输出 `context-ring`**（既有 8.6 用「没有快照 ⇒ context-ring 为 null」判据）。
import { useState } from 'react';

import type { ContextBreakdown } from '../protocol';
import { avatarSizes } from '../tokens';
import { arcPath, kFullTurn, ringSegments } from '../chat/ring';
import type { MemberSnapshotState } from '../group/model';
import {
  memberRingState,
  RING_BASE_SIZE,
  RING_PADDING,
  ringGeometry,
} from '../group/cards';

/** 完整环的容器边长（= 基准尺寸；既有调用零改动）。 */
const RING_SIZE = RING_BASE_SIZE;
const RING_CENTER = RING_SIZE / 2;
/** 完整环是实心扇形，没有描边：半径 = 容器/2 − 留白 = 50（100/120 = 83.3%）。 */
const RING_RADIUS = RING_BASE_SIZE / 2 - RING_PADDING;

/** 三瓣的颜色/标签（顺序与 ringSegments 一致）。实心扇形用 `fill-*`。 */
const SLICE_CLASSES = ['fill-accent', 'fill-ok', 'fill-muted'] as const;
const LEGEND_CLASSES = ['text-accent', 'text-ok', 'text-muted'] as const;
/** 紧凑环是描边环，用 `stroke-*`（同一组颜色令牌，不新增颜色）。 */
const STROKE_CLASSES = ['stroke-accent', 'stroke-ok', 'stroke-muted'] as const;
const SEGMENT_LABELS = ['二级摘要', '一级摘要', '原文'] as const;

export interface ContextRingProps {
  breakdown: ContextBreakdown;
  /** 容器边长；省略 = 既有 120 完整环（外观不变）。其它尺寸画 donut。 */
  size?: number;
}

/** donut 描边环（紧凑形态）：先画常驻轨道，再叠三瓣。 */
function DonutRing({
  breakdown,
  size,
}: {
  breakdown: ContextBreakdown;
  size: number;
}) {
  const geometry = ringGeometry(size);
  const segments = ringSegments(breakdown);
  const circumference = 2 * Math.PI * geometry.radius;
  const center = size / 2;
  let offset = 0;
  const slices = segments.map((segment, index) => {
    const dash = (segment.sweepRadians / kFullTurn) * circumference;
    const slice = { index, dash, offset, tokens: segment.tokens };
    offset += dash;
    return slice;
  });
  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      aria-hidden="true"
      className="block"
    >
      {/* 常驻铺底轨道：三段全 0 时只剩它（不是空白盒）。 */}
      <circle
        cx={center}
        cy={center}
        r={geometry.radius}
        fill="none"
        strokeWidth={geometry.strokeWidth}
        className="stroke-line"
      />
      {slices.map((slice) =>
        slice.dash > 0 ? (
          <circle
            key={slice.index}
            data-testid="ring-slice"
            data-tokens={slice.tokens}
            data-sweep={segments[slice.index].sweepRadians}
            cx={center}
            cy={center}
            r={geometry.radius}
            fill="none"
            strokeWidth={geometry.strokeWidth}
            strokeDasharray={`${slice.dash} ${Math.max(0, circumference - slice.dash)}`}
            strokeDashoffset={-slice.offset}
            transform={`rotate(-90 ${center} ${center})`}
            className={STROKE_CLASSES[slice.index]}
          />
        ) : null,
      )}
    </svg>
  );
}

export function ContextRing({ breakdown, size = RING_SIZE }: ContextRingProps) {
  if (size !== RING_SIZE) {
    return <DonutRing breakdown={breakdown} size={size} />;
  }
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

/**
 * 成员卡片上的紧凑环（change `chat-bubbles-avatars` D5 / D6）。
 *
 * 只画环、不常驻数字；悬停或键盘聚焦给 tokens 详情（**不要求百分比** —— web 的两只环
 * 都不在百分比条款内）。`loading` / `empty` / `error` 只给占位并标出状态，
 * MUST NOT 画一个空环冒充零占用。
 */
export function MemberRing({
  memberId,
  snapshot,
}: {
  memberId: string;
  snapshot: MemberSnapshotState | undefined;
}) {
  const [open, setOpen] = useState(false);
  const state = memberRingState(snapshot);
  const detailId = `member-ring-detail-${memberId}`;
  const testId = `member-ring-${memberId}`;
  const breakdown =
    snapshot !== undefined && snapshot.status === 'ok' ? snapshot.snapshot.breakdown : null;

  if (state.kind !== 'ok' || breakdown === null) {
    const label =
      state.kind === 'loading' ? '读取中' : state.kind === 'error' ? '读取失败' : '没有快照';
    return (
      <span
        data-testid={testId}
        data-ring-state={state.kind}
        title={`上下文占用：${label}`}
        aria-label={`上下文占用：${label}`}
        className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-full border border-line text-xs text-muted"
      >
        {state.kind === 'loading' ? '…' : '—'}
      </span>
    );
  }

  const segments = ringSegments(breakdown);
  const size = avatarSizes.member;
  return (
    <div className="relative shrink-0">
      <div
        data-testid={testId}
        data-ring-state="ok"
        role="img"
        tabIndex={0}
        aria-label={`上下文占用：对话 ${breakdown.conversationTokens} / 窗口 ${breakdown.windowTokens} tokens`}
        aria-describedby={open ? detailId : undefined}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') setOpen(false);
        }}
        className="inline-flex items-center justify-center rounded-full outline-none"
      >
        <DonutRing breakdown={breakdown} size={size} />
      </div>
      {open && (
        <div
          id={detailId}
          data-testid={detailId}
          role="tooltip"
          className="absolute left-0 top-full z-30 mt-1 w-48 rounded-card border border-line bg-surface p-2 text-xs text-muted shadow-e2"
        >
          <p data-testid={`${detailId}-total`}>
            对话 {breakdown.conversationTokens} / 窗口 {breakdown.windowTokens} tokens
          </p>
          <ul className="mt-1 space-y-1">
            {segments.map((segment, index) => (
              <li key={index} data-testid={`${detailId}-segment`} data-tokens={segment.tokens}>
                {SEGMENT_LABELS[index]} {segment.tokens}
              </li>
            ))}
            <li data-testid={`${detailId}-overhead`}>
              系统+工具固定开销 {breakdown.fixedOverheadTokens}
            </li>
          </ul>
        </div>
      )}
    </div>
  );
}
