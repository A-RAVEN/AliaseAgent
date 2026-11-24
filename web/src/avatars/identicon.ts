// 身份图案（identicon）：FNV-1a 32 位 → 5×5 横向镜像网格 + 三档派生色
// （change `chat-bubbles-avatars` 任务 1.2 / design D1）。
//
// 纯逻辑：只把种子映射成「哈希 / 颜色索引 / 15 个独立格 / 5×5 矩阵」，不碰 DOM、不读
// 文件系统。组件（`components/Avatar.tsx`）只负责按矩阵画 <rect>。
//
// 三条不可动的边界：
//   - 取色必须先转无符号再取模（`(h >>> 0) % 3`）：JS 位运算是有符号 32 位，最高位为 1
//     的种子用 `h % 3` 会得到负数，取到 undefined 让图案掉色；
//   - 填色类名是**固定字面量数组**，MUST NOT 用模板字符串拼接 —— Tailwind 只扫描源码里
//     的字面量类名，拼出来的类会被裁掉、图案变空白；
//   - 种子按原样字符串取（不 trim、不改大小写），保证"同 id 永远同图案"。

/** 左侧 3 列 × 5 行 = 15 个独立格（行优先编号 0..14）。 */
export const IDENTICON_CELL_COUNT = 15;

/** 网格边长（5×5）。 */
export const IDENTICON_GRID_SIZE = 5;

/**
 * 三档填色类名（固定字面量，顺序与 `avatarTints` 一致）。
 *
 * 不要改成 `fill-avatar-tint-${index}`：Tailwind 扫不到拼出来的类名。
 */
export const IDENTICON_FILL_CLASSES = [
  'fill-avatar-tint-0',
  'fill-avatar-tint-1',
  'fill-avatar-tint-2',
] as const;

/**
 * FNV-1a 32 位哈希（公开的通用字符串哈希，确定性、跨平台一致）。
 *
 * 公开测试向量：'' → 0x811C9DC5、'a' → 0xE40C292C、'foobar' → 0xBF9CF968。
 */
export function fnv1a32(seed: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index);
    // Math.imul + >>> 0：32 位乘法且结果保持无符号（普通 * 会丢精度）。
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

export interface IdenticonModel {
  /** 原样种子（不 trim / 不改大小写）。 */
  seed: string;
  /** 无符号 32 位哈希。 */
  hash: number;
  /** 三档颜色索引（0..2）。 */
  colorIndex: number;
  /** 15 个独立格（行优先，左侧 3 列 × 5 行）。 */
  cells: boolean[];
  /** 5×5 完整矩阵（含镜像），供组件逐格画。 */
  grid: boolean[][];
}

/** 种子 → 身份图案模型。空种子按空串处理（固定图案，不抛错）。 */
export function identicon(seed: string): IdenticonModel {
  const hash = fnv1a32(seed);
  const cells = Array.from(
    { length: IDENTICON_CELL_COUNT },
    (_, index) => ((hash >>> index) & 1) === 1,
  );
  const grid: boolean[][] = [];
  for (let row = 0; row < IDENTICON_GRID_SIZE; row += 1) {
    const first = cells[row * 3];
    const second = cells[row * 3 + 1];
    const third = cells[row * 3 + 2];
    // 列 3 = 列 1、列 4 = 列 0（左右镜像）。
    grid.push([first, second, third, second, first]);
  }
  const colorIndex = (hash >>> 0) % IDENTICON_FILL_CLASSES.length;
  return { seed, hash, colorIndex, cells, grid };
}

/** 该图案的填色类名（固定字面量里的一个）。 */
export function identiconFillClass(colorIndex: number): string {
  return IDENTICON_FILL_CLASSES[colorIndex];
}
