// 应用壳层（change `group-chat-layout` 任务 1.1 / design D1；R.6 主地标）。
//
// 只做布局，不持有数据：左列常驻会话列表、右列主区；管理页（Provider / 模板）
// 以覆盖层挂在**主区**里，绝不覆盖左列。群聊主区与单聊主区互斥渲染，所以页面
// 始终恰好一个 `<main>`：主地标就在壳层（R.6），`ChatScreen` / `GroupView` /
// `GroupLoading` 内部都不再写 `<main>`。
import type { ReactNode } from 'react';

export interface ChatShellProps {
  /** 左侧常驻会话列表（由应用入口渲染 `SessionList`，壳不复制它的状态）。 */
  sidebar: ReactNode;
  /** 侧栏底部槽位（change `chat-bubbles-avatars` 6.3：用户头像块）；必须仍在 aside 内。 */
  sidebarFooter?: ReactNode;
  /** 管理页覆盖层；只盖主区，左列仍可见可点。 */
  overlay?: ReactNode;
  /** 主区：群聊主区或单聊主区。 */
  children: ReactNode;
}

export function ChatShell({ sidebar, sidebarFooter = null, overlay = null, children }: ChatShellProps) {
  return (
    <div className="flex h-full min-h-0 bg-bg text-fg">
      <aside
        data-testid="session-sidebar"
        className="flex w-56 shrink-0 flex-col border-r border-line bg-surface"
      >
        <div className="flex min-h-0 flex-1 flex-col">{sidebar}</div>
        {sidebarFooter}
      </aside>
      <main
        data-testid="main-area"
        className="relative flex min-w-0 flex-1 flex-col"
      >
        {children}
        {overlay ? (
          // `z-40`：管理页必须真的盖住主区（change `global-settings-menu` 发现的既有层级漏洞）——
          // `GroupView` 的 header 是 `relative z-30`，旧值 `z-20` 会让群视图的顶栏画在管理页
          // **上面**（顶部 101px 被盖住，`templates-close` 的命中结果是 `group-kind`）。
          // 旧入口只长在单聊头部（无 z-index），所以这个冲突在本 change 把入口搬到左栏
          // 底部、群视图首次能开管理页之后才暴露出来。
          <div data-testid="panel-overlay" className="absolute inset-0 z-40 bg-bg">
            {overlay}
          </div>
        ) : null}
      </main>
    </div>
  );
}
