// 图片附件的前端纯逻辑（change `web-management-ui` 任务 2.2 / design D12）。
//
// 为什么放纯函数：贴图/选择图片的**读取**要浏览器 API（FileReader），但"一张图变成
// 待发附件""历史附件该显示什么提示"这些规则是纯的 —— vitest 直接锁，puppeteer 只
// 负责布局与交互（design D14）。
import { describe, expect, it } from 'vitest';

import {
  attachmentRowModel,
  parseDataUrl,
  pendingImageFromDataUrl,
} from './attachments';

const pngDataUrl =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/wD/2y6JAAAAAElFTkSuQmCC';

describe('parseDataUrl', () => {
  it('拆出 mediaType 与 base64', () => {
    const parsed = parseDataUrl(pngDataUrl);
    console.log('[解析]', parsed.mediaType, parsed.base64.length);
    expect(parsed.mediaType).toBe('image/png');
    expect(parsed.base64.startsWith('iVBORw0KGgo')).toBe(true);
  });

  it('不是 data URL 时抛错（不假装成功）', () => {
    expect(() => parseDataUrl('https://example.com/a.png')).toThrow();
  });
});

describe('pendingImageFromDataUrl', () => {
  it('生成待发附件：名字 / mediaType / base64 / 预览 URL', () => {
    const pending = pendingImageFromDataUrl('shot.png', pngDataUrl);
    console.log('[待发]', JSON.stringify({ name: pending.name, mediaType: pending.mediaType }));
    expect(pending.name).toBe('shot.png');
    expect(pending.mediaType).toBe('image/png');
    expect(pending.dataUrl).toBe(pngDataUrl);
    expect(pending.base64.length).toBeGreaterThan(10);
    expect(pending.id.length).toBeGreaterThan(0);
  });

  it('非图片类型拒绝（与核心的文件头判定同一条产品口径：只发图片）', () => {
    expect(() =>
      pendingImageFromDataUrl('a.txt', 'data:text/plain;base64,aGVsbG8='),
    ).toThrow(/图片/);
  });
});

describe('attachmentRowModel', () => {
  it('图片可用时出缩略图、无提示', () => {
    const model = attachmentRowModel({
      attachments: ['/x/a.png'],
      dataUrls: { '/x/a.png': pngDataUrl },
      imagesSupported: true,
    });
    console.log('[附件模型]', JSON.stringify(model));
    expect(model.thumbnails).toEqual([{ path: '/x/a.png', dataUrl: pngDataUrl }]);
    expect(model.notices).toEqual([]);
  });

  it('模型未声明 image：出「图片未发送」可见提示（不静默丢图）', () => {
    const model = attachmentRowModel({
      attachments: ['/x/a.png'],
      dataUrls: { '/x/a.png': pngDataUrl },
      imagesSupported: false,
    });
    console.log('[未发送提示]', JSON.stringify(model.notices));
    expect(model.notices.some((line) => line.includes('图片未发送'))).toBe(true);
  });

  it('文件丢失：出「图片已丢失」可见提示', () => {
    const model = attachmentRowModel({
      attachments: ['/x/gone.png'],
      dataUrls: { '/x/gone.png': null },
      imagesSupported: true,
    });
    console.log('[丢失提示]', JSON.stringify(model.notices));
    expect(model.notices.some((line) => line.includes('图片已丢失'))).toBe(true);
  });

  it('还没有取回字节时不出"丢失"提示（状态未知不冒充缺失）', () => {
    const model = attachmentRowModel({
      attachments: ['/x/loading.png'],
      dataUrls: {},
      imagesSupported: true,
    });
    expect(model.notices).toEqual([]);
    expect(model.thumbnails).toEqual([]);
  });

  it('没有附件时什么都不出', () => {
    const model = attachmentRowModel({
      attachments: [],
      dataUrls: {},
      imagesSupported: false,
    });
    expect(model).toEqual({ thumbnails: [], notices: [] });
  });
});
