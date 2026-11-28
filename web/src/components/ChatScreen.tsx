// 聊天屏（change `web-chat-screen`：把最小验证页扩成完整聊天屏）。
//
// 这里是**纯展示容器**：数据（ChatView / 会话 / 快照 / 计量）全部由 App（或测试
// harness）注入，组件自己不连 WS、不查库。这样 puppeteer 能在无核心的情况下驱动
// 同一份组件量布局（design D13）。
//
// change `group-chat-layout` D1：会话列表的宿主上提到 `ChatShell`，本组件瘦身为
// **纯主区**（header + 提示条 + 消息视图 + 快照 + 发送区）。它保留 error / notice /
// skillFailures 三条横幅；列表与选中状态不再由它持有。
//
// change `global-settings-menu` D6：管理入口收归壳层左栏底部的全局设置菜单 ——
// 本组件头部只承载身份与状态信息（标题 / token 计量 / 连接状态），不再有
// Provider / 模板按钮，也不再收 `onOpenProviders` / `onOpenTemplates` 两个回调。
//
// change `custom-workspace` D8：标题旁显示**当前会话的工作路径**；返工任务 12.6 把
// 「就地手输」换成「文件夹选择对话框」——用户明令不喜欢手输（会打错字），所以切换是
// 点选目录：点「切换」→ `FolderPickerDialog` → 核心的 `workspace.listDirs` 列子目录 →
// 「选择此目录」走 `onSetWorkspace`。组件仍是纯展示容器：路径与动作全由 App 注入，
// 不传回调时不渲染该控件（既有注入式挂架与别的宿主不受影响）。
import { useMemo, useState } from 'react';

import type { ChatView } from '../chat/model';
import type { PendingImage } from '../chat/attachments';
import { renderMessages } from '../chat/render';
import type { ConnectionStatus, SnapshotEventData } from '../protocol';
import { pickerStartPath, type WorkspaceDirsResult } from '../workspace/picker';
import { workspaceLabel } from '../workspace/model';
import type { AvatarData } from './Avatar';
import { Composer } from './Composer';
import { ConnectionBadge } from './ConnectionBadge';
import { ContextRing } from './ContextRing';
import { FolderPickerDialog } from './FolderPickerDialog';
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
  /** 单聊用户 / agent 头像（change `chat-bubbles-avatars` 4.4；App 层算好，组件不持 client）。 */
  userAvatar?: AvatarData;
  agentAvatar?: AvatarData;
  /** 当前会话的工作路径设置值（null = 未设置、用缺省主目录）。 */
  workspace?: string | null;
  /**
   * 保存工作路径（App 注入 RPC；返回 null = 成功，字符串 = 可显示的失败原因）。
   *
   * **不传就不渲染**该控件：既有注入式挂架与别的宿主不受影响（change
   * `custom-workspace` design D8）。
   */
  onSetWorkspace?: (path: string) => Promise<string | null>;
  /**
   * 列举一层子目录（App 注入 `workspace.listDirs`；`null` = 省略 `path`，起点由核心给）。
   *
   * 与 [onSetWorkspace] 同时注入才渲染切换控件（返工任务 12.6：只看不选没有意义）。
   */
  onListWorkspaceDirs?: (path: string | null) => Promise<WorkspaceDirsResult>;
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
  userAvatar,
  agentAvatar,
  workspace = null,
  onSetWorkspace,
  onListWorkspaceDirs,
}: ChatScreenProps) {
  const items = useMemo(() => renderMessages(view), [view]);
  const [showRealContext, setShowRealContext] = useState(false);
  const currentTitle = sessionSelected ? (sessionTitle ?? '（未选择会话）') : '（未选择会话）';
  // 文件夹选择对话框的开关（返工任务 12.6）：只属本组件，不上升。
  const [pickerOpen, setPickerOpen] = useState(false);
  // 空选中 / 未注入回调时不渲染该控件（群聊主区根本不渲染本组件）。
  const showWorkspace =
    onSetWorkspace !== undefined && onListWorkspaceDirs !== undefined && sessionSelected;

  const saveWorkspace = async (path: string): Promise<string | null> => {
    if (onSetWorkspace === undefined) {
      return '没有注入保存回调：工作路径未改动';
    }
    return onSetWorkspace(path);
  };

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
          {/* 工作路径（change `custom-workspace` D8 / 返工 12.6）：标题旁一行，单行截断
              + title 全文；「切换」弹文件夹选择对话框（不手输）。 */}
          {showWorkspace && (
            <div className="mt-1 flex min-w-0 items-center gap-2 text-xs text-muted">
              <span className="shrink-0">工作路径</span>
              <span
                className="min-w-0 max-w-sm truncate"
                data-testid="workspace-path"
                title={workspaceLabel(workspace)}
              >
                {workspaceLabel(workspace)}
              </span>
              <button
                type="button"
                data-testid="workspace-edit"
                onClick={() => setPickerOpen(true)}
                className="shrink-0 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
              >
                切换
              </button>
            </div>
          )}
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
          userAvatar={userAvatar}
          agentAvatar={agentAvatar}
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

      {/* 文件夹选择对话框（返工 12.6）：模态、盖住主区（z-50 > 群顶栏 z-30 /
          管理页覆盖层 z-40）；确认后由 App 走 `session.setWorkspace`。 */}
      {showWorkspace && pickerOpen && onListWorkspaceDirs !== undefined && (
        <FolderPickerDialog
          title="选择工作路径（单聊）"
          initialPath={pickerStartPath(workspace)}
          listDirs={onListWorkspaceDirs}
          onConfirm={saveWorkspace}
          onClose={() => setPickerOpen(false)}
        />
      )}
    </div>
  );
}
