// 头像上传的共用步骤（change `chat-bubbles-avatars` 任务 4.2 / 6.2 / 6.3 / design D3）。
//
// 只有两步：把文件读成 data URL → 交给核心的 `attachment.upload`（**不在浏览器里
// 做第二套图片校验**：大小上限与文件头魔数判定都在核心，重复口径会让两边漂移）。
import type { CoreClient } from '../protocol';

/** 把一个 File 读成 data URL（浏览器 API）。 */
export function readFileAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error(`读取文件失败：${file.name}`));
    reader.onload = () => resolve(String(reader.result ?? ''));
    reader.readAsDataURL(file);
  });
}

export interface UploadedAvatar {
  /** 核心返回的附件路径（写进 `template.save` / `profile.save`）。 */
  path: string;
  /** 本地上传时的 data URL（预览可直接用，不必再读一次）。 */
  dataUrl: string;
}

/** 读文件并上传；失败原样抛出（调用方负责显示可归因错误，不静默丢弃选择）。 */
export async function uploadAvatarFile(
  client: CoreClient,
  file: File,
): Promise<UploadedAvatar> {
  const dataUrl = await readFileAsDataUrl(file);
  const comma = dataUrl.indexOf(',');
  const base64 = comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
  const uploaded = await client.request<{ path: string }>('attachment.upload', {
    filename: file.name,
    base64,
  });
  return { path: uploaded.path, dataUrl };
}
