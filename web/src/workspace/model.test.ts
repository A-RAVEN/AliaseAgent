// 工作路径的 web 纯逻辑（change `custom-workspace` 任务 8.1 / design D8 / D9）。
//
// 只测可判定的文案与输入判定：
//   - `workspaceLabel(null)` 必须返回**与文档 / 组件逐字一致**的缺省文案；
//   - `workspaceLabel(path)` 原样返回（界面显示「设置值」，不做二次规范化）；
//   - `isWorkspaceSubmissionValid` 把空串 / 纯空白判为不可提交。
//
// 缺省文案写死在断言里是有意的：文档 `界面文案（web）` 行、GroupView / ChatScreen
// 的显示都引用同一个常量，三处漂移会在这里红。
import { describe, expect, it } from 'vitest';

import {
  isWorkspaceSubmissionValid,
  kDefaultWorkspaceLabel,
  workspaceLabel,
} from './model';

function obs(label: string, value: unknown): void {
  console.log(`[workspace] ${label}: ${JSON.stringify(value)}`);
}

describe('workspaceLabel：缺省文案与自定义路径', () => {
  it('null 返回缺省文案（与文档 / 组件逐字一致）', () => {
    obs('缺省文案', workspaceLabel(null));
    expect(kDefaultWorkspaceLabel).toBe('缺省（应用主目录）');
    expect(workspaceLabel(null)).toBe('缺省（应用主目录）');
  });

  it('非空路径原样返回（显示设置值，不二次规范化）', () => {
    const path = 'C:\\work\\项目 A';
    obs('自定义路径', workspaceLabel(path));
    expect(workspaceLabel(path)).toBe(path);
    const posix = '/home/user/project';
    expect(workspaceLabel(posix)).toBe(posix);
  });
});

describe('isWorkspaceSubmissionValid：空 / 空白不可提交', () => {
  it('空串与纯空白为假，非空为真', () => {
    obs('空串', isWorkspaceSubmissionValid(''));
    obs('纯空白', isWorkspaceSubmissionValid('   \t  '));
    obs('非空', isWorkspaceSubmissionValid('C:\\work'));
    expect(isWorkspaceSubmissionValid('')).toBe(false);
    expect(isWorkspaceSubmissionValid('   \t  ')).toBe(false);
    expect(isWorkspaceSubmissionValid('C:\\work')).toBe(true);
    expect(isWorkspaceSubmissionValid('/home/user')).toBe(true);
  });
});
