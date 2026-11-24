// 头像（change `chat-bubbles-avatars` 任务 4.2 / design D2、D4）。
//
// **纯展示**：只接收 `{dataUrl, source, seed, size}`，不自己拼路径、不发 RPC。
// 有 dataUrl 就画 `<img src={dataUrl}>`（`attachment.read` 取回的 data URL），否则画
// 由 seed 决定的身份图案；图片 `onError` 时切回身份图案（丢了也不留破图）。
//
// MUST NOT 用 `<img src="C:\\…">` / `file://`：静态服务只服务 web 根，浏览器拿不到
// 附件目录里的文件（字节链路在 App 层，D2）。
import { useEffect, useState } from 'react';

import {
  IDENTICON_GRID_SIZE,
  identicon,
  identiconFillClass,
} from '../avatars/identicon';

export type AvatarSource = 'upload' | 'identicon';

/** 一张头像渲染所需的最小数据（由 App 层的路径 → data URL 缓存算出来）。 */
export interface AvatarData {
  dataUrl: string | null;
  source: AvatarSource;
  /** 身份图案种子（原样字符串；上传图也带着它，便于 DOM 断言）。 */
  seed: string;
}

export interface AvatarProps extends AvatarData {
  /** 边长（px）：取 `avatarSizes` 的令牌值，不在这里写魔数。 */
  size: number;
  label?: string;
  /** 可选落点（成员卡片用 `member-avatar-<id>`；D5）。 */
  testId?: string;
}

export function Avatar({ dataUrl, source, seed, size, label, testId }: AvatarProps) {
  const [failed, setFailed] = useState(false);
  // 换了一张图（或同一路径重新取到字节）后要再给一次机会，不能一直停在身份图案。
  useEffect(() => setFailed(false), [dataUrl]);

  const showUpload = source === 'upload' && dataUrl !== null && !failed;
  if (showUpload) {
    return (
      <img
        data-testid={testId}
        data-avatar-source="upload"
        data-seed={seed}
        src={dataUrl}
        alt={label ?? '头像'}
        width={size}
        height={size}
        onError={() => setFailed(true)}
        className="shrink-0 rounded-full border border-line object-cover"
        style={{ width: size, height: size }}
      />
    );
  }

  const model = identicon(seed);
  return (
    <svg
      data-testid={testId}
      data-avatar-source="identicon"
      data-seed={seed}
      width={size}
      height={size}
      viewBox={`0 0 ${IDENTICON_GRID_SIZE} ${IDENTICON_GRID_SIZE}`}
      role="img"
      aria-label={label ?? `身份图案（${seed}）`}
      className="shrink-0 rounded-card"
      style={{ width: size, height: size }}
    >
      <rect
        x={0}
        y={0}
        width={IDENTICON_GRID_SIZE}
        height={IDENTICON_GRID_SIZE}
        className="fill-surface-2"
      />
      {model.grid.flatMap((row, y) =>
        row.map((filled, x) =>
          filled ? (
            <rect
              key={`${x}-${y}`}
              x={x}
              y={y}
              width={1}
              height={1}
              className={identiconFillClass(model.colorIndex)}
            />
          ) : null,
        ),
      )}
    </svg>
  );
}
