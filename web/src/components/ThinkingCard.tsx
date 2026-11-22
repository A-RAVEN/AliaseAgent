// 思考卡：默认折叠 + 折叠态严格单行 24px（change `web-chat-screen` 任务 3.2 /
// F-002 / design D7）。展开看完整思考文本（可滚，不丢弃）。
import { ChevronDown, ChevronRight } from 'lucide-react';
import { useState } from 'react';

import type { ThinkingCardModel } from '../chat/model';

export function ThinkingCard({ thinking }: { thinking: ThinkingCardModel }) {
  const [expanded, setExpanded] = useState(false);
  const empty = thinking.text.trim().length === 0;
  return (
    <div data-testid="thinking-card" data-collapsed={expanded ? 'false' : 'true'}>
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
        <span className="shrink-0 text-sm font-semibold text-muted">思考</span>
        <span className="min-w-0 flex-1 truncate text-sm text-muted">
          {empty ? '（空思考块）' : thinking.text.split('\n')[0]}
        </span>
      </button>
      {expanded && (
        <div className="rounded-b-card border-x border-b border-line bg-surface px-2 py-2">
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-sm text-muted">
            {empty ? '（这个思考块没有文本内容）' : thinking.text}
          </pre>
        </div>
      )}
    </div>
  );
}


