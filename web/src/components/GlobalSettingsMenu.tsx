// 全局设置菜单（change `global-settings-menu` 任务 3.1 / design D1~D8）。
//
// 左栏底部（用户头像块**之上**）唯一的管理入口：一个「设置」按钮，点开在按钮**上方**
// 浮出一张圆角菜单，菜单**恰好两项**「Provider 配置 / 模板配置」，分别打开既有的
// `ProvidersPage` / `TemplatesPage` 覆盖层（复用 `App` 的 `panel` 状态，不新写管理屏）。
//
// 为什么在左栏底部：左栏（`ChatShell` 的 `<aside>`）在单聊 / 群聊 / 空选中下都常驻，
// 管理页覆盖层只挂在 `<main>` 里 —— 所以这个入口与主区类型无关，群视图也能开管理页
// （修掉旧设计「管理入口长在单聊头部、群视图没有入口」）。
//
// 组件只做展示与开合：不连 WS、不持 client、不发 RPC（与 `UserAvatarBlock` 同一分工）。
// 菜单开合状态留在组件内（design D8）；菜单项写死两项，不做配置化（D4，防"悄悄多一项"）。
// 几何与颜色只取 tokens 生成的类名（`spacingScale` / `radii` / `elevation`）；
// 裸 hex 与 Tailwind 任意值会被 `src/tokens.test.ts` 抓红。
import { useEffect, useRef, useState } from 'react';
import { FileText, Server, Settings } from 'lucide-react';

export interface GlobalSettingsMenuProps {
  /** 打开 Provider 管理页（`App` 的 `setPanel('providers')`）。 */
  onOpenProviders: () => void;
  /** 打开模板管理页（`App` 的 `setPanel('templates')`）。 */
  onOpenTemplates: () => void;
}

/**
 * 菜单条目（design D4：**写死两项**，`as const` 保证不会被运行期改写）。
 *
 * 标签逐字为「Provider 配置」「模板配置」；`testId` 固定，e2e 以「`role="menuitem"`
 * 恰好 2 项 + 标签逐字」钉住"不许加第三项"。
 */
const menuItems = [
  {
    id: 'providers',
    label: 'Provider 配置',
    testId: 'global-settings-item-providers',
    icon: Server,
  },
  {
    id: 'templates',
    label: '模板配置',
    testId: 'global-settings-item-templates',
    icon: FileText,
  },
] as const;

export function GlobalSettingsMenu({
  onOpenProviders,
  onOpenTemplates,
}: GlobalSettingsMenuProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);

  // 打开期间才有意义：点菜单外（pointerdown 不在本组件容器内）关闭；`Escape` 关闭并把
  // 焦点还给按钮（design D7）。窄范围 + 精确移除，避免把监听器留给后续界面。
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      const container = containerRef.current;
      if (container === null) return;
      if (event.target instanceof Node && container.contains(event.target)) return;
      setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      setOpen(false);
      buttonRef.current?.focus();
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  /** 点条目：**先关菜单再回调**（否则管理页打开后菜单还浮着，design D7）。 */
  const pick = (id: 'providers' | 'templates') => {
    setOpen(false);
    if (id === 'providers') onOpenProviders();
    else onOpenTemplates();
  };

  return (
    // `relative` 是菜单向上定位的锚点；`border-t` 与用户头像块同一 footer 区。
    <div ref={containerRef} className="relative border-t border-line p-2">
      <button
        ref={buttonRef}
        type="button"
        data-testid="global-settings-button"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((previous) => !previous)}
        className="flex min-h-6 w-full items-center gap-2 rounded-card px-2 py-1 text-sm text-muted hover:bg-surface-2 hover:text-fg"
      >
        <Settings size={16} aria-hidden="true" />
        设置
      </button>
      {open && (
        <div
          data-testid="global-settings-menu"
          role="menu"
          aria-label="全局设置"
          className="absolute bottom-full left-2 right-2 z-30 mb-1 rounded-panel border border-line bg-surface p-1 shadow-e2"
        >
          {menuItems.map((item) => (
            <button
              key={item.id}
              type="button"
              role="menuitem"
              data-testid={item.testId}
              onClick={() => pick(item.id)}
              className="flex w-full items-center gap-2 rounded-card px-2 py-1 text-left text-sm text-fg hover:bg-surface-2"
            >
              <item.icon size={16} aria-hidden="true" />
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
