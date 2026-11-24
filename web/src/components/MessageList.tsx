// 消息列表：虚拟滚动 + 贴底跟随 + 上翻加载更早 + 悬浮跳底按钮
// （change `web-chat-screen` 任务 4.1 / 4.2 / 5.2，F-003 / F-004，design D9/D11）。
//
// 为什么消息列表也要虚拟化：一轮工具调用会产出几十条 item，长会话上百条；
// 全量渲染会让贴底跟随的每一帧都重排全部节点。
//
// 贴底判定用 token（`layoutConfig.bottomThresholdPx`，默认 24px = 正文行高），
// 不在这里写数字。布局/滚动断言全在 `e2e/layout.mjs`（真实渲染），本组件不写测试。
import { useVirtualizer } from '@tanstack/react-virtual';
import { ChevronDown } from 'lucide-react';
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

import type { ChatItem } from '../chat/render';
import { attachmentRowModel } from '../chat/attachments';
import { avatarSizes, layoutConfig } from '../tokens';
import type { AvatarData } from './Avatar';
import { Markdown } from './Markdown';
import { MessageBubble } from './MessageBubble';
import { ThinkingCard } from './ThinkingCard';
import { ToolCard } from './ToolCard';

/** 没传头像时的兜底：一律身份图案（decorative，不阻断渲染）。 */
const FALLBACK_AVATAR: AvatarData = { dataUrl: null, source: 'identicon', seed: '' };

export interface MessageListProps {
  items: ChatItem[];
  hasEarlier: boolean;
  loadingEarlier: boolean;
  onLoadEarlier: () => void;
  /** 附件路径 → data URL（null = 取回失败/文件丢失；键不存在 = 还没取）。 */
  attachments?: Record<string, string | null>;
  /** 当前模板是否声明了 image 输入模态（null = 未知，不提示）。 */
  imagesSupported?: boolean | null;
  /** 用户头像（App 层按 `profile.avatar_path` + 字节缓存算出，design D2）。 */
  userAvatar?: AvatarData;
  /** 当前会话 agent 的头像（模板上传图优先，否则会话 id 身份图案）。 */
  agentAvatar?: AvatarData;
}

/** 估算行高（真实高度由 measureElement 量出来；估算只影响未测量区域）。 */
function estimateSize(item: ChatItem): number {
  switch (item.kind) {
    case 'tool':
    case 'thinking':
      return 24 + 16;
    case 'indicator':
      return 20 + 16;
    case 'user':
      return 72;
    case 'assistant':
    case 'streaming':
      return 96;
    default:
      return 64;
  }
}

function MessageItem({
  item,
  attachments,
  imagesSupported,
  userAvatar,
  agentAvatar,
}: {
  item: ChatItem;
  attachments: Record<string, string | null>;
  imagesSupported: boolean | null;
  userAvatar: AvatarData;
  agentAvatar: AvatarData;
}) {
  switch (item.kind) {
    case 'user': {
      const rowModel = attachmentRowModel({
        attachments: item.attachments ?? [],
        dataUrls: attachments,
        imagesSupported,
      });
      return (
        <MessageBubble
          side="user"
          avatar={userAvatar}
          avatarSize={avatarSizes.bubble}
          testId="user-message"
        >
          <Markdown text={item.text ?? ''} />
          {rowModel.thumbnails.length > 0 && (
            <div className="mt-2 flex flex-wrap gap-2">
              {rowModel.thumbnails.map((thumbnail) => (
                <img
                  key={thumbnail.path}
                  data-testid="attachment-thumbnail"
                  src={thumbnail.dataUrl}
                  alt={`附件 ${thumbnail.path}`}
                  title={thumbnail.path}
                  className="h-16 w-16 rounded-card border border-line object-cover"
                />
              ))}
            </div>
          )}
          {rowModel.notices.map((line) => (
            <p
              key={line}
              data-testid={
                line.includes('图片未发送') ? 'attachment-not-sent' : 'attachment-missing'
              }
              className="mt-1 text-xs text-warn"
            >
              {line}
            </p>
          ))}
        </MessageBubble>
      );
    }
    case 'assistant':
      return (
        <MessageBubble
          side="agent"
          avatar={agentAvatar}
          avatarSize={avatarSizes.bubble}
          testId="assistant-message"
        >
          <Markdown text={item.text ?? ''} />
        </MessageBubble>
      );
    case 'streaming':
      return (
        <MessageBubble
          side="agent"
          avatar={agentAvatar}
          avatarSize={avatarSizes.bubble}
          testId="streaming-message"
        >
          <Markdown text={item.text ?? ''} />
        </MessageBubble>
      );
    case 'tool':
      return <ToolCard tool={item.tool!} />;
    case 'thinking':
      return <ThinkingCard thinking={item.thinking!} />;
    case 'indicator':
      return (
        <p data-testid="streaming-indicator" className="text-sm text-accent">
          正在生成…
        </p>
      );
    default:
      return null;
  }
}

export function MessageList({
  items,
  hasEarlier,
  loadingEarlier,
  onLoadEarlier,
  attachments = {},
  imagesSupported = null,
  userAvatar = FALLBACK_AVATAR,
  agentAvatar = FALLBACK_AVATAR,
}: MessageListProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [atBottom, setAtBottom] = useState(true);
  // 上翻加载更早页前记下"距底距离"：插入更早内容后用它还原，阅读位置不跳。
  const pendingFromBottom = useRef<number | null>(null);
  // 同步防重入：React 的 loadingEarlier 是异步 state，滚到顶时连续 scroll 事件
  // 会在同一批里重复触发加载（核心分页是幂等的，但会白拉一页并打乱游标）。
  const earlierRequested = useRef(false);
  const previousCount = useRef(items.length);

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (index) => estimateSize(items[index]),
    getItemKey: (index) => items[index].key,
    overscan: 8,
  });

  const scrollToBottom = useCallback(() => {
    virtualizer.scrollToOffset(virtualizer.getTotalSize());
  }, [virtualizer]);

  // 内容签名：条数 / 首项 / 末项文本长度（流式增量会让文本变长）。
  const signature =
    `${items.length}|${items[0]?.key ?? ''}|${items[items.length - 1]?.text?.length ?? 0}`;

  // 贴底跟随：只有仍然贴底时才自动滚到底（上翻阅读历史时不打扰）。
  //
  // 依赖里带 `getTotalSize()`：虚拟列表的行高是测量出来的，首屏先按估算渲染，
  // 量完总高度会变大；只按内容签名滚一次会停在半路（实测 distance=342px）。
  const totalSize = virtualizer.getTotalSize();
  useLayoutEffect(() => {
    if (!atBottom) return undefined;
    scrollToBottom();
    const frame = requestAnimationFrame(() => scrollToBottom());
    return () => cancelAnimationFrame(frame);
  }, [signature, totalSize, atBottom, scrollToBottom]);

  // 上翻加载更早页：保持"距底距离"不变 —— 插入的内容全在可视区上方，距底量不变
  // 就等于阅读位置不变（虚拟列表的总高先按估算、测量后由 react-virtual 校正）。
  useLayoutEffect(() => {
    const grew = items.length > previousCount.current;
    previousCount.current = items.length;
    const fromBottom = pendingFromBottom.current;
    if (!grew) return;
    earlierRequested.current = false;
    if (fromBottom === null) return;
    pendingFromBottom.current = null;
    const element = scrollRef.current;
    if (!element) return;
    element.scrollTop = Math.max(0, element.scrollHeight - fromBottom);
  }, [items, virtualizer]);

  const handleScroll = () => {
    const element = scrollRef.current;
    if (!element) return;
    const distance = element.scrollHeight - element.scrollTop - element.clientHeight;
    setAtBottom(distance <= layoutConfig.bottomThresholdPx);
    if (element.scrollTop > 0) {
      earlierRequested.current = false;
      return;
    }
    if (hasEarlier && !loadingEarlier && !earlierRequested.current) {
      earlierRequested.current = true;
      pendingFromBottom.current = element.scrollHeight - element.scrollTop;
      onLoadEarlier();
    }
  };

  const jumpToBottom = () => {
    setAtBottom(true);
    scrollToBottom();
    requestAnimationFrame(() => scrollToBottom());
  };

  useEffect(() => {
    // 会话切换（items 清零）后回到"贴底"初始态。
    if (items.length === 0) setAtBottom(true);
  }, [items.length]);

  return (
    <div className="relative min-h-0 flex-1">
      <div
        ref={scrollRef}
        onScroll={handleScroll}
        data-testid="message-list"
        className="h-full overflow-y-auto px-4 py-4"
      >
        {items.length === 0 ? (
          <p className="text-sm text-muted">还没有消息。在下面输入一句话并按 Enter（或点发送）。</p>
        ) : (
          <div style={{ height: virtualizer.getTotalSize(), position: 'relative', width: '100%' }}>
            {virtualizer.getVirtualItems().map((virtualItem) => {
              const item = items[virtualItem.index];
              return (
                <div
                  key={item.key}
                  data-index={virtualItem.index}
                  ref={virtualizer.measureElement}
                  style={{
                    position: 'absolute',
                    top: 0,
                    left: 0,
                    width: '100%',
                    transform: `translateY(${virtualItem.start}px)`,
                  }}
                >
                  <div data-testid="message-row" className="pb-4">
                    <MessageItem
                      item={item}
                      attachments={attachments}
                      imagesSupported={imagesSupported}
                      userAvatar={userAvatar}
                      agentAvatar={agentAvatar}
                    />
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
      {!atBottom && items.length > 0 && (
        <button
          type="button"
          data-testid="jump-to-bottom"
          aria-label="回到底部"
          title="回到底部"
          onClick={jumpToBottom}
          className="absolute bottom-4 right-4 flex h-8 w-8 items-center justify-center rounded-full border border-line bg-surface text-muted shadow-e2 hover:text-fg"
        >
          <ChevronDown size={16} aria-hidden="true" />
        </button>
      )}
    </div>
  );
}
