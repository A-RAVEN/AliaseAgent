// 聊天气泡（change `chat-bubbles-avatars` 任务 4.3 / design D4）。
//
// 单聊与群聊共用同一份：用户靠右（绿气泡 + 头像在行最右端），成员/agent 靠左
// （头像在左、可选名字在气泡上方、气泡在右）。
//
// **标识落点钉死**（design D4）：外层整行容器带调用方的 testid（`user-message` /
// `assistant-message` / `streaming-message`）且**含头像**；内层气泡单独一个元素，
// `data-testid="bubble"` + `data-bubble-side`，**纯气泡、不含头像**。布局断言只量
// 内层气泡（整行天然占满宽度，量不出东西）。
import type { ReactNode } from 'react';

import { Avatar, type AvatarData } from './Avatar';

export interface MessageBubbleProps {
  /** `member` 与 `agent` 同样靠左，只是 `data-bubble-side` 标出群成员（群聊验收读它）。 */
  side: 'user' | 'agent' | 'member';
  avatar: AvatarData;
  /** 头像边长（px）；调用方传 `avatarSizes.bubble`，这里不写数字。 */
  avatarSize: number;
  /** 整行容器的 testid（既有锚点，不能改名）。 */
  testId: string;
  /** 只有群聊传名字（单聊只有一个 agent，名字是噪音）。 */
  name?: string | null;
  children: ReactNode;
}

export function MessageBubble({
  side,
  avatar,
  avatarSize,
  testId,
  name = null,
  children,
}: MessageBubbleProps) {
  const user = side === 'user';
  return (
    <div
      data-testid={testId}
      data-message-side={side}
      className={user ? 'flex flex-row-reverse items-start gap-2' : 'flex items-start gap-2'}
    >
      <Avatar
        {...avatar}
        size={avatarSize}
        label={user ? '用户头像' : name !== null ? `${name}的头像` : '助手头像'}
      />
      {/* 气泡列：内层气泡贴着它自己的列缘（布局断言量它，不量整行）。 */}
      <div
        data-testid="bubble-column"
        className={user ? 'flex min-w-0 flex-col items-end' : 'flex min-w-0 flex-col items-start'}
      >
        {!user && name !== null && (
          <div data-testid="bubble-name" className="mb-1 text-xs text-muted">
            {name}
          </div>
        )}
        <div
          data-testid="bubble"
          data-bubble-side={side}
          className={
            user
              ? 'max-w-xl rounded-card border border-ok/40 bg-ok/15 px-3 py-2 text-fg'
              : 'max-w-2xl rounded-card border border-line bg-surface px-3 py-2 text-fg'
          }
        >
          {children}
        </div>
      </div>
    </div>
  );
}
