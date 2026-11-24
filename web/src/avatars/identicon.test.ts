// 身份图案（identicon）的纯逻辑用例（change `chat-bubbles-avatars` 任务 1.1 / design D1）。
//
// 红靶：模块不存在时 `npm test` 直接失败；实现若用有符号 `%` 取色、忘了镜像、
// 或把 15 个独立格画错位置，都会在这里红。
//
// 为什么 golden 向量写死：图案是「同一个 id 永远同一张脸」的承诺。哈希/取色/取位
// 任何一处改动都会让所有用户换脸，必须由一张写死的表守住，改实现就得同时改表并说明。
import { describe, expect, it } from 'vitest';

import { fnv1a32, identicon, IDENTICON_FILL_CLASSES } from './identicon';

/** 15 个独立格的位串（行优先，b0..b14）——与 design D1 的"掩码"列同口径。 */
function maskOf(model: ReturnType<typeof identicon>): string {
  return model.cells.map((cell) => (cell ? '1' : '0')).join('');
}

describe('fnv1a32：公开测试向量', () => {
  it('空串 / 单字符 / 多字符向量与公开规范一致', () => {
    const vectors: [string, number][] = [
      ['', 0x811c9dc5],
      ['a', 0xe40c292c],
      ['foobar', 0xbf9cf968],
    ];
    for (const [seed, expected] of vectors) {
      const actual = fnv1a32(seed);
      console.log('[fnv1a32]', JSON.stringify(seed), `0x${actual.toString(16).toUpperCase()}`);
      expect(actual, `fnv1a32(${JSON.stringify(seed)})`).toBe(expected);
    }
  });
});

describe('身份图案：seed → (哈希, 颜色索引, 15 位掩码)', () => {
  const goldens: { seed: string; hash: number; colorIndex: number; mask: string }[] = [
    { seed: 'local-user', hash: 0x9d2ccbac, colorIndex: 0, mask: '001101011101001' },
    { seed: 'm-1', hash: 0x273835da, colorIndex: 0, mask: '010110111010110' },
    { seed: 'general', hash: 0x24b9216b, colorIndex: 1, mask: '110101101000010' },
  ];

  it('三组 golden 向量逐项一致（hash / 颜色索引 / 掩码）', () => {
    for (const golden of goldens) {
      const model = identicon(golden.seed);
      console.log(
        '[identicon]',
        golden.seed,
        `hash=0x${model.hash.toString(16).toUpperCase()}`,
        `colorIndex=${model.colorIndex}`,
        `mask=${maskOf(model)}`,
      );
      expect(model.hash, `${golden.seed} 的哈希`).toBe(golden.hash);
      expect(model.colorIndex, `${golden.seed} 的颜色索引`).toBe(golden.colorIndex);
      expect(maskOf(model), `${golden.seed} 的 15 位掩码`).toBe(golden.mask);
      expect(model.cells.length, '左侧 3 列 × 5 行 = 15 个独立格').toBe(15);
    }
  });

  it('同种子连算两次，每一项都相同（确定性）', () => {
    const first = identicon('session-42');
    const second = identicon('session-42');
    console.log('[identicon] 两次结果', maskOf(first), maskOf(second));
    expect(second.hash).toBe(first.hash);
    expect(second.colorIndex).toBe(first.colorIndex);
    expect(maskOf(second)).toBe(maskOf(first));
    expect(second.grid).toEqual(first.grid);
  });

  it('左右镜像：5×5 网格里第 3 列 = 第 1 列、第 4 列 = 第 0 列', () => {
    for (const seed of ['local-user', 'm-1', 'general', '多字节种子']) {
      const { grid } = identicon(seed);
      expect(grid.length, '5 行').toBe(5);
      for (const row of grid) expect(row.length, '5 列').toBe(5);
      for (let row = 0; row < 5; row += 1) {
        expect(grid[row][3], `${seed} 第 ${row} 行第 3 列 = 第 1 列`).toBe(grid[row][1]);
        expect(grid[row][4], `${seed} 第 ${row} 行第 4 列 = 第 0 列`).toBe(grid[row][0]);
      }
    }
  });

  it('换种子变图案：两个不同 id 的掩码不同', () => {
    const a = maskOf(identicon('member-1'));
    const b = maskOf(identicon('member-2'));
    console.log('[identicon] member-1 / member-2', a, b);
    expect(a).not.toBe(b);
  });

  it('空串不抛错，且图案固定（每次都是同一份）', () => {
    let model!: ReturnType<typeof identicon>;
    expect(() => {
      model = identicon('');
    }).not.toThrow();
    expect(maskOf(model)).toBe(maskOf(identicon('')));
    expect(model.colorIndex).toBeGreaterThanOrEqual(0);
    expect(model.colorIndex).toBeLessThanOrEqual(2);
  });

  it('无符号回归：最高位为 1 的种子（local-user）颜色索引仍落在 0..2，不是 -1', () => {
    const model = identicon('local-user');
    console.log('[identicon] local-user 颜色索引', model.colorIndex, 'hash', model.hash);
    // 有符号实现会得到 -1658008660 % 3 === -1，取到 undefined 让图案掉色。
    expect(model.hash).toBeGreaterThan(0x7fffffff);
    expect(model.colorIndex).toBeGreaterThanOrEqual(0);
    expect(model.colorIndex).toBeLessThanOrEqual(2);
  });

  it('填色类名是固定字面量数组（3 档，不拼接）', () => {
    expect(IDENTICON_FILL_CLASSES).toEqual([
      'fill-avatar-tint-0',
      'fill-avatar-tint-1',
      'fill-avatar-tint-2',
    ]);
  });
});
