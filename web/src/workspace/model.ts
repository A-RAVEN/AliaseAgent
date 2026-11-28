// 工作路径的 web 纯逻辑：显示文案与输入判定（change `custom-workspace` design D8 / D9）。
//
// **单一事实源**：`kDefaultWorkspaceLabel` 同时被 `ChatScreen`（单聊标题旁）与
// `GroupView`（群右栏顶部）引用；用户文档的 `界面文案（web）：` 行也写同一句，
// `src/workspace/model.test.ts` 把三者钉在一起 —— 缺省文案漂移会直接红。
//
// 界面显示的是 `session.list` / `group.list` 返回的**设置值**（`Session.workspace`）；
// `null` = 未设置 ⇒ 显示缺省说明，不是空串、不是错误占位。
export const kDefaultWorkspaceLabel = '缺省（应用主目录）';

/** 显示用文案：`null`（未设置）→ 缺省说明；否则原样显示设置值。 */
export function workspaceLabel(workspace: string | null): string {
  return workspace ?? kDefaultWorkspaceLabel;
}

/**
 * 待提交的目录是否可用：空串 / 纯空白为假。
 *
 * 只判「有没有内容」—— 路径是否绝对、存在、是目录由**核心**校验（浏览器拿不到本机
 * 绝对路径，也做不了真正的目录检查；design D10 / D15）。返工后主要用在文件夹选择框
 * 的确认按钮上：核心若回了一个空 `path`，不许把它当成可提交的当前目录。
 */
export function isWorkspaceSubmissionValid(input: string): boolean {
  return input.trim().length > 0;
}
