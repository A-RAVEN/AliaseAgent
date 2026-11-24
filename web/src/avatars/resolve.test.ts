// 头像来源解析（change `chat-bubbles-avatars` 任务 1.3 / design D2）。
//
// 红靶：模块不存在时 `npm test` 红。解析只决定「该用上传图还是身份图案、种子是谁」，
// **不读文件系统**（文件是否存在由 App 层的 `attachment.read` 结果决定，D2 的字节链路）。
import { describe, expect, it } from 'vitest';

import { resolveAvatar } from './resolve';

describe('resolveAvatar：上传覆盖优先，否则身份图案', () => {
  it('同时给上传路径与身份种子 ⇒ 用上传图（source=upload）', () => {
    const resolved = resolveAvatar({
      entityId: 'member-1',
      identitySeed: 'seed-from-user',
      uploadedPath: 'C:/tmp/avatar.png',
    });
    console.log('[resolveAvatar] 上传优先', resolved);
    expect(resolved.source).toBe('upload');
    expect(resolved.uploadedPath).toBe('C:/tmp/avatar.png');
  });

  it('只有身份种子 ⇒ 身份图案（source=identicon），种子用 identitySeed', () => {
    const resolved = resolveAvatar({ entityId: 'member-1', identitySeed: 'seed-from-user' });
    console.log('[resolveAvatar] 仅种子', resolved);
    expect(resolved.source).toBe('identicon');
    expect(resolved.seed).toBe('seed-from-user');
    expect(resolved.uploadedPath).toBeNull();
  });

  it('上传路径为空串 / null 时回落身份图案', () => {
    for (const uploadedPath of ['', null, undefined]) {
      const resolved = resolveAvatar({ entityId: 'member-1', uploadedPath });
      console.log('[resolveAvatar] 空路径', JSON.stringify(uploadedPath), resolved);
      expect(resolved.source).toBe('identicon');
      expect(resolved.seed).toBe('member-1');
      expect(resolved.uploadedPath).toBeNull();
    }
  });

  it('来源标记与种子原样透出（种子不做 trim / 不改大小写）', () => {
    const rawSeed = '  Session-ABC  ';
    const resolved = resolveAvatar({
      entityId: 'session-1',
      identitySeed: rawSeed,
      uploadedPath: 'C:/tmp/a.png',
    });
    console.log('[resolveAvatar] 种子透出', resolved.seed);
    expect(resolved.seed).toBe(rawSeed);
    const identiconOnly = resolveAvatar({ entityId: 'Session-ABC' });
    expect(identiconOnly.seed).toBe('Session-ABC');
    expect(identiconOnly.source).toBe('identicon');
  });
});
