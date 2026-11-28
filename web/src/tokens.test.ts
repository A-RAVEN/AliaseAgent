// 设计 tokens 的守卫（change `web-chat-screen` 任务 1.1 / 2.1 / 7.3 的 web 侧）。
//
// 三件事：
//   ① `src/tokens.ts` 与 `src/index.css` 的 `@theme` **逐项一致**（改一处不改另一处
//      会红）——样式与代码不许有两份各自漂移的数字；
//   ② 组件只用 tokens 生成的工具类：`src/components/**` 与 `src/App.tsx` 里
//      禁裸 hex、禁 Tailwind 任意值（`bg-[#...]` / `text-[11px]` 这类）；
//   ③ 五档字阶就是 12/14/16/20/25，没有第六档（design D3）。
//
// 布局/滚动的像素断言不在这一层（jsdom 无布局引擎），见 `e2e/layout.mjs`。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import {
  avatarTints,
  elevation,
  folderPickerHeight,
  kDefaultBottomThresholdPx,
  kDefaultHeartbeatPeriodMs,
  kDefaultHeartbeatTimeoutMs,
  kDefaultReconnectBaseMs,
  kDefaultReconnectCapMs,
  kHeartbeatPeriodEnvKey,
  kHeartbeatTimeoutEnvKey,
  kReconnectBaseEnvKey,
  kReconnectCapEnvKey,
  kBottomThresholdEnvKey,
  lineHeights,
  palette,
  radii,
  readLayoutConfig,
  spacingScale,
  typeScale,
} from './tokens';

const SRC_DIR = path.dirname(fileURLToPath(import.meta.url));
const INDEX_CSS = fs.readFileSync(path.join(SRC_DIR, 'index.css'), 'utf8');

/**
 * 受 token 守卫约束的源文件（change `group-chat-layout` 任务 0.3：扫描范围补
 * `src/group/**` 与 `src/layout/**`，否则 `GroupView` 的裸值不会被抓到）。
 */
function guardedSourceFiles(): string[] {
  return [
    ...listFiles(path.join(SRC_DIR, 'components')),
    ...listFiles(path.join(SRC_DIR, 'group')),
    ...listFiles(path.join(SRC_DIR, 'layout')),
    // change `chat-bubbles-avatars` 1.2：身份图案组件目录也必须被扫到，否则新目录里
    // 写裸 hex / 任意 Tailwind 值时守卫形同虚设。
    ...listFiles(path.join(SRC_DIR, 'avatars')),
    path.join(SRC_DIR, 'App.tsx'),
  ].filter((file) => fs.existsSync(file));
}

function obs(label: string, value: unknown): void {
  console.log(`[tokens] ${label}: ${JSON.stringify(value)}`);
}

function themeValue(name: string): string | null {
  const match = new RegExp(`--${name}:\\s*([^;]+);`).exec(INDEX_CSS);
  return match ? match[1].trim() : null;
}

function listFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return listFiles(full);
    return entry.isFile() && /\.(tsx|ts)$/.test(entry.name) ? [full] : [];
  });
}

describe('设计 tokens 与 CSS @theme 一致', () => {
  it('调色板逐项一致（颜色只此一份）', () => {
    const pairs: [string, string][] = [
      ['color-bg', palette.bg],
      ['color-surface', palette.surface],
      ['color-surface-2', palette.surface2],
      ['color-line', palette.border],
      ['color-muted', palette.muted],
      ['color-fg', palette.text],
      ['color-accent', palette.accent],
      ['color-ok', palette.success],
      ['color-warn', palette.warning],
      ['color-danger', palette.danger],
      // 身份图案三档（change `chat-bubbles-avatars` 1.2）：CSS 侧与代码侧逐项比对。
      ['color-avatar-tint-0', avatarTints[0]],
      ['color-avatar-tint-1', avatarTints[1]],
      ['color-avatar-tint-2', avatarTints[2]],
    ];
    obs('CSS 里声明的调色板', pairs.map(([name]) => themeValue(name)));
    for (const [name, value] of pairs) {
      expect(themeValue(name), `index.css @theme 缺 --${name}`).toBe(value);
    }
    // 第 0 档就是 accent 本身（不写换算值，保持单一事实源）。
    expect(avatarTints[0].toLowerCase()).toBe(palette.accent);
    expect(avatarTints).toHaveLength(3);
  });

  it('字阶与行高逐项一致', () => {
    const scale: [string, number, number][] = [
      ['xs', typeScale.xs, lineHeights.xs],
      ['sm', typeScale.sm, lineHeights.sm],
      ['base', typeScale.base, lineHeights.base],
      ['xl', typeScale.xl, lineHeights.xl],
      ['2xl', typeScale.xxl, lineHeights.xxl],
    ];
    obs('代码字阶', typeScale);
    for (const [name, size, lineHeight] of scale) {
      expect(themeValue(`text-${name}`), `--text-${name}`).toBe(`${size}px`);
      expect(themeValue(`text-${name}--line-height`), `--text-${name}--line-height`).toBe(
        `${lineHeight}px`,
      );
    }
  });

  it('圆角与 elevation 一致', () => {
    expect(themeValue('radius-card')).toBe(`${radii.card}px`);
    expect(themeValue('radius-panel')).toBe(`${radii.panel}px`);
    expect(themeValue('shadow-e1')).toBe(elevation.e1);
    expect(themeValue('shadow-e2')).toBe(elevation.e2);
  });

  // 返工 12.10 / 12.12：用户先实测「界面把屏幕撑满了」，又实测「每次进新文件夹高度都跳变」。
  // 所以高度必须是**固定**的视口占比（`height` 不是 `max-height`），且与 CSS `@theme` 同值；
  // 固定像素会在小窗口上重新接近满屏，max-height 会随子目录数量伸缩 —— 两种都钉死拒绝。
  it('文件夹选择框固定高度 = 70dvh（两处同值、对话框用 h- 固定高度，不是 max-height / 固定像素）', () => {
    obs('folderPickerHeight', folderPickerHeight);
    expect(themeValue('height-folder-picker')).toBe(folderPickerHeight);
    const match = /^(\d+)dvh$/.exec(folderPickerHeight);
    expect(match, '高度必须写成 dvh 视口占比（固定像素在小窗口会重新接近满屏）').not.toBeNull();
    const percent = Number(match?.[1]);
    obs('固定高度（视口百分比）', percent);
    expect(percent).toBeGreaterThanOrEqual(60);
    expect(percent).toBeLessThanOrEqual(80);

    // 固定高度的两个必要条件：CSS 生成 `h-folder-picker`（height），组件真的用它。
    expect(INDEX_CSS, 'CSS 必须用 @utility h-folder-picker 生成 height 工具类').toMatch(
      /@utility h-folder-picker\s*\{/,
    );
    expect(INDEX_CSS, '旧的 max-h-folder-picker 工具类必须撤除（max-height 会随内容伸缩）')
      .not.toContain('max-h-folder-picker');
    const dialog = fs.readFileSync(path.join(SRC_DIR, 'components', 'FolderPickerDialog.tsx'), 'utf8');
    obs('对话框的高度类', {
      fixed: /\sh-folder-picker\s/.test(dialog),
      maxHeight: dialog.includes('max-h-folder-picker'),
    });
    expect(dialog, '对话框必须用 h-folder-picker（固定高度）').toMatch(/\sh-folder-picker\s/);
    expect(dialog, '对话框不得再用 max-h-folder-picker').not.toContain('max-h-folder-picker');
  });

  it('只有五档字阶（没有第六档混进来）', () => {
    const declared = [...INDEX_CSS.matchAll(/--text-([a-z0-9]+):/g)].map((m) => m[1]);
    obs('CSS 声明的字阶名', declared);
    expect(new Set(declared)).toEqual(new Set(['xs', 'sm', 'base', 'xl', '2xl']));
    expect(Object.values(typeScale)).toEqual([12, 14, 16, 20, 25]);
  });
});

describe('组件只用 tokens（禁裸 hex / 任意值）', () => {
  it('组件与 App 里没有裸 hex、没有 Tailwind 任意值', () => {
    const files = guardedSourceFiles();
    obs('扫描的文件', files.map((file) => path.relative(SRC_DIR, file)));
    expect(files.length, 'app 至少要有 App.tsx 与一个组件').toBeGreaterThan(1);
    expect(
      files.some((file) => path.basename(file) === 'GroupView.tsx'),
      '扫描范围必须包含 src/group/GroupView.tsx（群聊主区）',
    ).toBe(true);

    const violations: string[] = [];
    for (const file of files) {
      const source = fs.readFileSync(file, 'utf8');
      const label = path.relative(SRC_DIR, file);
      for (const match of source.matchAll(/#[0-9a-fA-F]{3,8}\b/g)) {
        violations.push(`${label}: 裸 hex ${match[0]}`);
      }
      for (const match of source.matchAll(/\b[a-z][a-z0-9-]*-\[[^\]]*\]/g)) {
        violations.push(`${label}: Tailwind 任意值 ${match[0]}`);
      }
    }
    obs('违规数', violations.length);
    expect(violations, `这些样式必须走 tokens 生成的类：\n${violations.join('\n')}`).toEqual(
      [],
    );
  });

  it('间距类只取 tokens 的 spacing scale（4/8/12/16/24/32/48/64，禁任意值）', () => {
    const allowedPx = new Set<number>(spacingScale);
    const files = guardedSourceFiles();
    const spacingPattern =
      /(?<![\w-])(?:p|px|py|pt|pb|pl|pr|m|mx|my|mt|mb|ml|mr|gap|gap-x|gap-y|space-x|space-y)-([0-9.]+)(?![\w-])/g;
    const violations: string[] = [];
    const used = new Set<string>();
    for (const file of files) {
      const source = fs.readFileSync(file, 'utf8');
      const label = path.relative(SRC_DIR, file);
      for (const match of source.matchAll(spacingPattern)) {
        used.add(match[0]);
        // Tailwind 的间距数值单位是 0.25rem = 4px。
        const px = Number(match[1]) * 4;
        if (px !== 0 && !allowedPx.has(px)) {
          violations.push(`${label}: ${match[0]} = ${px}px 不在 spacing scale 上`);
        }
      }
    }
    obs('用到的间距类', [...used].sort());
    expect(violations, `间距必须取自 spacing scale：\n${violations.join('\n')}`).toEqual([]);
  });
});

describe('可配参数（重连四参数 + 贴底阈值）', () => {
  it('默认值与 design D9/D12 的出处一致', () => {
    obs('默认值', {
      [kBottomThresholdEnvKey]: kDefaultBottomThresholdPx,
      [kReconnectBaseEnvKey]: kDefaultReconnectBaseMs,
      [kReconnectCapEnvKey]: kDefaultReconnectCapMs,
      [kHeartbeatPeriodEnvKey]: kDefaultHeartbeatPeriodMs,
      [kHeartbeatTimeoutEnvKey]: kDefaultHeartbeatTimeoutMs,
    });
    expect(kDefaultBottomThresholdPx).toBe(lineHeights.base);
    expect([
      kDefaultBottomThresholdPx,
      kDefaultReconnectBaseMs,
      kDefaultReconnectCapMs,
      kDefaultHeartbeatPeriodMs,
      kDefaultHeartbeatTimeoutMs,
    ]).toEqual([24, 1000, 30000, 15000, 5000]);
  });

  it('环境变量可覆盖每一项', () => {
    const config = readLayoutConfig({
      [kBottomThresholdEnvKey]: '40',
      [kReconnectBaseEnvKey]: '250',
      [kReconnectCapEnvKey]: '4000',
      [kHeartbeatPeriodEnvKey]: '3000',
      [kHeartbeatTimeoutEnvKey]: '900',
    });
    obs('覆盖后的配置', config);
    expect(config).toEqual({
      bottomThresholdPx: 40,
      reconnectBaseMs: 250,
      reconnectCapMs: 4000,
      heartbeatPeriodMs: 3000,
      heartbeatTimeoutMs: 900,
    });
  });

  it('配错不静默：非正数回退默认值并告警', () => {
    const warnings: string[] = [];
    const config = readLayoutConfig(
      { [kBottomThresholdEnvKey]: 'abc', [kReconnectBaseEnvKey]: '0' },
      (message) => warnings.push(message),
    );
    obs('告警', warnings);
    expect(config.bottomThresholdPx).toBe(kDefaultBottomThresholdPx);
    expect(config.reconnectBaseMs).toBe(kDefaultReconnectBaseMs);
    expect(warnings.length).toBe(2);
  });

  it('cap < base 时 cap 抬到 base 并告警（退避不会越退越短）', () => {
    const warnings: string[] = [];
    const config = readLayoutConfig(
      { [kReconnectBaseEnvKey]: '5000', [kReconnectCapEnvKey]: '1000' },
      (message) => warnings.push(message),
    );
    obs('cap/base', `${config.reconnectCapMs}/${config.reconnectBaseMs}`);
    expect(config.reconnectCapMs).toBe(5000);
    expect(warnings.join('\n')).toContain('cap 抬到 base');
  });
});
