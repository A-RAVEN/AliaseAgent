// 布局/滚动测试的 harness 入口（change `web-chat-screen` 任务 2.1 / design D13）。
//
// 为什么单独一个入口：puppeteer 要的是**真实布局引擎**（jsdom 的
// getBoundingClientRect 恒 0，量不出折叠卡单行高度 / 滚动位置），但真实聊天屏
// 依赖核心 WS + 数据库。这个 harness 只挂聊天屏组件、用可编程的假数据源驱动，
// 由 `e2e/layout.mjs` 在 headless Edge 里跑断言。
//
// 两种模式：
//   - 不注入 `window.__HARNESS_SCENARIO__`：渲染 canary（基建自检：真实布局引擎
//     可量 24px 单行高度、滚动真的会动）；
//   - 注入 scenario：渲染真实 `ChatScreen`，并通过 `window.__harness` 暴露
//     "推消息 / 推流式增量 / 上翻加载更早一页"这些驱动入口。
import { StrictMode, useCallback, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';

import '../../src/index.css';
import { applyAgentEvent, type AgentEventLike } from '../../src/chat/events';
import type { RawMessage } from '../../src/chat/model';
import { emptyChatView, type ChatView } from '../../src/chat/render';
import { ChatScreen } from '../../src/components/ChatScreen';
import type { ConnectionStatus, Session, SnapshotEventData } from '../../src/protocol';

interface HarnessScenario {
  sessions?: Session[];
  messages?: RawMessage[];
  streamingText?: string;
  isStreaming?: boolean;
  hasEarlier?: boolean;
  /** 每次"上翻加载更早"返回一批（先进后出：`shift()`）。 */
  earlierChunks?: RawMessage[][];
  /** 模拟网络延迟（ms）：让"加载中"态可见。 */
  earlierDelayMs?: number;
  error?: string | null;
  notice?: string | null;
  snapshot?: SnapshotEventData | null;
}

interface HarnessApi {
  pushEvent(event: AgentEventLike): void;
  pushMessage(message: RawMessage): void;
  pushChunk(text: string): void;
  setStreaming(streaming: boolean): void;
  remainingEarlierChunks(): number;
  messageCount(): number;
}

declare global {
  interface Window {
    __HARNESS_SCENARIO__?: HarnessScenario;
    __harness?: HarnessApi;
  }
}

function Canary() {
  return (
    <div>
      <div
        data-testid="canary-single-line"
        style={{
          height: 24,
          lineHeight: '24px',
          overflow: 'hidden',
          whiteSpace: 'nowrap',
          textOverflow: 'ellipsis',
          width: 200,
        }}
      >
        这一行必须被量成 24px 高（真实布局引擎）
      </div>
      <div
        data-testid="canary-scroll"
        style={{ height: 200, overflowY: 'auto', marginTop: 8 }}
      >
        <div data-testid="canary-tall" style={{ height: 2000 }}>
          很高的内容
        </div>
      </div>
    </div>
  );
}

function makeSessions(count: number): Session[] {
  return Array.from({ length: count }, (_, index) => ({
    id: `s-${index}`,
    title: `会话 ${index}`,
    agentType: 'general',
    parentSessionId: null,
    createdAt: index,
    updatedAt: index,
  }));
}

function Harness({ scenario }: { scenario: HarnessScenario }) {
  const sessions = useMemo(
    () => scenario.sessions ?? makeSessions(1),
    [scenario.sessions],
  );
  const [currentSessionId, setCurrentSessionId] = useState<string | null>(
    sessions[0]?.id ?? null,
  );
  const [view, setView] = useState<ChatView>(() => ({
    ...emptyChatView,
    messages: scenario.messages ?? [],
    streamingText: scenario.streamingText ?? '',
    isStreaming: scenario.isStreaming ?? false,
  }));
  const [hasEarlier, setHasEarlier] = useState(scenario.hasEarlier ?? false);
  const [loadingEarlier, setLoadingEarlier] = useState(false);
  const [error] = useState<string | null>(scenario.error ?? null);
  const [notice] = useState<string | null>(scenario.notice ?? null);
  const chunksRef = useRef<RawMessage[][]>(scenario.earlierChunks ?? []);

  const loadEarlier = useCallback(() => {
    const chunk = chunksRef.current.shift();
    if (!chunk) {
      setHasEarlier(false);
      return;
    }
    setLoadingEarlier(true);
    const delay = scenario.earlierDelayMs ?? 60;
    window.setTimeout(() => {
      setView((previous) => ({
        ...previous,
        messages: [...chunk, ...previous.messages],
      }));
      setHasEarlier(chunksRef.current.length > 0);
      setLoadingEarlier(false);
    }, delay);
  }, [scenario.earlierDelayMs]);

  useMemo(() => {
    window.__harness = {
      pushEvent: (event) => setView((previous) => applyAgentEvent(previous, event)),
      pushMessage: (message) =>
        setView((previous) =>
          applyAgentEvent(previous, {
            type: message.role === 'user' ? 'user.message' : 'assistant.message',
            data: message as unknown as Record<string, unknown>,
          }),
        ),
      pushChunk: (text) =>
        setView((previous) => applyAgentEvent(previous, { type: 'assistant.chunk', data: { text } })),
      setStreaming: (streaming) =>
        setView((previous) =>
          applyAgentEvent(previous, { type: 'agent.streaming', data: { streaming } }),
        ),
      remainingEarlierChunks: () => chunksRef.current.length,
      messageCount: () => view.messages.length,
    };
  }, [view.messages.length]);

  const status: ConnectionStatus = 'open';
  return (
    <ChatScreen
      status={status}
      sessions={sessions}
      currentSessionId={currentSessionId}
      onSelectSession={setCurrentSessionId}
      view={view}
      hasEarlier={hasEarlier}
      loadingEarlier={loadingEarlier}
      onLoadEarlier={loadEarlier}
      error={error}
      notice={notice}
      skillFailures={[]}
      snapshot={scenario.snapshot ?? null}
      metering={null}
      onSend={(text) =>
        window.__harness?.pushMessage({
          id: `sent-${Date.now()}`,
          role: 'user',
          content: text,
        })
      }
    />
  );
}

const scenario = window.__HARNESS_SCENARIO__;
createRoot(document.getElementById('root')!).render(
  <StrictMode>{scenario ? <Harness scenario={scenario} /> : <Canary />}</StrictMode>,
);
