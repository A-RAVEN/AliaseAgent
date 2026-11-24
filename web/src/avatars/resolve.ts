// 头像来源解析（change `chat-bubbles-avatars` 任务 1.4 / design D2）。
//
// 纯函数：只回答「该用上传图还是身份图案、身份图案的种子是谁」。**不读文件系统**、
// 不做 DOM 判断 —— 上传路径指向的文件是否真的能取到字节，由 App 层的
// `attachment.read` 结果决定（取不到就回落身份图案，见 design D2 的字节链路）。
//
// 种子的口径（D2 表）：群成员 / 单聊 agent / 模板预览用**实体 id**，用户用
// `profile.identitySeed`（核心已把 `userId ?? kDefaultUserSeed` 算好）。所以这里让
// `identitySeed` 优先、`entityId` 兜底，两个调用点都不必复制缺省常量。

export type AvatarSource = 'upload' | 'identicon';

export interface AvatarInput {
  /** 实体稳定 id（成员 id / 会话 id / 模板名 / 用户生效种子）。 */
  entityId: string;
  /** 可选的显式种子（用户头像的 `profile.identitySeed`）；空串视为没给。 */
  identitySeed?: string | null;
  /** 上传覆盖路径（模板 `avatar_path` / `profile.avatar_path`）；空串/null 视为没有。 */
  uploadedPath?: string | null;
}

export interface AvatarResolution {
  /** 该用哪一形态。是否真能画出上传图还要看字节是否取到（由组件按 dataUrl 判定）。 */
  source: AvatarSource;
  /** 身份图案的种子（原样透出，不 trim、不改大小写）。 */
  seed: string;
  /** 归一化后的上传路径（空串/null ⇒ null）。 */
  uploadedPath: string | null;
}

export function resolveAvatar(input: AvatarInput): AvatarResolution {
  const uploadedPath =
    typeof input.uploadedPath === 'string' && input.uploadedPath.length > 0
      ? input.uploadedPath
      : null;
  const seed =
    typeof input.identitySeed === 'string' && input.identitySeed.length > 0
      ? input.identitySeed
      : input.entityId;
  return {
    source: uploadedPath !== null ? 'upload' : 'identicon',
    seed,
    uploadedPath,
  };
}
