// 输入区：Enter 发送、Shift+Enter 换行（沿用最小验证页的键盘约定）。
import { useState, type KeyboardEvent } from 'react';

export interface ComposerProps {
  disabled: boolean;
  onSend: (text: string) => void;
}

export function Composer({ disabled, onSend }: ComposerProps) {
  const [input, setInput] = useState('');

  const submit = () => {
    const text = input.trim();
    if (!text || disabled) return;
    onSend(text);
    setInput('');
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  };

  return (
    <footer className="border-t border-line p-3">
      <div className="flex items-end gap-2">
        <textarea
          data-testid="composer"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={onKeyDown}
          placeholder="输入一句话，Enter 发送（Shift+Enter 换行）"
          rows={2}
          className="min-h-12 flex-1 resize-none rounded-card border border-line bg-surface px-3 py-2 text-base text-fg outline-none placeholder:text-muted focus:border-accent"
        />
        <button
          type="button"
          data-testid="send"
          onClick={submit}
          disabled={disabled || input.trim().length === 0}
          className="rounded-card bg-accent px-4 py-2 text-sm font-semibold text-bg disabled:cursor-not-allowed disabled:opacity-40"
        >
          发送
        </button>
      </div>
    </footer>
  );
}
