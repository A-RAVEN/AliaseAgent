// 图片附件的前端纯逻辑（change `web-management-ui` 任务 2.2 / design D12）。
//
// 产品口径（与核心一致，不另发明）：
//   - 只有图片能作为附件（类型判定的权威在核心 `probeImageBytes` 的文件头魔数；
//     前端只做"非 image/* 直接不发"的早筛，最终仍由核心拒绝）；
//   - 模型未声明 image 模态时**不静默丢图**：显示「图片未发送」提示行；
//   - 历史附件取不回来时显示「图片已丢失」提示行。

/** 一张等待发送的图片（Composer 里预览、发送时上传）。 */
export interface PendingImage {
  id: string;
  name: string;
  mediaType: string;
  base64: string;
  /** 预览用的 data URL（与 base64 同源，不额外请求）。 */
  dataUrl: string;
}

let pendingSeq = 0;

/** 拆 `data:<mime>;base64,<数据>`；不是 data URL 就抛错（不假装成功）。 */
export function parseDataUrl(dataUrl: string): { mediaType: string; base64: string } {
  const match = /^data:([^;,]+);base64,([\s\S]+)$/.exec(dataUrl ?? '');
  if (!match) {
    throw new Error(`不是 base64 data URL：${String(dataUrl).slice(0, 40)}`);
  }
  return { mediaType: match[1], base64: match[2] };
}

/** 一张图片的 data URL → 待发附件；非图片类型拒绝。 */
export function pendingImageFromDataUrl(name: string, dataUrl: string): PendingImage {
  const { mediaType, base64 } = parseDataUrl(dataUrl);
  if (!mediaType.startsWith('image/')) {
    throw new Error(`只支持图片附件：${name} 的类型是 ${mediaType}`);
  }
  pendingSeq += 1;
  return {
    id: `pending-${Date.now()}-${pendingSeq}`,
    name: name && name.length > 0 ? name : `image-${pendingSeq}`,
    mediaType,
    base64,
    dataUrl,
  };
}

export interface AttachmentRowModel {
  /** 能渲染的缩略图（按消息里 attachments 的顺序）。 */
  thumbnails: { path: string; dataUrl: string }[];
  /** 必须显示给用户的提示行（模型未声明 image / 文件丢失）。 */
  notices: string[];
}

/**
 * 一条用户消息的附件展示模型。
 *
 * `dataUrls[path]`：已取回的 data URL；`null` = 取回失败（文件丢失）；
 * 键不存在 = 还没取（状态未知 ⇒ **不冒充缺失**，也不出缩略图）。
 */
export function attachmentRowModel(options: {
  attachments: string[];
  dataUrls: Record<string, string | null>;
  imagesSupported: boolean | null;
}): AttachmentRowModel {
  const { attachments, dataUrls, imagesSupported } = options;
  if (attachments.length === 0) return { thumbnails: [], notices: [] };

  const thumbnails: { path: string; dataUrl: string }[] = [];
  const missing: string[] = [];
  for (const path of attachments) {
    if (!Object.prototype.hasOwnProperty.call(dataUrls, path)) continue;
    const dataUrl = dataUrls[path];
    if (dataUrl === null) {
      missing.push(path);
    } else if (typeof dataUrl === 'string') {
      thumbnails.push({ path, dataUrl });
    }
  }

  const notices: string[] = [];
  if (imagesSupported === false) {
    notices.push('图片未发送：当前模板未声明 image 输入模态，本次只发送了文字。');
  }
  for (const path of missing) {
    notices.push(`图片已丢失：附件文件不存在（${path}）。`);
  }
  return { thumbnails, notices };
}
