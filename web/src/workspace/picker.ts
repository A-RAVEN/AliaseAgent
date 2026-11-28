// 文件夹选择对话框的 web 纯逻辑（change `custom-workspace` 返工任务 12.4 / 12.11 / 12.13）。
//
// 用户明令「不喜欢手输路径」时切换工作路径 = 弹框**点选**目录；返工 12.13 用户又明确要
// 「像 Windows 资源管理器的地址栏」，于是浏览与可编辑地址栏并存：目录列表仍由核心的
// `workspace.listDirs` 提供，地址栏只把用户输入的文本原样交给核心校验。这一层只做不需要
// RPC 的几件事：
//
//   - `pickerStartPath`：会话 / 群的工作路径 → 对话框起点；`null` / 空白 ⇒ `null`
//     （请求里**省略** `path`，起点由核心取应用主目录 —— 浏览器不猜）；
//   - `parentPath`：上一级目录；Windows 盘符根的上一级是「此电脑」虚拟根（返工 12.11
//     多盘可达）；POSIX 根 / UNC 共享根返回 `null`；
//   - `pathCrumbs`：面包屑逐段 `{label, path}`，分隔符风格沿用输入；Windows 面包屑
//     顶层是「此电脑」（`@drives`）；
//   - `pickerDisplayPath`：地址栏 / 面包屑的显示文案（虚拟根用「此电脑」）；
//   - `normalizeAddressInput`：地址栏文本去空白 / 去掉外层引号，空 ⇒ `null`。
//
// 组件不自己拼路径：进入子目录用核心回的 `directories[].path`，面包屑用这里的 path，
// 「上级」用核心回的 `parent`。
export interface WorkspaceDirEntry {
  name: string;
  path: string;
}

/** `workspace.listDirs` 的回包形状（核心侧 `WorkspaceDirListing.toJson` 的镜像）。 */
export interface WorkspaceDirsResult {
  path: string;
  parent: string | null;
  directories: WorkspaceDirEntry[];
  exists: boolean;
  /** `false` = 「此电脑」虚拟根，不是真实目录（确认按钮必须禁用）。 */
  isDirectory: boolean;
}

/** 面包屑的一段：`label` 显示，`path` 是点击后要列举的绝对路径。 */
export interface PathCrumb {
  label: string;
  path: string;
}

/**
 * 「此电脑」虚拟根 sentinel（与核心 `kWorkspaceDrivesRoot` 逐字一致）。
 *
 * Windows 上 `workspace.listDirs('@drives')` 返回各逻辑盘；盘符根的 `parent` 也是它。
 * POSIX 没有这一层（核心会可归因拒绝）。
 */
export const kDrivesRoot = '@drives';
export const kDrivesRootLabel = '此电脑';

/**
 * 框内地址栏 / 面包屑要显示的路径文案（返工任务 12.13）：虚拟根「此电脑」用友好名，
 * 其它路径原样，`null` / 空串 ⇒ 空串。
 *
 * 地址栏的 `value` 与「当前显示的文件夹」都由它派生，两处不会出现两种写法。
 */
export function pickerDisplayPath(path: string | null): string {
  if (path === null || path.length === 0) return '';
  return path === kDrivesRoot ? kDrivesRootLabel : path;
}

/**
 * 地址栏文本 → 要交给 `workspace.listDirs` 校验的路径（返工任务 12.13）。
 *
 * - 去首尾空白；
 * - 去掉 Windows「复制为路径」自动加的一对**外层**双引号（`"C:\work"` ⇒ `C:\work`）；
 * - 空 / 只有空白 ⇒ `null`（调用方就地提示，不发 RPC）。
 *
 * 不做别的规范化：分隔符风格 / 大小写 / 尾斜杠 / 相对路径原样交给核心判定 ——
 * 前端不猜路径，合法性只有核心说了算（与 `pickerStartPath` 同一口径）。
 */
export function normalizeAddressInput(raw: string): string | null {
  let value = raw.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.slice(1, -1).trim();
  }
  return value.length === 0 ? null : value;
}

const kWindowsDriveRoot = /^[A-Za-z]:[\\/]*$/;
const kUncRoot = /^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]*$/;
const kUncServerOnly = /^[\\/]{2}[^\\/]+[\\/]*$/;

/** 去掉尾部分隔符（`C:\` 去掉后会变成 `C:`，所以根判断用原始 path）。 */
function stripTrailingSeparators(path: string): string {
  return path.replace(/[\\/]+$/, '');
}

/**
 * 对话框起点：工作路径设置值原样（去首尾空白），未设置 ⇒ `null`。
 *
 * 返回 `null` 时请求里 MUST 省略 `path` —— 起点由核心取应用主目录，前端不发明第二个
 * 缺省（与 `session.list` 的 `workspace = null` 同一口径）。
 */
export function pickerStartPath(workspace: string | null): string | null {
  if (workspace === null) return null;
  const trimmed = workspace.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/** `workspace.listDirs` 的请求参数：`null` ⇒ 省略 `path`。 */
export function workspaceDirsParams(path: string | null): Record<string, unknown> {
  return path === null ? {} : { path };
}

/** 上一级绝对路径；盘符根到「此电脑」；POSIX / UNC 根 / 无法再向上 ⇒ `null`。 */
export function parentPath(path: string): string | null {
  if (path.length === 0) return null;
  // 「此电脑」虚拟根再往上没有层。
  if (path === kDrivesRoot) return null;
  const trimmed = stripTrailingSeparators(path);
  if (trimmed.length === 0) return null;
  if (kWindowsDriveRoot.test(path)) {
    // 返工 12.11：`C:\` / `C:/` 的上一级是「此电脑」；`C:`（盘符相对路径）没有上级。
    return /^[A-Za-z]:[\\/]/.test(path) ? kDrivesRoot : null;
  }
  if (kUncRoot.test(path) || kUncServerOnly.test(path)) return null;
  const index = Math.max(trimmed.lastIndexOf('\\'), trimmed.lastIndexOf('/'));
  if (index < 0) return null;
  const candidate = trimmed.slice(0, index);
  // POSIX 一级目录（`/home`）的上一级是根 `/`。
  if (candidate.length === 0) return '/';
  // 盘符根（`C:`）保留一个分隔符 → `C:\` / `C:/`（沿用输入的分隔符风格）。
  if (/^[A-Za-z]:$/.test(candidate)) return `${candidate}${trimmed[index]}`;
  return candidate;
}

/** 面包屑的一段 label：盘符根给 `C:`、POSIX 根给 `/`、UNC 根给完整共享路径。 */
function crumbLabel(path: string): string {
  if (path === kDrivesRoot) return kDrivesRootLabel;
  const trimmed = stripTrailingSeparators(path);
  if (trimmed.length === 0) return path;
  if (kWindowsDriveRoot.test(path)) return trimmed;
  if (kUncRoot.test(path) || kUncServerOnly.test(path)) return trimmed;
  const index = Math.max(trimmed.lastIndexOf('\\'), trimmed.lastIndexOf('/'));
  return index < 0 ? trimmed : trimmed.slice(index + 1);
}

/** 面包屑（根 → 当前目录），每段都带可点击的绝对路径。 */
export function pathCrumbs(path: string): PathCrumb[] {
  const crumbs: PathCrumb[] = [];
  let current: string | null = path.length === 0 ? null : path;
  while (current !== null && current.length > 0) {
    crumbs.push({ label: crumbLabel(current), path: current });
    current = parentPath(current);
  }
  return crumbs.reverse();
}
