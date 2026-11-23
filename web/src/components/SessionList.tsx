// 会话侧栏（change `web-management-ui` 任务 1.3 / design D7）：
// 新建会话 · 删除（确认浮层）· 重命名（内联）· 切换 agent 模板（失败显示阶段+候选名）。
//
// 虚拟滚动沿用 change `web-chat-screen`（几百~几千会话只渲染可视区，行高 36px：
// text-sm(20) + py-2(8×2)）。删除确认与模板选择器不占虚拟行：确认做成侧栏内的浮层，
// 模板选择器放进页脚 —— 行高保持恒定，虚拟滚动的测量才不会被撑变。
import { useVirtualizer } from '@tanstack/react-virtual';
import { Plus } from 'lucide-react';
import { useRef, useState } from 'react';

import { sessionKindBadge, sessionKindLabel } from '../layout/model';
import { formatSwitchFailure, type AgentSwitchFailure } from '../manage/logic';
import type { Session } from '../protocol';

/** 行高：text-sm(20) + py-2(8×2) = 36。 */
const ROW_HEIGHT = 36;

export interface SessionListProps {
  sessions: Session[];
  currentSessionId: string | null;
  onSelect: (sessionId: string) => void;
  /** 新建会话（核心 `session.create`）。 */
  onCreate: () => void;
  /** 新建组（核心 `group.create`）；不传 = 不显示入口。 */
  onCreateGroup?: () => void;
  /** 重命名（核心 `session.rename`）；页面负责继续拼 `session.title`。 */
  onRename: (sessionId: string, title: string) => void;
  /** 删除（核心 `session.delete` / 群聊 `group.delete`）；确认浮层由本组件负责。 */
  onDelete: (session: Session) => void;
  /** 可选模板名（核心 `template.list`）；空数组 = 不显示切换下拉。 */
  templates: string[];
  /** 当前会话的模板名（下拉的选中值）。 */
  currentAgentType: string | null;
  /** 切换当前会话的模板（核心 `session.switchTemplate`）。 */
  onSwitchTemplate: (templateName: string) => void;
  /** 最近一次切换失败（含阶段与候选名）；null = 没有失败。 */
  switchFailure: AgentSwitchFailure | null;
  /** 断线 / 忙碌时禁用写操作。 */
  disabled?: boolean;
}

export function SessionList({
  sessions,
  currentSessionId,
  onSelect,
  onCreate,
  onCreateGroup,
  onRename,
  onDelete,
  templates,
  currentAgentType,
  onSwitchTemplate,
  switchFailure,
  disabled = false,
}: SessionListProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [draftTitle, setDraftTitle] = useState('');

  const virtualizer = useVirtualizer({
    count: sessions.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 6,
  });

  const pendingDelete = sessions.find((session) => session.id === pendingDeleteId) ?? null;
  const currentSession = sessions.find((session) => session.id === currentSessionId) ?? null;
  const currentIsGroup = currentSession?.kind === 'group';

  const beginRename = (session: Session) => {
    if (disabled) return;
    setPendingDeleteId(null);
    setEditingId(session.id);
    setDraftTitle(session.title);
  };

  const commitRename = () => {
    const title = draftTitle.trim();
    const sessionId = editingId;
    setEditingId(null);
    if (!sessionId || title.length === 0) return;
    onRename(sessionId, title);
  };

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div className="flex items-center justify-between px-3 py-2">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-muted">会话</h2>
        <div className="flex items-center gap-1">
          {onCreateGroup && (
            <button
              type="button"
              data-testid="group-create"
              title="新建组"
              aria-label="新建组"
              disabled={disabled}
              onClick={() => {
                setPendingDeleteId(null);
                setEditingId(null);
                onCreateGroup();
              }}
              className="flex h-6 items-center justify-center rounded-card border border-line px-1 text-xs text-muted hover:bg-surface-2 hover:text-fg disabled:cursor-not-allowed disabled:opacity-40"
            >
              + 组
            </button>
          )}
        <button
          type="button"
          data-testid="session-create"
          title="新建会话"
          aria-label="新建会话"
          disabled={disabled}
          onClick={() => {
            setPendingDeleteId(null);
            setEditingId(null);
            onCreate();
          }}
          className="flex h-6 w-6 items-center justify-center rounded-card text-muted hover:bg-surface-2 hover:text-fg disabled:cursor-not-allowed disabled:opacity-40"
        >
          <Plus size={16} aria-hidden="true" />
        </button>
        </div>
      </div>

      <div ref={scrollRef} data-testid="session-list" className="min-h-0 flex-1 overflow-y-auto px-2 py-1">
        {sessions.length === 0 ? (
          <p className="px-2 text-sm text-muted">没有会话：点上面的 + 新建一个。</p>
        ) : (
          <div style={{ height: virtualizer.getTotalSize(), position: 'relative', width: '100%' }}>
            {virtualizer.getVirtualItems().map((virtualItem) => {
              const session = sessions[virtualItem.index];
              const selected = session.id === currentSessionId;
              const editing = session.id === editingId;
              const badge = sessionKindBadge(session);
              return (
                <div
                  key={session.id}
                  style={{
                    position: 'absolute',
                    top: 0,
                    left: 0,
                    width: '100%',
                    height: ROW_HEIGHT,
                    transform: `translateY(${virtualItem.start}px)`,
                  }}
                  className="flex items-center gap-1"
                >
                  {editing ? (
                    <input
                      data-testid="session-rename-input"
                      autoFocus
                      value={draftTitle}
                      onChange={(event) => setDraftTitle(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') {
                          event.preventDefault();
                          commitRename();
                        } else if (event.key === 'Escape') {
                          setEditingId(null);
                        }
                      }}
                      className="h-8 min-w-0 flex-1 rounded-card border border-accent bg-surface px-2 text-sm text-fg outline-none"
                    />
                  ) : (
                    <button
                      type="button"
                      data-testid="session-row"
                      data-kind={session.kind}
                      data-session-id={session.id}
                      aria-current={selected ? 'true' : undefined}
                      title={`${session.title}（${sessionKindLabel(session)} · ${session.agentType}）`}
                      onClick={() => onSelect(session.id)}
                      className={
                        selected
                          ? 'h-full min-w-0 flex-1 truncate rounded-card bg-surface-2 px-2 text-left text-sm text-fg'
                          : 'h-full min-w-0 flex-1 truncate rounded-card px-2 text-left text-sm text-muted hover:bg-surface-2'
                      }
                    >
                      <span className="flex min-w-0 items-center gap-1">
                        {badge !== null && (
                          <span
                            data-testid="session-kind-badge"
                            className="shrink-0 text-xs text-accent"
                          >
                            {badge}
                          </span>
                        )}
                        <span
                          data-testid="session-title"
                          className="min-w-0 truncate"
                        >
                          {session.title}
                        </span>
                      </span>
                    </button>
                  )}
                  <button
                    type="button"
                    data-testid="session-rename"
                    title="重命名"
                    aria-label={`重命名 ${session.title}`}
                    disabled={disabled}
                    onClick={() => beginRename(session)}
                    className="shrink-0 rounded-card px-1 py-1 text-xs text-muted hover:bg-surface-2 hover:text-fg disabled:opacity-30"
                  >
                    改名
                  </button>
                  <button
                    type="button"
                    data-testid="session-delete"
                    title="删除"
                    aria-label={`删除 ${session.title}`}
                    disabled={disabled}
                    onClick={() => {
                      setEditingId(null);
                      setPendingDeleteId(session.id);
                    }}
                    className="shrink-0 rounded-card px-1 py-1 text-xs text-danger/80 hover:bg-surface-2 hover:text-danger disabled:opacity-30"
                  >
                    删除
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {(templates.length > 0 || switchFailure || currentIsGroup) && (
        <div className="border-t border-line px-3 py-2">
          {templates.length > 0 && (
            <label className="flex items-center gap-2 text-xs text-muted">
              <span className="shrink-0">模板</span>
              <select
                data-testid="template-select"
                value={currentAgentType ?? ''}
                disabled={disabled || currentSessionId === null || currentIsGroup}
                onChange={(event) => {
                  // 群聊的模板由各成员决定（change `group-chat-layout` D8）：
                  // 即使有人程序化派发 change，也不得发起 session.switchTemplate。
                  if (currentIsGroup) return;
                  onSwitchTemplate(event.target.value);
                }}
                className="h-7 min-w-0 flex-1 rounded-card border border-line bg-surface px-1 text-xs text-fg outline-none disabled:opacity-40"
              >
                {/* 当前模板不在候选里（例如已被删除）时也显示它，不假装它不存在。 */}
                {currentAgentType !== null && !templates.includes(currentAgentType) && (
                  <option value={currentAgentType}>{currentAgentType}（不在列表）</option>
                )}
                {templates.map((name) => (
                  <option key={name} value={name}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
          )}
          {currentIsGroup && (
            <p data-testid="group-template-note" className="mt-2 text-xs text-muted">
              群聊模板由各成员决定（成员的模板在右侧成员名单里编辑）。
            </p>
          )}
          {switchFailure && (
            <p
              data-testid="switch-failure"
              className="mt-2 rounded-card border border-danger/40 bg-danger/10 px-2 py-1 text-xs text-danger"
            >
              {formatSwitchFailure(switchFailure)}
            </p>
          )}
        </div>
      )}

      {pendingDelete && (
        <div
          data-testid="delete-confirm"
          className="absolute inset-x-2 top-8 z-10 rounded-card border border-danger/40 bg-surface p-3 text-xs text-fg shadow-e2"
        >
          <p className="mb-2">
            {pendingDelete.kind === 'group'
              ? `删除群聊「${pendingDelete.title}」？该群的成员、消息与摘要都会删除。`
              : `删除会话「${pendingDelete.title}」？该会话的运行实例与数据库记录都会被删除。`}
          </p>
          <div className="flex justify-end gap-2">
            <button
              type="button"
              data-testid="delete-cancel"
              onClick={() => setPendingDeleteId(null)}
              className="rounded-card border border-line px-2 py-1 text-muted hover:text-fg"
            >
              取消
            </button>
            <button
              type="button"
              data-testid="delete-confirm-button"
              onClick={() => {
                const target = pendingDelete;
                setPendingDeleteId(null);
                onDelete(target);
              }}
              className="rounded-card bg-danger px-2 py-1 font-semibold text-bg"
            >
              删除
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
