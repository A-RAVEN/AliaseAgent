// 文件夹选择对话框的纯逻辑（change `custom-workspace` 返工任务 12.3）。
//
// 只测三件可判定的事：
//   - `pickerStartPath`：会话 / 群的工作路径就是对话框起点；`null` / 空白 ⇒ 省略 `path`
//     （起点由核心取应用主目录，浏览器不该猜）；
//   - `parentPath`：上一级目录；Windows 盘符根的上一级是「此电脑」虚拟根（返工 12.11：
//     多盘可达），POSIX 根 / UNC 共享根返回 `null`（**不许**把根目录的上级拼成它自己 ——
//     那会让「上级」按钮永远可点、点一下原地打转）；
//   - `pathCrumbs`：面包屑逐段 `{label, path}`，分隔符风格沿用输入（Windows `\` /
//     POSIX `/` / UNC `\\server\share`）；Windows 面包屑顶层是「此电脑」。
//
// 断言钉到**每段的 label 与 path**，不是数组长度：把 `C:\work\alpha` 拼成
// `C:\work\alpha\alpha` 这类错误必须在这里红。
import { describe, expect, it } from 'vitest';

import {
  kDrivesRoot,
  kDrivesRootLabel,
  normalizeAddressInput,
  parentPath,
  pathCrumbs,
  pickerDisplayPath,
  pickerStartPath,
  workspaceDirsParams,
} from './picker';

function obs(label: string, value: unknown): void {
  console.log(`[picker] ${label}: ${JSON.stringify(value)}`);
}

describe('pickerStartPath：工作路径 = 对话框起点', () => {
  it('null / 空串 / 纯空白 ⇒ null（省略 path，起点由核心取主目录）', () => {
    obs('null', pickerStartPath(null));
    obs('空串', pickerStartPath(''));
    obs('纯空白', pickerStartPath('   \t  '));
    expect(pickerStartPath(null)).toBeNull();
    expect(pickerStartPath('')).toBeNull();
    expect(pickerStartPath('   \t  ')).toBeNull();
  });

  it('非空路径去首尾空白后原样返回（不改写分隔符 / 不做二次规范化）', () => {
    for (const path of [String.raw`C:\work\项目 A`, '/home/user/project']) {
      obs(`起点 ${path}`, pickerStartPath(path));
      expect(pickerStartPath(path)).toBe(path);
    }
    expect(pickerStartPath('  /home/user  ')).toBe('/home/user');
  });
});

describe('workspaceDirsParams：未设置时省略 path（起点由核心取主目录）', () => {
  it('null ⇒ 空参数对象；有值 ⇒ {path}', () => {
    obs('null 的参数', workspaceDirsParams(null));
    obs('有值的参数', workspaceDirsParams(String.raw`C:\work`));
    expect(workspaceDirsParams(null)).toEqual({});
    expect(workspaceDirsParams(String.raw`C:\work`)).toEqual({ path: String.raw`C:\work` });
    // 省略 path 与传空串是两件事：空串会被核心当成「省略」，但契约上只发 `{}`。
    expect('path' in workspaceDirsParams(null)).toBe(false);
  });
});

describe('parentPath：上一级；盘符根到「此电脑」', () => {
  it('Windows 盘符路径逐级向上，盘符根回到「此电脑」', () => {
    obs('C:\\work\\alpha', parentPath(String.raw`C:\work\alpha`));
    expect(parentPath(String.raw`C:\work\alpha`)).toBe(String.raw`C:\work`);
    expect(parentPath(String.raw`C:\work`)).toBe('C:\\');
    // 返工 12.11：盘符根不再是「到顶」，上一级是虚拟根「此电脑」。
    expect(parentPath('C:\\')).toBe(kDrivesRoot);
    expect(parentPath('C:/')).toBe(kDrivesRoot);
    // `C:` 是盘符相对路径（不是绝对根），没有可用的上级。
    expect(parentPath('C:')).toBeNull();
    expect(parentPath(kDrivesRoot)).toBeNull();
  });

  it('POSIX 路径逐级向上，/ 返回 null', () => {
    expect(parentPath('/home/user')).toBe('/home');
    expect(parentPath('/home')).toBe('/');
    expect(parentPath('/')).toBeNull();
  });

  it('UNC：共享根返回 null，深层目录回退到共享根', () => {
    obs('UNC 深层', parentPath(String.raw`\\server\share\dir`));
    expect(parentPath(String.raw`\\server\share\dir`)).toBe(String.raw`\\server\share`);
    expect(parentPath(String.raw`\\server\share`)).toBeNull();
    expect(parentPath(String.raw`\\server`)).toBeNull();
  });

  it('空串与相对片段没有上级', () => {
    expect(parentPath('')).toBeNull();
    expect(parentPath('alpha')).toBeNull();
  });
});

describe('pathCrumbs：面包屑逐段可点', () => {
  it('Windows：此电脑 → 盘符根 → 中间目录 → 末段', () => {
    const crumbs = pathCrumbs(String.raw`C:\work\alpha`);
    obs('Windows 面包屑', crumbs);
    expect(crumbs).toEqual([
      { label: kDrivesRootLabel, path: kDrivesRoot },
      { label: 'C:', path: 'C:\\' },
      { label: 'work', path: String.raw`C:\work` },
      { label: 'alpha', path: String.raw`C:\work\alpha` },
    ]);
  });

  it('POSIX：根 → 中间目录 → 末段（没有「此电脑」层）', () => {
    const crumbs = pathCrumbs('/home/user');
    obs('POSIX 面包屑', crumbs);
    expect(crumbs).toEqual([
      { label: '/', path: '/' },
      { label: 'home', path: '/home' },
      { label: 'user', path: '/home/user' },
    ]);
  });

  it('UNC：根段是 \\\\server\\share（不丢服务器名，也不挂到「此电脑」下）', () => {
    const crumbs = pathCrumbs(String.raw`\\server\share\dir`);
    obs('UNC 面包屑', crumbs);
    expect(crumbs).toEqual([
      { label: String.raw`\\server\share`, path: String.raw`\\server\share` },
      { label: 'dir', path: String.raw`\\server\share\dir` },
    ]);
  });

  it('空串 ⇒ 空数组；盘符根 / 此电脑根 / POSIX 根 ⇒ 顶层段', () => {
    expect(pathCrumbs('')).toEqual([]);
    expect(pathCrumbs('C:\\')).toEqual([
      { label: kDrivesRootLabel, path: kDrivesRoot },
      { label: 'C:', path: 'C:\\' },
    ]);
    expect(pathCrumbs(kDrivesRoot)).toEqual([{ label: kDrivesRootLabel, path: kDrivesRoot }]);
    expect(pathCrumbs('/')).toEqual([{ label: '/', path: '/' }]);
  });
});

// 返工 12.13（用户要求可编辑地址栏，且「路径输入和显示的文件夹对应」）：地址栏显示文案
// 与输入归一都是纯逻辑 —— 显示 / 输入两处必须用同一个函数，不许各写一份。
describe('地址栏：显示文案与输入归一（返工 12.13）', () => {
  it('pickerDisplayPath：「此电脑」虚拟根用友好名，其它路径原样（不改写分隔符 / 尾斜杠）', () => {
    obs('null 的显示', pickerDisplayPath(null));
    obs('空串的显示', pickerDisplayPath(''));
    obs('虚拟根的显示', pickerDisplayPath(kDrivesRoot));
    expect(pickerDisplayPath(null)).toBe('');
    expect(pickerDisplayPath('')).toBe('');
    expect(pickerDisplayPath(kDrivesRoot)).toBe(kDrivesRootLabel);
    expect(pickerDisplayPath('C:\\work\\')).toBe('C:\\work\\');
    expect(pickerDisplayPath('/home/u')).toBe('/home/u');
  });

  it('normalizeAddressInput：去首尾空白与 Windows「复制为路径」外层引号，空 ⇒ null', () => {
    const cases: [string, string | null][] = [
      [String.raw`  C:\work  `, String.raw`C:\work`],
      [String.raw`"C:\work"`, String.raw`C:\work`],
      [String.raw`  "C:\work\项目 A"  `, String.raw`C:\work\项目 A`],
      ['   ', null],
      ['""', null],
      ['', null],
    ];
    for (const [raw, expected] of cases) {
      obs(`归一「${raw}」`, normalizeAddressInput(raw));
      expect(normalizeAddressInput(raw)).toBe(expected);
    }
  });

  it('地址栏不做二次规范化：分隔符风格 / 尾斜杠 / 相对片段 / 虚拟根原样交给核心判定', () => {
    for (const path of [
      'C:/work/',
      'C:\\work\\',
      'alpha',
      kDrivesRoot,
      '/home/u',
    ]) {
      obs(`原样路径 ${path}`, normalizeAddressInput(` ${path} `));
      expect(normalizeAddressInput(` ${path} `)).toBe(path);
    }
  });
});
