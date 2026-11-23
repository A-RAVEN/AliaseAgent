// 聊天屏（change `web-chat-screen`：把最小验证页扩成完整聊天屏）。
//
// 这里是**纯展示容器**：数据（ChatView / 会话 / 快照 / 计量）全部由 App（或测试
// harness）注入，组件自己不连 WS、不查库。这样 puppeteer 能在无核心的情况下驱动
// 同一份组件量布局（design D13）。
//
// change `group-chat-layout` D1：会话列表的宿主上提到 `ChatShell`，本组件瘦身为
// **纯主区**（header + 提示条 + 消息视图 + 快照 + 发送区）。它保留 error / notice /
// skillFailures 三条横幅与 Provider / 模板入口；列表与选中状态不再由它持有。
import { useMemo, useState } from 'react';

import type { ChatView } from '../chat/model';
import type { PendingImage } from '../chat/attachments';
import { renderMessages } from '../chat/render';
import type { ConnectionStatus, SnapshotEventData } from '../protocol';
import { Composer } from './Composer';
import { ConnectionBadge } from './ConnectionBadge';
import { ContextRing } from './ContextRing';
import { MessageList } from './MessageList';
import { RealContextView } from './RealContextView';

export interface ChatScreenProps {
  status: ConnectionStatus;
  /** 当前会话标题；null = 没有选中会话（空聊天屏）。 */
  sessionTitle: string | null;
  /** 是否有选中会话（决定输入是否可用、是否渲染空态标题）。 */
  sessionSelected: boolean;
  view: ChatView;
  hasEarlier: boolean;
  loadingEarlier: boolean;
  onLoadEarlier: () => void;
  error: string | null;
  notice: string | null;
  skillFailures: string[];
  snapshot: SnapshotEventData | null;
  metering: Record<string, unknown> | null;
  onSend: (text: string, images?: PendingImage[]) => void;
  /** 附件路径 → data URL（null = 取回失败）；来源是 `attachment.read`（design D12）。 */
  attachments?: Record<string, string | null>;
  /** 当前模板是否声明 image 模态（null = 未知 ⇒ 不提示「图片未发送」）。 */
  imagesSupported?: boolean | null;
  /** 打开管理屏（change `web-management-ui` 3.3 / 3.4）；不传 = 不显示入口。 */
  onOpenProviders?: () => void;
  onOpenTemplates?: () => void;
}

export function ChatScreen({
  status,
  sessionTitle,
  sessionSelected,
  view,
  hasEarlier,
  loadingEarlier,
  onLoadEarlier,
  error,
  notice,
  skillFailures,
  snapshot,
  metering,
  onSend,
  attachments = {},
  imagesSupported = null,
  onOpenProviders,
  onOpenTemplates,
}: ChatScreenProps) {
  const items = useMemo(() => renderMessages(view), [view]);
  const [showRealContext, setShowRealContext] = useState(false);
  const currentTitle = sessionSelected ? (sessionTitle ?? '（未选择会话）') : '（未选择会话）';

  return (
    <div
      className="flex h-full min-h-0 flex-col bg-bg text-fg"
      data-streaming={view.isStreaming ? 'true' : 'false'}
    >
      <header className="flex items-center justify-between gap-4 border-b border-line px-4 py-3">
        {/* min-w-0 + flex-1：让标题列真的被约束住，truncate 才有东西可截 ——
            只写 min-w-0 时这一列按内容宽度撑开（实测 118 字符标题把 <p> 撑到 1054px，
            design_audit 判「单行 176 字符」）。 */}
        <div className="min-w-0 flex-1">
          <h1 className="truncate text-xl font-semibold">AliasAgent</h1>
          <p
            className="max-w-sm truncate text-xs text-muted"
            data-testid="current-session-title"
            title={currentTitle}
          >
            {currentTitle}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-3 text-xs text-muted">
          {metering && (
            <span>
              in {String(metering.input_tokens ?? 0)} / out{' '}
              {String(metering.output_tokens ?? 0)} tokens
            </span>
          )}
          {onOpenProviders && (
            <button
              type="button"
              data-testid="open-providers"
              onClick={onOpenProviders}
              className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
            >
              Providers
            </button>
          )}
          {onOpenTemplates && (
            <button
              type="button"
              data-testid="open-templates"
              onClick={onOpenTemplates}
              className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
            >
              模板
            </button>
          )}
          <ConnectionBadge status={status} />
        </div>
      </header>

      {/* R.6：主地标由 `ChatShell` 的 <main> 提供，这里不再写第二个 main。 */}
      <section className="flex min-h-0 flex-1 flex-col">
        {error && (
          <div
            data-testid="error-banner"
            className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
          >
            {error}
          </div>
        )}
        {notice && (
          <div
            data-testid="notice-banner"
            className="border-b border-line bg-surface px-4 py-2 text-xs text-muted"
          >
            {notice}
          </div>
        )}
        {skillFailures.length > 0 && (
          <div
            data-testid="skill-failures"
            className="border-b border-warn/40 bg-warn/10 px-4 py-2 text-xs text-warn"
          >
            <div className="font-semibold">有技能未生效：</div>
            <ul className="list-inside list-disc">
              {skillFailures.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
          </div>
        )}

        <MessageList
          items={items}
          hasEarlier={hasEarlier}
          loadingEarlier={loadingEarlier}
          onLoadEarlier={onLoadEarlier}
          attachments={attachments}
          imagesSupported={imagesSupported}
        />

        {loadingEarlier && (
          <div className="border-t border-line bg-surface px-4 py-1 text-xs text-muted">
            正在加载更早的消息…
          </div>
        )}

        {snapshot && (
          <section
            data-testid="context-snapshot"
            className="border-t border-line px-4 py-2 text-xs text-muted"
          >
            <div className="flex items-center justify-between gap-2">
              <span>
                上下文窗口 {snapshot.windowTokens} tokens · 模板 {snapshot.agentType} · 合计{' '}
                {snapshot.breakdown?.usedTokens ?? 0}
              </span>
              <button
                type="button"
                data-testid="toggle-real-context"
                onClick={() => setShowRealContext((previous) => !previous)}
                className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
              >
                {showRealContext ? '收起真实上下文' : '真实上下文'}
              </button>
            </div>
            {snapshot.breakdown ? (
              <div className="mt-2">
                <ContextRing breakdown={snapshot.breakdown} />
              </div>
            ) : (
              <p data-testid="no-breakdown" className="mt-1 text-warn">
                本次快照没有占用拆分数据：不渲染占用环（不静默当成 0）。
              </p>
            )}
            {showRealContext && <RealContextView snapshot={snapshot} />}
          </section>
        )}

        <Composer
          disabled={status !== 'open' || !sessionSelected}
          onSend={onSend}
        />
      </section>
    </div>
  );
}
