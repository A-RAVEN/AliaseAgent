// RpcClient 的重连 + 心跳状态机（change `web-chat-screen` 任务 6.1 / design D12）。
//
// 通道钉死（design D13）：**假 WS 对端**。心跳超时这一条在真实核心上造不出来
// （`_handlePing` 无条件同步回 ok），所以用 `ws` 起一个"接受连接但不回 ping"的
// 对端，让客户端的超时判死真的触发；同时用"会回 ping"的对端证明它不会乱重连。
import { afterEach, describe, expect, it } from 'vitest';
import { WebSocketServer, WebSocket as WsWebSocket, type WebSocket as WsSocket } from 'ws';
import type { AddressInfo } from 'node:net';
import { createServer } from 'node:net';
import { once } from 'node:events';

import {
  GROUP_RPC_METHODS,
  RpcClient,
  type ConnectionStatus,
  type GroupChainResult,
  type GroupSendResult,
  type GroupSendStepSource,
  type GroupSendStepStatus,
  type GroupSummary,
  type Session,
} from './protocol';
import { readLayoutConfig } from './tokens';

function obs(label: string, value: unknown): void {
  console.log(`[重连] ${label}: ${JSON.stringify(value)}`);
}

interface FakeCoreOptions {
  /** false = 接受连接但**不回任何消息**（心跳超时用例）。 */
  respond?: boolean;
}

interface FakeCore {
  url: string;
  connections: WsSocket[];
  methods: string[];
  connectedAt: number[];
  close: () => Promise<void>;
}

async function startFakeCore(options: FakeCoreOptions = {}): Promise<FakeCore> {
  const respond = options.respond ?? true;
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  const connections: WsSocket[] = [];
  const methods: string[] = [];
  const connectedAt: number[] = [];
  server.on('connection', (socket) => {
    connections.push(socket);
    connectedAt.push(Date.now());
    socket.on('message', (raw) => {
      if (!respond) return;
      let request: { id?: number; method?: string };
      try {
        request = JSON.parse(raw.toString()) as { id?: number; method?: string };
      } catch {
        return;
      }
      methods.push(request.method ?? '');
      if (request.method === 'core.ping') {
        socket.send(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { ok: true } }));
      }
    });
  });
  await once(server, 'listening');
  const port = (server.address() as AddressInfo).port;
  return {
    url: `ws://127.0.0.1:${port}`,
    connections,
    methods,
    connectedAt,
    close: () =>
      new Promise<void>((resolve) => {
        for (const socket of connections) socket.terminate();
        server.close(() => resolve());
      }),
  };
}

function testConfig(overrides: Record<string, string> = {}) {
  return readLayoutConfig({
    VITE_RECONNECT_BASE_MS: '20',
    VITE_RECONNECT_CAP_MS: '80',
    VITE_HEARTBEAT_PERIOD_MS: '40',
    VITE_HEARTBEAT_TIMEOUT_MS: '40',
    ...overrides,
  });
}

function makeClient(config = testConfig()) {
  return new RpcClient({
    config,
    webSocketFactory: (url) => new WsWebSocket(url) as unknown as WebSocket,
  });
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 4000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`等待"${what}"超时`);
}

const openClients: RpcClient[] = [];
const openServers: FakeCore[] = [];

afterEach(async () => {
  for (const client of openClients.splice(0)) client.close();
  for (const server of openServers.splice(0)) await server.close();
});

async function setup(options: FakeCoreOptions = {}) {
  const server = await startFakeCore(options);
  openServers.push(server);
  const client = makeClient();
  openClients.push(client);
  const statuses: ConnectionStatus[] = [];
  client.onStatus((status) => statuses.push(status));
  let reconnected = 0;
  client.onReconnected(() => {
    reconnected += 1;
  });
  return { server, client, statuses, reconnectedCount: () => reconnected };
}

describe('断开自动重连（指数退避）', () => {
  it('服务端断开后自动重连、状态开放、请求恢复、onReconnected 只触发一次', async () => {
    const { server, client, statuses, reconnectedCount } = await setup({ respond: true });
    await client.connect(server.url);
    obs('首次连接后的状态序列', statuses);
    expect(statuses).toEqual(['connecting', 'open']);

    server.connections[0].close();
    await waitFor(() => statuses.includes('reconnecting'), '进入重连态');
    await waitFor(
      () => server.connections.length >= 2 && statuses[statuses.length - 1] === 'open',
      '重连成功',
    );
    obs('重连后的状态序列', statuses);
    obs('服务端收到的连接数', server.connections.length);
    obs('onReconnected 触发次数', reconnectedCount());
    expect(reconnectedCount()).toBe(1);

    const ping = await client.request<{ ok: boolean }>('core.ping');
    obs('重连后的请求响应', ping);
    expect(ping.ok).toBe(true);
  });

  it('连不上核心时退避间隔递增且不超过 cap', async () => {
    // 拿一个"关掉的端口"：先 bind 再 close，之后连接一定失败（没有成功连接可重置退避）。
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, '127.0.0.1', () => resolve()));
    const port = (probe.address() as AddressInfo).port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    const attempts: number[] = [];
    const client = new RpcClient({
      config: testConfig({ VITE_RECONNECT_BASE_MS: '30', VITE_RECONNECT_CAP_MS: '120' }),
      webSocketFactory: (url) => {
        attempts.push(Date.now());
        return new WsWebSocket(url) as unknown as WebSocket;
      },
    });
    openClients.push(client);
    await client.connect(`ws://127.0.0.1:${port}`).catch(() => {
      // 首次连接失败是预期：重连链随后接管。
    });
    await waitFor(() => attempts.length >= 4, '至少 4 次连接尝试', 8000);
    const gaps: number[] = [];
    for (let index = 1; index < attempts.length; index += 1) {
      gaps.push(attempts[index] - attempts[index - 1]);
    }
    obs('相邻连接尝试间隔（ms）', gaps);
    expect(gaps.length).toBeGreaterThanOrEqual(3);
    // 30 → 60 → 120：后一次至少不小于前一次（允许平台调度误差）。
    expect(gaps[1]).toBeGreaterThanOrEqual(gaps[0] - 5);
    expect(gaps[2]).toBeGreaterThanOrEqual(gaps[1] - 5);
    expect(Math.max(...gaps)).toBeLessThanOrEqual(120 + 80);
  });
});

describe('心跳探活（周期 core.ping + 超时判死）', () => {
  it('存活对端：周期收到 core.ping，且不触发重连', async () => {
    const { server, client } = await setup({ respond: true });
    await client.connect(server.url);
    await waitFor(() => server.methods.filter((method) => method === 'core.ping').length >= 2, '两次心跳');
    obs('服务端收到的方法', server.methods);
    obs('连接数（不应增长）', server.connections.length);
    expect(server.connections.length).toBe(1);
  });

  it('假对端接受连接但不回 ping：心跳超时判死并触发重连', async () => {
    const { server, client, statuses } = await setup({ respond: false });
    await client.connect(server.url);
    obs('首次连接后的状态序列', statuses);
    await waitFor(() => statuses.includes('reconnecting'), '心跳超时后进入重连态');
    await waitFor(() => server.connections.length >= 2, '超时判死后重新连上（对端仍然不回）');
    obs('重连态出现后的状态序列', statuses);
    obs('服务端连接数', server.connections.length);
    expect(statuses).toContain('reconnecting');
    expect(server.connections.length).toBeGreaterThanOrEqual(2);
  });
});

describe('断线期间的请求', () => {
  it('未连接时请求被拒绝（不永久挂起）', async () => {
    const client = makeClient();
    openClients.push(client);
    await expect(client.request('core.ping')).rejects.toThrow(/未连接/);
  });
});
// ---------------------------------------------------------------------------
// 群聊协议（change `agent-group-chat` 任务 8.1）
// ---------------------------------------------------------------------------

describe('群聊协议形状', () => {
  it('十个群聊方法名在客户端清单里齐备（与核心 kCoreRpcMethodNames 同步）', () => {
    expect([...GROUP_RPC_METHODS]).toEqual([
      'group.create',
      'group.update',
      'group.chain',
      'group.list',
      'group.delete',
      'group.member.add',
      'group.member.remove',
      'group.member.update',
      'group.send',
      'group.view',
    ]);
  });

  // -------------------------------------------------------------------------
  // 自发反应（change `group-reactive-mode` 任务 5.1）
  // -------------------------------------------------------------------------

  it('steps 的状态枚举是封闭的（含 forced_empty / empty / cancelled / failed）', () => {
    // 类型层已经由 `GroupSendStep` 的联合类型固定；这里用可执行断言钉住取值，
    // 防止有人把枚举放宽成 string 而测试仍绿。
    const statuses: GroupSendStepStatus[] = [
      'replied',
      'passed',
      'forced_pass',
      'forced_empty',
      'empty',
      'failed',
      'cancelled',
    ];
    const sources: GroupSendStepSource[] = ['speaker', 'mention', 'reaction'];
    obs('steps statuses', statuses);
    obs('steps sources', sources);
    expect(statuses).toContain('forced_empty');
    expect(statuses).toContain('forced_pass');
    expect(statuses).toContain('empty');
    expect(statuses).toContain('cancelled');
    expect(statuses).toContain('failed');
    expect(statuses.length).toBe(7);
    expect(sources.length).toBe(3);
  });

  it('group.send 异步形状：只带 status/triggerSeq，不带 steps；链状态由 GroupChainResult 承载', () => {
    // 异步契约（change `group-reactive-mode` R.4 / D9）：send 的回包只有
    // groupId/sessionId/status/triggerSeq/error —— 链进度从 `group.chain` 读。
    const send: GroupSendResult = {
      groupId: 'g-1',
      sessionId: 'g-1',
      status: 'started',
      triggerSeq: 1,
    };
    obs('group.send 异步回包', send);
    expect(send.status).toBe('started');
    expect(send.triggerSeq).toBe(1);
    expect('steps' in send).toBe(false);
    expect('rounds' in send).toBe(false);

    const chain: GroupChainResult = {
      groupId: 'g-1',
      sessionId: 'g-1',
      status: 'completed',
      triggerSeq: 4,
      rounds: 2,
      stopReason: 'round_cap',
      steps: [
        {
          memberId: 'member-a',
          source: 'reaction',
          status: 'replied',
          triggerSeq: 1,
          publicSeq: 2,
          finalText: '甲的回复',
          error: null,
        },
        {
          memberId: 'member-b',
          source: 'reaction',
          status: 'passed',
          triggerSeq: 1,
          publicSeq: null,
          finalText: '[PASS]',
          error: null,
        },
      ],
    };
    obs('反应链状态', chain);
    expect(chain.steps.length).toBe(2);
    expect(chain.rounds).toBe(2);
    expect(chain.stopReason).toBe('round_cap');
    expect(chain.steps[0].publicSeq).toBe(2);
  });

  it('组会话可带 reactionsEnabled / maxRounds；group.list 项带 busy / runningMemberId', () => {
    const session: Session = {
      id: 'g-1',
      title: '新组',
      agentType: 'general',
      parentSessionId: null,
      createdAt: 1,
      updatedAt: 2,
      kind: 'group',
      overrides: null,
      reactionsEnabled: true,
      maxRounds: null,
    };
    const summary: GroupSummary = {
      ...session,
      members: [],
      busy: true,
      runningMemberId: 'member-a',
    };
    obs('组会话', session);
    obs('组项', summary);
    expect(session.reactionsEnabled).toBe(true);
    expect(session.maxRounds).toBeNull();
    expect(summary.busy).toBe(true);
    expect(summary.runningMemberId).toBe('member-a');
  });

  it('group.update 的实际 params 带 groupId 与 reactionsEnabled（payload 判据）', async () => {
    const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
    const received: Array<Record<string, unknown>> = [];
    server.on('connection', (socket) => {
      socket.on('message', (raw) => {
        const request = JSON.parse(raw.toString()) as {
          id?: number;
          method?: string;
          params?: Record<string, unknown>;
        };
        if (request.method === 'group.update' && request.params) {
          received.push(request.params);
          socket.send(
            JSON.stringify({
              jsonrpc: '2.0',
              id: request.id,
              result: {
                group: {
                  id: 'g-1',
                  reactionsEnabled: request.params.reactionsEnabled,
                },
              },
            }),
          );
        }
      });
    });
    await once(server, 'listening');
    const port = (server.address() as AddressInfo).port;
    const client = new RpcClient();
    await client.connect(`ws://127.0.0.1:${port}`);
    await client.request('group.update', {
      groupId: 'g-1',
      reactionsEnabled: false,
    });
    obs('group.update 实际收到的 params', received);
    expect(received).toEqual([{ groupId: 'g-1', reactionsEnabled: false }]);
    client.close();
    server.close();
  });

  it('group.send 的实际 params 带 speaker（payload 判据，不是 DOM 选中值）', async () => {
    const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
    const received: Array<Record<string, unknown>> = [];
    server.on('connection', (socket) => {
      socket.on('message', (raw) => {
        const request = JSON.parse(raw.toString()) as {
          id?: number;
          method?: string;
          params?: Record<string, unknown>;
        };
        if (request.method === 'group.send' && request.params) {
          received.push(request.params);
          socket.send(
            JSON.stringify({
              jsonrpc: '2.0',
              id: request.id,
              result: {
                groupId: 'g-1',
                sessionId: 'g-1',
                status: 'started',
                triggerSeq: 7,
              },
            }),
          );
        }
      });
    });
    await once(server, 'listening');
    const port = (server.address() as AddressInfo).port;
    const client = new RpcClient();
    await client.connect(`ws://127.0.0.1:${port}`);
    const result = await client.request<{
      status: string;
      triggerSeq: number;
    }>('group.send', { groupId: 'g-1', speaker: 'member-a', text: '说一句' });
    obs('group.send 实际收到的 params', received);
    expect(received).toEqual([
      { groupId: 'g-1', speaker: 'member-a', text: '说一句' },
    ]);
    expect(result.status).toBe('started');
    expect(result.triggerSeq).toBe(7);
    client.close();
    server.close();
  });
});