// 群视图的真应用端到端（change `agent-group-chat` 任务 8.3~8.7）。
//
// **不是 harness**：这里起一个假的核心（HTTP 静态 + /ws JSON-RPC），把 `web/dist`
// 里的真实 `App.tsx` 喂给它 —— 组视图必须挂在真实路由上（会话列表按 kind 分流），
// 而不是只存在于测试页面里。
//
// 判据以 **payload** 为准：假核心把收到的每个 RPC 的 method+params 与事后广播的
// agent.event payload 都记下来；DOM（分栏内容、按钮）只作辅助证据。
//
// 用法：
//   cd web
//   npm run build            # 生成 web/dist（真实应用）
//   node e2e/group.mjs       # EDGE_PATH 可覆盖；GROUP_KEEP=1 时测完保持服务
//
// 输出：逐条 [PASS]/[FAIL] + 实测数字 + 末尾 JSON 摘要；有失败退出码 1。
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import puppeteer from 'puppeteer-core';
import { WebSocketServer } from 'ws';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const DIST = path.join(ROOT, 'dist');

const results = [];
let failureCount = 0;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function obs(label, value) {
  console.log(`  [量] ${label} = ${typeof value === 'string' ? value : JSON.stringify(value)}`);
}

async function run(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - started });
    console.log(`[PASS] ${name}（${Date.now() - started}ms）`);
  } catch (error) {
    failureCount += 1;
    results.push({ name, ok: false, error: String(error?.message ?? error) });
    console.log(`[FAIL] ${name}：${error?.message ?? error}`);
  }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

function findEdge() {
  const candidates = [
    process.env.EDGE_PATH,
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 假核心：组会话的数据模型 + JSON-RPC + agent.event 广播
// ---------------------------------------------------------------------------

const windows = [1_000_000, 200_000];
let nextId = 1;
const sessions = [
  {
    id: 's-single',
    title: '单会话',
    agentType: 'general',
    parentSessionId: null,
    createdAt: 1,
    updatedAt: 1,
    kind: 'single',
    overrides: null,
    reactionsEnabled: true,
    maxRounds: null,
  },
];
const groups = new Map();
const rpcLog = [];
const eventLog = [];
let sockets = [];

function breakdown(windowTokens, raw, level1, level2) {
  return {
    level2Tokens: level2,
    level1Tokens: level1,
    rawTokens: raw,
    fixedOverheadTokens: 100,
    windowTokens,
    usedTokens: raw + level1 + level2 + 100,
    conversationTokens: raw + level1 + level2,
  };
}

function newGroup(title) {
  const id = `g-${nextId++}`;
  const session = {
    id,
    title,
    agentType: 'general',
    parentSessionId: null,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    kind: 'group',
    overrides: null,
    // 新建组默认开启自发反应（change `group-reactive-mode` D1）：假核心照产品口径来。
    reactionsEnabled: true,
    // 反应轮数上限（R.4 / D13）：null = 用产品默认；界面以默认值占位。
    maxRounds: null,
  };
  sessions.push(session);
  groups.set(id, {
    session,
    members: [],
    messages: [],
    snapshots: {},
    seq: 0,
    busy: false,
    runningMemberId: null,
    aborted: false,
    // R.8：吸收式执行器近似——用户请求排队、串行处理，**永不**因链在跑拒绝。
    pending: [],
    pumping: false,
    // 链状态（R.4 / D9）：idle = 本进程内还没有链；send 立刻回 started、链在后台跑。
    chain: idleChain(),
  });
  return session;
}

function idleChain() {
  return {
    status: 'idle',
    triggerSeq: null,
    rounds: 0,
    stopReason: null,
    steps: [],
  };
}

function chainOfGroup(group) {
  return group.chain ?? idleChain();
}

/**
 * 链进入终态：写 status/stopReason、清 busy、**只广播一次** `group.chain.completed`
 * （唯一新增的事件类型；payload 不带 steps，change `group-reactive-mode` R.2 / D7）。
 */
function finishChain(group, { status, stopReason }) {
  const chain = group.chain;
  if (!chain || chain.status !== 'running') return;
  chain.status = status;
  chain.stopReason = stopReason;
  group.busy = false;
  group.runningMemberId = null;
  broadcast({
    sessionId: group.session.id,
    groupId: group.session.id,
    type: 'group.chain.completed',
    data: {
      status: chain.status,
      stopReason: chain.stopReason,
      rounds: chain.rounds,
      triggerSeq: chain.triggerSeq,
    },
  });
}

/**
 * R.8：假核心的**吸收式执行器**近似。
 *
 * 用户请求排队、串行处理（同一时刻至多一条链写原文）；`group.send` 永不 busy。
 * 每条请求自己重建链状态（新用户触发重置 rounds / steps），处理完广播
 * `group.chain.completed`。真实核心的"轮边界吸收"语义见 design D3；e2e 只验界面契约。
 */
async function pumpGroup(group) {
  if (group.pumping) return;
  group.pumping = true;
  try {
    while (group.pending.length > 0) {
      const request = group.pending.shift();
      await runFakeChain(group, request);
    }
  } catch (error) {
    group.busy = false;
    group.runningMemberId = null;
    if (group.chain && group.chain.status === 'running') {
      finishChain(group, { status: 'failed', stopReason: 'failed' });
    }
    console.log(`  [假核心] group.send 后台失败：${error}`);
  } finally {
    group.pumping = false;
  }
}

/** 跑一条请求对应的假链（每个成员一步；`#pass` 步为结构化沉默）。 */
async function runFakeChain(group, request) {
  const { userMessage, text, responders, speaker } = request;
  group.busy = true;
  group.aborted = false;
  group.runningMemberId = null;
  group.chain = {
    status: 'running',
    triggerSeq: userMessage.seq,
    rounds: 0,
    stopReason: null,
    steps: [],
  };
  // `#forced-pass` / `#pass` 是**假核心专用**提示：分别模拟"被点名却返回 pass=true"
  // 与"自愿轮返回 pass=true"（都不写公开行）；用来验 web 的提示与 steps 状态。
  const forcedPassHint = text.includes('#forced-pass');
  const passHint = text.includes('#pass');
  const maxRounds = group.session.maxRounds;
  let index = 0;
  try {
    for (const member of responders) {
      if (group.aborted) break;
      if (maxRounds !== null && group.chain.rounds >= maxRounds) {
        finishChain(group, { status: 'completed', stopReason: 'round_cap' });
        return;
      }
      // 每一步之间可被 e2e gate 挂住：这样测试能看到"逐条冒出"的中间态，
      // 并在链仍在跑时断言"发送态已解除 / 还能再发"（R.4 / R.8）。
      if (index === 1 && sendGateEnabled) {
        await new Promise((resolve) => {
          sendGate = resolve;
        });
      }
      if (group.aborted) break;
      index += 1;
      group.chain.rounds += 1;
      group.runningMemberId = member.id;
      broadcast({
        sessionId: group.session.id,
        groupId: group.session.id,
        memberId: member.id,
        type: 'agent.streaming',
        data: { streaming: true },
      });
      const source = speaker && member.id === speaker.id ? 'speaker' : 'reaction';
      if (passHint || (forcedPassHint && index === 2)) {
        group.chain.steps.push({
          memberId: member.id,
          source,
          status: forcedPassHint && index === 2 ? 'forced_pass' : 'passed',
          triggerSeq: userMessage.seq,
          publicSeq: null,
          finalText: '',
          error: null,
        });
        broadcast({
          sessionId: group.session.id,
          groupId: group.session.id,
          memberId: member.id,
          type: 'agent.streaming',
          data: { streaming: false },
        });
        continue;
      }
      const privateMessage = pushMessage(group, {
        role: 'assistant',
        content: '',
        author: member.id,
        visibility: 'private-to-author',
      });
      const publicMessage = pushMessage(group, {
        role: 'assistant',
        content: `${member.name}的公开结论：已改完 lib/a.dart`,
        author: member.id,
      });
      group.snapshots[member.id] = {
        sessionId: group.session.id,
        model: 'fake-model',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        capturedAt: new Date().toISOString(),
        windowTokens: member.window,
        agentType: 'general',
        breakdown: breakdown(member.window, 1200, 300, 100),
        messages: [{ role: 'user', content: text }],
        system: '你是测试模板。',
        tools: '[]',
        skillFailures: [],
        skillFailureNotice: null,
      };
      broadcast({
        sessionId: group.session.id,
        groupId: group.session.id,
        memberId: member.id,
        type: 'assistant.message',
        data: publicMessage,
      });
      broadcast({
        sessionId: group.session.id,
        groupId: group.session.id,
        memberId: member.id,
        type: 'assistant.message',
        data: privateMessage,
      });
      broadcast({
        sessionId: group.session.id,
        groupId: group.session.id,
        memberId: member.id,
        type: 'agent.streaming',
        data: { streaming: false },
      });
      group.chain.steps.push({
        memberId: member.id,
        source,
        status: 'replied',
        triggerSeq: userMessage.seq,
        publicSeq: publicMessage.seq,
        finalText: publicMessage.content,
        error: null,
      });
    }
  } finally {
    group.busy = false;
    group.runningMemberId = null;
    if (group.chain && group.chain.status === 'running') {
      finishChain(group, {
        status: group.aborted ? 'cancelled' : 'completed',
        stopReason: group.aborted ? 'cancelled' : 'all_passed',
      });
    }
  }
}

function pushMessage(group, { role, content, author = null, visibility = 'public' }) {
  group.seq += 1;
  const message = {
    id: `m-${group.session.id}-${group.seq}`,
    seq: group.seq,
    sessionId: group.session.id,
    role,
    content,
    toolCalls: null,
    thinking: null,
    tokenCount: null,
    outputTokenCount: null,
    createdAt: Date.now(),
    attachments: [],
    author,
    visibility,
  };
  group.messages.push(message);
  return message;
}

function describeGroup(group) {
  return {
    ...group.session,
    members: group.members.map((member) => ({
      id: member.id,
      name: member.name,
      template: member.template,
      removedAt: member.removedAt,
      overrides: member.overrides,
      effective: {
        tools: member.overrides?.toolsSubset ?? ['read_file', 'list_dir', 'run_command'],
        systemPrompt: `模板 + ${member.overrides?.systemPromptAppend ?? ''}`,
        thinkingMode: member.overrides?.thinkingEffort ? 'adaptive' : 'disabled',
        thinkingEffort: member.overrides?.thinkingEffort ?? '',
        model: 'fake-model',
        maxContextTokens: member.window,
      },
    })),
    // 只读忙碌状态（change `group-reactive-mode` D7）：断线重连后的 web 靠它恢复
    // "链在跑"并启用取消按钮。
    busy: group.busy === true,
    runningMemberId: group.runningMemberId ?? null,
  };
}

/**
 * 假核心的「按成员分步」闸门（只用于 e2e 观察**逐步展开**，不是产品接口）。
 *
 * `GET /__gate_next_send` 让下一次 `group.send` 在**第一个成员之后**暂停；
 * `GET /__release_send` 放行。这样测试能在同一条链中途断言"时间线只出现了第一位
 * 成员的公开回复、还没有第二位"。
 */
let sendGate = null;
let sendGateEnabled = false;


function broadcast(event) {
  eventLog.push(event);
  const payload = JSON.stringify({ jsonrpc: '2.0', method: 'agent.event', params: event });
  for (const socket of sockets) socket.send(payload);
}

function reply(socket, id, result) {
  // 页面在链中途刷新/关闭时 socket 已关：静默跳过（假核心不该因此崩溃）。
  if (socket.readyState !== 1) return;
  socket.send(JSON.stringify({ jsonrpc: '2.0', id, result }));
}

/** 记录**响应**（payload 判据的一部分：`group.send` 的 steps 在响应里，不在 params 里）。 */
const responseLog = [];

function replyLogged(socket, id, method, result) {
  responseLog.push({ method, result });
  reply(socket, id, result);
}

function fail(socket, id, message) {
  if (socket.readyState !== 1) return;
  socket.send(
    JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32602, message } }),
  );
}

function handleRpc(socket, request) {
  const { id, method, params = {} } = request;
  rpcLog.push({ method, params });
  if (method === 'core.ping') return reply(socket, id, { ok: true });
  if (method === 'config.get') {
    return reply(socket, id, {
      missing: false,
      providers: {},
      agentTypes: { general: { input_modalities: ['text'] } },
      tools: ['read_file', 'list_dir', 'run_command'],
    });
  }
  if (method === 'template.list') {
    return reply(socket, id, {
      templates: [{ name: 'general' }, { name: 'narrow' }],
      tools: ['read_file', 'list_dir', 'run_command'],
      thinkingEfforts: ['low', 'medium', 'high', 'max'],
      defaultTools: ['read_file', 'list_dir', 'run_command'],
      providers: ['p'],
      effectiveNote: '只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。',
    });
  }
  if (method === 'session.list') return reply(socket, id, { sessions });
  if (method === 'session.create') {
    const session = {
      id: `s-${nextId++}`,
      title: '新会话',
      agentType: 'general',
      parentSessionId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      kind: 'single',
      overrides: null,
      reactionsEnabled: true,
    };
    sessions.unshift(session);
    return reply(socket, id, { session });
  }
  if (method === 'group.create') {
    const group = newGroup(params.title ?? '新组');
    return reply(socket, id, { group });
  }
  if (method === 'group.list') {
    return reply(socket, id, { groups: [...groups.values()].map(describeGroup) });
  }
  if (method === 'message.query') {
    const group = groups.get(params.sessionId);
    const all = [...(group?.messages ?? [])].sort((a, b) => a.seq - b.seq);
    const pageSize = params.pageSize;
    const pageOf = (start, end) => {
      const messages = all.slice(start, end);
      const firstSeq = messages.length > 0 ? messages[0].seq : null;
      const lastSeq = messages.length > 0 ? messages[messages.length - 1].seq : null;
      const hasEarlier = firstSeq !== null && all.some((message) => message.seq < firstSeq);
      const hasNewer = lastSeq !== null && all.some((message) => message.seq > lastSeq);
      return {
        sessionId: params.sessionId,
        pageSize,
        messages,
        nextCursor: hasNewer ? lastSeq : null,
        prevCursor: hasEarlier ? firstSeq : null,
      };
    };
    if (params.before !== undefined && params.before !== null) {
      // 反向游标：取 seq < before 的最后一页。
      const eligible = all.filter((message) => message.seq < params.before);
      return reply(socket, id, pageOf(
        Math.max(0, eligible.length - pageSize),
        eligible.length,
      ));
    }
    if (params.cursor !== undefined && params.cursor !== null) {
      const eligible = all.filter((message) => message.seq > params.cursor);
      return reply(socket, id, pageOf(0, Math.min(pageSize, eligible.length)));
    }
    if (params.anchor === 'head') return reply(socket, id, pageOf(0, pageSize));
    return reply(socket, id, pageOf(Math.max(0, all.length - pageSize), all.length));
  }
  if (method === 'group.member.add') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    const member = {
      id: `mem-${nextId++}`,
      name: params.name,
      template: params.templateName,
      removedAt: null,
      overrides: params.overrides ?? null,
      window: windows[group.members.length % windows.length],
    };
    group.members.push(member);
    return reply(socket, id, {
      groupId: params.groupId,
      member: describeGroup(group).members.find((entry) => entry.id === member.id),
    });
  }
  if (method === 'group.member.update') {
    const group = groups.get(params.groupId);
    const member = group?.members.find((entry) => entry.id === params.memberId);
    if (!member) return fail(socket, id, `成员 ${params.memberId} 不存在`);
    if (params.name) member.name = params.name;
    if (params.overrides) member.overrides = params.overrides;
    return reply(socket, id, {
      groupId: params.groupId,
      member: describeGroup(group).members.find((entry) => entry.id === member.id),
    });
  }
  if (method === 'group.member.remove') {
    const group = groups.get(params.groupId);
    const member = group?.members.find((entry) => entry.id === params.memberId);
    if (!member) return fail(socket, id, `成员 ${params.memberId} 不存在`);
    member.removedAt = Date.now();
    return reply(socket, id, { groupId: params.groupId, memberId: member.id, removed: true });
  }
  if (method === 'group.view') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    return reply(socket, id, {
      groupId: params.groupId,
      memberId: params.memberId,
      snapshot: group.snapshots[params.memberId] ?? null,
    });
  }
  if (method === 'group.update') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    const hasReactions = Object.prototype.hasOwnProperty.call(params, 'reactionsEnabled');
    const hasMaxRounds = Object.prototype.hasOwnProperty.call(params, 'maxRounds');
    if (!hasReactions && !hasMaxRounds) {
      return fail(socket, id, 'group.update 至少要给一个字段（reactionsEnabled / maxRounds）');
    }
    if (hasReactions && typeof params.reactionsEnabled !== 'boolean') {
      return fail(socket, id, 'reactionsEnabled 必须是布尔');
    }
    if (hasMaxRounds && params.maxRounds !== null) {
      const value = params.maxRounds;
      if (!Number.isInteger(value) || value < 1 || value > 50) {
        return fail(socket, id, `maxRounds 必须是 1..50 的整数或 null，实测 ${value}`);
      }
    }
    if (group.busy) return fail(socket, id, '组正在运行反应链：不能改设置');
    if (hasReactions) group.session.reactionsEnabled = params.reactionsEnabled;
    if (hasMaxRounds) group.session.maxRounds = params.maxRounds;
    return replyLogged(socket, id, method, { group: group.session });
  }
  if (method === 'group.chain') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    return replyLogged(socket, id, method, {
      groupId: group.session.id,
      sessionId: group.session.id,
      ...chainOfGroup(group),
    });
  }
  if (method === 'group.send') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    const text = params.text ?? '';
    const active = group.members.filter((member) => member.removedAt === null);
    const speaker =
      params.speaker === undefined || params.speaker === null
        ? null
        : active.find((member) => member.id === params.speaker) ?? null;
    if (params.speaker !== undefined && params.speaker !== null && speaker === null) {
      return fail(socket, id, `发言者 ${params.speaker} 不存在或已移除`);
    }
    if (!speaker && !group.session.reactionsEnabled) {
      return fail(socket, id, 'no_speaker：关闭自发反应时必须点名一个成员');
    }
    if (!speaker && text.trim().length === 0) {
      return fail(socket, id, 'no_trigger：没有可触发的公开消息');
    }
    /** 假核心按"点名者优先，其余按加入顺序"排步骤（真实核心同口径，见 design D3）。 */
    const responders = [];
    if (speaker) responders.push(speaker);
    if (group.session.reactionsEnabled) {
      for (const member of active) {
        if (speaker && member.id === speaker.id) continue;
        responders.push(member);
      }
    }
    // 用户消息由**组服务**写：事件不带 memberId（spec「不伪造 memberId」）。
    const userMessage = pushMessage(group, {
      role: 'user',
      content: text,
      author: null,
    });
    broadcast({
      sessionId: group.session.id,
      groupId: group.session.id,
      type: 'user.message',
      data: userMessage,
    });
    // **立刻回 started**（R.8：永不 busy；链运行中再发也接受、入队排队）。
    replyLogged(socket, id, method, {
      groupId: group.session.id,
      sessionId: group.session.id,
      status: 'started',
      triggerSeq: userMessage.seq,
    });
    group.pending.push({ userMessage, text, responders, speaker });
    void pumpGroup(group);
    return;
  }
  if (method === 'agent.cancel') {
    const group = groups.get(params.sessionId);
    if (group && (group.busy || group.pending.length > 0)) {
      const cancelledMemberId = group.runningMemberId;
      group.aborted = true;
      // R.8：取消停当前链并**清空排队**（已写入的用户消息保留）。
      group.pending.length = 0;
      if (sendGate) {
        sendGate();
        sendGate = null;
      }
      finishChain(group, { status: 'cancelled', stopReason: 'cancelled' });
      group.busy = false;
      group.runningMemberId = null;
      return replyLogged(socket, id, method, {
        sessionId: group.session.id,
        groupId: group.session.id,
        cancelled: true,
        reactionChainStopped: true,
        memberId: cancelledMemberId,
        reason: '已取消正在运行的成员，整条反应链已停止',
      });
    }
    return replyLogged(socket, id, method, { cancelled: false });
  }
  return fail(socket, id, `fake core 未实现 ${method}`);
}

// ---------------------------------------------------------------------------
// 静态 + WS 服务
// ---------------------------------------------------------------------------

function startServer() {
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url ?? '/').split('?')[0]);
    // e2e 夹具：造一个含 45 条历史（含已移除成员「丁」的私有/公开行）的组。
    // 只存在于假核心，不是产品接口。
    if (requestPath === '/__seed_group') {
      const seeded = newGroup('分页组');
      const group = groups.get(seeded.id);
      for (const name of ['甲', '乙', '丁']) {
        group.members.push({
          id: `mem-page-${name}`,
          name,
          template: 'general',
          removedAt: name === '丁' ? Date.now() : null,
          overrides: null,
          window: windows[group.members.length % windows.length],
        });
      }
      const [a, b, c] = group.members;
      pushMessage(group, { role: 'user', content: '分页历史 1：用户先说话' });
      pushMessage(group, { role: 'assistant', content: '', author: c.id, visibility: 'private-to-author' });
      pushMessage(group, { role: 'assistant', content: '丁的公开结论：已看完 lib/old.dart', author: c.id });
      pushMessage(group, { role: 'user', content: '分页历史 2：用户又说一句' });
      for (let i = 0; i < 41; i += 1) {
        const who = i % 2 === 0 ? a : b;
        pushMessage(group, { role: 'assistant', content: `${who.name}的历史公开回复 ${i}`, author: who.id });
      }
      const index = sessions.findIndex((session) => session.id === seeded.id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: seeded.id, title: seeded.title }));
      return;
    }
    // 自发反应的 e2e 夹具（假核心专用）：建一个**开启自发反应**、含三个成员的组。
    // 标题可由 `?title=` 指定，避免多个 '新组' 在会话列表里无法区分。
    if (requestPath === '/__seed_reaction_group') {
      const title =
        new URL(request.url ?? '/', 'http://127.0.0.1').searchParams.get('title') ??
        '反应组';
      const seeded = newGroup(title);
      const group = groups.get(seeded.id);
      for (const name of ['甲', '乙', '丙']) {
        group.members.push({
          id: `mem-rx-${seeded.id}-${name}`,
          name,
          template: 'general',
          removedAt: null,
          overrides: null,
          window: windows[group.members.length % windows.length],
        });
      }
      const index = sessions.findIndex((session) => session.id === seeded.id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: seeded.id, title: seeded.title }));
      return;
    }
    // e2e 观察「按成员分步展开」的闸门（只存在于假核心，不是产品接口）。
    if (requestPath === '/__gate_next_send') {      sendGateEnabled = true;
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ gated: true }));
      return;
    }
    if (requestPath === '/__release_send') {
      sendGateEnabled = false;
      if (sendGate) {
        sendGate();
        sendGate = null;
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ released: true }));
      return;
    }
    const relative = requestPath === '/' ? 'index.html' : requestPath.replace(/^\/+/, '');    const target = path.join(DIST, relative);
    if (!target.startsWith(DIST)) {
      response.writeHead(403).end('forbidden');
      return;
    }
    fs.readFile(target, (error, data) => {
      if (error) {
        response.writeHead(404).end('not found');
        return;
      }
      response.writeHead(200, {
        'Content-Type': MIME[path.extname(target)] ?? 'application/octet-stream',
        'Cache-Control': 'no-store',
      });
      response.end(data);
    });
  });
  const wss = new WebSocketServer({ server, path: '/ws' });
  wss.on('connection', (socket) => {
    sockets.push(socket);
    socket.on('message', (raw) => {
      let request;
      try {
        request = JSON.parse(raw.toString());
      } catch {
        return;
      }
      handleRpc(socket, request);
    });
    socket.on('close', () => {
      sockets = sockets.filter((entry) => entry !== socket);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({
        url: `http://127.0.0.1:${address.port}/`,
        close: () =>
          new Promise((done) => {
            for (const socket of sockets) socket.close();
            wss.close();
            server.close(done);
          }),
      });
    });
  });
}

if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.error('缺少 web/dist/index.html：先跑 `npm run build`。');
  process.exit(2);
}
const edgePath = findEdge();
if (!edgePath) {
  console.error('找不到 msedge.exe：设置 EDGE_PATH 指向本机 Edge。');
  process.exit(2);
}

// GROUP_DEFAULT=1：预先造一个有两个成员的组并排在会话列表首位，让真实 App 一打开
// 就落在组视图上（`design_audit` 要量的是组视图，不是聊天屏）。
if (process.env.GROUP_DEFAULT === '1') {
  const seeded = newGroup('审计组');
  const group = groups.get(seeded.id);
  for (const name of ['甲', '乙']) {
    group.members.push({
      id: `mem-seed-${name}`,
      name,
      template: 'general',
      removedAt: null,
      overrides: name === '甲' ? { toolsSubset: ['read_file'], systemPromptAppend: '只读不动手。' } : null,
      window: windows[group.members.length % windows.length],
    });
  }
  pushMessage(group, { role: 'user', content: '你们两个都看一下 lib/a.dart' });
  pushMessage(group, {
    role: 'assistant',
    content: '甲的公开结论：已改完 lib/a.dart',
    author: group.members[0].id,
  });
  pushMessage(group, {
    role: 'assistant',
    content: '',
    author: group.members[0].id,
    visibility: 'private-to-author',
  });
  group.snapshots[group.members[0].id] = {
    sessionId: group.session.id,
    model: 'fake-model',
    thinkingMode: 'adaptive',
    thinkingEffort: 'high',
    capturedAt: new Date().toISOString(),
    windowTokens: group.members[0].window,
    agentType: 'general',
    breakdown: breakdown(group.members[0].window, 1200, 300, 100),
    messages: [{ role: 'user', content: '你们两个都看一下 lib/a.dart' }],
    system: '你是测试模板。',
    tools: '[]',
    skillFailures: [],
    skillFailureNotice: null,
  };
  // 组会话排到最前：App 启动即选中它。
  const index = sessions.findIndex((session) => session.id === seeded.id);
  if (index >= 0) {
    const [entry] = sessions.splice(index, 1);
    sessions.unshift(entry);
  }
}

const staticServer = await startServer();
const browser = await puppeteer.launch({
  executablePath: edgePath,
  headless: true,
  args: [
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--hide-scrollbars',
    '--force-device-scale-factor=1',
  ],
});
console.log(`[群视图 e2e] url=${staticServer.url} edge=${edgePath} headless=true`);

async function openPage(width = 1280, height = 900) {
  const page = await browser.newPage();
  await page.setViewport({ width, height });
  page.on('console', (message) => {
    if (message.type() === 'error') console.log(`  [页面错误] ${message.text()}`);
  });
  page.on('pageerror', (error) => console.log(`  [页面异常] ${error.message}`));
  await page.goto(staticServer.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  return page;
}

/** 组视图当前已加载的行（公开时间线 + 每个私有分栏）。 */
/** 打开一个已存在的组：若应用已自动落在组视图（种子组排第一）就直接用，否则点会话行。 */
async function openExistingGroup(page, title) {
  await page.waitForFunction(
    (label) =>
      document.querySelector('[data-testid="group-view"]') !== null ||
      [...document.querySelectorAll('[data-testid="session-row"]')].some((row) =>
        row.textContent?.includes(label),
      ),
    { timeout: 15000 },
    title,
  );
  if ((await page.$('[data-testid="group-view"]')) === null) {
    await page.evaluate((label) => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes(label))?.click();
    }, title);
  }
  await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
}

async function groupRowCounts(page) {
  return page.evaluate(() => {
    const timelineSeqs = [...document.querySelectorAll('[data-testid="timeline-item"]')].map(
      (node) => Number(node.getAttribute('data-seq')),
    );
    const lanes = [...document.querySelectorAll('[data-testid^="lane-mem-"]')].map((article) => ({
      testid: article.getAttribute('data-testid'),
      rows: article.querySelectorAll('[data-testid="lane-item"]').length,
      text: article.textContent ?? '',
    }));
    return {
      timeline: timelineSeqs.length,
      timelineSeqs,
      lanes,
      totalLaneRows: lanes.reduce((sum, lane) => sum + lane.rows, 0),
    };
  });
}

async function clickByTestId(page, testId) {
  const selector = `[data-testid="${testId}"]`;
  await page.waitForSelector(selector, { timeout: 15000 });
  await page.click(selector);
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

await run('8.3 真实 App 挂载：建组 → 刷新 → 点组 → 组视图（不是 harness）', async () => {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    // 建组：会话列表的「＋ 组」入口。
    await clickByTestId(page, 'group-create');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const kind = await page.$eval('[data-testid="group-kind"]', (element) => element.textContent);
    obs('组视图 kind 标签', kind);
    assert(kind.includes('group'), `组视图应标 kind=group，实测 ${kind}`);

    // 刷新后：会话列表里仍有组；点它 → 仍进组视图（kind 分流，不是聊天屏）。
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    const groupRow = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      const target = rows.find((row) => row.textContent?.includes('新组'));
      if (!target) return null;
      return target.textContent;
    });
    obs('刷新后的会话行（找组）', groupRow);
    assert(groupRow !== null, '刷新后组会话必须仍出现在列表里');
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      const target = rows.find((row) => row.textContent?.includes('新组'));
      target.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    assert(
      (await page.$('[data-testid="group-timeline"]')) !== null,
      '组视图应显示公开时间线',
    );
  } finally {
    await page.close();
  }
});

let memberA = '';
let memberB = '';

await run('8.4 操作面：加两个成员、编辑覆盖层（生效可核）、选发言人发送', async () => {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    // 已在上一用例建过组：点它。
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });

    for (const name of ['甲', '乙']) {
      await page.type('[data-testid="member-name-input"]', name);
      await clickByTestId(page, 'member-add');
      await page.waitForFunction(
        (label) =>
          [...document.querySelectorAll('[data-testid^="member-name-"]')].some((node) =>
            node.textContent?.startsWith(label),
          ),
        { timeout: 15000 },
        name,
      );
    }
    const memberIds = await page.$$eval('[data-testid^="member-name-"]', (nodes) =>
      nodes
        .map((node) => node.getAttribute('data-testid')?.replace('member-name-', '') ?? '')
        // 排除"加入成员"输入框（data-testid="member-name-input"）。
        .filter((id) => id.startsWith('mem-')),
    );
    obs('成员 id', memberIds);
    assert(memberIds.length >= 2, `应有至少两个成员，实测 ${memberIds.length}`);
    [memberA, memberB] = memberIds;

    // 本用例验的是**关闭态纯点名**（旧语义）：先把自发反应关掉，这样只有被点名的
    // 成员跑一轮、乙保持"本次运行内没发过言"（8.6 的占位断言依赖它）。
    // 开关本身的行为由 9.1 单独验。
    const toggleChecked = await page.$eval(
      '[data-testid="reactions-toggle"]',
      (element) => element.checked,
    );
    if (toggleChecked) {
      await clickByTestId(page, 'reactions-toggle');
      await page.waitForFunction(
        () =>
          document.querySelector('[data-testid="reactions-toggle"]')?.checked === false,
        { timeout: 15000 },
      );
    }

    // 编辑甲的覆盖层：只留 read_file + 追加提示词 + high。
    await clickByTestId(page, `member-edit-${memberA}`);
    await page.waitForSelector(`[data-testid="override-editor-${memberA}"]`, { timeout: 15000 });
    const editorTools = await page.$$eval(
      `[data-testid^="tool-${memberA}-"]`,
      (nodes) => nodes.map((node) => node.getAttribute('data-testid')),
    );
    obs('覆盖层编辑器里的工具复选框', editorTools);
    for (const tool of ['list_dir', 'run_command']) {
      const checked = await page.$eval(
        `[data-testid="tool-${memberA}-${tool}"]`,
        (element) => element.checked,
      );
      if (checked) await page.click(`[data-testid="tool-${memberA}-${tool}"]`);
    }
    await page.type(`[data-testid="append-${memberA}"]`, '只读不动手。');
    await page.select(`[data-testid="effort-${memberA}"]`, 'high');
    await clickByTestId(page, `member-save-${memberA}`);
    await page.waitForFunction(
      (id) => {
        const node = document.querySelector(`[data-testid="effective-${id}"]`);
        return node?.textContent?.includes('read_file') && node.textContent.includes('high');
      },
      { timeout: 15000 },
      memberA,
    );
    const effective = await page.$eval(
      `[data-testid="effective-${memberA}"]`,
      (element) => element.textContent,
    );
    obs('甲生效配置（界面可核）', effective);
    assert(effective.includes('read_file') && !effective.includes('run_command'), '生效工具必须只剩子集');
    assert(effective.includes('high'), '生效思考强度必须是 high');

    // 选发言人并发送。
    await page.select('[data-testid="speaker-select"]', memberA);
    await page.type('[data-testid="group-input"]', '甲先说一句');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('甲的公开结论'),
        ),
      { timeout: 15000 },
    );

    // **payload 判据**：假核心实际收到的 group.send params。
    const sendRpc = rpcLog.filter((entry) => entry.method === 'group.send').at(-1);
    obs('group.send 实际 params', sendRpc?.params);
    assert(sendRpc?.params?.speaker === memberA, `speaker 必须是甲的 id，实测 ${sendRpc?.params?.speaker}`);
    assert(sendRpc?.params?.groupId, 'group.send 必须带 groupId');
    const updateRpc = rpcLog.filter((entry) => entry.method === 'group.member.update').at(-1);
    obs('group.member.update 实际 params', updateRpc?.params);
    assert(updateRpc?.params?.overrides?.toolsSubset?.length === 1, '工具子集必须真的提交了');
    assert(updateRpc?.params?.overrides?.thinkingEffort === 'high', '思考强度必须真的提交了');
  } finally {
    await page.close();
  }
});

await run('8.5 事件按 payload 归位：memberId 进分栏、公开回复进时间线', async () => {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    // 事件 payload（服务端记录）必须带 groupId + memberId。
    const messageEvents = eventLog.filter((event) => event.type === 'assistant.message');
    obs('assistant.message 事件身份', messageEvents.map((event) => ({ groupId: event.groupId, memberId: event.memberId })));
    assert(messageEvents.length >= 1, '应有 assistant.message 事件');
    for (const event of messageEvents) {
      assert(event.groupId, '事件必须带 groupId');
      assert(event.memberId, '事件必须带 memberId');
    }
    // 私有行落到甲的分栏、不出现在时间线。
    const laneText = await page.$eval(
      `[data-testid="lane-${memberA}"]`,
      (element) => element.textContent,
    );
    const timelineText = await page.$eval(
      '[data-testid="group-timeline"]',
      (element) => element.textContent,
    );
    obs('甲分栏内容含私有过程', laneText.includes('私有过程'));
    obs('时间线是否泄漏私有行', timelineText.includes('私有过程'));
    assert(laneText.includes('私有过程'), '私有行必须落到该成员分栏');
    assert(!timelineText.includes('私有过程'), '私有行不得进公开时间线');
    // DOM 选中值只作辅助：speaker 那个成员的运行事件必须真的带同一个 memberId
    // （链里可能还有别的成员，所以按 memberId 找，不是"最后一条事件"）。
    const sendRpc = rpcLog.filter((entry) => entry.method === 'group.send').at(-1);
    assert(
      messageEvents.some((event) => event.memberId === sendRpc?.params?.speaker),
      'speaker 的成员运行事件必须带同一个 memberId',
    );
  } finally {
    await page.close();
  }
});

await run('8.6 复用组件：真实上下文视图 + 每成员占用环（分母各自窗口）', async () => {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    // 甲有快照：环与窗口；乙没发过言：占位（环不渲染）。
    const windowA = await page.$eval(
      `[data-testid="lane-window-${memberA}"]`,
      (element) => element.textContent,
    );
    obs('甲的窗口（环分母）', windowA);
    assert(windowA.includes('1000000'), `甲的分母应是 1000000，实测 ${windowA}`);
    const ringA = await page.$(`[data-testid="lane-ring-${memberA}"]`);
    assert(ringA !== null, '甲应有占用环');
    const noSnapshotB = await page.$(`[data-testid="lane-nosnapshot-${memberB}"]`);
    assert(noSnapshotB !== null, '乙没发过言应显示"本次运行内没发过言"占位');
    const noRingB = await page.$(`[data-testid="lane-noring-${memberB}"]`);
    assert(noRingB !== null, '没有快照时环不渲染');

    // 真实上下文：group.view 的 system/messages/tools 原始 JSON。
    await clickByTestId(page, `lane-context-${memberA}`);
    await page.waitForSelector('[data-testid="real-context"]', { timeout: 15000 });
    const raw = await page.$eval('[data-testid="real-context"] pre', (element) => element.textContent);
    obs('真实上下文 JSON 片段', raw.slice(0, 80));
    assert(raw.includes('"system"') && raw.includes('"messages"') && raw.includes('"tools"'), '必须显示 system/messages/tools');
  } finally {
    await page.close();
  }
});

await run('8.8 上翻分页：公开时间线与私有分栏同步补页（before 游标 payload 判据）', async () => {
  // 假核心夹具：45 条历史，含已移除成员「丁」的私有/公开旧行（只存在于最旧的页）。
  const seeded = await fetch(`${staticServer.url}__seed_group`).then((response) => response.json());
  obs('分页夹具', seeded);
  const page = await openPage();
  try {
    await openExistingGroup(page, '分页组');
    await page.waitForSelector('[data-testid="timeline-item"]', { timeout: 15000 });

    const initial = await groupRowCounts(page);
    obs('首屏（尾页）行数', { timeline: initial.timeline, lanes: initial.totalLaneRows });
    assert(initial.timeline > 0, '首屏时间线应有行');
    assert(initial.totalLaneRows === 0, '尾页里不应有已移除成员的旧私有行');

    // 上翻：既有聊天屏的分页控件/复用同一套游标。
    await clickByTestId(page, 'group-load-earlier');
    await page.waitForFunction(
      (baseline) =>
        document.querySelectorAll('[data-testid="timeline-item"]').length > baseline,
      { timeout: 15000 },
      initial.timeline,
    );
    const after = await groupRowCounts(page);
    obs('上翻后行数', { timeline: after.timeline, lanes: after.totalLaneRows });
    assert(after.timeline > initial.timeline, '公开时间线必须补页');
    assert(after.totalLaneRows > initial.totalLaneRows, '私有分栏必须同步补页');
    const laneDing = after.lanes.find((lane) => lane.text.includes('丁'));
    assert(laneDing !== undefined, '已移除成员「丁」的分栏必须仍存在');
    assert(laneDing.text.includes('（已移除）'), '丁的分栏必须标「（已移除）」');
    assert(laneDing.rows >= 1, '丁的历史私有行必须在上翻后落到它的栏里');
    const timelineText = await page.$eval(
      '[data-testid="group-timeline"]',
      (element) => element.textContent,
    );
    assert(
      timelineText.includes('丁') && timelineText.includes('丁的公开结论'),
      '丁的公开旧行必须带作者归属进时间线（已移除成员仍可归属）',
    );

    // 不丢不重：时间线 seq 不重复，且确实加载到了更旧的 seq。
    assert(
      new Set(after.timelineSeqs).size === after.timelineSeqs.length,
      '上翻后时间线不得出现重复行',
    );
    const minBefore = Math.min(...initial.timelineSeqs);
    const minAfter = Math.min(...after.timelineSeqs);
    obs('最小 seq（上翻前 → 后）', `${minBefore} → ${minAfter}`);
    assert(minAfter < minBefore, '上翻必须加载到更旧的 seq');

    // payload 判据：message.query 实际带了 before 游标。
    const paged = rpcLog.filter(
      (entry) => entry.method === 'message.query' && entry.params.before !== undefined,
    );
    obs('带 before 的 message.query', paged.at(-1)?.params);
    assert(paged.length >= 1, '上翻必须用 before 游标（payload 判据，不看 DOM）');
  } finally {
    await page.close();
  }
});

await run('8.7 布局：1280 宽与窄屏不重叠/不溢出（几何断言）', async () => {
  for (const width of [1280, 720]) {
    const page = await openPage(width, 900);
    try {
      await openExistingGroup(page, '分页组');
      const geometry = await page.evaluate(() => {
        const timeline = document.querySelector('[data-testid="group-timeline"]')?.getBoundingClientRect();
        const lane = document.querySelector('[data-testid^="lane-"]')?.getBoundingClientRect();
        return {
          scrollWidth: document.documentElement.scrollWidth,
          innerWidth: window.innerWidth,
          timeline: timeline && { left: timeline.left, right: timeline.right, top: timeline.top, bottom: timeline.bottom },
          lane: lane && { left: lane.left, right: lane.right, top: lane.top, bottom: lane.bottom },
        };
      });
      obs(`${width}px 几何`, geometry);
      assert(
        geometry.scrollWidth <= geometry.innerWidth + 1,
        `${width}px：出现横向溢出（scrollWidth=${geometry.scrollWidth} > innerWidth=${geometry.innerWidth}）`,
      );
      const overlaps =
        geometry.timeline &&
        geometry.lane &&
        geometry.timeline.left < geometry.lane.right &&
        geometry.lane.left < geometry.timeline.right &&
        geometry.timeline.top < geometry.lane.bottom &&
        geometry.lane.top < geometry.timeline.bottom;
      assert(!overlaps, `${width}px：时间线与成员分栏重叠`);
      const tooSmall = await page.evaluate(() =>
        [...document.querySelectorAll('[data-testid="group-send"], [data-testid="member-add"], [data-testid="speaker-select"]')].some(
          (node) => node.getBoundingClientRect().height < 24,
        ),
      );
      assert(!tooSmall, `${width}px：关键控件高度小于 24px（触控尺寸不足）`);
    } finally {
      await page.close();
    }
  }
});

// ---------------------------------------------------------------------------
// 自发反应（change `group-reactive-mode` 任务 5.2 / design D10）
// ---------------------------------------------------------------------------

async function seedReactionGroup(title) {
  const seeded = await fetch(
    `${staticServer.url}__seed_reaction_group?title=${encodeURIComponent(title)}`,
  ).then((response) => response.json());
  obs(`反应组夹具 ${title}`, seeded);
  return seeded;
}

async function toggleChecked(page) {
  return page.$eval('[data-testid="reactions-toggle"]', (element) => element.checked);
}

async function waitForToggle(page, expected) {
  await page.waitForFunction(
    (want) =>
      document.querySelector('[data-testid="reactions-toggle"]')?.checked === want,
    { timeout: 15000 },
    expected,
  );
}

async function timelineHas(page, text) {
  return page.evaluate((label) => {
    const timeline = document.querySelector('[data-testid="group-timeline"]');
    return timeline?.textContent?.includes(label) === true;
  }, text);
}

await run('9.1 自发反应开关：新建组默认开启；点开关发出 group.update', async () => {
  await seedReactionGroup('反应组开关');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组开关');
    const initial = await toggleChecked(page);
    obs('打开组时的开关初始值', initial);
    assert(initial === true, '新建组默认必须开启自发反应（开关 checked）');

    await clickByTestId(page, 'reactions-toggle');
    await waitForToggle(page, false);
    const updateOff = rpcLog.filter((entry) => entry.method === 'group.update').at(-1);
    obs('group.update 实际 params（关闭）', updateOff?.params);
    assert(updateOff !== undefined, '点开关必须发出 group.update');
    assert(
      updateOff.params.reactionsEnabled === false,
      `group.update 必须带 reactionsEnabled=false，实测 ${JSON.stringify(updateOff.params)}`,
    );
    assert(updateOff.params.groupId, 'group.update 必须带 groupId');

    await clickByTestId(page, 'reactions-toggle');
    await waitForToggle(page, true);
    const updateOn = rpcLog.filter((entry) => entry.method === 'group.update').at(-1);
    obs('group.update 实际 params（开启）', updateOn?.params);
    assert(updateOn.params.reactionsEnabled === true, '再次点击必须改回 true');
  } finally {
    await page.close();
  }
});

await run('9.2 开启态不选发言人发送：speaker 缺省 + 成员分步出现（不是只看最终行数）', async () => {
  await seedReactionGroup('反应组分步');
  await fetch(`${staticServer.url}__gate_next_send`);
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组分步');
    assert((await toggleChecked(page)) === true, '该组必须是开启态');
    const speakerValue = await page.$eval(
      '[data-testid="speaker-select"]',
      (element) => element.value,
    );
    obs('发言人下拉的初始值', speakerValue);
    assert(speakerValue === '', '开启态默认必须是不点名（空发言人）');
    const firstOption = await page.$eval(
      '[data-testid="speaker-select"] option',
      (element) => element.textContent,
    );
    obs('发言人第一项文案', firstOption);
    assert(
      firstOption.includes('不点名'),
      `开启态第一项应是「（不点名，仅触发反应）」，实测 ${firstOption}`,
    );

    await page.type('[data-testid="group-input"]', '讲个笑话，大家评价');
    await clickByTestId(page, 'group-send');

    // **第一步先出现**：时间线先只有甲的公开回复。
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('甲的公开结论'),
        ),
      { timeout: 15000 },
    );
    const hasBWhileGated = await timelineHas(page, '乙的公开结论');
    obs('闸门挂住时是否已出现乙的公开回复', hasBWhileGated);
    assert(!hasBWhileGated, '闸门挂住时不应已出现第二位成员的公开回复（必须逐步展开）');
    // 无错误横幅：省略 speaker 是合法路径。
    const errBanner = await page.$('[data-testid="group-error"]');
    obs('是否有错误横幅', errBanner !== null);
    assert(errBanner === null, '省略 speaker 发送不应出现错误横幅');

    await fetch(`${staticServer.url}__release_send`);
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('乙的公开结论'),
        ) &&
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('丙的公开结论'),
        ),
      { timeout: 15000 },
    );

    const sendRpc = rpcLog.filter((entry) => entry.method === 'group.send').at(-1);
    obs('group.send 实际 params（省略 speaker）', sendRpc?.params);
    assert(sendRpc?.params, '必须真的发出 group.send');
    assert(
      !('speaker' in sendRpc.params) || !sendRpc.params.speaker,
      `开启态不选发言人时 params.speaker 必须缺省，实测 ${JSON.stringify(sendRpc.params.speaker)}`,
    );
    // 异步契约（R.4）：send 的响应只有 started（不含 steps）；链跑完后
    // 界面靠 group.chain 拿到 steps。
    const sendResponse = responseLog.filter((entry) => entry.method === 'group.send').at(-1);
    obs('group.send 响应', sendResponse?.result);
    assert(
      sendResponse?.result?.status === 'started',
      `group.send 必须立刻回 started，实测 ${JSON.stringify(sendResponse?.result)}`,
    );
    assert(
      !('steps' in (sendResponse?.result ?? {})),
      'group.send 响应不得带 steps（链进度从 group.chain 读）',
    );
    // 链结束：活动指示消失（App 收到 group.chain.completed 后重拉，status 变终态）。
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 15000 },
    );
    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    obs('group.chain 终态', chainResponse?.result);
    assert(
      chainResponse?.result?.status === 'completed',
      `group.chain 终态应为 completed，实测 ${JSON.stringify(chainResponse?.result?.status)}`,
    );
    const chainSteps = chainResponse?.result?.steps ?? [];
    obs('group.chain steps', chainSteps);
    assert(chainSteps.length >= 3, 'group.chain 必须带三位成员各一步');
    assert(
      chainSteps.every((step) => step.status === 'replied'),
      '本例三位成员都应 replied',
    );
    const anyFailureEvent = eventLog.filter((event) => event.type === 'turn.failed');
    assert(anyFailureEvent.length === 0, '正常反应链不应产生 turn.failed');
  } finally {
    await page.close();
  }
});

await run('9.3 forced_pass：只提示本次结果、不写公开行、不发 turn.failed', async () => {
  await seedReactionGroup('反应组拒绝');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组拒绝');
    assert((await toggleChecked(page)) === true, '该组必须是开启态');
    await page.type('[data-testid="group-input"]', '#forced-pass 我想听评价');
    await clickByTestId(page, 'group-send');
    await page.waitForSelector('[data-testid="forced-notice"]', { timeout: 15000 });
    const notice = await page.$eval(
      '[data-testid="forced-notice"]',
      (element) => element.textContent,
    );
    obs('被点名者没回应的提示文案', notice);
    assert(notice.includes('没有回应'), `提示必须说明被点名成员没有回应，实测 ${notice}`);

    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    const steps = chainResponse?.result?.steps ?? [];
    obs('group.chain steps（含 forced_pass）', steps);
    assert(
      steps.some((step) => step.status === 'forced_pass'),
      'group.chain 的 steps 里必须有 forced_pass（提示来自本次链状态，不是持久化告警）',
    );
    const hasSecondMemberPublic = await timelineHas(page, '乙的公开结论');
    obs('被拒绝成员是否有公开行', hasSecondMemberPublic);
    assert(!hasSecondMemberPublic, 'forced_pass 的成员不得写公开行');
    const failedEvents = eventLog.filter(
      (event) => event.type === 'turn.failed' && event.groupId === sendRpcGroupId(),
    );
    obs('turn.failed 事件', failedEvents.length);
    assert(failedEvents.length === 0, 'forced_pass 不是整轮失败：不许发 turn.failed');
  } finally {
    await page.close();
  }
});

function sendRpcGroupId() {
  return rpcLog.filter((entry) => entry.method === 'group.send').at(-1)?.params?.groupId;
}

await run('9.4 取消：链中按钮可用并发出 agent.cancel；重连（刷新）后 busy 仍可取消', async () => {
  await seedReactionGroup('反应组取消');
  await fetch(`${staticServer.url}__gate_next_send`);
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组取消');
    await page.type('[data-testid="group-input"]', '这条会停在第一位成员');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('甲的公开结论'),
        ),
      { timeout: 15000 },
    );
    const cancelDuring = await page.$eval(
      '[data-testid="group-cancel"]',
      (element) => element.disabled,
    );
    obs('链中取消按钮是否可用', !cancelDuring);
    assert(cancelDuring === false, '链进行中取消按钮必须可用');

    // 模拟"断线重连后本地 sending 丢失"：刷新页面。本地状态清空，但核心仍 busy。
    await page.reload({ waitUntil: 'domcontentloaded' });
    await openExistingGroup(page, '反应组取消');
    await page.waitForFunction(
      () => {
        const cancel = document.querySelector('[data-testid="group-cancel"]');
        return cancel !== null && cancel.disabled === false;
      },
      { timeout: 15000 },
    );
    const activeAfterReload = await page.$('[data-testid="reaction-active"]');
    obs('刷新后是否显示反应链进行中', activeAfterReload !== null);
    assert(activeAfterReload !== null, '重连后必须靠 group.busy 恢复「链在跑」的显示');

    await clickByTestId(page, 'group-cancel');
    // 取消成功后 `agent.cancel` 回包带 reactionChainStopped，界面重拉后 busy 变 false
    // ⇒「反应链进行中」指示消失（这也是"取消真的到达核心"的界面证据）。
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 15000 },
    );
    const cancelRpc = rpcLog.filter((entry) => entry.method === 'agent.cancel').at(-1);
    obs('agent.cancel 实际 params', cancelRpc?.params);
    assert(cancelRpc !== undefined, '点取消必须发出 agent.cancel');
    assert(cancelRpc.params.sessionId, 'agent.cancel 必须带组会话 id');
    const cancelResponse = responseLog
      .filter((entry) => entry.method === 'agent.cancel')
      .at(-1);
    obs('agent.cancel 响应', cancelResponse?.result);
    assert(
      cancelResponse?.result?.reactionChainStopped === true,
      '取消回包必须带 reactionChainStopped=true',
    );
    await fetch(`${staticServer.url}__release_send`);
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 异步发送 + 每组轮数上限（change `group-reactive-mode` R.4 / design D10、D13）
// ---------------------------------------------------------------------------

async function waitForRpcCount(method, count, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (rpcLog.filter((entry) => entry.method === method).length < count) {
    if (Date.now() > deadline) {
      throw new Error(`等待 ${method} 第 ${count} 次调用超时（实际 ${rpcLog.filter((e) => e.method === method).length}）`);
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

/** 在「反应轮数上限」输入框里填值并失焦保存（`''` = 清空 ⇒ maxRounds: null）。 */
async function setRoundCap(page, value) {
  await page.click('[data-testid="group-round-cap"]', { clickCount: 3 });
  if (value === '') {
    await page.keyboard.press('Backspace');
  } else {
    await page.type('[data-testid="group-round-cap"]', value);
  }
  await page.$eval('[data-testid="group-round-cap"]', (element) => element.blur());
}

await run('9.5 反应轮数上限：填 6 发 maxRounds=6，留空发 maxRounds=null（payload 判据）', async () => {
  await seedReactionGroup('反应组上限');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组上限');
    const initial = await page.$eval('[data-testid="group-round-cap"]', (element) => ({
      value: element.value,
      placeholder: element.placeholder,
    }));
    obs('上限输入框初值', initial);
    assert(initial.value === '', 'maxRounds=null 时输入框必须留空（以默认值占位）');
    assert(
      initial.placeholder.includes('默认 8'),
      `占位文案应是「默认 8」，实测 ${initial.placeholder}`,
    );

    const beforeSet = rpcLog.filter((entry) => entry.method === 'group.update').length;
    await setRoundCap(page, '6');
    await waitForRpcCount('group.update', beforeSet + 1);
    const setRpc = rpcLog.filter((entry) => entry.method === 'group.update').at(-1);
    obs('group.update 实际 params（设 6）', setRpc?.params);
    assert(setRpc?.params?.groupId, 'group.update 必须带 groupId');
    assert(
      setRpc?.params?.maxRounds === 6,
      `payload 的 maxRounds 必须是 6，实测 ${JSON.stringify(setRpc?.params)}`,
    );
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-round-cap"]')?.value === '6',
      { timeout: 15000 },
    );

    const beforeClear = rpcLog.filter((entry) => entry.method === 'group.update').length;
    await setRoundCap(page, '');
    await waitForRpcCount('group.update', beforeClear + 1);
    const clearRpc = rpcLog.filter((entry) => entry.method === 'group.update').at(-1);
    obs('group.update 实际 params（留空）', clearRpc?.params);
    assert(
      clearRpc?.params !== undefined &&
        Object.prototype.hasOwnProperty.call(clearRpc.params, 'maxRounds') &&
        clearRpc.params.maxRounds === null,
      `留空必须发 maxRounds: null（恢复默认），实测 ${JSON.stringify(clearRpc?.params)}`,
    );
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-round-cap"]')?.value === '',
      { timeout: 15000 },
    );
  } finally {
    await page.close();
  }
});

await run('9.6 异步发送：started 后发送态立即解除，链活动由 chain/事件驱动', async () => {
  await seedReactionGroup('反应组异步');
  await fetch(`${staticServer.url}__gate_next_send`);
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组异步');
    await page.type('[data-testid="group-input"]', '这条会停在第二位成员之前');
    await clickByTestId(page, 'group-send');
    // 第一位成员的公开回复出现：链仍在跑（第二位被 gate 挂住）。
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('甲的公开结论'),
        ),
      { timeout: 15000 },
    );
    const sendState = await page.$eval('[data-testid="group-send"]', (element) => ({
      disabled: element.disabled,
      text: element.textContent,
    }));
    obs('链中发送按钮', sendState);
    assert(sendState.disabled === false, 'started 之后发送态必须立即解除（不等链结束）');
    assert(
      sendState.text.includes('发送') && !sendState.text.includes('发送中'),
      `按钮文案必须回到「发送」，实测 ${sendState.text}`,
    );
    const activeDuring = await page.$('[data-testid="reaction-active"]');
    assert(activeDuring !== null, '链仍在跑时必须显示活动指示（started 响应驱动）');
    const sendResponse = responseLog.filter((entry) => entry.method === 'group.send').at(-1);
    obs('group.send 响应', sendResponse?.result);
    assert(sendResponse?.result?.status === 'started', 'group.send 必须回 started');
    assert(
      !('steps' in (sendResponse?.result ?? {})),
      'group.send 响应不得带 steps',
    );

    await fetch(`${staticServer.url}__release_send`);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 15000 },
    );
    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    obs('group.chain 终态', chainResponse?.result);
    assert(
      chainResponse?.result?.status === 'completed',
      `链终态应为 completed，实测 ${JSON.stringify(chainResponse?.result?.status)}`,
    );
  } finally {
    await page.close();
  }
});

await run('9.7 达轮数上限：round_cap 可归因提示 + 上限外的成员不写公开行', async () => {
  await seedReactionGroup('反应组上限停');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组上限停');
    const beforeSet = rpcLog.filter((entry) => entry.method === 'group.update').length;
    await setRoundCap(page, '1');
    await waitForRpcCount('group.update', beforeSet + 1);
    await page.type('[data-testid="group-input"]', '只跑一轮');
    await clickByTestId(page, 'group-send');
    await page.waitForSelector('[data-testid="round-cap-notice"]', { timeout: 15000 });
    const notice = await page.$eval(
      '[data-testid="round-cap-notice"]',
      (element) => element.textContent,
    );
    obs('round_cap 提示文案', notice);
    assert(notice.includes('已达轮数上限'), `提示必须说明达上限，实测 ${notice}`);
    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    obs('round_cap 链终态', chainResponse?.result);
    assert(
      chainResponse?.result?.status === 'completed',
      '达上限是优雅停（completed），不是失败',
    );
    assert(
      chainResponse?.result?.stopReason === 'round_cap',
      `stopReason 必须是 round_cap，实测 ${JSON.stringify(chainResponse?.result?.stopReason)}`,
    );
    assert(
      (chainResponse?.result?.steps ?? []).length === 1,
      '上限 1 轮 ⇒ 只跑了一位成员',
    );
    const timelineText = await page.$eval(
      '[data-testid="group-timeline"]',
      (element) => element.textContent,
    );
    assert(timelineText.includes('甲的公开结论'), '上限内的成员必须有公开行');
    assert(!timelineText.includes('乙的公开结论'), '上限外的成员不得写公开行');
  } finally {
    await page.close();
  }
});

await run('9.8 R.8 链中还能再发：group.send 永不 busy，第二条消息被接受/排队', async () => {
  await seedReactionGroup('反应组连发');
  await fetch(`${staticServer.url}__gate_next_send`);
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组连发');
    const beforeSends = responseLog.filter((entry) => entry.method === 'group.send').length;
    await page.type('[data-testid="group-input"]', '第一条（会停在 gate）');
    await clickByTestId(page, 'group-send');
    // 第一位成员流式出现 = 链在跑（第二位被 gate 挂住）。
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') !== null,
      { timeout: 15000 },
    );
    // 等 `started` 回包后的 setSending(false) 落地，再断言按钮可用。
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-send"]')?.disabled === false,
      { timeout: 15000 },
    );
    const sendState = await page.$eval('[data-testid="group-send"]', (element) => ({
      disabled: element.disabled,
    }));
    assert(sendState.disabled === false, '链运行中发送按钮必须可用（R.8）');
    await page.type('[data-testid="group-input"]', '第二条（链中追加）');
    await clickByTestId(page, 'group-send');
    await waitForRpcCount('group.send', beforeSends + 2);
    const sends = responseLog
      .filter((entry) => entry.method === 'group.send')
      .slice(beforeSends);
    obs('两次 group.send 回包', sends.map((entry) => entry.result));
    assert(sends.length >= 2, '链运行中第二次发送也必须真正发出');
    for (const entry of sends) {
      assert(
        entry.result?.status === 'started',
        `group.send 永不 busy，实测 ${JSON.stringify(entry.result)}`,
      );
      assert(entry.result?.status !== 'busy', '不得出现 busy 回包');
    }
    const chainBefore = responseLog.filter((entry) => entry.method === 'group.chain').length;
    await fetch(`${staticServer.url}__release_send`);
    // 两条请求各一条链（两条 group.chain.completed）；等 App 重拉两次再断言终态，
    // 避免恰好落在"链 1 结束、链 2 还没开始"的空隙。
    await waitForRpcCount('group.chain', chainBefore + 2);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 20000 },
    );
    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    obs('连发后的链终态', chainResponse?.result);
    assert(
      chainResponse?.result?.status === 'completed',
      `连发后链应优雅结束，实测 ${JSON.stringify(chainResponse?.result?.status)}`,
    );
  } finally {
    // 即使断言失败也放掉 gate：否则后续用例会被一条永远挂着的链拖死。
    await fetch(`${staticServer.url}__release_send`).catch(() => {});
    await page.close();
  }
});

await run('9.9 R.10 结构化沉默：passed 步骤不写公开行、链 all_passed', async () => {
  await seedReactionGroup('反应组结构化沉默');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组结构化沉默');
    const before = responseLog.filter((entry) => entry.method === 'group.send').length;
    await page.type('[data-testid="group-input"]', '随便聊聊 #pass');
    await clickByTestId(page, 'group-send');
    await waitForRpcCount('group.send', before + 1);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 15000 },
    );
    const chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    obs('结构化沉默链终态', chainResponse?.result);
    const steps = chainResponse?.result?.steps ?? [];
    assert(steps.length > 0, '链必须有 steps');
    assert(
      steps.every((step) => step.status === 'passed'),
      `#pass 的步骤必须全部是 passed，实测 ${JSON.stringify(steps.map((s) => s.status))}`,
    );
    assert(
      chainResponse?.result?.stopReason === 'all_passed',
      `结构化沉默应收敛为 all_passed，实测 ${JSON.stringify(chainResponse?.result?.stopReason)}`,
    );
    const timelineText = await page.$eval(
      '[data-testid="group-timeline"]',
      (element) => element.textContent,
    );
    assert(
      !timelineText.includes('的公开结论'),
      'passed 步骤不得写任何成员公开行（结构化沉默不占时间线）',
    );
  } finally {
    await page.close();
  }
});

// GROUP_SHOT=<path>：测试跑完后把真实组视图截一张图（视觉验收用）。
if (process.env.GROUP_SHOT) {  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await page.evaluate((id) => {
      document.querySelector(`[data-testid="lane-context-${id}"]`)?.click();
    }, memberA);
    await new Promise((done) => setTimeout(done, 600));
    const target = process.env.GROUP_SHOT;
    await page.screenshot({ path: target, fullPage: false });
    console.log(`[SHOT] captured ${target}`);
  } finally {
    await page.close();
  }
}

console.log('\n[群视图 e2e] 摘要：' + JSON.stringify({ total: results.length, failures: failureCount }));
await browser.close();

if (process.env.GROUP_KEEP === '1') {
  console.log(`[群视图 e2e] GROUP_KEEP=1：服务保持在 ${staticServer.url}（Ctrl+C 结束）`);
  process.on('SIGTERM', () => {
    void staticServer.close().then(() => process.exit(0));
  });
  await new Promise(() => {});
} else {
  await staticServer.close();
  process.exit(failureCount === 0 ? 0 : 1);
}
