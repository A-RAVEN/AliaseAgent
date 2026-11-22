// 真实上下文视图（change `web-management-ui` 任务 2.3 / design D13）。
//
// 显示这一步**实际发给模型**的原始 JSON（system / messages / tools），可滚可复制。
// 数据来自 `context.snapshot` 事件 —— 核心用 `ContextSnapshot.toRawJson()` 展开这三个
// 键（`lib/core/event_serialization.dart`），所以这里**不重新拼装**、不裁剪。
import { useState } from 'react';

import type { SnapshotEventData } from '../protocol';

export function RealContextView({ snapshot }: { snapshot: SnapshotEventData }) {
  const [copied, setCopied] = useState(false);
  const raw = {
    system: snapshot.system ?? '',
    messages: snapshot.messages ?? [],
    tools: snapshot.tools ?? '',
  };
  const text = JSON.stringify(raw, null, 2);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      // 剪贴板不可用（无权限/非安全上下文）：内容仍在 <pre> 里，可以手动选中复制。
      setCopied(false);
    }
  };

  return (
    <div data-testid="real-context" className="mt-2 rounded-card border border-line bg-bg/40">
      <div className="flex items-center justify-between border-b border-line px-2 py-1">
        <h3 className="text-xs font-semibold text-fg">真实上下文（原始 JSON）</h3>
        <button
          type="button"
          data-testid="copy-real-context"
          onClick={() => void copy()}
          className="rounded-card border border-line px-2 text-xs text-muted hover:text-fg"
        >
          {copied ? '已复制' : '复制'}
        </button>
      </div>
      <pre
        data-testid="real-context-json"
        className="max-h-64 overflow-auto px-2 py-2 text-xs text-muted"
      >
        {text}
      </pre>
    </div>
  );
}
