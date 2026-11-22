// 工具调用卡：Default 折叠 + 折叠态**严格单行 24px**（change `web-chat-screen`
// 任务 3.2 / F-002 / design D7）。
//
// 折叠不是丢弃：折叠态永远露出「工具名 + 状态 + 输入摘要」（每 toolCall 一张卡，
// 多工具消息就是多张单行卡），点开看完整输入与结果（结果可滚，不截断内容）。
// 高度必须是 24px（= 正文行高 token）—— 由 `e2e/layout.mjs` 在真实渲染里量，
// 组件里不写别的值。
import { ChevronDown, ChevronRight } from 'lucide-react';
import { useState } from 'react';

import type { ToolCardModel, ToolStatus } from '../chat/model';

const statusText: Record<ToolStatus, string> = {
  executing: '执行中',
  done: '完成',
  error: '失败',
};

const statusClass: Record<ToolStatus, string> = {
  executing: 'text-warn',
  done: 'text-ok',
  error: 'text-danger',
};

/** 折叠态摘要：输入的前两个键值（超出部分在展开里看，不静默省略）。 */
export function toolSummary(tool: ToolCardModel): string {
  const entries = Object.entries(tool.input);
  if (entries.length === 0) return '（无输入）';
  const head = entries.slice(0, 2).map(([key, value]) => {
    const text = typeof value === 'string' ? value : JSON.stringify(value);
    return `${key}: ${text}`;
  });
  return entries.length > 2 ? `${head.join(' · ')} · +${entries.length - 2} 项` : head.join(' · ');
}

export function ToolCard({ tool }: { tool: ToolCardModel }) {
  const [expanded, setExpanded] = useState(false);
  const fullResult = tool.result ?? tool.resultPreview ?? '';
  return (
    <div data-testid="tool-card" data-collapsed={expanded ? 'false' : 'true'}>
      <button
        type="button"
        aria-expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
        className={
          expanded
            ? 'flex w-full items-center gap-2 rounded-card bg-surface-2 px-2 py-1 text-left'
            : 'flex h-6 w-full items-center gap-2 overflow-hidden rounded-card px-2 text-left hover:bg-surface-2'
        }
      >
        {expanded ? (
          <ChevronDown size={12} className="shrink-0 text-muted" aria-hidden="true" />
        ) : (
          <ChevronRight size={12} className="shrink-0 text-muted" aria-hidden="true" />
        )}
        <span className="shrink-0 text-sm font-semibold text-fg">{tool.toolName}</span>
        <span className={`shrink-0 text-sm ${statusClass[tool.status]}`}>
          {statusText[tool.status]}
        </span>
        <span className="min-w-0 flex-1 truncate text-sm text-muted">{toolSummary(tool)}</span>
      </button>
      {expanded && (
        <div className="rounded-b-card border-x border-b border-line bg-surface px-2 py-2">
          <div className="text-xs text-muted">输入</div>
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-sm text-fg">
            {JSON.stringify(tool.input, null, 2)}
          </pre>
          <div className="mt-1 text-xs text-muted">结果</div>
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-sm text-fg">
            {fullResult.length > 0 ? fullResult : '（还没有结果）'}
          </pre>
        </div>
      )}
    </div>
  );
}


