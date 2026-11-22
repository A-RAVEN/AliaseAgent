// 会话列表：虚拟滚动（change `web-chat-screen` 任务 5.1 / design D11）。
//
// 数百~数千会话时只渲染可视区（固定行高 36px：py-2 + text-sm 行高 20）。
import { useVirtualizer } from '@tanstack/react-virtual';
import { useRef } from 'react';

import type { Session } from '../protocol';

/** 行高：text-sm(20) + py-2(8×2) = 36。 */
const ROW_HEIGHT = 36;

export interface SessionListProps {
  sessions: Session[];
  currentSessionId: string | null;
  onSelect: (sessionId: string) => void;
}

export function SessionList({ sessions, currentSessionId, onSelect }: SessionListProps) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const virtualizer = useVirtualizer({
    count: sessions.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 6,
  });

  return (
    <div ref={scrollRef} data-testid="session-list" className="min-h-0 flex-1 overflow-y-auto px-2 py-2">
      {sessions.length === 0 ? (
        <p className="px-2 text-sm text-muted">没有会话</p>
      ) : (
        <div style={{ height: virtualizer.getTotalSize(), position: 'relative', width: '100%' }}>
          {virtualizer.getVirtualItems().map((virtualItem) => {
            const session = sessions[virtualItem.index];
            const selected = session.id === currentSessionId;
            return (
              <div
                key={session.id}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  height: ROW_HEIGHT,
                  transform: `translateY(${virtualItem.start}px)`,
                }}
              >
                <button
                  type="button"
                  data-testid="session-row"
                  title={session.title}
                  onClick={() => onSelect(session.id)}
                  className={
                    selected
                      ? 'h-full w-full truncate rounded-card bg-surface-2 px-2 text-left text-sm text-fg'
                      : 'h-full w-full truncate rounded-card px-2 text-left text-sm text-muted hover:bg-surface-2'
                  }
                >
                  {session.title}
                </button>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
