// 群视图（change `agent-group-chat` 任务 8.3~8.7 / design D11）。
//
// 真实应用里的组屏幕：公开时间线 + 每成员私有分栏（含「已移除」栏）+ 每成员真实
// 上下文（复用 `RealContextView`）+ 每成员占用环（复用 `ContextRing`，分母是各自
// 实例窗口）+ 操作面（加成员 / 编辑覆盖层 / 选发言人并发送）。
//
// 组件是**纯展示 + 动作**：数据由 App 注入（它在真实 WS 上拉 group.list /
// message.query / group.view），动作直接走 `group.*` RPC 再让 App 重拉。
import { useState } from 'react';

import type {
  CoreClient,
  GroupMemberSummary,
  GroupSummary,
  InstanceOverrides,
  SnapshotEventData,
} from '../protocol';
import type { GroupLane, GroupTimelineItem } from './model';
import { ContextRing } from '../components/ContextRing';
import { RealContextView } from '../components/RealContextView';

export interface GroupViewProps {
  client: CoreClient;
  group: GroupSummary;
  members: GroupMemberSummary[];
  timeline: GroupTimelineItem[];
  lanes: GroupLane[];
  snapshots: Record<string, SnapshotEventData | null>;
  templates: string[];
  thinkingEfforts: string[];
  toolNames: string[];
  /** 还有更早的消息（= 上一页的 prevCursor 非空）。 */
  hasEarlier: boolean;
  loadingEarlier: boolean;
  onLoadEarlier: () => void;
  onReload: () => Promise<void> | void;
  onError: (message: string) => void;
}

export function GroupView({
  client,
  group,
  members,
  timeline,
  lanes,
  snapshots,
  templates,
  thinkingEfforts,
  toolNames,
  hasEarlier,
  loadingEarlier,
  onLoadEarlier,
  onReload,
  onError,
}: GroupViewProps) {
  const [newName, setNewName] = useState('');
  const [newTemplate, setNewTemplate] = useState(templates[0] ?? 'general');
  const [speaker, setSpeaker] = useState<string>('');
  const [draft, setDraft] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [subset, setSubset] = useState<Record<string, string[]>>({});
  const [append, setAppend] = useState<Record<string, string>>({});
  const [effort, setEffort] = useState<Record<string, string>>({});
  const [realContextFor, setRealContextFor] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const activeMembers = members.filter((member) => member.removedAt === null);

  const addMember = async () => {
    const name = newName.trim();
    if (!name) {
      onError('成员名不能为空');
      return;
    }
    setBusy(true);
    try {
      await client.request('group.member.add', {
        groupId: group.id,
        name,
        templateName: newTemplate,
      });
      setNewName('');
      await onReload();
    } catch (error) {
      onError(`加入成员失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const beginEdit = (member: GroupMemberSummary) => {
    setEditing(member.id);
    setSubset((previous) => ({
      ...previous,
      [member.id]: member.overrides?.toolsSubset ?? toolNames,
    }));
    setAppend((previous) => ({
      ...previous,
      [member.id]: member.overrides?.systemPromptAppend ?? '',
    }));
    setEffort((previous) => ({
      ...previous,
      [member.id]: member.overrides?.thinkingEffort ?? '',
    }));
  };

  const saveOverrides = async (member: GroupMemberSummary) => {
    const overrides: InstanceOverrides = {
      toolsSubset: subset[member.id] ?? [],
      systemPromptAppend: append[member.id] ?? '',
    };
    const effortValue = effort[member.id] ?? '';
    if (effortValue !== '') overrides.thinkingEffort = effortValue;
    setBusy(true);
    try {
      await client.request('group.member.update', {
        groupId: group.id,
        memberId: member.id,
        overrides,
      });
      setEditing(null);
      await onReload();
    } catch (error) {
      onError(`保存覆盖层失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const removeMember = async (member: GroupMemberSummary) => {
    setBusy(true);
    try {
      await client.request('group.member.remove', {
        groupId: group.id,
        memberId: member.id,
      });
      await onReload();
    } catch (error) {
      onError(`移除成员失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const send = async () => {
    if (!speaker) {
      onError('请先选择发言人（群发送必须点名一个成员）');
      return;
    }
    setBusy(true);
    try {
      await client.request('group.send', {
        groupId: group.id,
        speaker,
        text: draft,
      });
      setDraft('');
      await onReload();
    } catch (error) {
      onError(`发送失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col bg-bg text-fg" data-testid="group-view">
      <header className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
        <div className="min-w-0">
          <h1 className="truncate text-xl font-semibold">组视图 · {group.title}</h1>
          <p className="text-xs text-muted">成员共享一份原文；每个成员只看得到自己的私有过程。</p>
        </div>
        <span className="text-xs text-muted" data-testid="group-kind">
          kind={group.kind}
        </span>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* 成员与覆盖层 */}
        <aside className="w-72 shrink-0 overflow-y-auto border-r border-line bg-surface px-3 py-3">
          <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">成员</h2>
          <ul className="space-y-2" data-testid="group-members">
            {members.map((member) => (
              <li key={member.id} className="rounded-card border border-line bg-bg/40 p-2">
                <div className="flex items-center justify-between gap-2">
                  <span className="min-w-0 truncate text-sm" data-testid={`member-name-${member.id}`}>
                    {member.name}
                    {member.removedAt !== null && (
                      <span className="ml-1 text-warn" data-testid={`member-removed-${member.id}`}>
                        （已移除）
                      </span>
                    )}
                  </span>
                  <span className="shrink-0 text-xs text-muted">{member.template}</span>
                </div>
                {member.effective && (
                  <p className="mt-1 text-xs text-muted" data-testid={`effective-${member.id}`}>
                    生效工具：{(member.effective.tools ?? []).join('、') || '（无）'} · 思考：
                    {member.effective.thinkingMode ?? 'disabled'}
                    {member.effective.thinkingEffort ? `/${member.effective.thinkingEffort}` : ''}
                  </p>
                )}
                <div className="mt-1 flex gap-2 text-xs">
                  <button
                    type="button"
                    data-testid={`member-edit-${member.id}`}
                    disabled={busy || member.removedAt !== null}
                    onClick={() => beginEdit(member)}
                    className="min-h-6 rounded-card border border-line px-2 py-1 text-muted hover:text-fg disabled:opacity-40"
                  >
                    覆盖层
                  </button>
                  <button
                    type="button"
                    data-testid={`member-remove-${member.id}`}
                    disabled={busy || member.removedAt !== null}
                    onClick={() => void removeMember(member)}
                    className="min-h-6 rounded-card border border-danger/40 px-2 py-1 text-danger/80 hover:text-danger disabled:opacity-40"
                  >
                    移除
                  </button>
                </div>
                {editing === member.id && (
                  <div className="mt-2 space-y-1 text-xs" data-testid={`override-editor-${member.id}`}>
                    <div className="font-semibold text-muted">工具子集（只能收紧）</div>
                    {toolNames.map((tool) => (
                      <label key={tool} className="flex items-center gap-1">
                        <input
                          type="checkbox"
                          data-testid={`tool-${member.id}-${tool}`}
                          checked={(subset[member.id] ?? []).includes(tool)}
                          onChange={(event) => {
                            const next = new Set(subset[member.id] ?? []);
                            if (event.target.checked) next.add(tool);
                            else next.delete(tool);
                            setSubset((previous) => ({
                              ...previous,
                              [member.id]: [...next],
                            }));
                          }}
                        />
                        <span>{tool}</span>
                      </label>
                    ))}
                    <label className="block">
                      提示词追加
                      <input
                        type="text"
                        data-testid={`append-${member.id}`}
                        value={append[member.id] ?? ''}
                        onChange={(event) =>
                          setAppend((previous) => ({
                            ...previous,
                            [member.id]: event.target.value,
                          }))
                        }
                        className="mt-1 h-7 w-full rounded-card border border-line bg-surface px-2 text-xs"
                      />
                    </label>
                    <label className="block">
                      思考强度
                      <select
                        data-testid={`effort-${member.id}`}
                        value={effort[member.id] ?? ''}
                        onChange={(event) =>
                          setEffort((previous) => ({
                            ...previous,
                            [member.id]: event.target.value,
                          }))
                        }
                        className="mt-1 h-7 w-full rounded-card border border-line bg-surface px-1 text-xs"
                      >
                        <option value="">（无覆盖）</option>
                        <option value="">关闭思考（空串）</option>
                        {thinkingEfforts.map((value) => (
                          <option key={value} value={value}>
                            {value}
                          </option>
                        ))}
                      </select>
                    </label>
                    <button
                      type="button"
                      data-testid={`member-save-${member.id}`}
                      disabled={busy}
                      onClick={() => void saveOverrides(member)}
                      className="rounded-card border border-accent px-2 py-1 text-accent"
                    >
                      保存（重建实例）
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>

          <div className="mt-4 space-y-1 border-t border-line pt-3 text-xs">
            <h2 className="font-semibold uppercase tracking-wide text-muted">加入成员</h2>
            <input
              data-testid="member-name-input"
              value={newName}
              onChange={(event) => setNewName(event.target.value)}
              placeholder="显示名"
              className="h-7 w-full rounded-card border border-line bg-bg px-2"
            />
            <select
              data-testid="member-template-select"
              value={newTemplate}
              onChange={(event) => setNewTemplate(event.target.value)}
              className="h-7 w-full rounded-card border border-line bg-bg px-1"
            >
              {templates.map((template) => (
                <option key={template} value={template}>
                  {template}
                </option>
              ))}
            </select>
            <button
              type="button"
              data-testid="member-add"
              disabled={busy}
              onClick={() => void addMember()}
              className="w-full rounded-card border border-accent px-2 py-1 text-accent disabled:opacity-40"
            >
              加入
            </button>
          </div>
        </aside>

        {/* 公开时间线 */}
        <main className="flex min-w-0 flex-1 flex-col">
          <section className="min-h-0 flex-1 overflow-y-auto px-4 py-3" data-testid="group-timeline">
            <div className="mb-2 flex items-center justify-between gap-2">
              <h2 className="text-xs font-semibold uppercase tracking-wide text-muted">
                公开时间线
              </h2>
              {hasEarlier && (
                <button
                  type="button"
                  data-testid="group-load-earlier"
                  disabled={loadingEarlier}
                  onClick={onLoadEarlier}
                  className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
                >
                  {loadingEarlier ? '正在加载更早的消息…' : '加载更早的消息'}
                </button>
              )}
            </div>
            {timeline.length === 0 && (
              <p className="text-sm text-muted" data-testid="timeline-empty">
                还没有公开消息：选一个发言人开始。
              </p>
            )}
            <ul className="space-y-2">
              {timeline.map((item, index) => (
                <li
                  key={`${item.seq ?? index}-${index}`}
                  data-testid="timeline-item"
                  data-seq={item.seq ?? ''}
                  className="rounded-card border border-line bg-surface px-3 py-2"
                >
                  <div className="text-xs text-muted" data-testid="timeline-author">
                    {item.authorName === null ? '用户' : item.authorName}
                  </div>
                  <div className="whitespace-pre-wrap text-sm">{item.content}</div>
                </li>
              ))}
            </ul>
          </section>

          <div className="border-t border-line px-4 py-2">
            <div className="flex items-center gap-2">
              <label className="flex items-center gap-1 text-xs text-muted">
                发言人
                <select
                  data-testid="speaker-select"
                  value={speaker}
                  onChange={(event) => setSpeaker(event.target.value)}
                  className="h-7 rounded-card border border-line bg-surface px-1 text-xs"
                >
                  <option value="">（未选择）</option>
                  {activeMembers.map((member) => (
                    <option key={member.id} value={member.id}>
                      {member.name}
                    </option>
                  ))}
                </select>
              </label>
              <textarea
                data-testid="group-input"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                placeholder="给点名成员的一句话（可留空：不带文本的点名不写空用户行）"
                className="h-10 min-w-0 flex-1 resize-none rounded-card border border-line bg-surface px-2 py-1 text-sm"
              />
              <button
                type="button"
                data-testid="group-send"
                disabled={busy}
                onClick={() => void send()}
                className="rounded-card bg-accent px-3 py-2 text-sm font-semibold text-bg disabled:opacity-40"
              >
                点名发送
              </button>
            </div>
          </div>
        </main>
      </div>

      {/* 成员私有分栏 */}
      <section className="max-h-72 shrink-0 overflow-y-auto border-t border-line bg-surface px-4 py-2">
        <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
          成员私有分栏（仅该成员可见）
        </h2>
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
          {lanes.map((lane) => {
            const snapshot = snapshots[lane.memberId] ?? null;
            return (
              <article
                key={lane.memberId}
                data-testid={`lane-${lane.memberId}`}
                className="rounded-card border border-line bg-bg/40 p-2"
              >
                <header className="flex items-center justify-between gap-2">
                  <span className="truncate text-sm">
                    {lane.name}
                    {lane.removed && <span className="ml-1 text-warn">（已移除）</span>}
                  </span>
                  <span className="shrink-0 text-xs text-muted">仅该成员可见</span>
                </header>
                <ul className="mt-1 space-y-1">
                  {lane.messages.map((message, index) => (
                    <li
                      key={`${message.id}-${index}`}
                      data-testid="lane-item"
                      data-seq={message.seq ?? ''}
                      className="rounded-card border border-line/60 px-2 py-1 text-xs text-muted"
                    >
                      {message.content.trim().length > 0
                        ? message.content
                        : '（私有过程：思考 / 工具调用）'}
                    </li>
                  ))}
                  {lane.messages.length === 0 && (
                    <li className="text-xs text-muted">（本次已加载页里没有私有行）</li>
                  )}
                </ul>
                <div className="mt-2 flex items-center gap-2">
                  <button
                    type="button"
                    data-testid={`lane-context-${lane.memberId}`}
                    onClick={() =>
                      setRealContextFor((previous) =>
                        previous === lane.memberId ? null : lane.memberId,
                      )
                    }
                    className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
                  >
                    真实上下文
                  </button>
                  {snapshot ? (
                    <span className="text-xs text-muted" data-testid={`lane-window-${lane.memberId}`}>
                      窗口 {snapshot.windowTokens}
                    </span>
                  ) : (
                    <span className="text-xs text-muted" data-testid={`lane-nosnapshot-${lane.memberId}`}>
                      本次运行内没发过言
                    </span>
                  )}
                </div>
                {snapshot?.breakdown ? (
                  <div className="mt-2" data-testid={`lane-ring-${lane.memberId}`}>
                    <ContextRing breakdown={snapshot.breakdown} />
                  </div>
                ) : (
                  <p className="mt-1 text-xs text-warn" data-testid={`lane-noring-${lane.memberId}`}>
                    没有快照或没有占用拆分：环不渲染（不静默当成 0）。
                  </p>
                )}
                {realContextFor === lane.memberId && snapshot && (
                  <RealContextView snapshot={snapshot} />
                )}
                {realContextFor === lane.memberId && !snapshot && (
                  <p className="mt-1 text-xs text-muted" data-testid={`lane-nocontext-${lane.memberId}`}>
                    还没有真实发出的上下文可看（重启后为空是既定语义）。
                  </p>
                )}
              </article>
            );
          })}
        </div>
      </section>
    </div>
  );
}

