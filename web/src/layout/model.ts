// 应用壳层的主区判定与会话类型文案（change `group-chat-layout` 任务 0.1 / design D2）。
//
// 纯函数：壳层（`ChatShell`）按 `workspaceMode` 切主区；会话列表与详情共用
// `sessionKindLabel` / `sessionKindBadge`，避免两处各写一套类型文案。
import type { Session } from '../protocol';

/** 主区三态：群聊 / 单聊（含空聊天屏）/ 无选中。 */
export type WorkspaceMode = 'group' | 'chat' | 'empty';

/**
 * 选中会话 → 主区类型。
 *
 * `null` / `undefined`（删到最后一条、首屏还没选）⇒ `empty`：主区仍是聊天屏，
 * 但必须是空聊天屏（标题「（未选择会话）」、输入禁用、不残留上一条会话的内容）。
 * 运行时的未知 `kind` 按单聊处理（防御脏值，不制造第三种页面）。
 */
export function workspaceMode(
  session: Pick<Session, 'kind'> | null | undefined,
): WorkspaceMode {
  if (!session) return 'empty';
  return session.kind === 'group' ? 'group' : 'chat';
}

/** 完整类型名（行标题 / 无障碍文案用）。 */
export function sessionKindLabel(session: Pick<Session, 'kind'>): '群聊' | '单聊' {
  return session.kind === 'group' ? '群聊' : '单聊';
}

/** 列表行的小标记：只给群聊行返回「群」，单聊不显示标记（224px 的行里省宽度）。 */
export function sessionKindBadge(session: Pick<Session, 'kind'>): '群' | null {
  return session.kind === 'group' ? '群' : null;
}
