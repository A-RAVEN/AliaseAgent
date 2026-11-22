// 输入区（change `web-management-ui` 任务 2.2）：在原有"Enter 发送 / Shift+Enter 换行"
// 之上加**图片粘贴 / 选择**：预览 → 可移除 → 发送时随 attachments 一起交给核心。
//
// 粘贴与选择都只做"读成为待发附件"，上传由上层调 `attachment.upload`（核心负责
// 大小上限与文件头魔数校验）—— 前端不做第二套判据。
import { useRef, useState, type ClipboardEvent, type ChangeEvent, type KeyboardEvent } from 'react';

import { pendingImageFromDataUrl, type PendingImage } from '../chat/attachments';

export interface ComposerProps {
  disabled: boolean;
  onSend: (text: string, images?: PendingImage[]) => void;
}

/** 把一个 File 读成 data URL（浏览器 API；纯逻辑在 `chat/attachments.ts`）。 */
function readFileAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error(`读取文件失败：${file.name}`));
    reader.onload = () => resolve(String(reader.result ?? ''));
    reader.readAsDataURL(file);
  });
}

export function Composer({ disabled, onSend }: ComposerProps) {
  const [input, setInput] = useState('');
  const [images, setImages] = useState<PendingImage[]>([]);
  const [attachError, setAttachError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const addFiles = async (files: File[]) => {
    if (files.length === 0) return;
    setAttachError(null);
    for (const file of files) {
      if (!file.type.startsWith('image/')) {
        setAttachError(`只支持图片附件：${file.name}（${file.type || '未知类型'}）`);
        continue;
      }
      try {
        const dataUrl = await readFileAsDataUrl(file);
        setImages((previous) => [...previous, pendingImageFromDataUrl(file.name, dataUrl)]);
      } catch (error: unknown) {
        setAttachError(error instanceof Error ? error.message : String(error));
      }
    }
  };

  const removeImage = (id: string) => {
    setImages((previous) => previous.filter((image) => image.id !== id));
  };

  const submit = () => {
    const text = input.trim();
    if (disabled) return;
    if (!text && images.length === 0) return;
    onSend(text, images);
    setInput('');
    setImages([]);
    setAttachError(null);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  };

  const onPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    const files: File[] = [];
    for (const item of Array.from(event.clipboardData?.items ?? [])) {
      if (item.kind === 'file' && item.type.startsWith('image/')) {
        const file = item.getAsFile();
        if (file) files.push(file);
      }
    }
    if (files.length > 0) {
      event.preventDefault();
      void addFiles(files);
    }
  };

  const onPickFiles = (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    void addFiles(files);
    event.target.value = '';
  };

  return (
    <footer className="border-t border-line p-3">
      {images.length > 0 && (
        <div data-testid="pending-images" className="mb-2 flex flex-wrap gap-2">
          {images.map((image) => (
            <div
              key={image.id}
              data-testid="pending-image"
              className="relative h-16 w-16 overflow-hidden rounded-card border border-line"
            >
              <img src={image.dataUrl} alt={image.name} className="h-full w-full object-cover" />
              <button
                type="button"
                data-testid="pending-image-remove"
                title={`移除 ${image.name}`}
                aria-label={`移除 ${image.name}`}
                onClick={() => removeImage(image.id)}
                className="absolute right-0 top-0 flex h-5 w-5 items-center justify-center rounded-card bg-bg/80 text-xs text-danger"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}
      {attachError && (
        <p
          data-testid="attach-error"
          className="mb-2 rounded-card border border-danger/40 bg-danger/10 px-2 py-1 text-xs text-danger"
        >
          {attachError}
        </p>
      )}
      <div className="flex items-end gap-2">
        <button
          type="button"
          data-testid="image-button"
          title="选择图片"
          aria-label="选择图片"
          disabled={disabled}
          onClick={() => fileInputRef.current?.click()}
          className="rounded-card border border-line px-3 py-2 text-sm text-muted hover:text-fg disabled:cursor-not-allowed disabled:opacity-40"
        >
          图片
        </button>
        <input
          ref={fileInputRef}
          data-testid="image-input"
          type="file"
          accept="image/*"
          multiple
          onChange={onPickFiles}
          className="hidden"
        />
        <textarea
          data-testid="composer"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
          placeholder="输入一句话（可粘贴图片），Enter 发送（Shift+Enter 换行）"
          rows={2}
          className="min-h-12 flex-1 resize-none rounded-card border border-line bg-surface px-3 py-2 text-base text-fg outline-none placeholder:text-muted focus:border-accent"
        />
        <button
          type="button"
          data-testid="send"
          onClick={submit}
          disabled={disabled || (input.trim().length === 0 && images.length === 0)}
          className="rounded-card bg-accent px-4 py-2 text-sm font-semibold text-bg disabled:cursor-not-allowed disabled:opacity-40"
        >
          发送
        </button>
      </div>
    </footer>
  );
}
