// 聊天屏（change `web-chat-screen`：把最小验证页扩成完整聊天屏）。
//
// 这里是**纯展示容器**：数据（ChatView / 会话 / 快照 / 计量）全部由 App（或测试
// harness）注入，组件自己不连 WS、不查库。这样 puppeteer 能在无核心的情况下驱动
// 同一份组件量布局（design D13）。
//
// 结构（design D1/D6）：左会话栏（虚拟滚动）· 消息区（虚拟滚动 + 贴底跟随 + 跳底）·
// 顶部状态 · 底部输入。
import { useMemo } from 'react';

import type { ChatView } from '../chat/model';
import { renderMessages } from '../chat/render';
import type { ConnectionStatus, Session, SnapshotEventData } from '../protocol';
import { Composer } from './Composer';
import { ConnectionBadge } from './ConnectionBadge';
import { MessageList } from './MessageList';
import { SessionList } from './SessionList';

export interface ChatScreenProps {
  status: ConnectionStatus;
  sessions: Session[];
  currentSessionId: string | null;
  onSelectSession: (sessionId: string) => void;
  view: ChatView;
  hasEarlier: boolean;
  loadingEarlier: boolean;
  onLoadEarlier: () => void;
  error: string | null;
  notice: string | null;
  skillFailures: string[];
  snapshot: SnapshotEventData | null;
  metering: Record<string, unknown> | null;
  onSend: (text: string) => void;
}

export function ChatScreen({
  status,
  sessions,
  currentSessionId,
  onSelectSession,
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
}: ChatScreenProps) {
  const items = useMemo(() => renderMessages(view), [view]);
  const currentTitle =
    sessions.find((session) => session.id === currentSessionId)?.title ?? '（未选择会话）';

  const breakdownRows = snapshot?.breakdown
    ? [
        { label: '二级摘要', value: snapshot.breakdown.level2Tokens },
        { label: '一级摘要', value: snapshot.breakdown.level1Tokens },
        { label: '原文', value: snapshot.breakdown.rawTokens },
        { label: '系统+工具', value: snapshot.breakdown.fixedOverheadTokens },
      ]
    : [];

  return (
    <div
      className="flex h-full flex-col bg-bg text-fg"
      data-streaming={view.isStreaming ? 'true' : 'false'}
    >
      <header className="flex items-center justify-between gap-4 border-b border-line px-4 py-3">
        <div className="min-w-0">
          <h1 className="truncate text-xl font-semibold">AliasAgent</h1>
          <p className="truncate text-xs text-muted" data-testid="current-session-title">
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
          <ConnectionBadge status={status} />
        </div>
      </header>

      <div className="flex min-h-0 flex-1">
        <aside className="flex w-56 shrink-0 flex-col border-r border-line bg-surface">
          <h2 className="px-3 py-2 text-xs font-semibold uppercase tracking-wide text-muted">
            会话
          </h2>
          <SessionList
            sessions={sessions}
            currentSessionId={currentSessionId}
            onSelect={onSelectSession}
          />
        </aside>

        <main className="flex min-w-0 flex-1 flex-col">
          {error && (
            <div
              data-testid="error-banner"
              className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
            >
              {error}
            </div>
          )}
          {notice && (
            <div className="border-b border-line bg-surface px-4 py-2 text-xs text-muted">
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
              上下文窗口 {snapshot.windowTokens} tokens · 模板 {snapshot.agentType}
              {breakdownRows.length > 0 && (
                <span className="ml-2 space-x-2">
                  {breakdownRows.map((row) => (
                    <span key={row.label}>
                      {row.label} {row.value}
                    </span>
                  ))}
                </span>
              )}
            </section>
          )}

          <Composer
            disabled={status !== 'open' || currentSessionId === null}
            onSend={onSend}
          />
        </main>
      </div>
    </div>
  );
}
