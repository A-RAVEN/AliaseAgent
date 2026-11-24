// 侧栏用户头像块（change `chat-bubbles-avatars` 任务 6.3 / design D2、D3、D8）。
//
// 三件事：
//   ① 显示当前用户头像（上传图没有字节时按身份图案）；
//   ② 「换头像」走 `attachment.upload` + `profile.save`、「恢复默认」传空串；
//   ③ **读取失败可见**：`config.get` 抛错时显示「头像资料读取失败：…」并可重试，
//      MUST NOT 静默把失败当成"没有头像"（design D8）。
//
// 头像字节由 App 层解析（这里只收 dataUrl），本组件只发两个写 RPC。
import { useRef, useState } from 'react';

import { avatarSizes } from '../tokens';
import { uploadAvatarFile } from '../avatars/upload';
import type { CoreClient, Profile } from '../protocol';
import { Avatar, type AvatarData } from './Avatar';

export interface UserAvatarBlockProps {
  client: CoreClient;
  /** 当前用户资料（null = 还没读到 / 读失败）。 */
  profile: Profile | null;
  avatar: AvatarData;
  /** `config.get` 的失败文本（null = 正常）。 */
  error: string | null;
  /** 保存成功后就地更新（不整页刷新）。 */
  onUpdated: (profile: Profile) => void;
  /** 读取失败提示里的「重试」（App 的 `loadProfile`）。 */
  onRetry: () => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function UserAvatarBlock({
  client,
  profile,
  avatar,
  error,
  onUpdated,
  onRetry,
}: UserAvatarBlockProps) {
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  /** 写 `profile.save`：`''` = 恢复默认，非空 = 设为该路径。 */
  const saveAvatar = async (avatarPath: string) => {
    setBusy(true);
    setActionError(null);
    try {
      const result = await client.request<{ profile: Profile }>('profile.save', {
        avatarPath,
      });
      onUpdated(result.profile);
    } catch (saveError: unknown) {
      setActionError(`保存头像失败：${errorText(saveError)}`);
    } finally {
      setBusy(false);
    }
  };

  const onPickFile = async (file: File | undefined) => {
    if (!file) return;
    setBusy(true);
    setActionError(null);
    try {
      const uploaded = await uploadAvatarFile(client, file);
      await saveAvatar(uploaded.path);
    } catch (uploadError: unknown) {
      setActionError(`上传头像失败：${errorText(uploadError)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section
      data-testid="user-avatar-block"
      className="border-t border-line p-3 text-xs text-muted"
      aria-label="用户头像"
    >
      <div className="flex items-center gap-2">
        <Avatar {...avatar} size={avatarSizes.member} label="用户头像" />
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm text-fg">用户</p>
          <p className="truncate" title={profile?.identitySeed ?? ''}>
            {profile?.identitySeed ?? '—'}
          </p>
        </div>
      </div>

      {error !== null && (
        <div data-testid="user-avatar-error" className="mt-2 text-danger">
          <p>头像资料读取失败：{error}</p>
          <button
            type="button"
            data-testid="user-avatar-retry"
            onClick={onRetry}
            className="mt-1 min-h-6 rounded-card border border-danger/40 px-2 py-1 text-danger"
          >
            重试
          </button>
        </div>
      )}
      {actionError !== null && (
        <p data-testid="user-avatar-action-error" className="mt-2 text-danger">
          {actionError}
        </p>
      )}

      <div className="mt-2 flex items-center gap-2">
        <button
          type="button"
          data-testid="user-avatar-change"
          disabled={busy}
          onClick={() => fileRef.current?.click()}
          className="min-h-6 rounded-card border border-line px-2 py-1 text-muted hover:text-fg disabled:opacity-40"
        >
          换头像
        </button>
        <button
          type="button"
          data-testid="user-avatar-reset"
          disabled={busy}
          onClick={() => void saveAvatar('')}
          className="min-h-6 rounded-card border border-line px-2 py-1 text-muted hover:text-fg disabled:opacity-40"
        >
          恢复默认
        </button>
      </div>
      <input
        ref={fileRef}
        type="file"
        accept="image/*"
        data-testid="user-avatar-file"
        className="hidden"
        onChange={(event) => {
          const file = event.target.files?.[0];
          event.target.value = '';
          void onPickFile(file);
        }}
      />
    </section>
  );
}
