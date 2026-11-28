// 文件夹选择对话框（change `custom-workspace` 返工任务 12.6 / 12.12 / 12.13）。
//
// 用户原话（12.6）：「我不喜欢手动输入路径，手动输入可能会输入错，帮我加返工任务改成弹个
// 路径选择框」。所以主交互是**点选**：打开时列举子目录，点子文件夹进入下一层、点面包屑
// 跳回上层、「上级」回退、「选择此目录」确认、「取消」不发写请求。
//
// 返工 12.13 用户又明确要「一个路径输入框，和一个真正的 windows 文件浏览器一样，路径输入
// 和显示的文件夹对应」—— 于是**浏览 + 可编辑地址栏并存**：地址栏 input 显示当前文件夹，
// 浏览（点目录 / 上级 / 面包屑）后跟着同步；用户改完按 Enter（或「跳转」）把文本交给核心
// 的 `workspace.listDirs` 校验：合法 ⇒ 导航到该目录；非法 ⇒ 框内就地报错、不跳、地址栏
// 回到当前文件夹（保持「输入框 = 显示的文件夹」）。地址栏不是唯一入口，点选仍是主路径。
//
// 返工 12.12 用户原话：「窗口高度现在不固定，每次进新窗口高度都会跳变」。框用**固定高度**
// `h-folder-picker`（70dvh），不是 max-height —— 子目录多少都同高，列表在框内滚动。
//
// 浏览器拿不到本机绝对路径（`<input type=file webkitdirectory>` 只给相对名，
// `showDirectoryPicker()` 只给目录句柄），所以目录列表由核心的 `workspace.listDirs`
// 提供 —— 这是**应用内**的文件夹对话框，不是系统对话框。
//
// 组件是纯展示 + 动作：不连 WS、不拼路径（子目录用核心回的 `directories[].path`，
// 上级用核心回的 `parent`，地址栏文本原样交给核心校验）。层级用 `z-50`：必须盖住群视图
// 顶栏（`z-30`）与管理页覆盖层（`panel-overlay` 的 `z-40`），见返工任务 12.5 ⑤ 的层级断言。
import { useCallback, useEffect, useRef, useState } from 'react';

import {
  kDrivesRoot,
  normalizeAddressInput,
  pathCrumbs,
  pickerDisplayPath,
  type WorkspaceDirsResult,
} from '../workspace/picker';
import { isWorkspaceSubmissionValid } from '../workspace/model';

export interface FolderPickerDialogProps {
  /** 对话框标题（单聊 / 群各一句，见用户文档的 `界面文案（web）`）。 */
  title: string;
  /** 起点；`null` = 省略 `path`，起点由核心取应用主目录。 */
  initialPath: string | null;
  /** 列举一层子目录（注入 RPC：`workspace.listDirs`）。 */
  listDirs: (path: string | null) => Promise<WorkspaceDirsResult>;
  /**
   * 确认选择当前目录。
   *
   * 返回 `null` = 成功（组件自行关闭）；返回字符串 = 可显示的失败原因
   * （**不关框**、就地显示、已保存路径不变）。
   */
  onConfirm: (path: string) => Promise<string | null>;
  /** 取消 / Escape / 点背景。 */
  onClose: () => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function FolderPickerDialog({
  title,
  initialPath,
  listDirs,
  onConfirm,
  onClose,
}: FolderPickerDialogProps) {
  const [listing, setListing] = useState<WorkspaceDirsResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [confirmError, setConfirmError] = useState<string | null>(null);
  // 地址栏文本：默认 = 当前显示的文件夹（`pickerDisplayPath`）；用户可编辑，Enter / 「跳转」
  // 才交给核心校验（返工 12.13）。
  const [address, setAddress] = useState('');
  const dialogRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  // 请求序号：连点几个目录时只认最后一次的回包（晚到的旧目录不覆盖新当前目录）。
  const requestSeq = useRef(0);
  // 注入函数 / 关闭回调每帧都会换身份：用 ref 取最新值，避免 effect 反复重订阅。
  const listDirsRef = useRef(listDirs);
  listDirsRef.current = listDirs;
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  // 确认中标志的 ref 版本：Escape 监听器只在挂载时注册一次，要靠 ref 读最新值。
  const confirmingRef = useRef(false);
  confirmingRef.current = confirming;

  const load = useCallback(async (path: string | null): Promise<'ok' | 'failed' | 'stale'> => {
    const seq = requestSeq.current + 1;
    requestSeq.current = seq;
    setLoading(true);
    setLoadError(null);
    // 换了目录：上一个目录的确认失败原因不再适用（不把旧错挂到新目录上）。
    setConfirmError(null);
    try {
      const result = await listDirsRef.current(path);
      if (requestSeq.current !== seq) return 'stale';
      setListing(result);
      return 'ok';
    } catch (error) {
      if (requestSeq.current !== seq) return 'stale';
      // 就地可归因：保留当前已读到的目录，只报告这次列举失败。
      setLoadError(`读取目录失败：${errorText(error)}`);
      return 'failed';
    } finally {
      if (requestSeq.current === seq) setLoading(false);
    }
  }, []);

  // 地址栏 = 当前显示的文件夹：listing 一变（点目录 / 上级 / 面包屑 / 跳转成功）就同步，
  // 浏览与输入两处永远显示同一路径（返工 12.13）。
  const displayPath = pickerDisplayPath(listing?.path ?? null);
  useEffect(() => {
    setAddress(displayPath);
  }, [displayPath]);

  // 地址栏跳转：合法 ⇒ 导航；非法 ⇒ 框内报错、不跳、地址栏回到当前文件夹。
  const jumpToAddress = async () => {
    if (confirming || loading) return;
    const target = normalizeAddressInput(address);
    if (target === null) {
      setLoadError('请输入一个目录路径');
      inputRef.current?.focus();
      return;
    }
    setLoadError(null);
    const outcome = await load(target);
    if (outcome !== 'failed') return;
    // 非法路径不改变当前浏览：地址栏恢复成当前文件夹（错误文本里已含用户输入的路径与原因，
    // 信息不会丢），并全选旧文本方便直接重打。
    setAddress(displayPath);
    requestAnimationFrame(() => {
      inputRef.current?.focus();
      inputRef.current?.select();
    });
  };

  useEffect(() => {
    void load(initialPath);
  }, [load, initialPath]);

  // 打开即聚焦对话框；Escape 关闭（确认中不关，避免半途丢失正在提交的结果）。
  useEffect(() => {
    dialogRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      if (confirmingRef.current) return;
      onCloseRef.current();
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, []);

  const confirm = async () => {
    // `isDirectory=false` 只出现在「此电脑」虚拟根：它不是真实目录，不能被选成工作路径。
    if (listing === null || !listing.isDirectory || loading || confirming) return;
    // 核心若回了空 `path`（不该发生），不许把它当成"选好了"：就地说明、不发写请求。
    if (!isWorkspaceSubmissionValid(listing.path)) {
      setConfirmError('当前目录不可用：请换一个目录再试');
      return;
    }
    setConfirming(true);
    setConfirmError(null);
    let failure: string | null;
    try {
      failure = await onConfirm(listing.path);
    } catch (error) {
      // 宿主没接住的异常也变成框内可归因文本（不炸页面、不静默关框）。
      failure = `保存工作路径失败：${errorText(error)}`;
    }
    setConfirming(false);
    if (failure === null) {
      onCloseRef.current();
      return;
    }
    setConfirmError(failure);
  };

  const crumbs = listing === null ? [] : pathCrumbs(listing.path);
  const entries = listing?.directories ?? [];
  const parent = listing?.parent ?? null;
  const canGoUp = parent !== null && !loading;
  // 返工 12.11：「此电脑」虚拟根显示友好名称；它不是真实目录（isDirectory=false），
  // 确认按钮必须禁用并给出可读原因。
  const atDrivesRoot = listing?.path === kDrivesRoot;
  const canConfirm =
    listing !== null &&
    listing.isDirectory &&
    !loading &&
    !confirming &&
    isWorkspaceSubmissionValid(listing.path);

  return (
    <div
      data-testid="folder-picker"
      role="presentation"
      onClick={(event) => {
        // 只有点在背景（不是对话框内容）上才关；确认中不关。
        if (event.target !== event.currentTarget || confirming) return;
        onCloseRef.current();
      }}
      className="fixed inset-0 z-50 flex items-center justify-center bg-bg/60 p-4"
    >
      <div
        ref={dialogRef}
        data-testid="folder-picker-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
        className="flex h-folder-picker w-full max-w-xl flex-col gap-3 rounded-panel border border-line bg-surface p-4 text-fg shadow-e2"
      >
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 data-testid="folder-picker-title" className="text-sm font-semibold">
            {title}
          </h2>
          <p className="text-xs text-muted">
            {atDrivesRoot
              ? '点磁盘进入，选好后点「选择此目录」'
              : '点文件夹进入，选好后点「选择此目录」'}
          </p>
        </div>

        {/* 面包屑：每段都能点回去（根 → 当前目录）。 */}
        <nav
          aria-label="当前目录"
          className="flex min-w-0 flex-wrap items-center gap-1 text-xs"
          data-testid="folder-picker-crumbs"
        >
          {crumbs.map((crumb, index) => (
            <span key={crumb.path} className="flex min-w-0 items-center gap-1">
              {index > 0 && (
                <span aria-hidden="true" className="text-muted">
                  ›
                </span>
              )}
              <button
                type="button"
                data-testid="folder-picker-crumb"
                data-path={crumb.path}
                onClick={() => void load(crumb.path)}
                className="max-w-xs truncate rounded-card px-1 py-1 text-muted hover:text-fg"
              >
                {crumb.label}
              </button>
            </span>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="folder-picker-up"
            disabled={!canGoUp}
            onClick={() => {
              if (parent !== null) void load(parent);
            }}
            className="min-h-6 shrink-0 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
          >
            上级
          </button>
          <input
            ref={inputRef}
            data-testid="folder-picker-path"
            aria-label="路径"
            title={displayPath}
            value={address}
            onChange={(event) => setAddress(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== 'Enter') return;
              event.preventDefault();
              void jumpToAddress();
            }}
            spellCheck={false}
            autoComplete="off"
            className="min-h-6 min-w-0 flex-1 rounded-card border border-line bg-bg/40 px-2 py-1 text-xs text-fg focus:border-accent"
          />
          <button
            type="button"
            data-testid="folder-picker-go"
            disabled={confirming || loading}
            title="跳到地址栏输入的目录"
            onClick={() => void jumpToAddress()}
            className="min-h-6 shrink-0 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg disabled:opacity-40"
          >
            跳转
          </button>
        </div>

        <div
          data-testid="folder-picker-list"
          className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto rounded-card border border-line bg-bg/40 p-2"
        >
          {loading && (
            <p data-testid="folder-picker-loading" className="text-xs text-muted">
              正在读取目录…
            </p>
          )}
          {!loading && loadError !== null && (
            <p data-testid="folder-picker-load-error" className="text-xs text-danger">
              {loadError}
            </p>
          )}
          {!loading && loadError === null && entries.length === 0 && (
            <p data-testid="folder-picker-empty" className="text-xs text-muted">
              这个目录下没有子文件夹（仍然可以选择它本身）
            </p>
          )}
          {!loading &&
            entries.map((entry) => (
              <button
                key={entry.path}
                type="button"
                data-testid="folder-picker-entry"
                data-path={entry.path}
                data-name={entry.name}
                title={entry.path}
                onClick={() => void load(entry.path)}
                className="flex w-full items-center justify-between gap-2 rounded-card px-2 py-1 text-left text-sm text-fg hover:bg-surface-2"
              >
                <span className="min-w-0 truncate">{entry.name}</span>
                <span aria-hidden="true" className="text-xs text-muted">
                  ›
                </span>
              </button>
            ))}
        </div>

        {atDrivesRoot && (
          <p data-testid="folder-picker-drives-hint" className="text-xs text-muted">
            「此电脑」不是目录：请先进入一个磁盘，再点「选择此目录」。
          </p>
        )}

        {confirmError !== null && (
          <p data-testid="folder-picker-error" className="text-xs text-danger">
            {confirmError}
          </p>
        )}

        <div className="flex items-center justify-end gap-2">
          <button
            type="button"
            data-testid="folder-picker-cancel"
            onClick={() => onCloseRef.current()}
            className="min-h-6 rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
          >
            取消
          </button>
          <button
            type="button"
            data-testid="folder-picker-confirm"
            disabled={!canConfirm}
            title={atDrivesRoot ? '「此电脑」不是目录：请先进入一个磁盘' : undefined}
            onClick={() => void confirm()}
            className="min-h-6 rounded-card border border-accent px-2 py-1 text-xs text-accent disabled:opacity-40"
          >
            {confirming ? '正在保存…' : '选择此目录'}
          </button>
        </div>
      </div>
    </div>
  );
}
