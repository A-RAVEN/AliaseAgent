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

/** Node 侧轮询等待（DOM 状态仍用 `page.waitForFunction`，这里只等 rpcLog / 响应计数）。 */
async function waitFor(check, message, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`等待超时：${message}`);
}

// `pageerror` 统一收集（R.1 / R.11）：每个 page 一份，`run` 在本用例结束时断言为空。
// 探针（`Promise.reject`）在用例里主动清空自己的数组，避免误报。
const pagesOpened = [];
const pageErrorsByPage = new WeakMap();

function pageErrorsOf(page) {
  return pageErrorsByPage.get(page) ?? [];
}

function assertNoPageErrors(pages) {
  const problems = [];
  for (const page of pages) {
    for (const message of pageErrorsOf(page)) problems.push(message);
  }
  assert(problems.length === 0, `本用例出现未捕获的页面异常：${problems.join(' | ')}`);
}

async function run(name, fn) {
  const started = Date.now();
  const pageMark = pagesOpened.length;
  try {
    await fn();
    assertNoPageErrors(pagesOpened.slice(pageMark));
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
// 头像夹具（change `chat-bubbles-avatars`）：假核心里"读得出来"的那张图与模板路径。
const FAKE_AVATAR_PATH = 'uploaded/fake-agent-avatar.png';
const FAKE_BROKEN_AVATAR_PATH = 'uploaded/fake-missing-avatar.png';
const FAKE_AVATAR_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/wD/2y6JAAAAAElFTkSuQmCC';

// ---------------------------------------------------------------------------
// 文件夹选择对话框的假目录树（change `custom-workspace` 返工任务 12.5）
//
// 页面只点选、不手输：目录列表由核心的 `workspace.listDirs` 给。假核心不做磁盘访问，
// 这棵树就是固定夹具 —— 起点 = 会话 / 群的工作路径；省略 `path` ⇒ 假「应用主目录」。
// 叶子目录里 `locked` 故意让 `setWorkspace` 拒绝（造「框内就地报错」）。
// ---------------------------------------------------------------------------
const PICKER_HOME = 'C:\\Users\\ws-tester';
const LONG_SEGMENTS = [
  '一个非常长的工作目录名-用于验证单行截断',
  'src',
  'deeply',
  'nested',
  'package',
];
const LONG_WORKSPACE = ['C:\\work', ...LONG_SEGMENTS].join('\\');
/** 对话框里会点进去 / 选中的两个子目录（假目录树的叶子）。 */
const WORKSPACE_NEW = `${LONG_WORKSPACE}\\alpha`;
const WORKSPACE_GROUP_NEW = `${LONG_WORKSPACE}\\beta`;
/** 假核心会拒绝保存的目录（「目录不可用」注入）。 */
const WORKSPACE_LOCKED = `${LONG_WORKSPACE}\\locked`;
const WORKSPACE_BAD = WORKSPACE_LOCKED;
/** 40 个子目录的夹具（返工任务 12.10：长列表必须在框内滚动，不能把框撑满屏）。 */
const PICKER_CROWDED = 'C:\\crowded';
const PICKER_CROWDED_CHILDREN = Array.from(
  { length: 40 },
  (_, index) => `folder-${String(index + 1).padStart(2, '0')}`,
);
/** 「此电脑」虚拟根 sentinel（返工任务 12.11；核心 `workspace.listDirs` 同字符串）。 */
const PICKER_DRIVES_ROOT = '@drives';
/** 假核心列出的盘符（固定夹具：不依赖真机是否真有 D:）。 */
const PICKER_DRIVES = ['C:\\', 'D:\\'];

/** 路径 → 子目录名（只列子目录）。父目录必须也在树里，否则「上级」会列举失败。 */
const PICKER_TREE = (() => {
  const tree = new Map();
  tree.set('C:\\work', [LONG_SEGMENTS[0]]);
  let current = 'C:\\work';
  for (let index = 0; index < LONG_SEGMENTS.length; index += 1) {
    current = `${current}\\${LONG_SEGMENTS[index]}`;
    tree.set(
      current,
      index + 1 < LONG_SEGMENTS.length
        ? [LONG_SEGMENTS[index + 1]]
        : ['alpha', 'beta', 'locked'],
    );
  }
  for (const leaf of ['alpha', 'beta', 'locked']) {
    tree.set(`${LONG_WORKSPACE}\\${leaf}`, []);
  }
  // 返工 12.10：40 个子目录，用来验「框有高度上限、列表内部滚动」。
  tree.set(PICKER_CROWDED, PICKER_CROWDED_CHILDREN);
  // 返工 12.12：每个子目录也是可进入的叶子 —— 用「多目录 ↔ 空叶子」前后对比框高是否恒定。
  for (const name of PICKER_CROWDED_CHILDREN) tree.set(`${PICKER_CROWDED}\\${name}`, []);
  // 返工 12.11：盘符根 + 第二个盘（D:）的固定夹具，「此电脑」不在树里（虚拟根单独回包）。
  tree.set('C:\\', ['work', 'crowded']);
  tree.set('D:\\', ['projects']);
  tree.set('D:\\projects', []);
  tree.set(PICKER_HOME, ['Documents', 'Projects']);
  tree.set(`${PICKER_HOME}\\Documents`, []);
  tree.set(`${PICKER_HOME}\\Projects`, []);
  return tree;
})();

/**
 * 假核心的「上级」计算（返工任务 12.11）：盘符根 → 「此电脑」虚拟根；普通目录 → 上一级。
 * 取代原先 `lastIndexOf('\\') <= 2 ? null` 的写法（那会把 `C:\work` 也算成没有上级）。
 */
function pickerParentOf(dir) {
  const normalized = dir.replace(/[\\/]+$/, '');
  if (/^[A-Za-z]:$/.test(normalized)) return PICKER_DRIVES_ROOT;
  const index = Math.max(normalized.lastIndexOf('\\'), normalized.lastIndexOf('/'));
  if (index < 0) return null;
  const parent = normalized.slice(0, index);
  if (/^[A-Za-z]:$/.test(parent)) return `${parent}\\`;
  return parent;
}

/** 拼假目录的子路径：盘符根已带尾分隔符时不要拼出双分隔符（`C:\\crowded`）。 */
function pickerJoin(dir, name) {
  return dir.endsWith('\\') || dir.endsWith('/') ? `${dir}${name}` : `${dir}\\${name}`;
}

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
/** GROUP_DEFAULT=1 时预置的审计组 id（末尾把它放回首位，保证 design_audit 落在群聊主区）。 */
let auditGroupId = null;

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

function newGroup(title, workspace = null) {
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
    // 工作路径设置值（change `custom-workspace`）：null = 未设置（显示缺省文案）。
    workspace: workspace ?? null,
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
    // R.15：`group.chain` 始终带 `error`（真核心 `toJson` 同口径：失败真因或 null）。
    error: null,
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
  // 非失败终态不带旧错（契约：completed / cancelled 的 error 为 null）。
  if (status !== 'failed') chain.error = null;
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
  // 2.5 的链启动闸门：让测试先切到成员视图、再放行整条链。
  if (startGateEnabled) {
    startGateEnabled = false;
    await new Promise((resolve) => {
      startGate = resolve;
    });
  }
  group.busy = true;
  group.aborted = false;
  group.runningMemberId = null;
  group.chain = {
    status: 'running',
    triggerSeq: userMessage.seq,
    rounds: 0,
    stopReason: null,
    error: null,
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
      if (streamGateEnabled) {
        streamGateEnabled = false;
        await new Promise((resolve) => {
          streamGate = resolve;
        });
      }
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
    busy: groupLoadFlags.busyFor === group.session.id ? true : group.busy === true,
    runningMemberId:
      groupLoadFlags.busyFor === group.session.id
        ? (group.members.find((member) => member.removedAt === null)?.id ?? null)
        : (group.runningMemberId ?? null),
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

/**
 * 群加载的故障 / 延迟注入（change `group-chat-layout` 任务 1.2；只存在于假核心）。
 *
 * 用来制造「A 的晚到响应」与「message.query 失败」两个红靶：
 *   - `messageQueryDelay`：对指定 groupId 的 `message.query` 延迟回复；
 *   - `messageQueryFailFor`：对指定 sessionId 的 `message.query` 直接回错；
 *   - `groupListDelayMs`：全部 `group.list` 延迟（制造切群竞态的时间窗）；
 *   - `groupViewDelay` / `groupViewFail`：按 groupId（+ memberId）延迟 / 回错。
 */
const groupLoadFlags = {
  messageQueryFailFor: null,
  // 下一条**单聊**的 `message.query` 失败一次（R.1：避免 boot 的 loadSessions 抢先吞掉）。
  messageQueryFailKind: null,
  messageQueryDelay: { groupId: null, ms: 0 },
  groupListDelayMs: 0,
  groupViewDelay: { groupId: null, memberId: null, ms: 0 },
  groupViewFail: { groupId: null, memberId: null },
  // R.1：会话列表刷新失败 / 延迟（reloadSessions 单独报错；R.2 的 refreshAfterReconnect 窗口）。
  sessionListFail: false,
  sessionListDelayMs: 0,
  // R.10：指定会话删除失败（删除失败不得关管理面板）。
  deleteFailFor: null,
  // R.2：`group.update` 回包延迟（卡住旧群 onReload 的续体）。
  groupUpdateDelayMs: 0,
  // R.6：`config.get` 返回 missing=true（Wizard 态，没有 main 地标）。
  configMissing: false,
  // R.4：没有真实链时也能造「链在跑」的只读状态（`group.list` 的 busy/runningMemberId）。
  busyFor: null,
  // change `custom-workspace`：让 setWorkspace 对这个路径报「不存在」（造保存失败态）。
  workspaceFailPath: null,
};

/** 链启动闸门（2.5：先切到成员视图再放行，制造「提示产生时不在群聊标签」）。 */
let startGate = null;
let startGateEnabled = false;
/** 成员流式闸门（2.4/2.5：把「正在反应…」的可见窗口挂住，供 DOM 断言）。 */
let streamGate = null;
let streamGateEnabled = false;


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
  responseLog.push({ method, result, at: Date.now() });
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
  rpcLog.push({ method, params, at: Date.now() });
  if (method === 'core.ping') return reply(socket, id, { ok: true });
  if (method === 'config.get') {
    return reply(socket, id, {
      missing: groupLoadFlags.configMissing === true,
      providers: {},
      agentTypes: { general: { input_modalities: ['text'] } },
      tools: ['read_file', 'list_dir', 'run_command'],
      // 用户资料（change `chat-bubbles-avatars`）：没有上传头像，种子是常量缺省值。
      profile: { avatarPath: null, userId: null, identitySeed: 'local-user' },
    });
  }
  if (method === 'template.list') {
    return reply(socket, id, {
      templates: [
        { name: 'general' },
        { name: 'narrow' },
        { name: 'avatar-tpl', avatar_path: FAKE_AVATAR_PATH },
        { name: 'broken-avatar-tpl', avatar_path: FAKE_BROKEN_AVATAR_PATH },
      ],
      tools: ['read_file', 'list_dir', 'run_command'],
      thinkingEfforts: ['low', 'medium', 'high', 'max'],
      defaultTools: ['read_file', 'list_dir', 'run_command'],
      providers: ['p'],
      effectiveNote: '只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。',
    });
  }
  if (method === 'attachment.read') {
    // 只认那张"存在的"假头像；其它路径回错（造"文件被删"的回落）。
    if (params.path === FAKE_AVATAR_PATH) {
      return reply(socket, id, {
        path: FAKE_AVATAR_PATH,
        bytes: 0,
        base64: FAKE_AVATAR_DATA_URL.slice(FAKE_AVATAR_DATA_URL.indexOf(',') + 1),
        mediaType: 'image/png',
      });
    }
    return fail(socket, id, `图片已丢失：附件文件不存在（${params.path}）`);
  }
  if (method === 'attachment.upload') {
    const path = `uploaded/${String(params.filename ?? 'avatar.png')}`;
    return reply(socket, id, {
      path,
      bytes: 0,
      format: 'png',
      mediaType: 'image/png',
      width: 1,
      height: 1,
    });
  }
  if (method === 'session.list') {
    const respond = () => reply(socket, id, { sessions });
    if (groupLoadFlags.sessionListFail) {
      return fail(socket, id, 'session.list 失败（e2e 注入）');
    }
    if (groupLoadFlags.sessionListDelayMs > 0) {
      setTimeout(respond, groupLoadFlags.sessionListDelayMs);
      return;
    }
    return respond();
  }
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
      maxRounds: null,
      // change `custom-workspace`：`session.create {workspace}` 原样返回（假核心不做目录校验）。
      workspace: params.workspace ?? null,
    };
    sessions.unshift(session);
    return reply(socket, id, { session });
  }
  if (method === 'group.create') {
    const group = newGroup(params.title ?? '新组', params.workspace ?? null);
    return replyLogged(socket, id, method, { group });
  }
  // ---------------------------------------------------------------------------
  // 文件夹选择对话框（change `custom-workspace` 返工任务 12.5）：只列子目录；省略
  // path ⇒ 假「应用主目录」。非法 / 不存在的目录回可归因 `-32602`（不静默空列表）。
  // ---------------------------------------------------------------------------
  if (method === 'workspace.listDirs') {
    const requested = params.path;
    if (requested !== undefined && requested !== null && typeof requested !== 'string') {
      return fail(socket, id, 'Invalid params: path 必须是字符串或省略');
    }
    const raw = typeof requested === 'string' ? requested.trim() : '';
    const dir = raw.length === 0 ? PICKER_HOME : raw;
    // 返工 12.11：「此电脑」虚拟根只列盘符；它不是真实目录（isDirectory=false），
    // 界面据此禁用「选择此目录」。
    if (dir === PICKER_DRIVES_ROOT) {
      return reply(socket, id, {
        path: PICKER_DRIVES_ROOT,
        parent: null,
        directories: PICKER_DRIVES.map((root) => ({
          name: root.replace(/\\+$/, ''),
          path: root,
        })),
        exists: true,
        isDirectory: false,
      });
    }
    const children = PICKER_TREE.get(dir);
    if (children === undefined) {
      return fail(socket, id, `工作路径「${dir}」不存在：请改成一个已存在的绝对目录`);
    }
    return reply(socket, id, {
      path: dir,
      parent: pickerParentOf(dir),
      directories: [...children]
        .sort((left, right) => left.localeCompare(right))
        .map((name) => ({ name, path: pickerJoin(dir, name) })),
      exists: true,
      isDirectory: true,
    });
  }
  // ---------------------------------------------------------------------------
  // 工作路径切换（change `custom-workspace`）：payload 由 rpcLog 记录；失败用
  // `groupLoadFlags.workspaceFailPath` 注入（演示"核心可归因错误"）。
  // ---------------------------------------------------------------------------
  if (method === 'session.setWorkspace') {
    const session = sessions.find((entry) => entry.id === params.sessionId);
    if (!session) return fail(socket, id, `会话 ${params.sessionId} 不存在`);
    if (session.kind !== 'single') {
      return fail(socket, id, `会话 ${params.sessionId} 是组会话：请用 group.setWorkspace`);
    }
    if (typeof params.workspace !== 'string' || params.workspace.trim().length === 0) {
      return fail(socket, id, 'workspace 必填且必须是非空字符串');
    }
    if (
      groupLoadFlags.workspaceFailPath !== null &&
      params.workspace === groupLoadFlags.workspaceFailPath
    ) {
      return fail(socket, id, `工作路径「${params.workspace}」不可用：目录没有访问权限（e2e 注入）`);
    }
    session.workspace = params.workspace;
    session.updatedAt = Date.now();
    return replyLogged(socket, id, method, { session });
  }
  if (method === 'group.setWorkspace') {
    const group = groups.get(params.groupId);
    if (!group) {
      const single = sessions.find((entry) => entry.id === params.groupId);
      if (single) {
        return fail(socket, id, `会话 ${params.groupId} 是单聊会话：请用 session.setWorkspace`);
      }
      return fail(socket, id, `组 ${params.groupId} 不存在`);
    }
    if (group.busy || groupLoadFlags.busyFor === params.groupId) {
      return fail(socket, id, '组正在运行反应链：busy，工作路径未改动（不排队）');
    }
    if (typeof params.workspace !== 'string' || params.workspace.trim().length === 0) {
      return fail(socket, id, 'workspace 必填且必须是非空字符串');
    }
    if (
      groupLoadFlags.workspaceFailPath !== null &&
      params.workspace === groupLoadFlags.workspaceFailPath
    ) {
      return fail(socket, id, `工作路径「${params.workspace}」不可用：目录没有访问权限（e2e 注入）`);
    }
    group.session.workspace = params.workspace;
    group.session.updatedAt = Date.now();
    return replyLogged(socket, id, method, { group: describeGroup(group) });
  }
  if (method === 'session.rename') {
    const session = sessions.find((entry) => entry.id === params.sessionId);
    if (!session) return fail(socket, id, `会话 ${params.sessionId} 不存在`);
    session.title = String(params.title ?? '');
    session.updatedAt = Date.now();
    return replyLogged(socket, id, method, { session });
  }
  if (method === 'group.list') {
    const respond = () =>
      reply(socket, id, { groups: [...groups.values()].map(describeGroup) });
    if (groupLoadFlags.groupListDelayMs > 0) {
      setTimeout(respond, groupLoadFlags.groupListDelayMs);
      return;
    }
    return respond();
  }
  if (method === 'message.query') {
    const respond = () => {
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
    };
    const shouldFail =
      groupLoadFlags.messageQueryFailFor === params.sessionId ||
      (groupLoadFlags.messageQueryFailKind === 'single' && !groups.has(params.sessionId));
    if (shouldFail && groupLoadFlags.messageQueryFailKind === 'single') {
      // `messageQueryFailKind` 只失败一次（R.1：点开该单聊那一下）。
      groupLoadFlags.messageQueryFailKind = null;
    }
    const delay = groupLoadFlags.messageQueryDelay;
    const delayed = delay.groupId !== null && delay.groupId === params.sessionId && delay.ms > 0;
    if (shouldFail) {
      // 延迟 + 失败：让「加载失败但已切走」的守卫用例有窗口（R.1）。
      if (delayed) {
        setTimeout(() => fail(socket, id, 'message.query 失败（e2e 注入）'), delay.ms);
        return;
      }
      return fail(socket, id, 'message.query 失败（e2e 注入）');
    }
    if (delayed) {
      setTimeout(respond, delay.ms);
      return;
    }
    return respond();
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
    // 齿轮面板里换模板（change `chat-bubbles-avatars` D5）：payload 带 templateName。
    if (typeof params.templateName === 'string' && params.templateName.length > 0) {
      member.template = params.templateName;
    }
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
    const failCfg = groupLoadFlags.groupViewFail;
    if (failCfg.groupId === params.groupId && failCfg.memberId === params.memberId) {
      return fail(socket, id, 'group.view 失败（e2e 注入）');
    }
    const respond = () =>
      reply(socket, id, {
        groupId: params.groupId,
        memberId: params.memberId,
        snapshot: group.snapshots[params.memberId] ?? null,
      });
    const delay = groupLoadFlags.groupViewDelay;
    if (
      delay.groupId === params.groupId &&
      (delay.memberId === null || delay.memberId === params.memberId) &&
      delay.ms > 0
    ) {
      setTimeout(respond, delay.ms);
      return;
    }
    return respond();
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
    if (groupLoadFlags.groupUpdateDelayMs > 0) {
      // R.2：延迟回包，卡住旧群 `onReload` 的续体（状态已改，回包晚到）。
      setTimeout(
        () => replyLogged(socket, id, method, { group: group.session }),
        groupLoadFlags.groupUpdateDelayMs,
      );
      return;
    }
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
  // 群行删除（change `group-chat-layout` 任务 1.4）：核心负责停链 / 销毁实例 / 级联删数据。
  if (method === 'group.delete') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    groups.delete(params.groupId);
    const index = sessions.findIndex((session) => session.id === params.groupId);
    if (index >= 0) sessions.splice(index, 1);
    return replyLogged(socket, id, method, { groupId: params.groupId, deleted: true });
  }
  // 单聊删除。
  if (method === 'session.delete') {
    if (groupLoadFlags.deleteFailFor === params.sessionId) {
      return fail(socket, id, 'session.delete 失败（e2e 注入）');
    }
    const index = sessions.findIndex((session) => session.id === params.sessionId);
    if (index < 0) return fail(socket, id, `会话 ${params.sessionId} 不存在`);
    sessions.splice(index, 1);
    return replyLogged(socket, id, method, {
      sessionId: params.sessionId,
      deleted: true,
    });
  }
  if (method === 'agent.cancel') {    const group = groups.get(params.sessionId);
    if (group && (group.busy || group.pending.length > 0)) {
      const cancelledMemberId = group.runningMemberId;
      group.aborted = true;
      // R.8：取消停当前链并**清空排队**（已写入的用户消息保留）。
      group.pending.length = 0;
      if (sendGate) {
        sendGate();
        sendGate = null;
      }
      if (streamGate) {
        streamGate();
        streamGate = null;
      }
      if (startGate) {
        startGate();
        startGate = null;
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
    // 群聊气泡 / 成员卡片 / 紧凑环的夹具（change `chat-bubbles-avatars` 5.3）。
    // 成员模板覆盖：无上传图（甲/乙）、同模板同上传图（丙/丁）、模板头像读不到（辛）、
    // 已移除（壬）、快照 ok（戊）、快照失败（庚）、快照还在加载（己，靠 flag 延迟）。
    if (requestPath === '/__seed_bubble_group') {
      const seeded = newGroup('气泡卡片组');
      const group = groups.get(seeded.id);
      const specs = [
        { key: 'a', id: 'mem-bub-a', name: '甲', template: 'general' },
        { key: 'b', id: 'mem-bub-b', name: '乙', template: 'narrow' },
        { key: 'c', id: 'mem-bub-c', name: '丙', template: 'avatar-tpl' },
        { key: 'd', id: 'mem-bub-d', name: '丁', template: 'avatar-tpl' },
        { key: 'e', id: 'mem-bub-e', name: '戊', template: 'general' },
        // 庚（失败）排在己（延迟）之前：错误态先到，延迟的己留出"加载中"窗口。
        { key: 'g', id: 'mem-bub-g', name: '庚', template: 'general' },
        { key: 'f', id: 'mem-bub-f', name: '己', template: 'general' },
        { key: 'broken', id: 'mem-bub-broken', name: '辛', template: 'broken-avatar-tpl' },
        { key: 'removed', id: 'mem-bub-removed', name: '壬', template: 'general', removed: true },
      ];
      const members = {};
      for (const spec of specs) {
        group.members.push({
          id: spec.id,
          name: spec.name,
          template: spec.template,
          removedAt: spec.removed === true ? Date.now() : null,
          overrides: null,
          window: windows[group.members.length % windows.length],
        });
        members[spec.key] = spec.id;
      }
      pushMessage(group, { role: 'user', content: '气泡夹具：用户先说一句' });
      for (const spec of specs) {
        if (spec.removed === true) continue;
        if (spec.key === 'f' || spec.key === 'g') continue;
        pushMessage(group, {
          role: 'assistant',
          content: `${spec.name}的公开结论（种子）`,
          author: spec.id,
        });
      }
      group.snapshots['mem-bub-e'] = {
        sessionId: group.session.id,
        model: 'fake-model',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        capturedAt: new Date().toISOString(),
        windowTokens: windows[0],
        agentType: 'general',
        breakdown: breakdown(windows[0], 1200, 300, 100),
        messages: [{ role: 'user', content: '气泡夹具上下文' }],
        system: '你是测试模板。',
        tools: '[]',
        skillFailures: [],
        skillFailureNotice: null,
      };
      const index = sessions.findIndex((session) => session.id === seeded.id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: seeded.id, title: seeded.title, members }));
      return;
    }
    // 群加载的故障 / 延迟注入开关（change `group-chat-layout` 1.2；假核心夹具）。
    if (requestPath === '/__flags') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      if (q.get('reset') === '1') {
        groupLoadFlags.messageQueryFailFor = null;
        groupLoadFlags.messageQueryFailKind = null;
        groupLoadFlags.messageQueryDelay = { groupId: null, ms: 0 };
        groupLoadFlags.groupListDelayMs = 0;
        groupLoadFlags.groupViewDelay = { groupId: null, memberId: null, ms: 0 };
        groupLoadFlags.groupViewFail = { groupId: null, memberId: null };
        groupLoadFlags.sessionListFail = false;
        groupLoadFlags.sessionListDelayMs = 0;
        groupLoadFlags.deleteFailFor = null;
        groupLoadFlags.groupUpdateDelayMs = 0;
        groupLoadFlags.configMissing = false;
        groupLoadFlags.busyFor = null;
        groupLoadFlags.workspaceFailPath = null;
      }
      if (q.has('messageQueryFailFor')) {
        groupLoadFlags.messageQueryFailFor = q.get('messageQueryFailFor');
      }
      if (q.has('messageQueryFailKind')) {
        groupLoadFlags.messageQueryFailKind = q.get('messageQueryFailKind');
      }
      if (q.has('messageQueryDelayGroupId')) {
        groupLoadFlags.messageQueryDelay = {
          groupId: q.get('messageQueryDelayGroupId'),
          ms: Number(q.get('messageQueryDelayMs') ?? 0),
        };
      }
      if (q.has('groupListDelayMs')) {
        groupLoadFlags.groupListDelayMs = Number(q.get('groupListDelayMs'));
      }
      if (q.has('groupViewDelayGroupId')) {
        groupLoadFlags.groupViewDelay = {
          groupId: q.get('groupViewDelayGroupId'),
          memberId: q.get('groupViewDelayMemberId') ?? null,
          ms: Number(q.get('groupViewDelayMs') ?? 0),
        };
      }
      if (q.has('groupViewFailGroupId')) {
        groupLoadFlags.groupViewFail = {
          groupId: q.get('groupViewFailGroupId'),
          memberId: q.get('groupViewFailMemberId') ?? null,
        };
      }
      if (q.has('sessionListFail')) {
        groupLoadFlags.sessionListFail = q.get('sessionListFail') === '1';
      }
      if (q.has('sessionListDelayMs')) {
        groupLoadFlags.sessionListDelayMs = Number(q.get('sessionListDelayMs'));
      }
      if (q.has('deleteFailFor')) {
        groupLoadFlags.deleteFailFor = q.get('deleteFailFor');
      }
      if (q.has('groupUpdateDelayMs')) {
        groupLoadFlags.groupUpdateDelayMs = Number(q.get('groupUpdateDelayMs'));
      }
      if (q.has('configMissing')) {
        groupLoadFlags.configMissing = q.get('configMissing') === '1';
      }
      if (q.has('busyFor')) {
        groupLoadFlags.busyFor = q.get('busyFor');
      }
      if (q.has('workspaceFailPath')) {
        groupLoadFlags.workspaceFailPath = q.get('workspaceFailPath');
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify(groupLoadFlags));
      return;
    }
    // 造一条单聊；`front=1` 时排到会话列表首位（夹具，不是产品接口）。
    // change `custom-workspace`：`workspace=` 给该单聊设工作路径（用于显示 / 切换用例）。
    if (requestPath === '/__seed_single') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const session = {
        id: `s-${nextId++}`,
        title: q.get('title') ?? '新单聊',
        agentType: 'general',
        parentSessionId: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        kind: 'single',
        overrides: null,
        reactionsEnabled: true,
        maxRounds: null,
        workspace: q.get('workspace') ?? null,
      };
      if (q.get('front') === '1') sessions.unshift(session);
      else sessions.push(session);
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: session.id, title: session.title }));
      return;
    }
    // 造一个带工作路径、两个成员的组（change `custom-workspace` 群栏用例的夹具）。
    if (requestPath === '/__seed_workspace_group') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const seeded = newGroup(q.get('title') ?? '工作区组', q.get('workspace') ?? null);
      const group = groups.get(seeded.id);
      for (const name of ['甲', '乙']) {
        group.members.push({
          id: `mem-ws-${seeded.id}-${name}`,
          name,
          template: 'general',
          removedAt: null,
          overrides: null,
          window: windows[group.members.length % windows.length],
        });
      }
      pushMessage(group, { role: 'user', content: '工作路径夹具：用户先说一句' });
      pushMessage(group, {
        role: 'assistant',
        content: '甲的公开结论（工作路径夹具）',
        author: group.members[0].id,
      });
      const index = sessions.findIndex((session) => session.id === seeded.id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: seeded.id, title: seeded.title }));
      return;
    }
    // 把一个会话排到首位（控制删除后「下一条」的类型）。
    if (requestPath === '/__promote_session') {
      const id = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams.get('id');
      const index = sessions.findIndex((session) => session.id === id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id, promoted: index >= 0 }));
      return;
    }
    // 直接删一个会话（测试清理用；产品路径走 session.delete / group.delete）。
    if (requestPath === '/__delete_session') {
      const id = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams.get('id');
      const index = sessions.findIndex((session) => session.id === id);
      if (index >= 0) sessions.splice(index, 1);
      groups.delete(id);
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id, deleted: index >= 0 }));
      return;
    }
    // 作者负控夹具（R.13）：甲 / 乙 两位成员的私有行（行数不同），供独立 oracle 对账。
    if (requestPath === '/__seed_author_group') {
      const seeded = newGroup('R13 作者组');
      const group = groups.get(seeded.id);
      for (const spec of [
        { id: 'mem-author-a', name: '甲' },
        { id: 'mem-author-b', name: '乙' },
      ]) {
        group.members.push({
          id: spec.id,
          name: spec.name,
          template: 'general',
          removedAt: null,
          overrides: null,
          window: windows[group.members.length % windows.length],
        });
      }
      pushMessage(group, { role: 'user', content: 'R13 起点' });
      for (let index = 0; index < 2; index += 1) {
        pushMessage(group, {
          role: 'assistant',
          content: `甲的私有过程 ${index}`,
          author: 'mem-author-a',
          visibility: 'private-to-author',
        });
      }
      for (let index = 0; index < 3; index += 1) {
        pushMessage(group, {
          role: 'assistant',
          content: `乙的私有过程 ${index}`,
          author: 'mem-author-b',
          visibility: 'private-to-author',
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
    // 滚动存档夹具（R.9）：20 人成员名单 + 尾页里「甲」的 25 条私有行。
    if (requestPath === '/__seed_scroll_group') {
      const seeded = newGroup('R9 滚动组');
      const group = groups.get(seeded.id);
      for (let index = 0; index < 20; index += 1) {
        group.members.push({
          id: `mem-scroll-${index}`,
          name: index === 0 ? '甲' : `成员${index}`,
          template: 'general',
          removedAt: null,
          overrides: null,
          window: windows[index % windows.length],
        });
      }
      for (let index = 0; index < 5; index += 1) {
        pushMessage(group, {
          role: 'assistant',
          content: `R9 公开历史 ${index}`,
          author: 'mem-scroll-1',
        });
      }
      for (let index = 0; index < 25; index += 1) {
        pushMessage(group, {
          role: 'assistant',
          content: '',
          author: 'mem-scroll-0',
          visibility: 'private-to-author',
        });
      }
      group.snapshots['mem-scroll-0'] = {
        sessionId: group.session.id,
        model: 'fake-model',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        capturedAt: new Date().toISOString(),
        windowTokens: windows[0],
        agentType: 'general',
        breakdown: breakdown(windows[0], 1200, 300, 100),
        messages: [{ role: 'user', content: 'R9 上下文' }],
        system: '你是测试模板。',
        tools: '[]',
        skillFailures: [],
        skillFailureNotice: null,
      };
      const index = sessions.findIndex((session) => session.id === seeded.id);
      if (index >= 0) {
        const [entry] = sessions.splice(index, 1);
        sessions.unshift(entry);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ id: seeded.id, title: seeded.title }));
      return;
    }
    // 改一个组的反应轮数上限（R.8 夹具：让第一轮就 round_cap，便于观察一次性提示）。
    if (requestPath === '/__set_max_rounds') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const group = groups.get(q.get('groupId'));
      if (group) {
        const raw = q.get('value');
        group.session.maxRounds = raw === null || raw === 'null' ? null : Number(raw);
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ groupId: q.get('groupId'), maxRounds: group?.session.maxRounds ?? null }));
      return;
    }
    // 造一个「链在跑」但不 busy 的只读状态（R.4：验证重载失败后清掉旧链）。
    if (requestPath === '/__set_chain') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const group = groups.get(q.get('groupId'));
      if (group) {
        const status = q.get('status') ?? 'running';
        group.chain = {
          status,
          triggerSeq: 1,
          rounds: status === 'running' ? 1 : 2,
          stopReason: status === 'running' ? null : (q.get('stopReason') ?? 'round_cap'),
          error: null,
          steps: [],
        };
        group.busy = false;
        group.runningMemberId = null;
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ groupId: q.get('groupId'), status: group?.chain?.status ?? null }));
      return;
    }
    // 造一条**失败的链**（R.15）：`group.chain` 返回 failed + error，并发
    // `group.chain.completed`（与真核心一致），让界面重拉后显示 group-chain-error。
    if (requestPath === '/__fail_chain') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const group = groups.get(q.get('groupId'));
      const reason = q.get('error') ?? 'provider boom（e2e 注入）';
      let chain = null;
      if (group) {
        const author = group.members.find((member) => member.removedAt === null) ?? null;
        chain = {
          status: 'failed',
          triggerSeq: group.seq,
          rounds: 1,
          stopReason: 'failed',
          error: reason,
          steps:
            author === null
              ? []
              : [
                  {
                    memberId: author.id,
                    source: 'reaction',
                    status: 'failed',
                    triggerSeq: group.seq,
                    publicSeq: null,
                    finalText: null,
                    error: reason,
                  },
                ],
        };
        group.chain = chain;
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
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ groupId: q.get('groupId'), chain }));
      return;
    }
    // 伪造一条组内 `assistant.message` 事件（R.4：链在跑时触发一次 App 的 loadGroup 重载）。
    if (requestPath === '/__emit_group_message') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const group = groups.get(q.get('groupId'));
      let message = null;
      if (group) {
        message = pushMessage(group, {
          role: 'assistant',
          content: q.get('content') ?? '事件消息',
          author: group.members.find((member) => member.removedAt === null)?.id ?? null,
        });
        broadcast({
          sessionId: group.session.id,
          groupId: group.session.id,
          memberId: message.author,
          type: 'assistant.message',
          data: message,
        });
      }
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ message }));
      return;
    }
    // 掐断页面连接（R.2）：客户端会自动重连并走 `refreshAfterReconnect`。
    if (requestPath === '/__drop_sockets') {
      const dropped = sockets.length;
      for (const socket of sockets) socket.close();
      sockets = [];
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ dropped }));
      return;
    }
    // 原始消息读数（R.13）：给 e2e 的独立 oracle 按作者统计私有行，不经过 DOM。
    if (requestPath === '/__query_messages') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const id = q.get('sessionId');
      const group = groups.get(id);
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(
        JSON.stringify({
          sessionId: id,
          messages: [...(group?.messages ?? [])].sort((a, b) => a.seq - b.seq),
        }),
      );
      return;
    }
    // 伪造一条 `session.title` 事件（验证群主区标题与列表同步）。
    if (requestPath === '/__emit_title') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const sessionId = q.get('sessionId');
      const title = q.get('title') ?? '';
      const session = sessions.find((entry) => entry.id === sessionId);
      if (session) session.title = title;
      broadcast({ sessionId, type: 'session.title', data: { title } });
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ sessionId, title }));
      return;
    }
    // 给某条单聊广播上下文快照 + token 计量（验证切会话清空旧快照/计量）。
    if (requestPath === '/__emit_snapshot') {
      const sessionId =
        new URL(request.url ?? '/', 'http://127.0.0.1').searchParams.get('sessionId') ??
        's-single';
      const windowTokens = 200_000;
      broadcast({
        sessionId,
        type: 'context.snapshot',
        data: {
          sessionId,
          model: 'fake-model',
          thinkingMode: 'disabled',
          thinkingEffort: '',
          capturedAt: new Date().toISOString(),
          windowTokens,
          agentType: 'general',
          breakdown: breakdown(windowTokens, 1200, 300, 100),
          messages: [{ role: 'user', content: '快照消息' }],
          system: '你是测试模板。',
          tools: '[]',
          skillFailures: [],
          skillFailureNotice: null,
        },
      });
      broadcast({
        sessionId,
        type: 'agent.metering',
        data: { input_tokens: 12, output_tokens: 3 },
      });
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ sessionId }));
      return;
    }
    // 造一个「成员名与消息都唯一」的组（切群竞态用例要能从标题下认出是谁的数据）。
    if (requestPath === '/__seed_distinct_group') {
      const q = new URL(request.url ?? '/', 'http://127.0.0.1').searchParams;
      const seeded = newGroup(q.get('title') ?? '区分组');
      const group = groups.get(seeded.id);
      const member = {
        id: `mem-${nextId++}`,
        name: q.get('member') ?? '成员',
        template: 'general',
        removedAt: null,
        overrides: null,
        window: windows[0],
      };
      group.members.push(member);
      const content = q.get('content') ?? '唯一消息';
      pushMessage(group, { role: 'user', content });
      pushMessage(group, {
        role: 'assistant',
        content: `${member.name}的公开结论：${content}`,
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
        messages: [{ role: 'user', content }],
        system: '你是测试模板。',
        tools: '[]',
        skillFailures: [],
        skillFailureNotice: null,
      };
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(
        JSON.stringify({
          id: seeded.id,
          title: seeded.title,
          memberId: member.id,
          memberName: member.name,
        }),
      );
      return;
    }
    // 成员视图四态 / 软删 / 未知作者 / breakdown:null / 只在更早页的私有行（2.2 夹具）。
    if (requestPath === '/__seed_member_states') {
      const seeded = newGroup('成员状态组');
      const group = groups.get(seeded.id);
      const specs = [
        { id: 'mem-ms-a', name: '甲一', window: 1_000_000, snapshot: 'ok' },
        { id: 'mem-ms-b', name: '乙一', window: 200_000, snapshot: 'ok' },
        { id: 'mem-ms-c', name: '丙一', window: 200_000, snapshot: 'no-breakdown' },
        { id: 'mem-ms-d', name: '丁一', window: 200_000, snapshot: 'none' },
        { id: 'mem-ms-e', name: '戊一', window: 200_000, snapshot: 'ok' },
        { id: 'mem-ms-f', name: '己一', window: 200_000, snapshot: 'ok' },
        { id: 'mem-ms-g', name: '庚一', window: 200_000, snapshot: 'ok', removed: true },
      ];
      for (const spec of specs) {
        group.members.push({
          id: spec.id,
          name: spec.name,
          template: 'general',
          removedAt: spec.removed ? Date.now() : null,
          overrides: null,
          window: spec.window,
        });
      }
      // seq1：庚一的私有行 —— 只存在于最旧页，用来验成员视图的空态与取回入口。
      pushMessage(group, {
        role: 'assistant',
        content: '',
        author: 'mem-ms-g',
        visibility: 'private-to-author',
      });
      // 40 条公开历史把 seq1 挤出首屏（pageSize=30）。
      for (let index = 0; index < 40; index += 1) {
        pushMessage(group, {
          role: 'assistant',
          content: `公开历史 ${index}`,
          author: index % 2 === 0 ? 'mem-ms-a' : 'mem-ms-b',
        });
      }
      // 尾页里的私有行（甲/乙/丙/戊/己）+ 未知作者的私有行。
      for (const id of ['mem-ms-a', 'mem-ms-b', 'mem-ms-c', 'mem-ms-e', 'mem-ms-f']) {
        pushMessage(group, {
          role: 'assistant',
          content: '',
          author: id,
          visibility: 'private-to-author',
        });
      }
      pushMessage(group, {
        role: 'assistant',
        content: '幽灵私有过程',
        author: 'ghost-9',
        visibility: 'private-to-author',
      });
      // 快照：丁一没有（empty）；丙一 breakdown=null；其余有环。
      for (const spec of specs) {
        if (spec.snapshot === 'none') continue;
        group.snapshots[spec.id] = {
          sessionId: group.session.id,
          model: 'fake-model',
          thinkingMode: 'disabled',
          thinkingEffort: '',
          capturedAt: new Date().toISOString(),
          windowTokens: spec.window,
          agentType: 'general',
          breakdown:
            spec.snapshot === 'no-breakdown'
              ? null
              : breakdown(spec.window, 1200, 300, 100),
          messages: [{ role: 'user', content: '上下文消息' }],
          system: '你是测试模板。',
          tools: '[]',
          skillFailures: [],
          skillFailureNotice: null,
        };
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
    if (requestPath === '/__gate_member_stream') {
      streamGateEnabled = true;
      response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ gated: true }));
      return;
    }
    if (requestPath === '/__gate_chain_start') {
      startGateEnabled = true;
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
      if (startGate) {
        startGate();
        startGate = null;
      }
      if (streamGate) {
        streamGate();
        streamGate = null;
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
  auditGroupId = seeded.id;
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
  // pageerror 统一收集（R.1）：未捕获异常与未处理的 Promise 拒绝都进这里，
  // 由 `run` 在本用例结束时断言为空（探针见 R.1 / R.11）。
  const errors = [];
  pageErrorsByPage.set(page, errors);
  pagesOpened.push(page);
  page.on('console', (message) => {
    if (message.type() === 'error') console.log(`  [页面错误] ${message.text()}`);
  });
  page.on('pageerror', (error) => {
    errors.push(String(error?.message ?? error));
    console.log(`  [页面异常] ${error.message}`);
  });
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

async function clickByTestId(page, testId) {
  const selector = `[data-testid="${testId}"]`;
  await page.waitForSelector(selector, { timeout: 15000 });
  await page.click(selector);
}

/**
 * 打开 Provider 管理页（change `global-settings-menu` 2.1）。
 *
 * 管理入口收归**左栏底部**的全局设置菜单：先点「设置」按钮，再点「Provider 配置」。
 * 原先直接点单聊头部旧按钮的四个用例统一走这里 —— 旧按钮已随 D6 撤除，
 * 断言强度不变（仍然是"打开管理页后做原来那套壳层/删除断言"）。
 */
async function openProvidersPage(page) {
  await clickByTestId(page, 'global-settings-button');
  await clickByTestId(page, 'global-settings-item-providers');
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

    // change `group-chat-layout` 1.1：组视图打开时会话列表**常驻且唯一**，仍能点回单聊。
    const shellWhenGroup = await page.evaluate(() => {
      const lists = [...document.querySelectorAll('[data-testid="session-list"]')];
      const sidebar = lists[0]?.closest('[data-testid="session-sidebar"]');
      return {
        listCount: lists.length,
        inSidebar: sidebar !== null && sidebar !== undefined,
        sidebarWidth: sidebar?.getBoundingClientRect().width ?? null,
        mainCount: document.querySelectorAll('main').length,
      };
    });
    obs('组视图打开时的壳层', shellWhenGroup);
    assert(
      shellWhenGroup.listCount === 1,
      `组视图打开时全页必须恰好一个 session-list，实测 ${shellWhenGroup.listCount}`,
    );
    assert(shellWhenGroup.inSidebar, 'session-list 的祖先链必须含 session-sidebar');
    assert(
      shellWhenGroup.sidebarWidth === 224,
      `左侧会话列表宽度必须是 224px，实测 ${shellWhenGroup.sidebarWidth}`,
    );
    assert(
      shellWhenGroup.mainCount === 1,
      `页面必须恰好一个 main 地标，实测 ${shellWhenGroup.mainCount}`,
    );
    await clickSessionRow(page, '单会话');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-view"]') === null,
      { timeout: 15000 },
    );
    assert(
      (await page.$('[data-testid="session-list"]')) !== null,
      '点回单聊后会话列表必须仍在',
    );
    assert(
      (await page.$('[data-testid="message-list"]')) !== null,
      '点回单聊后主区必须渲染单聊消息视图（只换主区，不整屏重建）',
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
    // 私有行落到甲的分栏、不出现在时间线（change `group-chat-layout` 2.2：
    // 私有行迁到「成员视图」标签内的该成员私有过程列表）。
    await clickByTestId(page, 'group-tab-members');
    await page.waitForSelector(`[data-testid="member-select-${memberA}"]`, { timeout: 15000 });
    await clickByTestId(page, `member-select-${memberA}`);
    await page.waitForSelector('[data-testid="member-private-row"]', { timeout: 15000 });
    const laneText = await page.$eval(
      '[data-testid="member-private-section"]',
      (element) => element.textContent,
    );
    const timelineText = await page.$eval(
      '[data-testid="group-timeline"]',
      (element) => element.textContent,
    );
    obs('甲成员视图内容含私有过程', laneText.includes('私有过程'));
    obs('时间线是否泄漏私有行', timelineText.includes('私有过程'));
    assert(laneText.includes('私有过程'), '私有行必须落到该成员的成员视图');
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
    await clickSessionRow(page, '新组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    // change `group-chat-layout` 2.2：真实上下文与占用环迁到「成员视图」。
    await clickByTestId(page, 'group-tab-members');
    await clickByTestId(page, `member-select-${memberA}`);
    // 甲有快照：环与窗口。
    await page.waitForSelector('[data-testid="member-window"]', { timeout: 15000 });
    const windowA = await page.$eval(
      '[data-testid="member-window"]',
      (element) => element.textContent,
    );
    obs('甲的窗口（环分母）', windowA);
    assert(windowA.includes('1000000'), `甲的分母应是 1000000，实测 ${windowA}`);
    const ringA = await page.$('[data-testid="context-ring"]');
    assert(ringA !== null, '甲应有占用环');

    // 真实上下文：group.view 的 system/messages/tools 原始 JSON（无需展开按钮）。
    await page.waitForSelector('[data-testid="real-context"]', { timeout: 15000 });
    const raw = await page.$eval('[data-testid="real-context"] pre', (element) => element.textContent);
    obs('真实上下文 JSON 片段', raw.slice(0, 80));
    assert(raw.includes('"system"') && raw.includes('"messages"') && raw.includes('"tools"'), '必须显示 system/messages/tools');

    // 乙没发过言：窗口 200000（选择器可切换），快照空态占位、环不渲染。
    await clickByTestId(page, `member-select-${memberB}`);
    await page.waitForSelector('[data-testid="member-no-snapshot"]', { timeout: 15000 });
    const noSnapshotB = await page.$('[data-testid="member-no-snapshot"]');
    assert(noSnapshotB !== null, '乙没发过言应显示"本次运行内没发过言"占位');
    const noRingB = await page.$('[data-testid="context-ring"]');
    assert(noRingB === null, '没有快照时环不渲染');
  } finally {
    await page.close();
  }
});

await run('8.8 上翻分页：公开时间线与成员视图私有行同步补页（before 游标 payload 判据）', async () => {
  // 假核心夹具：45 条历史，含已移除成员「丁」的私有/公开旧行（只存在于最旧的页）。
  const seeded = await fetch(`${staticServer.url}__seed_group`).then((response) => response.json());
  obs('分页夹具', seeded);
  const page = await openPage();
  try {
    await openExistingGroup(page, '分页组');
    await page.waitForSelector('[data-testid="timeline-item"]', { timeout: 15000 });

    const initialSeqs = await page.$$eval('[data-testid="timeline-item"]', (nodes) =>
      nodes.map((node) => Number(node.getAttribute('data-seq'))),
    );
    obs('首屏（尾页）时间线行数', initialSeqs.length);
    assert(initialSeqs.length > 0, '首屏时间线应有行');

    // change `group-chat-layout` 2.2：私有行在「成员视图」里看。选已移除的丁：
    // 它的私有行只在更早页 ⇒ 先显示「本次已加载页里没有私有行」+ 取回入口。
    await clickByTestId(page, 'group-tab-members');
    await clickByTestId(page, 'member-select-mem-page-丁');
    await page.waitForSelector('[data-testid="member-private-section"]', { timeout: 15000 });
    const emptyBefore = await page.$('[data-testid="member-private-empty"]');
    const rowsBefore = await page.$$eval('[data-testid="member-private-row"]', (nodes) => nodes.length);
    obs('尾页里丁的私有行', { emptyBefore: emptyBefore !== null, rowsBefore });
    assert(emptyBefore !== null, '尾页里丁的私有行必须显示空态（不是静默空白）');
    assert(rowsBefore === 0, '尾页里不应有已移除成员的旧私有行');

    // 成员视图自己的「加载更早」入口（复用同一份 groupMessages 游标）。
    await clickByTestId(page, 'member-load-earlier');
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="member-private-row"]').length > 0,
      { timeout: 15000 },
    );
    const rowsAfter = await page.$$eval('[data-testid="member-private-row"]', (nodes) => nodes.length);
    const privateText = await page.$eval(
      '[data-testid="member-private-section"]',
      (element) => element.textContent ?? '',
    );
    obs('上翻后丁的私有行数', rowsAfter);
    assert(rowsAfter >= 1, '丁的历史私有行必须在上翻后落到成员视图');
    assert(privateText.includes('私有过程'), '私有行内容必须显示（空内容显示「私有过程」占位）');

    // 切回群聊：公开时间线同步补页。
    await clickByTestId(page, 'group-tab-chat');
    const afterSeqs = await page.$$eval('[data-testid="timeline-item"]', (nodes) =>
      nodes.map((node) => Number(node.getAttribute('data-seq'))),
    );
    obs('上翻后时间线行数', afterSeqs.length);
    assert(afterSeqs.length > initialSeqs.length, '公开时间线必须同步补页');
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
      new Set(afterSeqs).size === afterSeqs.length,
      '上翻后时间线不得出现重复行',
    );
    const minBefore = Math.min(...initialSeqs);
    const minAfter = Math.min(...afterSeqs);
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

await run('8.7 布局：1280 宽与窄屏不重叠/不溢出 + 成员名单右置、底部分栏已删（几何断言）', async () => {
  for (const width of [1280, 720]) {
    const page = await openPage(width, 900);
    try {
      await openExistingGroup(page, '分页组');
      const geometry = await page.evaluate(() => {
        const rect = (selector) => {
          const node = document.querySelector(selector);
          if (!node) return null;
          const box = node.getBoundingClientRect();
          return {
            left: box.left,
            right: box.right,
            top: box.top,
            bottom: box.bottom,
            width: box.width,
            height: box.height,
          };
        };
        return {
          scrollWidth: document.documentElement.scrollWidth,
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight,
          timeline: rect('[data-testid="group-timeline"]'),
          members: rect('[data-testid="group-members"]'),
          // 发送区在群视图里是 `group-send`（与 `group-input` 同一行），量它的底边。
          composer: rect('[data-testid="group-send"]'),
          laneCount: document.querySelectorAll('[data-testid^="lane-"]').length,
          mainCount: document.querySelectorAll('main').length,
          listCount: document.querySelectorAll('[data-testid="session-list"]').length,
        };
      });
      obs(`${width}px 几何`, geometry);
      assert(
        geometry.scrollWidth <= geometry.innerWidth + 1,
        `${width}px：出现横向溢出（scrollWidth=${geometry.scrollWidth} > innerWidth=${geometry.innerWidth}）`,
      );
      assert(geometry.mainCount === 1, `${width}px：页面必须恰好一个 main，实测 ${geometry.mainCount}`);
      assert(geometry.listCount === 1, `${width}px：群聊打开时必须恰好一个 session-list`);
      // 底部分栏已删（change `group-chat-layout` 2.3）：`lane-*` 计数为 0。
      assert(
        geometry.laneCount === 0,
        `${width}px：底部分栏必须已删除（[data-testid^="lane-"] 计数 ${geometry.laneCount}）`,
      );
      // 发送区贴底：底部分栏不再挤占垂直空间。
      assert(geometry.composer !== null, `${width}px：必须存在发送区`);
      const composerGap = geometry.innerHeight - geometry.composer.bottom;
      obs(`${width}px 发送区距视口底`, composerGap);
      assert(
        composerGap <= 24,
        `${width}px：发送区底边必须贴近视口底（实测距底 ${composerGap}px）`,
      );
      // 成员名单右置（>= xl 静态列）：在时间线右边且不重叠。
      if (width >= 1280) {
        assert(
          geometry.members !== null && geometry.members.width > 0,
          '1280px：成员名单必须可见',
        );
        assert(
          Math.abs(geometry.members.width - 288) <= 0.5,
          `1280px：成员名单宽度必须是 288px（w-72 原值），实测 ${geometry.members.width}`,
        );
        assert(
          geometry.timeline !== null && geometry.members.left >= geometry.timeline.right - 0.5,
          `1280px：成员名单必须在时间线右侧（timeline.right=${geometry.timeline?.right} / members.left=${geometry.members.left}）`,
        );
      } else {
        // 窄屏抽屉关闭时成员名单不可见（2.4 另测打开后的几何）。
        assert(
          geometry.members === null || geometry.members.width === 0,
          `720px：抽屉关闭时成员名单不得静态占位（实测宽 ${geometry.members?.width}）`,
        );
      }
      // 窄屏（< xl）成员名单是抽屉：隐藏元素高度为 0，量它会假红。成员控件
      // 在 720 的测法由 2.4「先开抽屉再量」，这里 720 只量常驻控件。
      const controlSelector =
        width >= 1280
          ? '[data-testid="group-send"], [data-testid="member-add"], [data-testid="speaker-select"]'
          : '[data-testid="group-send"], [data-testid="speaker-select"]';
      const tooSmall = await page.evaluate((selector) =>
        [...document.querySelectorAll(selector)].some(
          (node) => node.getBoundingClientRect().height < 24,
        ),
      controlSelector);
      assert(!tooSmall, `${width}px：关键控件高度小于 24px（触控尺寸不足）`);
    } finally {
      await page.close();
    }
  }
});

// ---------------------------------------------------------------------------
// 1.x 应用壳层、常驻列表与群加载正确性（change `group-chat-layout` 任务 1.1~1.6）
// ---------------------------------------------------------------------------

/** 设置假核心的故障 / 延迟注入（`reset=1` 清空全部）。 */
async function setGroupFlags(query) {
  const result = await fetch(`${staticServer.url}__flags?${query}`).then((response) =>
    response.json(),
  );
  obs(`假核心 flags（${query}）`, result);
  return result;
}

/** 造一条单聊（夹具）。 */
async function seedSingle(title, { front = false, workspace = null } = {}) {
  const query = new URLSearchParams({ title });
  if (front) query.set('front', '1');
  if (workspace !== null) query.set('workspace', workspace);
  const seeded = await fetch(
    `${staticServer.url}__seed_single?${query.toString()}`,
  ).then((response) => response.json());
  obs(`单聊夹具 ${title}`, seeded);
  return seeded;
}

/** 造一个带工作路径、两个成员的组（change `custom-workspace` 夹具）。 */
async function seedWorkspaceGroup(title, workspace) {
  const query = new URLSearchParams({ title });
  if (workspace !== null && workspace !== undefined) query.set('workspace', workspace);
  const seeded = await fetch(
    `${staticServer.url}__seed_workspace_group?${query.toString()}`,
  ).then((response) => response.json());
  obs(`工作区组夹具 ${title}`, seeded);
  return seeded;
}

/** 造一个成员名 / 消息内容都唯一的组（夹具）。 */
async function seedDistinctGroup(title, member, content) {
  const seeded = await fetch(
    `${staticServer.url}__seed_distinct_group?title=${encodeURIComponent(title)}` +
      `&member=${encodeURIComponent(member)}&content=${encodeURIComponent(content)}`,
  ).then((response) => response.json());
  obs(`组夹具 ${title}`, seeded);
  return seeded;
}

/** 把基础单聊排回首位：让新页面的首屏落在聊天屏（否则会先落在某个组上）。 */
async function ensureSingleFirst() {
  await fetch(`${staticServer.url}__promote_session?id=s-single`);
}

/**
 * R 节的隔离夹具：清空全部会话（含组）后造一条基础单聊并排到首位。
 *
 * 1.4b 会把会话删到 0（那时 `s-single` 也没了），R 节每条用例自己造会话，
 * 互不依赖前序用例的残留（R.11 的 flag 串味判据也靠它）。
 */
async function resetToBaseSingle(title = '基础单聊') {
  for (const session of [...sessions]) {
    await fetch(`${staticServer.url}__delete_session?id=${session.id}`).catch(() => {});
  }
  return seedSingle(title, { front: true });
}

/** 点会话行（按标题子串）。 */
async function clickSessionRow(page, title) {
  await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
  const clicked = await page.evaluate((label) => {
    const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
    const target = rows.find((row) => row.textContent?.includes(label));
    if (!target) return false;
    target.click();
    return true;
  }, title);
  assert(clicked, `会话列表里找不到「${title}」这一行`);
}

/** 删除会话列表里指定 id 的某一行（确认浮层；R.11 用）。 */
async function deleteSessionRowById(page, sessionId) {
  await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
  const opened = await page.evaluate((id) => {
    const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
    const row = rows.find((entry) => entry.getAttribute('data-session-id') === id);
    const button = row?.parentElement?.querySelector('[data-testid="session-delete"]');
    if (!button) return false;
    button.click();
    return true;
  }, sessionId);
  assert(opened, `会话列表里找不到 id=${sessionId} 这一行的删除按钮`);
  await page.waitForSelector('[data-testid="delete-confirm-button"]', { timeout: 15000 });
  await page.evaluate(() => {
    document.querySelector('[data-testid="delete-confirm-button"]')?.click();
  });
}


/** 删除会话列表的第一行（确认浮层）。 */
async function deleteFirstSessionRow(page) {
  await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
  // 用 DOM 点击（不依赖浮层的可见性判定）：本用例验的是删除走哪条 RPC，
  // 列表本身的命中测试由 1.5 的 elementFromPoint 断言负责。
  const opened = await page.evaluate(() => {
    const row = document.querySelector('[data-testid="session-row"]');
    const button = row?.parentElement?.querySelector('[data-testid="session-delete"]');
    if (!button) return false;
    button.click();
    return true;
  });
  assert(opened, '第一行会话的删除按钮必须存在');
  await page.waitForSelector('[data-testid="delete-confirm-button"]', { timeout: 15000 });
  await page.evaluate(() => {
    document.querySelector('[data-testid="delete-confirm-button"]')?.click();
  });
}

await run('1.2 群加载：A 的晚到响应不挂到 B / message.query 失败保留占位 / 激活清旧快照与计量', async () => {
  // ① 乱序响应：A 的 message.query 延迟，点 A 后立刻点 B，A 的晚到结果必须丢弃。
  const a = await seedDistinctGroup('慢组A', '阿慢', 'A组唯一消息');
  const b = await seedDistinctGroup('快组B', '阿快', 'B组唯一消息');
  await setGroupFlags(
    `reset=1&messageQueryDelayGroupId=${a.id}&messageQueryDelayMs=900` +
      `&groupViewDelayGroupId=${a.id}&groupViewDelayMs=900`,
  );
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '慢组A');
    await new Promise((resolve) => setTimeout(resolve, 80));
    await clickSessionRow(page, '快组B');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('快组B') === true,
      { timeout: 15000 },
    );
    // 等 A 的晚到响应真的到达（900ms 延迟 + 余量）。
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const state = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      members: [...document.querySelectorAll('[data-testid^="member-name-"]')]
        .filter((node) => !node.getAttribute('data-testid')?.endsWith('-input'))
        .map((node) => node.textContent ?? ''),
      timeline: document.querySelector('[data-testid="group-timeline"]')?.textContent ?? '',
      error: document.querySelector('[data-testid="group-view-error"]')?.textContent ?? null,
    }));
    obs('切到 B 后（A 的响应已到）', state);
    assert(state.title.includes('快组B'), `主区标题必须是 B，实测「${state.title}」`);
    assert(
      !state.title.includes('慢组A'),
      `A 的摘要不得挂到 B 标题下，实测「${state.title}」`,
    );
    assert(
      state.members.some((name) => name.includes('阿快')),
      `B 的成员必须显示，实测 ${JSON.stringify(state.members)}`,
    );
    assert(
      !state.members.some((name) => name.includes('阿慢')),
      `A 的成员不得出现在 B 的成员名单，实测 ${JSON.stringify(state.members)}`,
    );
    assert(
      state.timeline.includes('B组唯一消息'),
      'B 的消息必须显示',
    );
    assert(
      !state.timeline.includes('A组唯一消息'),
      'A 的晚到消息不得提交到 B 的时间线',
    );
    assert(state.error === null, `过期响应不得在新群产生错误，实测 ${state.error}`);
  } finally {
    await page.close();
  }

  // ② message.query 失败：占位保留、错误可归因、不出现空时间线。
  const c = await seedDistinctGroup('失败组C', '阿败', 'C组消息');
  await setGroupFlags(`reset=1&messageQueryFailFor=${c.id}`);
  await ensureSingleFirst();
  const failedPage = await openPage();
  try {
    await failedPage.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(failedPage, '失败组C');
    await failedPage.waitForSelector('[data-testid="group-loading"]', { timeout: 15000 });
    await failedPage.waitForSelector('[data-testid="group-loading-error"]', { timeout: 15000 });
    const failState = await failedPage.evaluate(() => ({
      loading: document.querySelector('[data-testid="group-loading"]') !== null,
      error: document.querySelector('[data-testid="group-loading-error"]')?.textContent ?? '',
      timelineEmpty: document.querySelector('[data-testid="timeline-empty"]') !== null,
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
    }));
    obs('message.query 失败时的主区', failState);
    assert(failState.loading, '加载失败时群聊占位必须保留');
    assert(
      failState.error.includes('message.query 失败'),
      `错误必须可见且可归因，实测「${failState.error}」`,
    );
    assert(!failState.timelineEmpty, '加载失败不得用空时间线冒充加载完成');
  } finally {
    await failedPage.close();
  }
  await setGroupFlags('reset=1');

  // ③ 激活重置：从有快照 + 计量的单聊切到另一条会话，旧内容不得残留。
  const second = await seedSingle('第二个单聊', { front: true });
  const resetPage = await openPage();
  try {
    await resetPage.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    // 打开页面时自动选中 sessions[0] = 第二个单聊；先回到「单会话」产生快照与计量。
    await clickSessionRow(resetPage, '单会话');
    await resetPage.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await fetch(`${staticServer.url}__emit_snapshot?sessionId=s-single`);
    await resetPage.waitForSelector('[data-testid="context-snapshot"]', { timeout: 15000 });
    const before = await resetPage.evaluate(() => ({
      snapshot: document.querySelector('[data-testid="context-snapshot"]') !== null,
      ring: document.querySelector('[data-testid="context-ring"]') !== null,
      metering: document.body.textContent.includes('in 12 / out 3 tokens'),
    }));
    obs('切会话前（快照 / 环 / 计量）', before);
    assert(before.snapshot && before.ring && before.metering, '快照 / 环 / 计量必须先真的显示');
    await clickSessionRow(resetPage, '第二个单聊');
    await resetPage.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('第二个单聊') === true,
      { timeout: 15000 },
    );
    const after = await resetPage.evaluate(() => ({
      snapshot: document.querySelector('[data-testid="context-snapshot"]') !== null,
      ring: document.querySelector('[data-testid="context-ring"]') !== null,
      metering: document.body.textContent.includes('in 12 / out 3 tokens'),
    }));
    obs('切会话后（旧快照 / 环 / 计量）', after);
    assert(!after.snapshot, '切换会话后不得残留上一条会话的 context-snapshot');
    assert(!after.ring, '切换会话后不得残留上一条会话的占用环');
    assert(!after.metering, '切换会话后不得残留上一条会话的 token 计量');
  } finally {
    await resetPage.close();
    // 清掉夹具，避免把 sessions[0] 留给后续用例 / GROUP_DEFAULT 审计页。
    await fetch(`${staticServer.url}__delete_session?id=${second.id}`).catch(() => {});
  }
});

await run('1.3 会话列表按 kind 区分：群行有「群」标记与 data-kind，单聊行 data-kind=single', async () => {
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
    const rows = await page.evaluate(() =>
      [...document.querySelectorAll('[data-testid="session-row"]')].map((row) => ({
        kind: row.getAttribute('data-kind'),
        title: row.getAttribute('title'),
        text: row.textContent ?? '',
        height: row.getBoundingClientRect().height,
        badge: row.querySelector('[data-testid="session-kind-badge"]')?.textContent ?? null,
        sessionId: row.getAttribute('data-session-id'),
      })),
    );
    obs('会话行类型标记', rows.slice(0, 8));
    const groupRow = rows.find((row) => row.kind === 'group');
    const singleRow = rows.find((row) => row.kind === 'single');
    assert(groupRow !== undefined, '列表里必须有 data-kind="group" 的群聊行');
    assert(singleRow !== undefined, '列表里必须有 data-kind="single" 的单聊行');
    assert(groupRow.badge === '群', `群聊行必须显示「群」标记，实测 ${groupRow.badge}`);
    assert(singleRow.badge === null, '单聊行不得显示「群」标记');
    assert(
      groupRow.title?.includes('群聊') === true,
      `群聊行的标题/无障碍文案必须用「群聊」，实测「${groupRow.title}」`,
    );
    assert(
      singleRow.title?.includes('单聊') === true,
      `单聊行的标题/无障碍文案必须用「单聊」，实测「${singleRow.title}」`,
    );
    assert(
      Math.abs(groupRow.height - 36) <= 1,
      `加类型标记后行高必须仍是 36px，实测 ${groupRow.height}`,
    );
  } finally {
    await page.close();
  }
});

await run('1.4 群行删除走 group.delete、单聊删除走 session.delete，删除后按 kind 激活', async () => {
  await ensureSingleFirst();
  const page = await openPage();
  let createdGroupId = null;
  let seededSingleId = null;
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickByTestId(page, 'group-create');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const created = responseLog.filter((entry) => entry.method === 'group.create').at(-1);
    const groupId = created?.result?.group?.id;
    const groupTitle = created?.result?.group?.title;
    obs('新建的删除用组', { groupId, groupTitle });
    assert(groupId, 'group.create 必须返回新组 id');

    const single = await seedSingle('待删单聊', { front: true });
    seededSingleId = single.id;
    // 让组排在单聊之后：先把组提到首位，再把单聊提到首位 ⇒ [单聊, 组, ...]。
    await fetch(`${staticServer.url}__promote_session?id=${groupId}`);
    await fetch(`${staticServer.url}__promote_session?id=${single.id}`);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('待删单聊') === true,
      { timeout: 15000 },
    );

    // ① 删除当前单聊：下一条是群聊 ⇒ 必须发 session.delete，并按群激活。
    await deleteFirstSessionRow(page);
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const groupDeleteRpcs = rpcLog.filter(
      (entry) => entry.method === 'session.delete' && entry.params.sessionId === single.id,
    );
    obs('删除单聊时的 session.delete', groupDeleteRpcs.at(-1)?.params);
    assert(groupDeleteRpcs.length === 1, '删除单聊必须发 session.delete（带该 sessionId）');
    const afterSingleDelete = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      isGroup: document.querySelector('[data-testid="group-view"]') !== null,
    }));
    obs('删除单聊后的主区', afterSingleDelete);
    assert(
      afterSingleDelete.isGroup && afterSingleDelete.title.includes(groupTitle),
      `删除单聊后下一条是群聊时必须按群加载，实测 ${JSON.stringify(afterSingleDelete)}`,
    );

    // ② 删除当前群：下一条是单聊 ⇒ 必须发 group.delete（payload 带 groupId）。
    const groupDeletesBefore = rpcLog.filter((entry) => entry.method === 'group.delete').length;
    await deleteFirstSessionRow(page);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-view"]') === null,
      { timeout: 15000 },
    );
    const groupDeletes = rpcLog.filter((entry) => entry.method === 'group.delete');
    obs('删除群时的 group.delete', groupDeletes.at(-1)?.params);
    assert(
      groupDeletes.length === groupDeletesBefore + 1,
      '删除群行必须发 group.delete（不是 session.delete）',
    );
    assert(
      groupDeletes.at(-1)?.params?.groupId === groupId,
      `group.delete 的 payload 必须带被删组的 groupId，实测 ${JSON.stringify(groupDeletes.at(-1)?.params)}`,
    );
    const afterGroupDelete = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      hasMessageList: document.querySelector('[data-testid="message-list"]') !== null,
      hasGroup: document.querySelector('[data-testid="group-view"]') !== null,
    }));
    obs('删除群后的主区', afterGroupDelete);
    assert(!afterGroupDelete.hasGroup, '删除群后不得继续显示群视图');
    assert(
      afterGroupDelete.hasMessageList &&
        afterGroupDelete.title.includes('单会话'),
      `删除群后下一条是单聊时必须按单聊加载，实测 ${JSON.stringify(afterGroupDelete)}`,
    );
  } finally {
    await page.close();
    // 清理夹具（若断言失败，组/单聊可能还在）。
    if (seededSingleId) {
      await fetch(`${staticServer.url}__delete_session?id=${seededSingleId}`).catch(() => {});
    }
  }
});

await run('1.5 管理面板只盖主区：列表仍唯一可点、滚动位置不变、点会话关闭面板', async () => {
  await ensureSingleFirst();
  // 造足够的行让会话列表真的可滚动（约 10 条真实会话不足一屏，scrollTop 断言会空转）。
  const fillers = [];
  for (let index = 0; index < 30; index += 1) {
    const filler = await seedSingle(`填充会话 ${index}`);
    fillers.push(filler.id);
  }
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '单会话');
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const list = document.querySelector('[data-testid="session-list"]');
      list.scrollTop = Math.min(240, list.scrollHeight - list.clientHeight);
    });
    await new Promise((resolve) => setTimeout(resolve, 250));
    const scrollBefore = await page.$eval(
      '[data-testid="session-list"]',
      (element) => element.scrollTop,
    );
    obs('打开面板前的列表 scrollTop', scrollBefore);
    assert(scrollBefore > 0, `列表必须真的可滚动（scrollTop=${scrollBefore}）`);

    await openProvidersPage(page);
    await page.waitForSelector('[data-testid="providers-page"]', { timeout: 15000 });
    const panelState = await page.evaluate(() => {
      const lists = [...document.querySelectorAll('[data-testid="session-list"]')];
      const sidebar = document.querySelector('[data-testid="session-sidebar"]');
      const list = lists[0];
      const listRect = list?.getBoundingClientRect();
      // 取一条**完整落在滚动视口内**的行做命中测试（列表滚到中段后第一行可能被裁掉）。
      const row = [...document.querySelectorAll('[data-testid="session-row"]')].find((node) => {
        const box = node.getBoundingClientRect();
        return (
          listRect !== undefined &&
          box.height > 0 &&
          box.top >= listRect.top &&
          box.bottom <= listRect.bottom
        );
      });
      const rowRect = row?.getBoundingClientRect();
      const hit = rowRect
        ? document.elementFromPoint(
            rowRect.left + rowRect.width / 2,
            rowRect.top + rowRect.height / 2,
          )
        : null;
      return {
        listCount: lists.length,
        sidebarWidth: sidebar?.getBoundingClientRect().width ?? null,
        hitInList: hit !== null && list?.contains(hit) === true,
        hitTestId: hit?.getAttribute('data-testid') ?? hit?.tagName ?? null,
        hitIsOverlay: hit?.closest('[data-testid="providers-page"]') !== null,
        mainCount: document.querySelectorAll('main').length,
        scrollTop: list?.scrollTop ?? null,
      };
    });
    obs('打开 Provider 页后的壳层', panelState);
    assert(panelState.listCount === 1, '管理面板打开时列表必须仍恰好一个节点');
    assert(
      panelState.sidebarWidth === 224,
      `管理面板打开时左列宽度必须不变（224px），实测 ${panelState.sidebarWidth}`,
    );
    assert(
      panelState.hitInList && !panelState.hitIsOverlay,
      `elementFromPoint 必须命中会话列表而不是覆盖层（命中 ${panelState.hitTestId}）`,
    );
    assert(
      panelState.scrollTop === scrollBefore,
      `打开面板不得重置列表滚动位置（前 ${scrollBefore} / 后 ${panelState.scrollTop}）`,
    );
    assert(panelState.mainCount === 1, `页面必须恰好一个 main，实测 ${panelState.mainCount}`);

    await page.click('[data-testid="providers-close"]');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="providers-page"]') === null,
      { timeout: 15000 },
    );
    // 再开一次，点一个会话 ⇒ 面板关闭、主区切到该会话。
    await openProvidersPage(page);
    await page.waitForSelector('[data-testid="providers-page"]', { timeout: 15000 });
    await clickSessionRow(page, '单会话');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="providers-page"]') === null,
      { timeout: 15000 },
    );
    const afterSelect = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      hasPanel: document.querySelector('[data-testid="providers-page"]') !== null,
    }));
    obs('点会话后的主区', afterSelect);
    assert(!afterSelect.hasPanel, '点会话后管理面板必须关闭');
    assert(afterSelect.title.includes('单会话'), '主区必须切到被点的会话');
  } finally {
    await page.close();
    // 清掉填充会话，恢复列表规模（后续用例按标题找行，不能被挤出虚拟化窗口）。
    for (const id of fillers) {
      await fetch(`${staticServer.url}__delete_session?id=${id}`).catch(() => {});
    }
  }
});

await run('1.6 群行重命名同步主区标题、session.title 事件同步、群模板下拉禁用并说明', async () => {
  const seeded = await seedDistinctGroup('改名组', '阿改', '改名组的消息');
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '改名组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });

    // ① 内联重命名群行 ⇒ 群主区标题同步。
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      const row = rows.find((entry) => entry.textContent?.includes('改名组'));
      row?.parentElement?.querySelector('[data-testid="session-rename"]')?.click();
    });
    await page.waitForSelector('[data-testid="session-rename-input"]', { timeout: 15000 });
    await page.click('[data-testid="session-rename-input"]');
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyA');
    await page.keyboard.up('Control');
    await page.type('[data-testid="session-rename-input"]', '重命名后的组');
    await page.keyboard.press('Enter');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('重命名后的组') === true,
      { timeout: 15000 },
    );
    const renameRpc = rpcLog.filter((entry) => entry.method === 'session.rename').at(-1);
    obs('session.rename 实际 params', renameRpc?.params);
    assert(
      renameRpc?.params?.sessionId === seeded.id && renameRpc?.params?.title === '重命名后的组',
      '重命名必须发 session.rename（payload 判据）',
    );
    assert(
      (await page.$eval('[data-testid="group-view"] h1', (element) => element.textContent))?.includes(
        '重命名后的组',
      ) === true,
      '群主区标题必须同步新标题',
    );

    // ② session.title 事件 ⇒ 列表与主区一起同步。
    await fetch(
      `${staticServer.url}__emit_title?sessionId=${seeded.id}&title=${encodeURIComponent('事件改名组')}`,
    );
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('事件改名组') === true &&
        [...document.querySelectorAll('[data-testid="session-row"]')].some((row) =>
          row.textContent?.includes('事件改名组'),
        ),
      { timeout: 15000 },
    );
    obs('事件改名后主区标题', await page.$eval('[data-testid="group-view"] h1', (element) => element.textContent));

    // ③ 群模板下拉：禁用或不存在 + 说明 + 强制选择也不发 RPC。
    const templateState = await page.evaluate(() => {
      const select = document.querySelector('[data-testid="template-select"]');
      return {
        exists: select !== null,
        disabled: select === null ? null : select.disabled,
        note: document.querySelector('[data-testid="group-template-note"]')?.textContent ?? null,
      };
    });
    obs('群聊时的模板下拉', templateState);
    assert(
      templateState.note?.includes('群聊模板由各成员决定') === true,
      `群聊必须显示「群聊模板由各成员决定」，实测「${templateState.note}」`,
    );
    assert(
      templateState.exists === false || templateState.disabled === true,
      '群聊打开时模板选择器必须禁用或不存在',
    );
    const switchBefore = rpcLog.filter(
      (entry) => entry.method === 'session.switchTemplate',
    ).length;
    await page.evaluate(() => {
      const select = document.querySelector('[data-testid="template-select"]');
      if (!select) return;
      select.value = 'narrow';
      select.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert(
      rpcLog.filter((entry) => entry.method === 'session.switchTemplate').length === switchBefore,
      '群聊时强制选择模板也不得发出 session.switchTemplate',
    );
  } finally {
    await page.close();
    // 清理夹具，避免影响后续用例（审计组在 GROUP_DEFAULT 下要保持首位，见文件末）。
    await fetch(`${staticServer.url}__delete_session?id=${seeded.id}`).catch(() => {});
  }
});

// ---------------------------------------------------------------------------
// 2.x 群聊双标签、成员视图、窄屏抽屉与反应状态（change `group-chat-layout`）
// ---------------------------------------------------------------------------

await run('2.1 双标签：文案逐字、hidden 切换、不重拉 RPC、草稿/滚动/链状态保持', async () => {
  await fetch(`${staticServer.url}__seed_group`);
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '分页组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const initial = await page.evaluate(() => {
      const chat = document.querySelector('[data-testid="group-tab-chat"]');
      const members = document.querySelector('[data-testid="group-tab-members"]');
      return {
        chatText: chat?.textContent?.trim() ?? '',
        memberText: members?.textContent?.trim() ?? '',
        role: chat?.getAttribute('role') ?? null,
        ariaSelected: chat?.getAttribute('aria-selected') ?? null,
        active: document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab'),
        chatDisplay: getComputedStyle(
          document.querySelector('[data-testid="group-chat-panel"]'),
        ).display,
        memberDisplay: getComputedStyle(document.querySelector('[data-testid="member-view"]')).display,
      };
    });
    obs('双标签初始状态', initial);
    assert(initial.chatText === '群聊', `标签文案必须逐字为「群聊」，实测「${initial.chatText}」`);
    assert(
      initial.memberText === '成员视图',
      `标签文案必须逐字为「成员视图」，实测「${initial.memberText}」`,
    );
    assert(initial.role === 'tab', '标签按钮必须有 role="tab"');
    assert(initial.ariaSelected === 'true', '激活标签必须有 aria-selected="true"');
    assert(initial.active === 'chat', `根节点 data-active-tab 必须是 chat，实测 ${initial.active}`);
    assert(initial.chatDisplay !== 'none', '群聊面板必须可见');
    assert(initial.memberDisplay === 'none', '未激活的成员视图必须 display:none（保持挂载）');

    // 草稿与滚动位置：切标签前后不变（不重建 GroupView）。
    await page.type('[data-testid="group-input"]', '切标签不丢的草稿');
    await page.evaluate(() => {
      document.querySelector('[data-testid="group-timeline"]').scrollTop = 120;
    });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const before = await page.evaluate(() => ({
      draft: document.querySelector('[data-testid="group-input"]')?.value ?? '',
      scroll: document.querySelector('[data-testid="group-timeline"]')?.scrollTop ?? 0,
    }));
    obs('切标签前（草稿 / scrollTop）', before);
    const rpcBefore = rpcLog.filter(
      (entry) => entry.method.startsWith('group.') || entry.method === 'session.list',
    ).length;
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 15000 },
    );
    const onMembers = await page.evaluate(() => ({
      chatDisplay: getComputedStyle(
        document.querySelector('[data-testid="group-chat-panel"]'),
      ).display,
      memberDisplay: getComputedStyle(document.querySelector('[data-testid="member-view"]')).display,
      draft: document.querySelector('[data-testid="group-input"]')?.value ?? '',
      ariaHidden: document
        .querySelector('[data-testid="group-chat-panel"]')
        ?.getAttribute('aria-hidden'),
    }));
    const rpcAfter = rpcLog.filter(
      (entry) => entry.method.startsWith('group.') || entry.method === 'session.list',
    ).length;
    obs('切到成员视图后', onMembers);
    assert(onMembers.chatDisplay === 'none', '切到成员视图后群聊面板必须 display:none');
    assert(onMembers.memberDisplay !== 'none', '成员视图面板必须可见');
    assert(onMembers.ariaHidden === 'true', '隐藏的群聊面板必须 aria-hidden="true"');
    assert(
      rpcAfter === rpcBefore,
      `切标签不得重拉任何 group.* / session.list（前 ${rpcBefore} / 后 ${rpcAfter}）`,
    );
    assert(onMembers.draft === before.draft, '切标签不得丢输入草稿');
    // 注意：display:none 期间浏览器会把 scrollTop 归零，故只在切回后断言恢复值。

    await clickByTestId(page, 'group-tab-chat');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 15000 },
    );
    const back = await page.evaluate(() => ({
      draft: document.querySelector('[data-testid="group-input"]')?.value ?? '',
      scroll: document.querySelector('[data-testid="group-timeline"]')?.scrollTop ?? 0,
    }));
    obs('切回群聊后', back);
    assert(back.draft === before.draft, '切回群聊必须保留草稿');
    assert(back.scroll === before.scroll, '切回群聊必须保留时间线滚动位置');

    // 链运行中切标签：活动指示与取消按钮仍在（本地状态不因切标签丢失）。
    await fetch(`${staticServer.url}__gate_next_send`);
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') !== null,
      { timeout: 15000 },
    );
    await clickByTestId(page, 'group-tab-members');
    const duringChain = await page.evaluate(() => ({
      active: document.querySelector('[data-testid="reaction-active"]') !== null,
      cancel: document.querySelector('[data-testid="group-cancel"]') !== null,
      cancelDisabled: document.querySelector('[data-testid="group-cancel"]')?.disabled ?? null,
    }));
    obs('链中切到成员视图后的反应控件', duringChain);
    assert(duringChain.active, '链运行中切标签后仍必须显示反应链活动指示');
    assert(duringChain.cancel, '链运行中切标签后仍必须存在取消按钮');
    assert(duringChain.cancelDisabled === false, '链运行中取消按钮必须可用');
  } finally {
    await fetch(`${staticServer.url}__release_send`).catch(() => {});
    await page.close();
  }
});

await run('2.2 成员视图完整性：四态快照 / 软删保持 / 未知作者 / breakdown:null / 更早页私有行', async () => {
  const seeded = await fetch(`${staticServer.url}__seed_member_states`).then((response) =>
    response.json(),
  );
  obs('成员状态组夹具', seeded);
  await setGroupFlags(
    `reset=1&groupViewFailGroupId=${seeded.id}&groupViewFailMemberId=mem-ms-e` +
      `&groupViewDelayGroupId=${seeded.id}&groupViewDelayMemberId=mem-ms-f&groupViewDelayMs=3000`,
  );
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await clickByTestId(page, 'group-tab-members');
    await page.waitForSelector('[data-testid="member-view"]', { timeout: 15000 });

    // ① 延迟的成员：loading（不伪装成"没发过言"）。
    await clickByTestId(page, 'member-select-mem-ms-f');
    const loading = await page.evaluate(() => ({
      loading: document.querySelector('[data-testid="member-snapshot-loading"]') !== null,
      noSnapshot: document.querySelector('[data-testid="member-no-snapshot"]') !== null,
    }));
    obs('己一（group.view 延迟）的快照状态', loading);
    assert(loading.loading, 'group.view 未返回时必须显示 member-snapshot-loading');
    assert(!loading.noSnapshot, 'loading 不得伪装成「没发过言」');

    // ② 甲一：窗口 1000000 + 环 + 真实上下文 + 私有行。
    await clickByTestId(page, 'member-select-mem-ms-a');
    await page.waitForSelector('[data-testid="member-window"]', { timeout: 15000 });
    const a = await page.evaluate(() => ({
      window: document.querySelector('[data-testid="member-window"]')?.textContent ?? '',
      ring: document.querySelector('[data-testid="context-ring"]') !== null,
      rows: document.querySelectorAll('[data-testid="member-private-row"]').length,
      realContext: document.querySelector('[data-testid="real-context"] pre')?.textContent ?? '',
    }));
    obs('甲一的成员视图', { window: a.window, ring: a.ring, rows: a.rows });
    assert(a.window.includes('1000000'), `甲一的窗口必须是 1000000，实测 ${a.window}`);
    assert(a.ring, '甲一有 breakdown ⇒ 必须渲染占用环');
    assert(a.rows >= 1, '甲一在已加载页里有私有行');
    assert(
      a.realContext.includes('"system"') &&
        a.realContext.includes('"messages"') &&
        a.realContext.includes('"tools"'),
      '成员视图必须直接显示 system/messages/tools 原始 JSON',
    );

    // ③ 乙一：窗口 200000（各自分母）+ 环。
    await clickByTestId(page, 'member-select-mem-ms-b');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="member-window"]')?.textContent?.includes('200000') === true,
      { timeout: 15000 },
    );
    const b = await page.evaluate(() => ({
      window: document.querySelector('[data-testid="member-window"]')?.textContent ?? '',
      ring: document.querySelector('[data-testid="context-ring"]') !== null,
    }));
    obs('乙一的窗口/环', b);
    assert(b.window.includes('200000'), `乙一的窗口必须是 200000，实测 ${b.window}`);
    assert(b.ring, '乙一有 breakdown ⇒ 必须渲染占用环');

    // ④ 丙一：breakdown=null ⇒ 显式说明且不画空环。
    await clickByTestId(page, 'member-select-mem-ms-c');
    await page.waitForSelector('[data-testid="member-no-breakdown"]', { timeout: 15000 });
    const c = await page.evaluate(() => ({
      noBreakdown: document.querySelector('[data-testid="member-no-breakdown"]') !== null,
      ring: document.querySelector('[data-testid="context-ring"]') !== null,
    }));
    obs('丙一（breakdown:null）', c);
    assert(c.noBreakdown, 'breakdown:null 必须显示 member-no-breakdown');
    assert(!c.ring, 'breakdown:null 不得渲染占用环（不静默当成 0）');

    // ⑤ 丁一：真没发过言 ⇒ empty 占位。
    await clickByTestId(page, 'member-select-mem-ms-d');
    await page.waitForSelector('[data-testid="member-no-snapshot"]', { timeout: 15000 });
    obs('丁一显示没发过言占位', true);

    // ⑥ 戊一：group.view 失败 ⇒ error + 重试，绝不显示「没发过言」。
    await clickByTestId(page, 'member-select-mem-ms-e');
    await page.waitForSelector('[data-testid="member-snapshot-error"]', { timeout: 15000 });
    const e = await page.evaluate(() => ({
      error: document.querySelector('[data-testid="member-snapshot-error"]')?.textContent ?? '',
      retry: document.querySelector('[data-testid="member-snapshot-retry"]') !== null,
      noSnapshot: document.querySelector('[data-testid="member-no-snapshot"]') !== null,
    }));
    obs('戊一（group.view 失败）', e);
    assert(e.error.includes('group.view 失败'), `错误必须可归因，实测「${e.error}」`);
    assert(e.retry, '快照失败必须提供重试按钮');
    assert(!e.noSnapshot, '读取失败不得伪装成「没发过言」');

    // ⑦ 庚一（软删）：选中后保持；私有行只在更早页 ⇒ 空态 + 取回入口。
    await clickByTestId(page, 'member-select-mem-ms-g');
    await page.waitForSelector('[data-testid="member-private-empty"]', { timeout: 15000 });
    const g = await page.evaluate(() => ({
      pressed: document
        .querySelector('[data-testid="member-select-mem-ms-g"]')
        ?.getAttribute('aria-pressed'),
      empty: document.querySelector('[data-testid="member-private-empty"]')?.textContent ?? '',
      loadEarlier: document.querySelector('[data-testid="member-load-earlier"]') !== null,
    }));
    obs('庚一（已移除、私有行在更早页）', g);
    assert(g.pressed === 'true', '软删成员被选中后必须保持选中');
    assert(g.empty.includes('本次已加载页里'), '空态必须写明范围「本次已加载页里」');
    assert(g.loadEarlier, '空态必须提供 member-load-earlier 取回入口');

    // 切回群聊再切回来：软删成员的选中不丢。
    await clickByTestId(page, 'group-tab-chat');
    await clickByTestId(page, 'group-tab-members');
    const stillSelected = await page.$eval(
      '[data-testid="member-select-mem-ms-g"]',
      (element) => element.getAttribute('aria-pressed'),
    );
    obs('切标签后庚一仍选中', stillSelected);
    assert(stillSelected === 'true', '切换标签不得重置软删成员的选择');

    // 未知作者私有行：只读横幅，不静默丢行。
    const unknown = await page.$eval(
      '[data-testid="member-unknown-authors"]',
      (element) => element.textContent ?? '',
    );
    obs('未知作者横幅', unknown);
    assert(unknown.includes('ghost-9') || unknown.includes('幽灵'), '未知作者横幅必须列出该行');

    // 点「加载更早的消息」：丁/庚的历史私有行出现。
    await clickByTestId(page, 'member-load-earlier');
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="member-private-row"]').length > 0,
      { timeout: 15000 },
    );
    const rowsAfter = await page.$$eval(
      '[data-testid="member-private-row"]',
      (nodes) => nodes.length,
    );
    obs('加载更早页后庚一的私有行数', rowsAfter);
    assert(rowsAfter >= 1, '加载更早页后私有行必须出现');

    // ⑧ 重试：清掉注入的失败后点重试，戊一的快照恢复（不重载整条时间线）。
    await setGroupFlags('reset=1');
    await clickByTestId(page, 'member-select-mem-ms-e');
    await page.waitForSelector('[data-testid="member-snapshot-retry"]', { timeout: 15000 });
    await clickByTestId(page, 'member-snapshot-retry');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="context-ring"]') !== null &&
        document.querySelector('[data-testid="member-snapshot-error"]') === null,
      { timeout: 15000 },
    );
    obs('重试后戊一恢复占用环', true);
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
    await fetch(`${staticServer.url}__delete_session?id=${seeded.id}`).catch(() => {});
  }
});

await run('2.4 窄屏抽屉、头部流式成员名与 aria', async () => {
  await seedReactionGroup('抽屉组');
  await ensureSingleFirst();
  const page = await openPage(720, 900);
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '抽屉组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const closed = await page.evaluate(() => ({
      toggle: document.querySelector('[data-testid="group-members-toggle"]') !== null,
      membersWidth:
        document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ?? 0,
      listWidth:
        document.querySelector('[data-testid="session-list"]')?.getBoundingClientRect().width ?? 0,
      overflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
      mainCount: document.querySelectorAll('main').length,
    }));
    obs('720px 抽屉关闭时', closed);
    assert(closed.toggle, '窄屏必须出现「成员」按钮');
    assert(closed.membersWidth === 0, '抽屉关闭时成员名单不可见');
    assert(closed.listWidth > 0, '窄屏下会话列表仍必须可见');
    assert(closed.overflow, '720px 不得横向溢出');

    // 链运行时头部显示正在流式的成员名（抽屉关着也能看到「谁在反应」）。
    await fetch(`${staticServer.url}__gate_member_stream`);
    await page.type('[data-testid="group-input"]', '抽屉用例');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="reaction-active"]')?.textContent?.includes('甲') ===
        true,
      { timeout: 15000 },
    );
    const activeText = await page.$eval(
      '[data-testid="reaction-active"]',
      (element) => element.textContent ?? '',
    );
    obs('头部反应指示文案', activeText);
    assert(activeText.includes('甲'), '头部反应指示必须含正在流式的成员名「甲」');

    // 先打开抽屉再量成员控件（隐藏元素高度为 0，量它会假红）。
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 15000 },
    );
    const opened = await page.evaluate(() => {
      const members = document.querySelector('[data-testid="group-members"]');
      const toggle = document.querySelector('[data-testid="group-members-toggle"]');
      const add = document.querySelector('[data-testid="member-add"]');
      return {
        id: members?.id ?? null,
        expanded: toggle?.getAttribute('aria-expanded') ?? null,
        controls: toggle?.getAttribute('aria-controls') ?? null,
        memberAddHeight: add?.getBoundingClientRect().height ?? 0,
        membersWidth: members?.getBoundingClientRect().width ?? 0,
        listWidth:
          document.querySelector('[data-testid="session-list"]')?.getBoundingClientRect().width ?? 0,
        overflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
      };
    });
    obs('720px 打开抽屉后', opened);
    assert(opened.id === 'group-members', '成员名单必须有 id="group-members"');
    assert(opened.expanded === 'true', 'toggle 必须 aria-expanded="true"');
    assert(opened.controls === 'group-members', 'toggle 必须 aria-controls="group-members"');
    assert(opened.memberAddHeight >= 24, `member-add 高度必须 ≥24px，实测 ${opened.memberAddHeight}`);
    assert(Math.abs(opened.membersWidth - 288) <= 0.5, `抽屉宽度必须是 288px，实测 ${opened.membersWidth}`);
    assert(opened.listWidth > 0, '抽屉不得盖住会话列表');
    assert(opened.overflow, '打开抽屉后仍不得横向溢出');

    await clickByTestId(page, 'group-members-close');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) === 0,
      { timeout: 15000 },
    );
    obs('关闭抽屉后成员名单隐藏', true);
  } finally {
    await fetch(`${staticServer.url}__release_send`).catch(() => {});
    await page.close();
  }

  // 1280px：成员名单是静态右列，toggle 隐藏。
  const wide = await openPage(1280, 900);
  try {
    await wide.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(wide, '抽屉组');
    await wide.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const state = await wide.evaluate(() => ({
      membersWidth:
        document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ?? 0,
      toggleWidth:
        document.querySelector('[data-testid="group-members-toggle"]')?.getBoundingClientRect()
          .width ?? 0,
      memberAddHeight:
        document.querySelector('[data-testid="member-add"]')?.getBoundingClientRect().height ?? 0,
      overflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
    }));
    obs('1280px 成员名单', state);
    assert(state.membersWidth > 0, '1280px 成员名单必须静态可见');
    assert(state.toggleWidth === 0, '1280px 「成员」按钮必须隐藏');
    assert(state.memberAddHeight >= 24, '1280px 的 member-add 也必须 ≥24px');
    assert(state.overflow, '1280px 不得横向溢出');
  } finally {
    await wide.close();
  }
});

await run('2.5 反应进行中的成员指示 + 成员视图未读提示（round_cap / forced_pass）', async () => {
  await seedReactionGroup('未读点组');
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, '未读点组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });

    // ① 链运行中成员卡片显示「正在反应…」（不是只有头部）。
    await fetch(`${staticServer.url}__gate_member_stream`);
    await page.type('[data-testid="group-input"]', '#forced-pass 我想听评价');
    await clickByTestId(page, 'group-send');
    await page.waitForSelector('[data-testid^="member-streaming-"]', { timeout: 15000 });
    const streamingText = await page.$eval(
      '[data-testid^="member-streaming-"]',
      (element) => element.textContent ?? '',
    );
    obs('成员卡片流式指示', streamingText);
    assert(streamingText.includes('正在反应'), '成员卡片必须显示「正在反应…」');

    // ② 链结束前切到成员视图：提示产生时不在群聊标签 ⇒ 未读点。
    await clickByTestId(page, 'group-tab-members');
    await fetch(`${staticServer.url}__release_send`);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 20000 },
    );
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-tab-chat"]')?.getAttribute('data-unread') ===
        'true',
      { timeout: 20000 },
    );
    const unread = await page.evaluate(() => ({
      flag: document.querySelector('[data-testid="group-tab-chat"]')?.getAttribute('data-unread'),
      dot: document.querySelector('[data-testid="group-tab-unread"]') !== null,
    }));
    obs('forced_pass 后的未读标记', unread);
    assert(unread.flag === 'true', '成员视图激活时链终态提示必须置 data-unread="true"');
    assert(unread.dot, '未读必须有可见小点（group-tab-unread）');

    await clickByTestId(page, 'group-tab-chat');
    await page.waitForSelector('[data-testid="forced-notice"]', { timeout: 15000 });
    const cleared = await page.evaluate(() => ({
      flag: document.querySelector('[data-testid="group-tab-chat"]')?.getAttribute('data-unread'),
      dot: document.querySelector('[data-testid="group-tab-unread"]') !== null,
    }));
    obs('切回群聊后的未读标记', cleared);
    assert(cleared.flag !== 'true' && !cleared.dot, '切回群聊后未读必须清除');

    // ③ round_cap 同样要有未读点：用链启动闸门先切到成员视图再放行整条链。
    const updatesBefore = rpcLog.filter((entry) => entry.method === 'group.update').length;
    await setRoundCap(page, '1');
    await waitForRpcCount('group.update', updatesBefore + 1);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-round-cap"]')?.value === '1',
      { timeout: 15000 },
    );
    await fetch(`${staticServer.url}__gate_chain_start`);
    await page.type('[data-testid="group-input"]', '只跑一轮');
    await clickByTestId(page, 'group-send');
    await clickByTestId(page, 'group-tab-members');
    await fetch(`${staticServer.url}__release_send`);
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-tab-chat"]')?.getAttribute('data-unread') ===
        'true',
      { timeout: 20000 },
    );
    obs('round_cap 后的未读标记', true);
    await clickByTestId(page, 'group-tab-chat');
    await page.waitForSelector('[data-testid="round-cap-notice"]', { timeout: 15000 });
    const afterRoundCap = await page.evaluate(() => ({
      notice: document.querySelector('[data-testid="round-cap-notice"]')?.textContent ?? '',
      flag: document.querySelector('[data-testid="group-tab-chat"]')?.getAttribute('data-unread'),
      dot: document.querySelector('[data-testid="group-tab-unread"]') !== null,
    }));
    obs('切回群聊后的 round_cap 提示', afterRoundCap);
    assert(afterRoundCap.notice.includes('已达轮数上限'), '切回群聊必须看到 round_cap 提示');
    assert(afterRoundCap.flag !== 'true' && !afterRoundCap.dot, '切回群聊后未读必须清除');
  } finally {
    await fetch(`${staticServer.url}__release_send`).catch(() => {});
    await page.close();
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
    const errBanner = await page.$('[data-testid="group-view-error"]');
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

await run('R.15 失败链显示真因：group-chain-error 可见含文本、不复用其它错误、下次发送清除', async () => {
  const seeded = await seedReactionGroup('反应组失败归因');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组失败归因');
    const reason = 'provider boom（e2e 注入）';
    await fetch(
      `${staticServer.url}__fail_chain?groupId=${encodeURIComponent(seeded.id)}&error=${encodeURIComponent(reason)}`,
    );
    await page.waitForSelector('[data-testid="group-chain-error"]', { timeout: 15000 });
    const shown = await page.$eval(
      '[data-testid="group-chain-error"]',
      (element) => element.textContent ?? '',
    );
    obs('group-chain-error 文案', shown);
    assert(shown.includes(reason), `失败提示必须含真因，实测 ${shown}`);
    const chainResponse = responseLog
      .filter((entry) => entry.method === 'group.chain' && entry.result?.groupId === seeded.id)
      .at(-1);
    obs('失败链 group.chain 回包', chainResponse?.result);
    assert(chainResponse?.result?.status === 'failed', 'group.chain 必须回 failed');
    assert(
      String(chainResponse?.result?.error ?? '').includes(reason),
      `group.chain.error 必须含真因，实测 ${JSON.stringify(chainResponse?.result?.error)}`,
    );
    // 独立 testid：不得复用加载/视图错误横幅。
    assert(
      (await page.$('[data-testid="group-view-error"]')) === null,
      '链失败不得复用 group-view-error',
    );
    assert(
      (await page.$('[data-testid="group-loading-error"]')) === null,
      '链失败不得复用 group-loading-error',
    );
    // 一过性：下次发送即清（不常驻）。
    await page.type('[data-testid="group-input"]', '失败之后重新发一条');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-chain-error"]') === null,
      { timeout: 15000 },
    );
    obs('下次发送后 group-chain-error', await page.$('[data-testid="group-chain-error"]'));
  } finally {
    await page.close();
  }
});

await run('R.15 completed / cancelled 链不显示 group-chain-error（回归）', async () => {
  const seeded = await seedReactionGroup('反应组非失败链');
  const page = await openPage();
  try {
    await openExistingGroup(page, '反应组非失败链');
    const chainOfGroup = () =>
      responseLog
        .filter((entry) => entry.method === 'group.chain' && entry.result?.groupId === seeded.id)
        .at(-1)?.result;

    await page.type('[data-testid="group-input"]', '先跑一条成功的链');
    await clickByTestId(page, 'group-send');
    await waitFor(() => chainOfGroup()?.status === 'completed', 'completed 链的 group.chain 回包');
    obs('completed 链回包', chainOfGroup());
    assert(chainOfGroup()?.error === null, 'completed 链的 error 必须为 null');
    assert(
      (await page.$('[data-testid="group-chain-error"]')) === null,
      'completed 链不得显示 group-chain-error',
    );

    await fetch(`${staticServer.url}__gate_next_send`);
    await page.type('[data-testid="group-input"]', '这条会被取消');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[data-testid="timeline-item"]')].some((node) =>
          node.textContent?.includes('甲的公开结论'),
        ),
      { timeout: 15000 },
    );
    await clickByTestId(page, 'group-cancel');
    await waitFor(() => chainOfGroup()?.status === 'cancelled', 'cancelled 链的 group.chain 回包');
    obs('cancelled 链回包', chainOfGroup());
    assert(chainOfGroup()?.error === null, 'cancelled 链的 error 必须为 null');
    assert(
      (await page.$('[data-testid="group-chain-error"]')) === null,
      'cancelled 链不得显示 group-chain-error',
    );
    await fetch(`${staticServer.url}__release_send`).catch(() => {});
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
  // 上一次保存的重拉期间输入框是 disabled：等它恢复可编辑再点（否则点到 disabled
  // 元素不会聚焦，随后的 blur 也不会触发 onBlur，保存被静默跳过）。
  await page.waitForFunction(
    () => {
      const input = document.querySelector('[data-testid="group-round-cap"]');
      return input !== null && input.disabled === false;
    },
    { timeout: 15000 },
  );
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
    const completedBefore = eventLog.filter(
      (event) => event.type === 'group.chain.completed',
    ).length;
    await fetch(`${staticServer.url}__release_send`);
    // 两条请求各一条链（两条 `group.chain.completed`）：等**事件**到齐再断言终态。
    // change `group-chat-layout` 的代次守卫会把两次几乎同时发生的重拉合并成一次
    // （只提交最后一次，这是刻意的），所以这里不要求两次 `group.chain` RPC。
    const completedDeadline = Date.now() + 20000;
    while (
      eventLog.filter((event) => event.type === 'group.chain.completed').length <
      completedBefore + 2
    ) {
      if (Date.now() > completedDeadline) {
        throw new Error('两条链的终态事件未在 20s 内到齐');
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    await waitForRpcCount('group.chain', chainBefore + 1);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 20000 },
    );
    // 等最后一次 `group.chain` 回包（代次合并后的最终状态）落地。
    let chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    const finalDeadline = Date.now() + 5000;
    while (chainResponse?.result?.status !== 'completed') {
      if (Date.now() > finalDeadline) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
      chainResponse = responseLog.filter((entry) => entry.method === 'group.chain').at(-1);
    }
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

// GROUP_SHOT=<path>：测试跑完后把真实组视图（群聊标签）截一张图（视觉验收用）。
if (process.env.GROUP_SHOT) {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await new Promise((done) => setTimeout(done, 600));
    const target = process.env.GROUP_SHOT;
    await page.screenshot({ path: target, fullPage: false });
    console.log(`[SHOT] captured ${target}`);
  } finally {
    await page.close();
  }
}

// GROUP_SHOT_MEMBERS=<path>：切到「成员视图」并选中一个成员后截图
// （核对选择器、私有行、真实上下文、占用环；change `group-chat-layout` 4.2）。
if (process.env.GROUP_SHOT_MEMBERS) {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('新组'))?.click();
    });
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await clickByTestId(page, 'group-tab-members');
    await page.waitForSelector('[data-testid^="member-select-"]', { timeout: 15000 });
    await page.evaluate(() => {
      document.querySelector('[data-testid^="member-select-"]')?.click();
    });
    await page.waitForSelector('[data-testid="member-context-section"]', { timeout: 15000 });
    await new Promise((done) => setTimeout(done, 600));
    const target = process.env.GROUP_SHOT_MEMBERS;
    await page.screenshot({ path: target, fullPage: false });
    console.log(`[SHOT] captured ${target}`);
  } finally {
    await page.close();
  }
}

// 1.4（续）空聊天屏：删到最后一条会话后主区必须清空（change `group-chat-layout` 1.4）。
await run('1.4b 删除最后一条会话后主区是空聊天屏（标题 / 输入禁用 / 无残留）', async () => {
  await ensureSingleFirst();
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    for (let guard = 0; guard < 50; guard += 1) {
      const remaining = sessions.length;
      if (remaining === 0) break;
      await page.evaluate(() => {
        const list = document.querySelector('[data-testid="session-list"]');
        if (list) list.scrollTop = 0;
      });
      await deleteFirstSessionRow(page);
      const deadline = Date.now() + 15000;
      while (sessions.length >= remaining) {
        if (Date.now() > deadline) {
          throw new Error(`删除后服务端会话数仍是 ${sessions.length}（删除前 ${remaining}）`);
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }
    obs('删除全部会话后的剩余会话数', sessions.length);
    assert(sessions.length === 0, `应删到 0 条会话，实测 ${sessions.length}`);
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('（未选择会话）') === true,
      { timeout: 15000 },
    );
    const emptyState = await page.evaluate(() => {
      const composer = document.querySelector('[data-testid="composer"]');
      return {
        title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
        composerDisabled: composer === null ? null : composer.disabled === true,
        messageRows: document.querySelectorAll('[data-testid="message-row"]').length,
        timelineItems: document.querySelectorAll('[data-testid="timeline-item"]').length,
        snapshot: document.querySelector('[data-testid="context-snapshot"]') !== null,
        groupView: document.querySelector('[data-testid="group-view"]') !== null,
        listHint: document.querySelector('[data-testid="session-list"]')?.textContent ?? '',
      };
    });
    obs('空聊天屏', emptyState);
    assert(emptyState.title.includes('（未选择会话）'), '空聊天屏标题必须是「（未选择会话）」');
    assert(emptyState.composerDisabled === true, '空聊天屏的输入必须禁用');
    assert(emptyState.messageRows === 0, '空聊天屏不得残留消息行');
    assert(emptyState.timelineItems === 0, '空聊天屏不得残留群时间线');
    assert(!emptyState.snapshot, '空聊天屏不得残留上一条会话的快照');
    assert(!emptyState.groupView, '删到最后一条不得继续显示群视图');
    assert(emptyState.listHint.includes('没有会话'), '会话列表必须显示空态提示');
  } finally {
    await page.close();
  }
  // GROUP_DEFAULT 审计种子：删空后重建一个组并排到首位，保证
  // `GROUP_KEEP=1` 之后的 design_audit 仍直接落在群聊主区。
  if (process.env.GROUP_DEFAULT === '1') {
    const seeded = await seedReactionGroup('审计组');
    auditGroupId = seeded.id;
  }
});

// ---------------------------------------------------------------------------
// R 节：返工红靶（change `group-chat-layout` R.1~R.13）
// （1.4b 把会话删到 0，R 段每条用例用 resetToBaseSingle 自造隔离夹具）
// ---------------------------------------------------------------------------

await run('R.1 单聊加载错误出口与操作错误分离（加载失败横幅 / 守卫 / pageerror）', async () => {
  await resetToBaseSingle('R1 基础单聊');
  const victim = await seedSingle('R1 加载失败单聊');
  const other = await seedSingle('R1 另一条单聊');
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.waitForFunction(
      () => document.querySelector('[data-testid="message-list"]') !== null,
      { timeout: 15000 },
    );

    // ① message.query 失败：错误横幅可归因、主区不是无横幅空白、无 unhandled。
    await setGroupFlags('messageQueryFailKind=single');
    await clickSessionRow(page, 'R1 加载失败单聊');
    await page.waitForSelector('[data-testid="error-banner"]', { timeout: 15000 });
    const loadFail = await page.evaluate(() => ({
      error: document.querySelector('[data-testid="error-banner"]')?.textContent ?? '',
      title:
        document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      messageList: document.querySelector('[data-testid="message-list"]') !== null,
    }));
    obs('单聊加载失败的主区', loadFail);
    assert(
      loadFail.error.includes('加载会话失败'),
      `加载失败必须显示「加载会话失败：…」，实测「${loadFail.error}」`,
    );
    assert(
      loadFail.title.includes('R1 加载失败单聊'),
      `加载失败时主区标题必须仍是被点的会话（不是空白），实测「${loadFail.title}」`,
    );
    assert(loadFail.messageList, '加载失败时主区必须仍是聊天屏（有横幅，不是空白主区）');
    assertNoPageErrors([page]);
    // pageerror 收集器探针：未处理的 Promise 拒绝必须被收集（否则统一断言是空的）。
    const before = pageErrorsOf(page).length;
    await page.evaluate(() => {
      void Promise.reject(new Error('pageerror 探针（R.1）'));
    });
    await waitFor(
      () => pageErrorsOf(page).length > before,
      'pageerror 收集器没有收到 Promise.reject 探针',
    );
    obs('pageerror 探针', pageErrorsOf(page).slice(before));
    pageErrorsOf(page).length = 0;

    // ② session.create 成功但随后加载失败：错误必须是「加载会话失败」，不是「新建会话失败」。
    await setGroupFlags('reset=1&messageQueryFailKind=single');
    await clickByTestId(page, 'session-create');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('新会话') === true &&
        document
          .querySelector('[data-testid="error-banner"]')
          ?.textContent?.includes('加载会话失败') === true,
      { timeout: 15000 },
    );
    const createFailError =
      (await page.$eval('[data-testid="error-banner"]', (element) => element.textContent ?? '')) ??
      '';
    obs('新建成功后加载失败的错误文案', createFailError);
    assert(
      !createFailError.includes('新建会话失败'),
      `新建 RPC 成功、加载失败时不得误报「新建会话失败」，实测「${createFailError}」`,
    );

    // ③ session.delete 成功但随后加载失败：不得误报「删除会话失败」。
    await setGroupFlags('reset=1');
    // 当前会话是刚新建的那条；删除后下一条是 base 单聊 ⇒ 让 base 的加载失败。
    const baseId = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      const row = rows.find((entry) => entry.textContent?.includes('R1 基础单聊'));
      return row?.getAttribute('data-session-id') ?? null;
    });
    assert(baseId, '会话列表里必须能读到基础单聊的 session id');
    await setGroupFlags(`messageQueryFailFor=${baseId}`);
    await deleteFirstSessionRow(page);
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('R1 基础单聊') === true &&
        document
          .querySelector('[data-testid="error-banner"]')
          ?.textContent?.includes('加载会话失败') === true,
      { timeout: 15000 },
    );
    const deleteFailError =
      (await page.$eval('[data-testid="error-banner"]', (element) => element.textContent ?? '')) ??
      '';
    obs('删除成功后加载失败的错误文案', deleteFailError);
    assert(
      !deleteFailError.includes('删除会话失败'),
      `删除 RPC 成功、加载失败时不得误报「删除会话失败」，实测「${deleteFailError}」`,
    );

    // ④ reloadSessions 的 session.list 失败：单独显示「列表刷新失败」，不混成新建/删除失败。
    await setGroupFlags('reset=1&sessionListFail=1');
    await clickByTestId(page, 'session-create');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="error-banner"]')
          ?.textContent?.includes('列表刷新失败') === true,
      { timeout: 15000 },
    );
    const listFailError =
      (await page.$eval('[data-testid="error-banner"]', (element) => element.textContent ?? '')) ??
      '';
    obs('列表刷新失败的错误文案', listFailError);
    assert(
      !listFailError.includes('新建会话失败') && !listFailError.includes('删除会话失败'),
      `session.list 失败必须单独报「列表刷新失败」，实测「${listFailError}」`,
    );

    // ⑤ 加载延迟 + 失败 + 立刻切走：catch 的 session 守卫不得把错误挂到新会话。
    await setGroupFlags(
      `reset=1&messageQueryFailFor=${victim.id}` +
        `&messageQueryDelayGroupId=${victim.id}&messageQueryDelayMs=700`,
    );
    await clickSessionRow(page, 'R1 加载失败单聊');
    // 同一个 event loop 里切走：700ms 后那条失败才回来。
    await clickSessionRow(page, 'R1 另一条单聊');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('R1 另一条单聊') === true,
      { timeout: 15000 },
    );
    await new Promise((resolve) => setTimeout(resolve, 900));
    const afterSwitch = await page.evaluate(() => ({
      title:
        document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      error: document.querySelector('[data-testid="error-banner"]')?.textContent ?? null,
    }));
    obs('延迟失败后已切走的主区', afterSwitch);
    assert(
      afterSwitch.title.includes('R1 另一条单聊'),
      `切走后主区必须仍是新会话，实测「${afterSwitch.title}」`,
    );
    assert(
      afterSwitch.error === null || !afterSwitch.error.includes('加载会话失败'),
      `旧会话的加载失败不得挂到新会话，实测「${afterSwitch.error}」`,
    );
    assertNoPageErrors([page]);
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
    await fetch(`${staticServer.url}__delete_session?id=${other.id}`).catch(() => {});
  }
});

await run('R.2 群加载入口先判归属再自增代次（旧群续体 / 重连旧 session 都不顶掉新群）', async () => {
  await resetToBaseSingle('R2 基础单聊');
  await seedDistinctGroup('R2 慢群A', '阿慢A', 'R2 A组唯一消息');
  await seedDistinctGroup('R2 快群B', '阿快B', 'R2 B组唯一消息');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R2 慢群A');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('R2 慢群A') === true,
      { timeout: 15000 },
    );

    // ① 旧群 `onReload` 续体：`group.update` 回包延迟卡住 A 的续体，
    //    同一 event loop 里先点 A 的开关、再点 B 行。
    await setGroupFlags('reset=1&groupUpdateDelayMs=400&groupListDelayMs=900');
    const mark = rpcLog.length;
    await page.evaluate(() => {
      const toggle = document.querySelector('[data-testid="reactions-toggle"]');
      toggle?.click();
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes('R2 快群B'))?.click();
    });
    await waitFor(
      () => rpcLog.slice(mark).some((entry) => entry.method === 'group.update'),
      '点 A 的 reactions-toggle 必须发出 group.update',
    );
    const entries = rpcLog.slice(mark);
    const updateIdx = entries.findIndex((entry) => entry.method === 'group.update');
    const updateReq = entries[updateIdx];
    const bLoad = entries.slice(updateIdx + 1).find((entry) => entry.method === 'group.list');
    obs('R.2 触发顺序', {
      groupUpdateRequestAt: updateReq.at,
      switchToBLoadAt: bLoad?.at ?? null,
    });
    assert(bLoad, '切到 B 后必须发出 group.list（B 的加载请求）');
    await waitFor(
      () =>
        responseLog.some(
          (entry) => entry.method === 'group.update' && entry.at >= bLoad.at,
        ),
      'group.update 的回包必须晚于切到 B 的加载请求（否则没制造出续体竞态）',
    );
    const updateResp = responseLog
      .filter((entry) => entry.method === 'group.update')
      .at(-1);
    obs('R.2 续体恢复点', {
      groupUpdateResponseAt: updateResp.at,
      deltaAfterSwitchMs: updateResp.at - bLoad.at,
    });
    // A 的续体会在回包后立刻重发 group.list（延迟 900ms）——B 不得被它顶死。
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('R2 快群B') === true,
      { timeout: 15000 },
    );
    // 等过 A 续体的 group.list 延迟（900ms）+ 余量，再确认 B 没被顶回占位。
    await new Promise((resolve) => setTimeout(resolve, 1300));
    const afterContinuation = await page.evaluate(() => ({
      title:
        document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      loading: document.querySelector('[data-testid="group-loading"]') !== null,
      members: [...document.querySelectorAll('[data-testid^="member-name-"]')]
        .map((node) => node.textContent ?? '')
        .join('|'),
      timeline: document.querySelector('[data-testid="group-timeline"]')?.textContent ?? '',
      error: document.querySelector('[data-testid="group-view-error"]')?.textContent ?? null,
    }));
    obs('旧群续体恢复后 B 的状态', afterContinuation);
    assert(
      afterContinuation.title.includes('R2 快群B'),
      `旧群续体不得把 B 顶掉，实测标题「${afterContinuation.title}」`,
    );
    assert(!afterContinuation.loading, 'B 不得永久停在 group-loading');
    assert(
      afterContinuation.members.includes('阿快B') && !afterContinuation.members.includes('阿慢A'),
      `B 的成员表必须唯一属于 B，实测 ${afterContinuation.members}`,
    );
    assert(
      afterContinuation.timeline.includes('R2 B组唯一消息'),
      'B 的时间线必须加载出自己的消息',
    );
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
  }

  // ② `refreshAfterReconnect` 用旧 sessionId 发起的加载不得顶掉新群：
  //    重连后 session.list 延迟期间切走，旧 session 的 loadGroup 续体不敌新群。
  await setGroupFlags('reset=1');
  await seedDistinctGroup('R2 重连群A', '阿重A', 'R2 重连A消息');
  await seedDistinctGroup('R2 重连群B', '阿重B', 'R2 重连B消息');
  const reconnectPage = await openPage();
  try {
    await reconnectPage.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(reconnectPage, 'R2 重连群A');
    await reconnectPage.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('R2 重连群A') === true,
      { timeout: 15000 },
    );
    await setGroupFlags('sessionListDelayMs=1500&groupListDelayMs=2500');
    const mark = rpcLog.length;
    await fetch(`${staticServer.url}__drop_sockets`);
    // 连接断开后客户端自动重连（组视图里没有连接徽标，用 refreshAfterReconnect
    // 发出的 session.list 作为「已重连并进入刷新」的证据）。
    await waitFor(
      () => rpcLog.slice(mark).some((entry) => entry.method === 'session.list'),
      '重连后必须发出 session.list（refreshAfterReconnect）',
      20000,
    );
    // 在刷新还没回来时切走：此时旧 sessionId 的 loadGroup 续体还在路上。
    await clickSessionRow(reconnectPage, 'R2 重连群B');
    await waitFor(
      () => {
        const entries = rpcLog.slice(mark);
        const idx = entries.findIndex((entry) => entry.method === 'session.list');
        return idx >= 0 && entries.slice(idx + 1).some((entry) => entry.method === 'group.list');
      },
      '切到 B 后必须发出 B 的 group.list',
      5000,
    );
    const entriesNow = rpcLog.slice(mark);
    const refreshIdxNow = entriesNow.findIndex((entry) => entry.method === 'session.list');
    const refreshList = entriesNow[refreshIdxNow];
    const bLoad = entriesNow
      .slice(refreshIdxNow + 1)
      .find((entry) => entry.method === 'group.list');
    obs(
      '点击 B 后的请求序列（相对 refresh 的 session.list）',
      entriesNow.map((entry) => `${entry.method}@+${entry.at - refreshList.at}ms`),
    );
    obs('R.2 重连触发顺序', {
      refreshSessionListAt: refreshList.at,
      switchToBLoadAt: bLoad?.at ?? null,
      deltaBeforeRefreshReturnsMs: bLoad ? refreshList.at + 1500 - bLoad.at : null,
    });
    assert(bLoad, '切到 B 后必须发出 B 的 group.list');
    assert(
      bLoad.at < refreshList.at + 1500,
      'B 的加载必须发生在 refreshAfterReconnect 的 session.list 返回之前（否则竞态没成立）',
    );
    await reconnectPage.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-view"] h1')
          ?.textContent?.includes('R2 重连群B') === true,
      { timeout: 20000 },
    );
    await reconnectPage.waitForFunction(
      () => document.querySelector('[data-testid="group-loading"]') === null,
      { timeout: 15000 },
    );
    const afterRefresh = await reconnectPage.evaluate(() => ({
      title:
        document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      members: [...document.querySelectorAll('[data-testid^="member-name-"]')]
        .map((node) => node.textContent ?? '')
        .join('|'),
      timeline: document.querySelector('[data-testid="group-timeline"]')?.textContent ?? '',
    }));
    obs('旧 session 刷新续体后 B 的状态', afterRefresh);
    assert(
      afterRefresh.title.includes('R2 重连群B') &&
        afterRefresh.members.includes('阿重B') &&
        !afterRefresh.members.includes('阿重A') &&
        afterRefresh.timeline.includes('R2 重连B消息'),
      `旧 session 的刷新续体不得顶掉新群，实测 ${JSON.stringify(afterRefresh)}`,
    );
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await reconnectPage.close();
  }
});

await run('R.3 抽屉背景不盖头部：720px 真实点击头部标签（命中判据）', async () => {
  await resetToBaseSingle('R3 基础单聊');
  await seedReactionGroup('R3 抽屉组');
  const page = await openPage(720, 900);
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    // 先开抽屉（真实点击，不绕过命中层）。
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 15000 },
    );
    const opened = await page.evaluate(() => ({
      backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
      expanded:
        document.querySelector('[data-testid="group-members-toggle"]')?.getAttribute('aria-expanded') ??
        null,
    }));
    obs('720px 抽屉打开', opened);
    assert(opened.backdrop && opened.expanded === 'true', '抽屉必须真的打开（背景 + aria-expanded）');

    // 真实 page.click：背景若盖住头部，点击会落到背景上，标签不切。
    await page.click('[data-testid="group-tab-members"]');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );
    const afterTabClick = await page.evaluate(() => ({
      tab: document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab'),
      membersWidth:
        document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ?? 0,
      backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
    }));
    obs('点「成员视图」后', afterTabClick);
    assert(afterTabClick.tab === 'members', '真实点击头部标签必须切到成员视图（不能命中背景）');
    assert(afterTabClick.membersWidth === 0, '切到成员视图后抽屉必须关闭');
    assert(!afterTabClick.backdrop, '切到成员视图后抽屉背景必须消失');

    // 再点回「群聊」：抽屉仍保持关闭。
    await page.click('[data-testid="group-tab-chat"]');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 5000 },
    );
    const backToChat = await page.evaluate(() => ({
      membersWidth:
        document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ?? 0,
      backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
    }));
    obs('点回「群聊」后', backToChat);
    assert(
      backToChat.membersWidth === 0 && !backToChat.backdrop,
      '切回群聊后抽屉必须保持关闭（不自行重开）',
    );
  } finally {
    await page.close();
  }
});

await run('R.4 重载失败保留已加载内容（不退 group-loading）+ 首屏失败仍占位', async () => {
  await resetToBaseSingle('R4 基础单聊');
  const stable = await seedDistinctGroup('R4 稳定组', '阿稳', 'R4 已加载消息');
  // 造一个「链在跑」的只读状态（busy=false，chain=running）：重载失败后必须清掉，
  // 否则取消按钮会被旧链误启用、头部一直显示「正在反应」。
  await fetch(`${staticServer.url}__set_chain?groupId=${stable.id}&status=running`);
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R4 稳定组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="group-timeline"]')
          ?.textContent?.includes('R4 已加载消息') === true,
      { timeout: 15000 },
    );
    const before = await page.evaluate(() => ({
      reactionActive: document.querySelector('[data-testid="reaction-active"]') !== null,
      cancelDisabled:
        document.querySelector('[data-testid="group-cancel"]')?.hasAttribute('disabled') ?? null,
      members: [...document.querySelectorAll('[data-testid^="member-name-"]')]
        .map((node) => node.textContent ?? '')
        .join('|'),
    }));
    obs('重载失败前（链在跑）', before);
    assert(before.reactionActive, '前置：group.chain=running 时必须显示链活动指示');
    assert(before.cancelDisabled === false, '前置：链在跑时取消按钮必须可用');

    // onReload（链在跑时由组内消息事件触发）遇到 group.list ok / message.query 失败。
    // 不能点 reactions-toggle：链在跑时设置项被禁用（这是产品既有正确行为）。
    await setGroupFlags(`messageQueryFailFor=${stable.id}`);
    await fetch(
      `${staticServer.url}__emit_group_message?groupId=${stable.id}&content=${encodeURIComponent('R4 事件触发的重载')}`,
    );
    await page.waitForSelector('[data-testid="group-view-error"]', { timeout: 15000 });
    const after = await page.evaluate(() => ({
      groupView: document.querySelector('[data-testid="group-view"]') !== null,
      loading: document.querySelector('[data-testid="group-loading"]') !== null,
      error: document.querySelector('[data-testid="group-view-error"]')?.textContent ?? '',
      timeline: document.querySelector('[data-testid="group-timeline"]')?.textContent ?? '',
      members: [...document.querySelectorAll('[data-testid^="member-name-"]')]
        .map((node) => node.textContent ?? '')
        .join('|'),
      timelineEmpty: document.querySelector('[data-testid="timeline-empty"]') !== null,
      reactionActive: document.querySelector('[data-testid="reaction-active"]') !== null,
      cancelDisabled:
        document.querySelector('[data-testid="group-cancel"]')?.hasAttribute('disabled') ?? null,
    }));
    obs('重载失败后', after);
    assert(after.groupView, '重载失败 MUST NOT 把整页打回 GroupLoading（group-view 必须还在）');
    assert(!after.loading, '重载失败不得退回 group-loading');
    assert(after.error.includes('加载组视图失败'), `错误必须可见且可归因，实测「${after.error}」`);
    assert(after.timeline.includes('R4 已加载消息'), '重载失败必须保留已加载的时间线');
    assert(after.members.includes('阿稳'), '重载失败必须保留已加载的成员名单');
    assert(!after.timelineEmpty, '重载失败不得用 timeline-empty 冒充空时间线');
    assert(!after.reactionActive, '重载失败必须清掉旧链的活动指示');
    assert(after.cancelDisabled === true, '重载失败后旧链不得让取消按钮保持可用');

    // 首屏首次加载失败：仍然显示 group-loading + 可归因错误。
    const failing = await seedDistinctGroup('R4 首屏失败组', '阿败', '不该出现');
    await setGroupFlags(`reset=1&messageQueryFailFor=${failing.id}`);
    // 假核心刚种下的组还不在页面的会话列表状态里：刷新一次让列表重拉。
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R4 首屏失败组');
    await page.waitForSelector('[data-testid="group-loading"]', { timeout: 15000 });
    const firstLoad = await page.evaluate(() => ({
      loading: document.querySelector('[data-testid="group-loading"]') !== null,
      error: document.querySelector('[data-testid="group-loading-error"]')?.textContent ?? '',
      timelineEmpty: document.querySelector('[data-testid="timeline-empty"]') !== null,
      groupView: document.querySelector('[data-testid="group-view"]') !== null,
    }));
    obs('首屏失败时', firstLoad);
    assert(firstLoad.loading, '首屏首次失败必须保留 group-loading 占位');
    assert(firstLoad.error.includes('加载组视图失败'), '首屏失败必须显示可归因错误');
    assert(!firstLoad.timelineEmpty, '首屏失败不得出现空时间线');
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
  }
});

await run('R.5 抽屉跨断点可收 + 可访问性（Escape / role=dialog / aria-modal / 焦点）', async () => {
  await resetToBaseSingle('R5 基础单聊');
  await seedReactionGroup('R5 抽屉组');
  const page = await openPage(720, 900);
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 15000 },
    );
    const opened = await page.evaluate(() => {
      const aside = document.querySelector('[data-testid="group-members"]');
      const backdrop = document.querySelector('[data-testid="group-members-backdrop"]');
      return {
        role: aside?.getAttribute('role') ?? null,
        ariaModal: aside?.getAttribute('aria-modal') ?? null,
        position: aside === null ? null : getComputedStyle(aside).position,
        backdrop: backdrop !== null,
        focusInside: aside !== null && aside.contains(document.activeElement),
      };
    });
    obs('720px 打开抽屉的语义与焦点', opened);
    assert(opened.role === 'dialog', `抽屉必须有 role="dialog"，实测 ${opened.role}`);
    assert(opened.ariaModal === 'true', '抽屉必须有 aria-modal="true"');
    assert(opened.focusInside, '打开抽屉后焦点必须进入抽屉');
    assert(opened.position === 'absolute', '窄屏抽屉必须是 absolute 浮层');

    // Escape 可关，焦点回到触发按钮。
    await page.keyboard.press('Escape');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) === 0,
      { timeout: 5000 },
    );
    const afterEscape = await page.evaluate(() => ({
      backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
      focusTestId: document.activeElement?.getAttribute('data-testid') ?? null,
      expanded:
        document.querySelector('[data-testid="group-members-toggle"]')?.getAttribute('aria-expanded') ??
        null,
    }));
    obs('Escape 后', afterEscape);
    assert(!afterEscape.backdrop, 'Escape 后抽屉背景必须消失');
    assert(
      afterEscape.focusTestId === 'group-members-toggle',
      `Escape 关闭后焦点必须回到「成员」按钮，实测 ${afterEscape.focusTestId}`,
    );
    assert(afterEscape.expanded === 'false', 'Escape 关闭后 aria-expanded 必须是 false');

    // 跨断点：720 打开 → 1280 必须变成静态右列、无 absolute 残留、按钮/背景隐藏。
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 5000 },
    );
    await page.setViewport({ width: 1280, height: 900 });
    await page.waitForFunction(
      () => {
        const aside = document.querySelector('[data-testid="group-members"]');
        if (aside === null) return false;
        return (
          getComputedStyle(aside).position === 'static' &&
          aside.getBoundingClientRect().width > 0 &&
          document.querySelector('[data-testid="group-members-backdrop"]') === null
        );
      },
      { timeout: 5000 },
    );
    const wide = await page.evaluate(() => {
      const aside = document.querySelector('[data-testid="group-members"]');
      const toggle = document.querySelector('[data-testid="group-members-toggle"]');
      const close = document.querySelector('[data-testid="group-members-close"]');
      return {
        position: aside === null ? null : getComputedStyle(aside).position,
        width: aside?.getBoundingClientRect().width ?? 0,
        backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
        toggleVisible: (toggle?.getBoundingClientRect().width ?? 0) > 0,
        closeVisible: (close?.getBoundingClientRect().width ?? 0) > 0,
        overflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
      };
    });
    obs('拉宽到 1280px', wide);
    assert(wide.position === 'static', `1280px 成员名单必须是静态右列，实测 ${wide.position}`);
    assert(wide.width >= 287, `1280px 成员名单必须仍可见（w-72），实测 ${wide.width}`);
    assert(!wide.backdrop && !wide.toggleVisible && !wide.closeVisible, '1280px 不得残留抽屉浮层控件');
    assert(wide.overflow, '1280px 不得横向溢出');

    // 缩回 720：抽屉必须保持关闭（不得自行重开）。
    await page.setViewport({ width: 720, height: 900 });
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) === 0,
      { timeout: 5000 },
    );
    const narrowAgain = await page.evaluate(() => ({
      width:
        document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ?? 0,
      backdrop: document.querySelector('[data-testid="group-members-backdrop"]') !== null,
      expanded:
        document.querySelector('[data-testid="group-members-toggle"]')?.getAttribute('aria-expanded') ??
        null,
    }));
    obs('缩回 720px', narrowAgain);
    assert(narrowAgain.width === 0 && !narrowAgain.backdrop, '缩回窄屏后抽屉必须保持关闭');
    assert(narrowAgain.expanded === 'false', '缩回窄屏后 aria-expanded 必须是 false');
  } finally {
    await page.close();
  }
});

await run('R.6 主地标唯一可见（四态 + Wizard 0）+ 标签 tabpanel a11y', async () => {
  await resetToBaseSingle('R6 基础单聊');
  const okGroup = await seedReactionGroup('R6 正常组');
  const loadFail = await seedDistinctGroup('R6 首屏失败组', '阿败', '不该出现');
  const page = await openPage();
  const readMainLandmark = () =>
    page.evaluate(() => {
      const main = document.querySelector('main');
      const mainArea = document.querySelector('[data-testid="main-area"]');
      const rect = main?.getBoundingClientRect();
      return {
        count: document.querySelectorAll('main').length,
        isMainArea: main !== null && main === mainArea,
        mainAreaExists: mainArea !== null,
        visible:
          rect !== undefined &&
          rect !== null &&
          rect.width > 0 &&
          rect.height > 0 &&
          main !== null &&
          getComputedStyle(main).display !== 'none',
        tag: main?.tagName ?? null,
      };
    });
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    // ① 单聊态
    await clickSessionRow(page, 'R6 基础单聊');
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    const single = await readMainLandmark();
    obs('单聊态的主地标', single);
    assert(
      single.count === 1 && single.isMainArea && single.visible,
      `单聊态必须恰好一个可见 main 且是 main-area，实测 ${JSON.stringify(single)}`,
    );

    // ② 群聊标签
    await clickSessionRow(page, 'R6 正常组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const chatTab = await readMainLandmark();
    obs('群聊标签的主地标', chatTab);
    assert(
      chatTab.count === 1 && chatTab.isMainArea && chatTab.visible,
      `群聊标签态必须恰好一个可见 main 且是 main-area，实测 ${JSON.stringify(chatTab)}`,
    );

    // ③ 成员视图（不能把唯一 main 藏在 hidden 面板里）
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 15000 },
    );
    const membersTab = await readMainLandmark();
    obs('成员视图的主地标', membersTab);
    assert(
      membersTab.count === 1 && membersTab.isMainArea && membersTab.visible,
      `成员视图态必须恰好一个可见 main 且是 main-area，实测 ${JSON.stringify(membersTab)}`,
    );

    // ④ 群加载占位（首屏失败仍显示 group-loading）
    await setGroupFlags(`reset=1&messageQueryFailFor=${loadFail.id}`);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R6 首屏失败组');
    await page.waitForSelector('[data-testid="group-loading"]', { timeout: 15000 });
    const loadingState = await readMainLandmark();
    obs('群加载占位态的主地标', loadingState);
    assert(
      loadingState.count === 1 && loadingState.isMainArea && loadingState.visible,
      `群加载态必须恰好一个可见 main 且是 main-area，实测 ${JSON.stringify(loadingState)}`,
    );

    // ⑤ 标签 a11y：tab 的 aria-controls 指向 role=tabpanel 面板。
    await setGroupFlags('reset=1');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R6 正常组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const tabA11y = await page.evaluate(() =>
      [...document.querySelectorAll('[role="tab"]')].map((tab) => {
        const controls = tab.getAttribute('aria-controls');
        const panel = controls === null ? null : document.getElementById(controls);
        return {
          testId: tab.getAttribute('data-testid'),
          id: tab.id,
          controls,
          panelRole: panel?.getAttribute('role') ?? null,
          panelLabelledBy: panel?.getAttribute('aria-labelledby') ?? null,
          selected: tab.getAttribute('aria-selected'),
        };
      }),
    );
    obs('标签 a11y', tabA11y);
    assert(tabA11y.length === 2, `必须有两个 role=tab 的标签，实测 ${tabA11y.length}`);
    for (const tab of tabA11y) {
      assert(tab.controls !== null, `${tab.testId} 必须有 aria-controls`);
      assert(tab.panelRole === 'tabpanel', `${tab.controls} 必须有 role="tabpanel"`);
      assert(
        tab.panelLabelledBy === tab.id && tab.id.length > 0,
        `${tab.controls} 的 aria-labelledby 必须指回 ${tab.testId}`,
      );
    }

    // ⑥ Wizard 态：壳外渲染，main 数量为 0（D1 只承诺四态，这里证明 Wizard 不在承诺外）。
    await setGroupFlags('reset=1&configMissing=1');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="wizard"]', { timeout: 15000 });
    await page.waitForFunction(
      () => document.querySelector('[data-testid="main-area"]') === null,
      { timeout: 10000 },
    );
    const wizard = await page.evaluate(() => ({
      count: document.querySelectorAll('main').length,
      mainArea: document.querySelector('[data-testid="main-area"]') !== null,
      bodyText: document.body.textContent?.slice(0, 40) ?? '',
    }));
    obs('Wizard 态', wizard);
    assert(wizard.count === 0, `Wizard 态 main 数量必须为 0，实测 ${wizard.count}`);
    assert(!wizard.mainArea, 'Wizard 态不应渲染应用壳（main-area 不存在）');
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
  }
});

await run('R.7 成员按钮只在群聊标签可用（切换/aria-expanded 与 aside 可见性一致）', async () => {
  await resetToBaseSingle('R7 基础单聊');
  await seedReactionGroup('R7 抽屉组');
  const page = await openPage(720, 900);
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const readToggle = () =>
      page.evaluate(() => {
        const toggle = document.querySelector('[data-testid="group-members-toggle"]');
        const aside = document.querySelector('[data-testid="group-members"]');
        const tab = document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab');
        return {
          tab,
          toggleExists: toggle !== null,
          toggleDisabled: toggle instanceof HTMLButtonElement ? toggle.disabled : null,
          expanded: toggle?.getAttribute('aria-expanded') ?? null,
          asideWidth: aside?.getBoundingClientRect().width ?? 0,
        };
      });
    // 群聊标签：打开抽屉 ⇒ aria-expanded=true 且 aside 真的可见。
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 5000 },
    );
    const chatOpen = await readToggle();
    obs('群聊标签下抽屉打开', chatOpen);
    assert(chatOpen.toggleExists, '群聊标签下「成员」按钮必须存在');
    assert(
      chatOpen.expanded === 'true' && chatOpen.asideWidth > 0,
      '抽屉打开时 aria-expanded 必须与 aside 可见性一致',
    );

    // 在抽屉打开态真实点「成员视图」：toggle 必须消失/不可用，抽屉关闭。
    await page.click('[data-testid="group-tab-members"]');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );
    const membersTab = await readToggle();
    obs('成员视图标签下', membersTab);
    assert(membersTab.tab === 'members', '必须真的切到成员视图');
    assert(
      !membersTab.toggleExists || membersTab.toggleDisabled === true,
      '成员视图标签下「成员」按钮必须不存在或不可用（不得空转）',
    );
    assert(membersTab.asideWidth === 0, '切到成员视图后抽屉必须关闭');

    // 切回群聊：抽屉保持关闭，aria-expanded 与可见性一致（false / 0）。
    await page.click('[data-testid="group-tab-chat"]');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 5000 },
    );
    const backToChat = await readToggle();
    obs('切回群聊后', backToChat);
    assert(backToChat.toggleExists || backToChat.toggleDisabled === true, '切回群聊后按钮应可用');
    assert(
      backToChat.expanded === 'false' && backToChat.asideWidth === 0,
      '切回群聊后抽屉必须关闭且 aria-expanded=false',
    );
  } finally {
    await page.close();
  }
});

await run('R.8 换群不重放旧链提示（挂载基线 + 只 bump 当前群）', async () => {
  await resetToBaseSingle('R8 基础单聊');
  const seeded = await seedReactionGroup('R8 提示组');
  await fetch(`${staticServer.url}__set_max_rounds?groupId=${seeded.id}&value=1`);
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    // 第一轮：触发一条链，1 轮上限 ⇒ round_cap 一次性提示出现（tick 被 bump）。
    await page.type('[data-testid="group-input"]', 'R8 第一轮');
    await clickByTestId(page, 'group-send');
    await page.waitForSelector('[data-testid="round-cap-notice"]', { timeout: 15000 });
    const firstNotice = await page.$eval(
      '[data-testid="round-cap-notice"]',
      (element) => element.textContent ?? '',
    );
    obs('第一次 round_cap 提示', firstNotice);

    // 切到单聊再切回：GroupView 必然重挂（GroupLoading 门），旧提示不得重放。
    await clickSessionRow(page, 'R8 基础单聊');
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    const chainMark = responseLog.filter((entry) => entry.method === 'group.chain').length;
    await clickSessionRow(page, 'R8 提示组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await waitFor(
      () =>
        responseLog.filter((entry) => entry.method === 'group.chain').length > chainMark,
      '切回 A 后必须重新拿到 group.chain 响应',
    );
    // 等两帧渲染（重放提示的 effect 在挂载后跑；两帧之后再断言）。
    await page.evaluate(
      () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))),
        ),
    );
    await new Promise((resolve) => setTimeout(resolve, 150));
    const replay = await page.evaluate(() => ({
      notice: document.querySelector('[data-testid="round-cap-notice"]')?.textContent ?? null,
      forced: document.querySelector('[data-testid="forced-notice"]')?.textContent ?? null,
      chainStatus:
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ?? null,
    }));
    obs('切回 A 后（旧提示不得重放）', replay);
    assert(replay.notice === null, `切回 A 后旧 round_cap 提示不得重放，实测「${replay.notice}」`);
    assert(replay.forced === null, '切回 A 后旧 forced_pass 提示不得重放');

    // 挂载后新链结束仍要出提示（tick 必须继续单调）。
    await page.type('[data-testid="group-input"]', 'R8 第二轮');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="round-cap-notice"]') === null,
      { timeout: 5000 },
    );
    await page.waitForSelector('[data-testid="round-cap-notice"]', { timeout: 15000 });
    const secondNotice = await page.$eval(
      '[data-testid="round-cap-notice"]',
      (element) => element.textContent ?? '',
    );
    obs('第二次 round_cap 提示', secondNotice);
    assert(
      secondNotice.includes('已达轮数上限'),
      `挂载后新链结束必须出提示，实测「${secondNotice}」`,
    );
  } finally {
    await page.close();
  }
});

await run('R.9 成员视图与成员名单滚动位置恢复（夹具真可滚）', async () => {
  await resetToBaseSingle('R9 基础单聊');
  await fetch(`${staticServer.url}__seed_scroll_group`);
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });

    // ① 成员名单（1280 静态右列）：真滚到中段 → 切标签 → 切回 → 恢复。
    const rosterBefore = await page.evaluate(() => {
      const aside = document.querySelector('[data-testid="group-members"]');
      if (aside === null) return null;
      aside.scrollTop = 160;
      return {
        scrollTop: aside.scrollTop,
        scrollHeight: aside.scrollHeight,
        clientHeight: aside.clientHeight,
      };
    });
    obs('成员名单滚动前', rosterBefore);
    assert(rosterBefore !== null, '成员名单必须存在');
    assert(
      rosterBefore.scrollHeight > rosterBefore.clientHeight && rosterBefore.scrollTop > 0,
      '成员名单必须先真的可滚（否则滚动断言会假绿）',
    );
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );
    await clickByTestId(page, 'group-tab-chat');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 5000 },
    );
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.scrollTop ?? 0) >= 150,
      { timeout: 5000 },
    );
    const rosterAfter = await page.evaluate(() => ({
      scrollTop: document.querySelector('[data-testid="group-members"]')?.scrollTop ?? 0,
    }));
    obs('成员名单恢复后', rosterAfter);
    assert(
      Math.abs(rosterAfter.scrollTop - 160) <= 2,
      `切回群聊后成员名单滚动位置必须恢复（期望 160，实测 ${rosterAfter.scrollTop}）`,
    );

    // ② 成员视图（甲 25 条私有行）：真滚到中段 → 切标签 → 切回 → 恢复。
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );
    await clickByTestId(page, 'member-select-mem-scroll-0');
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="member-private-row"]').length === 25,
      { timeout: 15000 },
    );
    const memberBefore = await page.evaluate(() => {
      const view = document.querySelector('[data-testid="member-view"]');
      if (view === null) return null;
      view.scrollTop = 300;
      return {
        scrollTop: view.scrollTop,
        scrollHeight: view.scrollHeight,
        clientHeight: view.clientHeight,
        rows: document.querySelectorAll('[data-testid="member-private-row"]').length,
      };
    });
    obs('成员视图滚动前', memberBefore);
    assert(memberBefore !== null && memberBefore.rows === 25, '成员视图必须先有 25 条私有行');
    assert(
      memberBefore.scrollHeight > memberBefore.clientHeight && memberBefore.scrollTop > 0,
      '成员视图必须先真的可滚（否则滚动断言会假绿）',
    );
    await clickByTestId(page, 'group-tab-chat');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 5000 },
    );
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );
    await page.waitForFunction(
      () => (document.querySelector('[data-testid="member-view"]')?.scrollTop ?? 0) >= 280,
      { timeout: 5000 },
    );
    const memberAfter = await page.evaluate(() => ({
      scrollTop: document.querySelector('[data-testid="member-view"]')?.scrollTop ?? 0,
    }));
    obs('成员视图恢复后', memberAfter);
    assert(
      Math.abs(memberAfter.scrollTop - 300) <= 2,
      `切回成员视图后滚动位置必须恢复（期望 300，实测 ${memberAfter.scrollTop}）`,
    );

    // ③ 720 抽屉：打开 → 真滚 → 关闭 → 再打开 → 恢复。
    await clickByTestId(page, 'group-tab-chat');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'chat',
      { timeout: 5000 },
    );
    await page.setViewport({ width: 720, height: 900 });
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) === 0,
      { timeout: 5000 },
    );
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 5000 },
    );
    const drawerBefore = await page.evaluate(() => {
      const aside = document.querySelector('[data-testid="group-members"]');
      if (aside === null) return null;
      aside.scrollTop = 120;
      return { scrollTop: aside.scrollTop, scrollHeight: aside.scrollHeight, clientHeight: aside.clientHeight };
    });
    obs('抽屉滚动前', drawerBefore);
    assert(
      drawerBefore !== null &&
        drawerBefore.scrollHeight > drawerBefore.clientHeight &&
        drawerBefore.scrollTop > 0,
      '720 抽屉必须先真的可滚',
    );
    // 用 Escape 关抽屉：`page.click` 会把可滚容器滚到按钮处（关闭按钮在顶部），
    // 那会先改掉 scrollTop，测不到「关掉再打开」的恢复（R.9 实测踩到）。
    await page.keyboard.press('Escape');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) === 0,
      { timeout: 5000 },
    );
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.getBoundingClientRect().width ??
          0) > 0,
      { timeout: 5000 },
    );
    const drawerReopened = await page.evaluate(() => {
      const aside = document.querySelector('[data-testid="group-members"]');
      return {
        width: aside?.getBoundingClientRect().width ?? 0,
        scrollTop: aside?.scrollTop ?? 0,
        scrollHeight: aside?.scrollHeight ?? 0,
        clientHeight: aside?.clientHeight ?? 0,
      };
    });
    obs('抽屉重新打开后（读数）', drawerReopened);
    await page.waitForFunction(
      () =>
        (document.querySelector('[data-testid="group-members"]')?.scrollTop ?? 0) >= 100,
      { timeout: 5000 },
    );
    const drawerAfter = await page.evaluate(() => ({
      scrollTop: document.querySelector('[data-testid="group-members"]')?.scrollTop ?? 0,
    }));
    obs('抽屉重新打开后', drawerAfter);
    assert(
      Math.abs(drawerAfter.scrollTop - 120) <= 2,
      `重新打开抽屉后成员名单滚动位置必须恢复（期望 120，实测 ${drawerAfter.scrollTop}）`,
    );
  } finally {
    await page.close();
  }
});

await run('R.10 删除当前会话关管理面板（成功关 / 失败保留）', async () => {
  await resetToBaseSingle('R10 当前单聊');
  const nextSingle = await seedSingle('R10 下一条单聊');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('R10 当前单聊') === true,
      { timeout: 15000 },
    );
    // 管理页打开（只盖主区，侧栏仍可点）。
    await openProvidersPage(page);
    await page.waitForSelector('[data-testid="panel-overlay"]', { timeout: 15000 });

    // 成功分支：从侧栏真实删除当前会话 ⇒ 面板必须关闭，主区按下一条加载。
    await page.click('[data-testid="session-delete"]');
    await page.waitForSelector('[data-testid="delete-confirm-button"]', { timeout: 15000 });
    await page.click('[data-testid="delete-confirm-button"]');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="panel-overlay"]') === null,
      { timeout: 15000 },
    );
    const afterSuccess = await page.evaluate(() => ({
      overlay: document.querySelector('[data-testid="panel-overlay"]') !== null,
      title:
        document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      error: document.querySelector('[data-testid="error-banner"]')?.textContent ?? null,
    }));
    obs('删除成功后', afterSuccess);
    assert(!afterSuccess.overlay, '删除成功后面板必须关闭（panel-overlay 消失）');
    assert(
      afterSuccess.title.includes('R10 下一条单聊'),
      `删除成功后主区必须按新会话加载，实测「${afterSuccess.title}」`,
    );

    // 失败分支：假核心删除报错 ⇒ 面板保留、错误可见（不被 setPanel(null) 掩盖）。
    await openProvidersPage(page);
    await page.waitForSelector('[data-testid="panel-overlay"]', { timeout: 15000 });
    const currentId = await page.evaluate(() => {
      const row = document.querySelector('[data-testid="session-row"]');
      return row?.getAttribute('data-session-id') ?? null;
    });
    assert(currentId, '必须能读到当前会话 id');
    await setGroupFlags(`reset=1&deleteFailFor=${currentId}`);
    await page.click('[data-testid="session-delete"]');
    await page.waitForSelector('[data-testid="delete-confirm-button"]', { timeout: 15000 });
    await page.click('[data-testid="delete-confirm-button"]');
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="error-banner"]')
          ?.textContent?.includes('删除会话失败') === true,
      { timeout: 15000 },
    );
    const afterFailure = await page.evaluate(() => ({
      overlay: document.querySelector('[data-testid="panel-overlay"]') !== null,
      error: document.querySelector('[data-testid="error-banner"]')?.textContent ?? '',
    }));
    obs('删除失败后', afterFailure);
    assert(afterFailure.overlay, '删除失败时面板必须保留（不得被 setPanel(null) 掩盖）');
    assert(
      afterFailure.error.includes('删除会话失败'),
      `删除失败必须显示可归因错误，实测「${afterFailure.error}」`,
    );
    assert(nextSingle.id, '夹具单聊必须存在');
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
  }
});

/** 组/RPC 日志允许清单（R.11）：删群段只允许这些方法（`core.ping` 是心跳，显式放行）。 */
const kRpcAllowlist = new Set([
  'core.ping',
  'config.get',
  'template.list',
  'session.list',
  'session.create',
  'session.delete',
  'session.rename',
  'session.switchTemplate',
  'message.query',
  'group.create',
  'group.update',
  'group.delete',
  'group.list',
  'group.chain',
  'group.send',
  'group.view',
  'group.member.add',
  'group.member.remove',
  'group.member.update',
  'agent.cancel',
  'agent.send',
  'attachment.upload',
  'attachment.read',
]);

await run('R.11 测试质量：pageerror 统一断言 / 错误态 testid 拆分 / rpcLog 禁止清单 / flag 不串味', async () => {
  await resetToBaseSingle('R11 基础单聊');
  const failing = await seedDistinctGroup('R11 首屏失败组', '阿败', '不该出现');
  const okGroup = await seedDistinctGroup('R11 视图失败组', '阿稳', 'R11 已加载消息');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    // ① 加载失败与视图失败的错误态 testid 不得互相冒充（旧 group-error 已拆掉）。
    await setGroupFlags(`reset=1&messageQueryFailFor=${failing.id}`);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R11 首屏失败组');
    await page.waitForSelector('[data-testid="group-loading"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="group-loading-error"]', { timeout: 15000 });
    const loadingError = await page.evaluate(() => ({
      loadingError: document.querySelector('[data-testid="group-loading-error"]') !== null,
      viewError: document.querySelector('[data-testid="group-view-error"]') !== null,
      legacy: document.querySelector('[data-testid="group-error"]') !== null,
    }));
    obs('加载失败时的错误态 testid', loadingError);
    assert(loadingError.loadingError, '加载失败必须用 group-loading-error');
    assert(!loadingError.viewError, '加载失败不得复用到 group-view-error');
    assert(!loadingError.legacy, '旧的 group-error testid 必须拆掉');

    // 视图失败（已有首屏、重载失败）：只能用 group-view-error。
    await setGroupFlags('reset=1');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'R11 视图失败组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await setGroupFlags(`messageQueryFailFor=${okGroup.id}`);
    await fetch(
      `${staticServer.url}__emit_group_message?groupId=${okGroup.id}&content=${encodeURIComponent('R11 触发重载')}`,
    );
    await page.waitForSelector('[data-testid="group-view-error"]', { timeout: 15000 });
    const viewError = await page.evaluate(() => ({
      viewError: document.querySelector('[data-testid="group-view-error"]') !== null,
      loadingError: document.querySelector('[data-testid="group-loading-error"]') !== null,
      groupView: document.querySelector('[data-testid="group-view"]') !== null,
    }));
    obs('视图失败时的错误态 testid', viewError);
    assert(viewError.viewError && viewError.groupView, '重载失败必须用 group-view-error 且保留 group-view');
    assert(!viewError.loadingError, '重载失败不得冒充 group-loading-error');

    // ② 删群段的 rpcLog 禁止清单（不清 responseLog：group.create 的 id 从它取）。
    await setGroupFlags('reset=1');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickByTestId(page, 'group-create');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const created = responseLog.filter((entry) => entry.method === 'group.create').at(-1);
    const groupId = created?.result?.group?.id ?? null;
    assert(groupId, 'group.create 必须返回新组 id（responseLog 不得被清空）');
    const responseMark = responseLog.length;
    rpcLog.length = 0;
    await deleteSessionRowById(page, groupId);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="group-view"]') === null,
      { timeout: 15000 },
    );
    const deleteRpcs = rpcLog.filter((entry) => entry.method === 'group.delete');
    const forbidden = rpcLog.filter(
      (entry) => entry.method === 'session.delete' && entry.params?.sessionId === groupId,
    );
    const unexpected = rpcLog.filter((entry) => !kRpcAllowlist.has(entry.method));
    obs('删群段的 rpcLog', {
      methods: rpcLog.map((entry) => entry.method),
      groupDeletePayload: deleteRpcs.at(-1)?.params ?? null,
      responseLogGrew: responseLog.length > responseMark,
    });
    assert(
      deleteRpcs.some((entry) => entry.params?.groupId === groupId),
      '删群必须发 group.delete（payload 带 groupId）',
    );
    assert(forbidden.length === 0, `删群不得出现该组的 session.delete，实测 ${JSON.stringify(forbidden)}`);
    assert(
      unexpected.length === 0,
      `删群段出现未预期 RPC：${JSON.stringify(unexpected.map((entry) => entry.method))}`,
    );
    assert(responseLog.length > responseMark, 'responseLog 不得被清空（group.create 的 id 依赖它）');

    // ③ flag 不串味：置一个失败 flag 后 reset，新页面必须正常加载。
    await setGroupFlags('messageQueryFailKind=single');
    await setGroupFlags('reset=1');
    const cleanPage = await openPage();
    try {
      await cleanPage.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
      await cleanPage.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
      const clean = await cleanPage.evaluate(() => ({
        error: document.querySelector('[data-testid="error-banner"]')?.textContent ?? null,
        title:
          document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      }));
      obs('reset 后的新页面', clean);
      assert(clean.error === null, `flag reset 后新会话不得报加载错误，实测「${clean.error}」`);
    } finally {
      await cleanPage.close();
    }
  } finally {
    await setGroupFlags('reset=1').catch(() => {});
    await page.close();
  }
});

await run('R.13 作者负控：member-private-row 的 data-author = message.author + 独立 oracle', async () => {
  await resetToBaseSingle('R13 基础单聊');
  const seeded = await fetch(`${staticServer.url}__seed_author_group`).then((response) =>
    response.json(),
  );
  obs('R13 作者组夹具', seeded);
  // 独立 oracle：从假核心的原始消息按 author 统计私有行（不经过 DOM）。
  const raw = await fetch(
    `${staticServer.url}__query_messages?sessionId=${encodeURIComponent(seeded.id)}`,
  ).then((response) => response.json());
  const oracle = {};
  for (const message of raw.messages) {
    if (message.visibility !== 'private-to-author' || message.author === null) continue;
    oracle[message.author] = (oracle[message.author] ?? 0) + 1;
  }
  obs('R13 oracle（按作者统计私有行）', oracle);
  assert((oracle['mem-author-a'] ?? 0) === 2, 'oracle：甲应有 2 条私有行');
  assert((oracle['mem-author-b'] ?? 0) === 3, 'oracle：乙应有 3 条私有行');

  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await clickByTestId(page, 'group-tab-members');
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="group-view"]')?.getAttribute('data-active-tab') ===
        'members',
      { timeout: 5000 },
    );

    const readRows = () =>
      page.evaluate(() => ({
        authors: [...document.querySelectorAll('[data-testid="member-private-row"]')].map((row) =>
          row.getAttribute('data-author'),
        ),
        contents: [...document.querySelectorAll('[data-testid="member-private-row"]')].map(
          (row) => row.textContent ?? '',
        ),
      }));

    // 甲：每一行的 data-author 都必须是甲；行数必须与 oracle 相等（不是只看 >0）。
    await clickByTestId(page, 'member-select-mem-author-a');
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="member-private-row"]').length > 0,
      { timeout: 15000 },
    );
    const rowsA = await readRows();
    obs('选中甲时的私有行', rowsA);
    assert(rowsA.authors.length === 2, `选中甲时应显示 2 条私有行，实测 ${rowsA.authors.length}`);
    assert(
      rowsA.authors.every((author) => author === 'mem-author-a'),
      `选中甲时每行 data-author 都必须是甲，实测 ${JSON.stringify(rowsA.authors)}`,
    );
    assert(
      rowsA.authors.length === oracle['mem-author-a'],
      '甲的行数必须与独立 oracle 一致（data-author 不能恒真自证）',
    );
    assert(
      rowsA.contents.every((content) => content.includes('甲的私有过程')),
      '选中甲时读到的内容必须属于甲（不能把乙的行挂到甲下）',
    );

    // 乙：选中切换后 data-author 必须随选择变成乙。
    await clickByTestId(page, 'member-select-mem-author-b');
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="member-private-row"]').length === 3,
      { timeout: 15000 },
    );
    const rowsB = await readRows();
    obs('选中乙时的私有行', rowsB);
    assert(
      rowsB.authors.every((author) => author === 'mem-author-b'),
      `选中乙时每行 data-author 都必须是乙，实测 ${JSON.stringify(rowsB.authors)}`,
    );
    assert(
      rowsB.authors.length === oracle['mem-author-b'],
      '乙的行数必须与独立 oracle 一致',
    );
    assert(
      rowsB.contents.every((content) => content.includes('乙的私有过程')),
      '选中乙时读到的内容必须属于乙',
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 5.3 群聊气泡、成员卡片与紧凑环（change `chat-bubbles-avatars` / design D4、D5、D6）
//
// 独立组 id + 结束时清场；连跑两遍确认夹具不串味。断言只读 data-bubble-side /
// data-avatar-source / data-state / data-ring-state，量内层气泡**左缘**（不量右缘、
// 不量"宽度 < 一半"）。
// ---------------------------------------------------------------------------

async function bubbleCaseOnce(pass) {
  const seeded = await fetch(`${staticServer.url}__seed_bubble_group`).then((response) =>
    response.json(),
  );
  obs(`气泡/卡片夹具（第 ${pass} 遍）`, { id: seeded.id, members: seeded.members });
  const ids = seeded.members;
  const groupId = seeded.id;
  await setGroupFlags(
    `reset=1&groupViewFailGroupId=${groupId}&groupViewFailMemberId=${ids.g}` +
      `&groupViewDelayGroupId=${groupId}&groupViewDelayMemberId=${ids.f}&groupViewDelayMs=30000`,
  );
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="timeline-item"]', { timeout: 15000 });
    // 等头像字节与快照陆续到达（假核心即时回，给两帧 + 一点余量）。
    await new Promise((resolve) => setTimeout(resolve, 1200));

    // ---- ① / ② 气泡几何：用户靠右、成员靠左（只量内层气泡左缘）----
    const timeline = await page.evaluate(() => {
      const rect = (node) => {
        const box = node.getBoundingClientRect();
        return {
          left: box.left,
          right: box.right,
          top: box.top,
          bottom: box.bottom,
          width: box.width,
        };
      };
      return [...document.querySelectorAll('[data-testid="timeline-item"]')].map((item) => {
        const bubble = item.querySelector('[data-testid="bubble"]');
        const column = item.querySelector('[data-testid="bubble-column"]');
        const avatar = item.querySelector('[data-avatar-source]');
        const name = item.querySelector('[data-testid="bubble-name"]');
        return {
          side: bubble?.dataset.bubbleSide ?? null,
          text: item.innerText,
          row: rect(item),
          bubble: bubble ? rect(bubble) : null,
          column: column ? rect(column) : null,
          avatar: avatar
            ? {
                ...rect(avatar),
                source: avatar.dataset.avatarSource,
                seed: avatar.dataset.seed,
                src: avatar.getAttribute('src'),
                tag: avatar.tagName,
              }
            : null,
          name: name
            ? { text: name.textContent ?? '', ...rect(name) }
            : null,
          bubbleCount: item.querySelectorAll('[data-testid="bubble"]').length,
        };
      });
    });
    obs('时间线行数', timeline.length);
    const userRow = timeline.find((row) => row.side === 'user');
    const memberA = timeline.find((row) => row.text.includes('甲的公开结论（种子）'));
    const memberB = timeline.find((row) => row.text.includes('乙的公开结论（种子）'));
    assert(userRow !== undefined, '时间线必须有用户行');
    assert(memberA !== undefined && memberB !== undefined, '时间线必须有甲/乙的成员行');
    assert(
      userRow.bubbleCount === 1,
      `整行容器里应恰好一个内层气泡（纯气泡），实测 ${userRow.bubbleCount}`,
    );
    assert(
      userRow.bubble.left > userRow.row.left + userRow.row.width / 2,
      `用户内层气泡左缘必须落在行右半区（气泡 ${userRow.bubble.left} / 行 ${userRow.row.left}+${userRow.row.width / 2}）`,
    );
    assert(
      userRow.avatar !== null && userRow.avatar.left >= userRow.bubble.right - 0.5,
      '用户头像必须在该行最右端（气泡右侧）',
    );
    assert(
      Math.abs(memberA.bubble.left - memberA.column.left) <= 1,
      `成员内层气泡左缘必须贴自己的列（≤1px）：气泡 ${memberA.bubble.left} / 列 ${memberA.column.left}`,
    );
    assert(
      memberA.avatar !== null && memberA.avatar.right <= memberA.bubble.left + 0.5,
      '成员头像必须在气泡左侧',
    );
    assert(
      memberA.avatar.left - memberA.row.left <= 1,
      `成员头像必须贴行左缘（≤1px）：头像 ${memberA.avatar.left} / 行 ${memberA.row.left}`,
    );
    assert(memberA.name !== null && memberA.name.text === '甲', '成员名字必须在气泡上方');
    assert(
      memberA.name.bottom <= memberA.bubble.top + 1,
      `名字必须在气泡上方（名字底 ${memberA.name.bottom} / 气泡顶 ${memberA.bubble.top}）`,
    );

    // ---- ③ 两名成员（模板无上传图）的身份图案种子是各自 id、图案不同 ----
    assert(
      memberA.avatar.source === 'identicon' && memberB.avatar.source === 'identicon',
      '无上传图的模板必须画身份图案',
    );
    assert(
      memberA.avatar.seed === ids.a && memberB.avatar.seed === ids.b,
      `头像种子必须是成员 id（甲 ${ids.a} / 乙 ${ids.b}），实测 ${memberA.avatar.seed} / ${memberB.avatar.seed}`,
    );
    const patterns = await page.evaluate(() => {
      const patternOf = (needle) => {
        const row = [...document.querySelectorAll('[data-testid="timeline-item"]')].find((node) =>
          node.innerText.includes(needle),
        );
        const svg = row?.querySelector('svg[data-avatar-source]');
        if (!svg) return null;
        return [...svg.querySelectorAll('rect')]
          .filter((node) => (node.getAttribute('class') ?? '').startsWith('fill-avatar-tint'))
          .map((node) => `${node.getAttribute('x')},${node.getAttribute('y')}`)
          .join('|');
      };
      return { a: patternOf('甲的公开结论（种子）'), b: patternOf('乙的公开结论（种子）') };
    });
    obs('甲/乙 身份图案格位', patterns);
    assert(patterns.a !== null && patterns.b !== null && patterns.a !== patterns.b,
      '两名成员的身份图案必须不同（成员 id 不同）');

    // ---- ④ 同模板同上传图：两人头像 src 相同且都是 data URL；两条都能按名字归属 ----
    const shared = await page.evaluate(() => {
      const info = (needle) => {
        const row = [...document.querySelectorAll('[data-testid="timeline-item"]')].find((node) =>
          node.innerText.includes(needle),
        );
        const avatar = row?.querySelector('[data-avatar-source]');
        const name = row?.querySelector('[data-testid="bubble-name"]');
        return {
          source: avatar?.dataset.avatarSource ?? null,
          src: avatar?.getAttribute('src') ?? null,
          name: name?.textContent ?? null,
        };
      };
      return { c: info('丙的公开结论（种子）'), d: info('丁的公开结论（种子）') };
    });
    obs('丙/丁 同模板同上传图', shared);
    assert(shared.c.source === 'upload' && shared.d.source === 'upload', '可读上传图必须显示为上传');
    assert(
      typeof shared.c.src === 'string' && shared.c.src.startsWith('data:'),
      '上传头像的 src 必须是 data URL（不是绝对路径）',
    );
    assert(shared.c.src === shared.d.src, '同模板同上传图时两人头像相同（属预期）');
    assert(shared.c.name === '丙' && shared.d.name === '丁', '同图时靠名字归属');

    // ---- ⑤ 成员卡片：头像 / 状态点 / 紧凑环 / 齿轮 ----
    const cards = await page.evaluate((idList) => {
      const read = (id) => {
        const avatar = document.querySelector(`[data-testid="member-avatar-${id}"]`);
        const status = document.querySelector(`[data-testid="member-status-${id}"]`);
        const ring = document.querySelector(`[data-testid="member-ring-${id}"]`);
        const gear = document.querySelector(`[data-testid="member-edit-${id}"]`);
        return {
          avatar: avatar
            ? { source: avatar.dataset.avatarSource, seed: avatar.dataset.seed }
            : null,
          status: status ? status.dataset.state ?? null : null,
          ring: ring
            ? {
                state: ring.dataset.ringState ?? null,
                circles: ring.querySelectorAll('circle').length,
                slices: ring.querySelectorAll('[data-testid="ring-slice"]').length,
              }
            : null,
          gear: gear !== null,
          gearHeight: gear ? gear.getBoundingClientRect().height : 0,
        };
      };
      const out = {};
      for (const id of idList) out[id] = read(id);
      return out;
    }, [ids.a, ids.b, ids.removed]);
    obs('成员卡片要素', cards);
    for (const [label, id] of [['甲', ids.a], ['乙', ids.b], ['已移除的壬', ids.removed]]) {
      const card = cards[id];
      assert(card.avatar !== null, `${label} 卡片必须有头像（member-avatar-<id>）`);
      assert(
        card.status === 'idle' || card.status === 'running',
        `${label} 的状态点必须有 data-state（running/idle），实测 ${card.status}`,
      );
      assert(card.ring !== null, `${label} 卡片必须有紧凑环（member-ring-<id>）`);
      assert(card.gear, `${label} 卡片必须有齿轮（member-edit-<id>）`);
      assert(card.gearHeight >= 24, `${label} 的齿轮命中高度必须 ≥24px，实测 ${card.gearHeight}`);
    }

    // ---- ⑥ 成员都没有快照时全页 context-ring 数量为 0（紧凑环不得叫 context-ring）----
    const ringCount = await page.evaluate(() => ({
      contextRing: document.querySelectorAll('[data-testid="context-ring"]').length,
      memberRing: document.querySelectorAll('[data-testid^="member-ring-"]').length,
    }));
    obs('环的标识', ringCount);
    assert(ringCount.contextRing === 0, `紧凑环不得复用 context-ring，实测 ${ringCount.contextRing}`);
    assert(ringCount.memberRing >= 3, '成员卡片必须有紧凑环占位或环');

    // ---- ⑧ / ⑬ 空态 / 失败 / 加载态：只给占位、不画三瓣 ----
    await page.waitForFunction(
      (id) => document.querySelector(`[data-testid="member-ring-${id}"]`)?.dataset.ringState === 'error',
      { timeout: 15000 },
      ids.g,
    );
    const ringStates = await page.evaluate((idMap) => {
      const read = (id) => {
        const node = document.querySelector(`[data-testid="member-ring-${id}"]`);
        return node
          ? { state: node.dataset.ringState ?? null, circles: node.querySelectorAll('circle').length }
          : null;
      };
      return { empty: read(idMap.a), error: read(idMap.g), loading: read(idMap.f) };
    }, ids);
    obs('环状态占位', ringStates);
    assert(ringStates.empty.state === 'empty', `没发过言的成员环状态应为 empty，实测 ${ringStates.empty.state}`);
    assert(ringStates.error.state === 'error', `读取失败的成员环状态应为 error，实测 ${ringStates.error.state}`);
    assert(ringStates.loading.state === 'loading', `仍在加载的成员环状态应为 loading，实测 ${ringStates.loading.state}`);
    for (const [label, state] of Object.entries(ringStates)) {
      assert(state.circles === 0, `${label} 态不得画三瓣（不得画空环冒充零占用）`);
    }
    // 加载 / 失败两个夹具的观察目的已达成：清掉延迟与失败注入，后续重拉走快路径
    // （否则 30s 的 group.view 会把链结束后的重拉拖住）。
    await setGroupFlags('reset=1');

    // ---- ⑦ 悬停紧凑环：浮层给 tokens 详情（对话 / 窗口 / 三瓣；不要求百分比）----
    await page.waitForFunction(
      (id) => document.querySelector(`[data-testid="member-ring-${id}"]`)?.dataset.ringState === 'ok',
      { timeout: 15000 },
      ids.e,
    );
    await page.hover(`[data-testid="member-ring-${ids.e}"]`);
    await page.waitForSelector(`[data-testid="member-ring-detail-${ids.e}"]`, { timeout: 8000 });
    const detail = await page.$eval(
      `[data-testid="member-ring-detail-${ids.e}"]`,
      (node) => node.innerText,
    );
    obs('紧凑环悬停详情', detail);
    for (const anchor of ['对话', '窗口', '1200', '300', '100']) {
      assert(detail.includes(anchor), `紧凑环详情缺少「${anchor}」，实测「${detail}」`);
    }

    // ---- ⑨ 已移除成员：齿轮仍可开、面板只读（保存/移除不发 RPC）----
    await clickByTestId(page, `member-edit-${ids.removed}`);
    await page.waitForSelector(`[data-testid="override-editor-${ids.removed}"]`, {
      timeout: 8000,
    });
    const removedPanel = await page.evaluate((id) => {
      const panel = document.querySelector(`[data-testid="override-editor-${id}"]`);
      const save = panel?.querySelector(`[data-testid="member-save-${id}"]`);
      const remove = panel?.querySelector(`[data-testid="member-remove-${id}"]`);
      const controls = [...(panel?.querySelectorAll('select,input,textarea') ?? [])];
      return {
        saveAria: save?.getAttribute('aria-disabled') ?? null,
        removeAria: remove?.getAttribute('aria-disabled') ?? null,
        allControlsDisabled: controls.length > 0 && controls.every((node) => node.disabled === true),
        effective: panel?.querySelector(`[data-testid="effective-${id}"]`)?.textContent != null,
      };
    }, ids.removed);
    obs('已移除成员的面板', removedPanel);
    assert(removedPanel.saveAria === 'true', '已移除成员的保存必须标 aria-disabled="true"');
    assert(removedPanel.removeAria === 'true', '已移除成员的移除必须标 aria-disabled="true"');
    assert(removedPanel.allControlsDisabled, '已移除成员的模板/工具/提示词/强度控件必须禁用');
    assert(removedPanel.effective, '面板里仍要能看到它移除前的生效结果');

    const writesBefore = rpcLog.filter(
      (entry) =>
        (entry.method === 'group.member.update' || entry.method === 'group.member.remove') &&
        entry.params?.memberId === ids.removed,
    ).length;
    await page.click(`[data-testid="member-save-${ids.removed}"]`).catch(() => {});
    await page.click(`[data-testid="member-remove-${ids.removed}"]`).catch(() => {});
    await new Promise((resolve) => setTimeout(resolve, 400));
    const writesAfter = rpcLog.filter(
      (entry) =>
        (entry.method === 'group.member.update' || entry.method === 'group.member.remove') &&
        entry.params?.memberId === ids.removed,
    ).length;
    obs('已移除成员的写请求数（前 / 后）', { writesBefore, writesAfter });
    assert(writesAfter === writesBefore, '已移除成员的保存/移除点击不得发起任何写请求');
    await clickByTestId(page, `member-edit-${ids.removed}`);

    // ---- ⑪ 卡面不再有生效工具长列表（只在面板里）----
    const cardFace = await page.evaluate((id) => {
      const name = document.querySelector(`[data-testid="member-name-${id}"]`);
      const card = name?.closest('li');
      return {
        hasEffective: card?.querySelector(`[data-testid="effective-${id}"]`) !== null,
        text: card?.innerText ?? '',
      };
    }, ids.a);
    obs('甲的卡面文本', cardFace.text);
    assert(!cardFace.hasEffective, '卡面不得再摊出生效结果节点（effective 只在面板里）');
    assert(!cardFace.text.includes('生效工具：'), '卡面不得再显示「生效工具：」长列表');

    // ---- ⑩ 面板里换模板并保存：payload 带 templateName、保存不收起、头像随模板变 ----
    await clickByTestId(page, `member-edit-${ids.a}`);
    await page.waitForSelector(`[data-testid="member-template-${ids.a}"]`, { timeout: 8000 });
    await page.select(`[data-testid="member-template-${ids.a}"]`, 'avatar-tpl');
    await clickByTestId(page, `member-save-${ids.a}`);
    await waitFor(
      () =>
        rpcLog.some(
          (entry) =>
            entry.method === 'group.member.update' &&
            entry.params?.memberId === ids.a &&
            entry.params?.templateName === 'avatar-tpl',
        ),
      'group.member.update 的 payload 必须带 templateName',
    );
    assert(
      (await page.$(`[data-testid="override-editor-${ids.a}"]`)) !== null,
      '保存后不得自动收起面板',
    );
    await page.waitForFunction(
      (id) =>
        document.querySelector(`[data-testid="member-avatar-${id}"]`)?.dataset.avatarSource ===
        'upload',
      { timeout: 15000 },
      ids.a,
    );
    const aBubbleAvatar = await page.evaluate((needle) => {
      const row = [...document.querySelectorAll('[data-testid="timeline-item"]')].find((node) =>
        node.innerText.includes(needle),
      );
      return row?.querySelector('[data-avatar-source]')?.dataset.avatarSource ?? null;
    }, '甲的公开结论（种子）');
    obs('换模板后甲的头像来源（卡片 / 气泡）', aBubbleAvatar);
    assert(aBubbleAvatar === 'upload', '换到有头像的模板后气泡头像也必须跟着变');
    await clickByTestId(page, `member-edit-${ids.a}`);

    // ---- ⑭ 模板头像读不到：该成员头像回落身份图案 ----
    const brokenAvatar = await page.evaluate((id) => {
      const node = document.querySelector(`[data-testid="member-avatar-${id}"]`);
      return node ? { source: node.dataset.avatarSource, seed: node.dataset.seed } : null;
    }, ids.broken);
    obs('模板头像读不到的成员头像', brokenAvatar);
    assert(brokenAvatar !== null && brokenAvatar.source === 'identicon',
      '模板头像读不到时必须回落身份图案');
    assert(brokenAvatar.seed === ids.broken, '回落时种子仍是成员 id');

    // ---- ⑫ 流式状态点：门挂住甲 ⇒ 甲 running / 乙 idle；放行后两者都 idle ----
    await fetch(`${staticServer.url}__gate_member_stream`);
    await page.type('[data-testid="group-input"]', '开始反应');
    await clickByTestId(page, 'group-send');
    await page.waitForFunction(
      (id) => document.querySelector(`[data-testid="member-status-${id}"]`)?.dataset.state === 'running',
      { timeout: 15000 },
      ids.a,
    );
    const duringStream = await page.evaluate((idMap) => {
      const read = (id) =>
        document.querySelector(`[data-testid="member-status-${id}"]`)?.dataset.state ?? null;
      return {
        a: read(idMap.a),
        b: read(idMap.b),
        streamingTextExists: document.querySelector(`[data-testid="member-streaming-${idMap.a}"]`) !== null,
        streamingText:
          document.querySelector(`[data-testid="member-streaming-${idMap.a}"]`)?.textContent ?? '',
      };
    }, ids);
    obs('流式中的状态点', duringStream);
    assert(duringStream.a === 'running', '正在流式的成员状态点必须是 running');
    assert(duringStream.b === 'idle', '没在流式的成员状态点必须是 idle（不猜）');
    assert(duringStream.streamingText.includes('正在反应'), '运行中必须带可读的「正在反应…」文本');

    await fetch(`${staticServer.url}__release_send`);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="reaction-active"]') === null,
      { timeout: 20000 },
    );
    await page.waitForFunction(
      (idMap) => {
        const read = (id) =>
          document.querySelector(`[data-testid="member-status-${id}"]`)?.dataset.state ?? null;
        return read(idMap.a) === 'idle' && read(idMap.b) === 'idle';
      },
      { timeout: 20000 },
      ids,
    );
    obs('链结束后状态点', await page.evaluate((idMap) => {
      const read = (id) =>
        document.querySelector(`[data-testid="member-status-${id}"]`)?.dataset.state ?? null;
      return { a: read(idMap.a), b: read(idMap.b) };
    }, ids));
  } finally {
    await page.close();
    await setGroupFlags('reset=1').catch(() => {});
  }
  // 清场：删掉本遍的组（下一次 pass 从干净会话列表开始）。
  await fetch(`${staticServer.url}__delete_session?id=${groupId}`).catch(() => {});
}

await run('5.3 群聊气泡 / 成员卡片 / 紧凑环（连跑两遍不串味）', async () => {
  await bubbleCaseOnce(1);
  await bubbleCaseOnce(2);
});

// ---------------------------------------------------------------------------
// 全局设置菜单（change `global-settings-menu` 2.1 / design D1~D9）
//
// 单聊与群聊共用**左栏底部**这一个管理入口：菜单向上浮出、恰好两项、旧头部入口为 0。
// `SETTINGS_SHOT` / `SETTINGS_SHOT_GROUP` 分别留「单聊菜单打开」「群聊菜单打开」两张图。
// ---------------------------------------------------------------------------
await run('全局设置菜单：左栏底部唯一管理入口（恰好两项 / 向上浮出 / 群聊可达 / 旧入口为 0）', async () => {
  await resetToBaseSingle('设置菜单基础单聊');
  const group = await seedDistinctGroup('设置菜单群', '阿设', '设置菜单群消息');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    // ① 全局设置按钮必须在（找不到即红：这就是本 change 的入口本体）。
    await page.waitForSelector('[data-testid="global-settings-button"]', { timeout: 15000 });

    const before = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      messageRows: document.querySelectorAll('[data-testid="message-row"]').length,
      legacyProviders: document.querySelectorAll('[data-testid="open-providers"]').length,
      legacyTemplates: document.querySelectorAll('[data-testid="open-templates"]').length,
    }));
    obs('打开菜单前的单聊屏', before);
    assert(
      before.legacyProviders === 0,
      `单聊头部不得再有旧 Provider 入口，实测 ${before.legacyProviders} 个`,
    );
    assert(
      before.legacyTemplates === 0,
      `单聊头部不得再有旧模板入口，实测 ${before.legacyTemplates} 个`,
    );
    assert(
      before.title.includes('设置菜单基础单聊'),
      `首屏必须落在基础单聊，实测「${before.title}」`,
    );

    // ① 按钮在左栏底部、用户头像块上方，且可访问性属性齐备。
    const buttonBox = await page.evaluate(() => {
      const box = (node) => {
        const rect = node?.getBoundingClientRect();
        return rect === undefined
          ? null
          : {
              top: rect.top,
              bottom: rect.bottom,
              left: rect.left,
              right: rect.right,
              width: rect.width,
              height: rect.height,
            };
      };
      const button = document.querySelector('[data-testid="global-settings-button"]');
      const sidebar = document.querySelector('[data-testid="session-sidebar"]');
      const avatarBlock = document.querySelector('[data-testid="user-avatar-block"]');
      return {
        inSidebar: button !== null && sidebar !== null && sidebar.contains(button),
        label: button?.textContent?.trim() ?? '',
        iconCount: button?.querySelectorAll('svg').length ?? 0,
        ariaHaspopup: button?.getAttribute('aria-haspopup') ?? null,
        ariaExpanded: button?.getAttribute('aria-expanded') ?? null,
        button: box(button),
        avatarBlock: box(avatarBlock),
      };
    });
    obs('设置按钮的几何与可访问性', buttonBox);
    assert(buttonBox.inSidebar, '设置按钮必须在 session-sidebar 内');
    assert(
      buttonBox.label.includes('设置'),
      `按钮必须有可见文字「设置」，实测「${buttonBox.label}」`,
    );
    assert(buttonBox.iconCount >= 1, '按钮必须带 Settings 图标（<svg>）');
    assert(
      buttonBox.ariaHaspopup === 'menu',
      `按钮必须 aria-haspopup="menu"，实测 ${buttonBox.ariaHaspopup}`,
    );
    assert(
      buttonBox.ariaExpanded === 'false',
      `菜单初始必须 aria-expanded="false"，实测 ${buttonBox.ariaExpanded}`,
    );
    assert(
      buttonBox.button !== null && buttonBox.avatarBlock !== null,
      '设置按钮与用户头像块都必须存在',
    );
    assert(
      buttonBox.button.top < buttonBox.avatarBlock.top,
      `设置按钮必须在用户头像块之上（按钮 top=${buttonBox.button?.top} / 头像块 top=${buttonBox.avatarBlock?.top}）`,
    );

    // ② / ③ 点开菜单：恰好两项、标签逐字、各带图标、向上浮出且不超出左栏。
    await clickByTestId(page, 'global-settings-button');
    await page.waitForSelector('[data-testid="global-settings-menu"]', { timeout: 15000 });
    const menuState = await page.evaluate(() => {
      const box = (node) => {
        const rect = node?.getBoundingClientRect();
        return rect === undefined
          ? null
          : {
              top: rect.top,
              bottom: rect.bottom,
              left: rect.left,
              right: rect.right,
              width: rect.width,
              height: rect.height,
            };
      };
      const menu = document.querySelector('[data-testid="global-settings-menu"]');
      const items = [...(menu?.querySelectorAll('[role="menuitem"]') ?? [])];
      return {
        expanded:
          document
            .querySelector('[data-testid="global-settings-button"]')
            ?.getAttribute('aria-expanded') ?? null,
        role: menu?.getAttribute('role') ?? null,
        ariaLabel: menu?.getAttribute('aria-label') ?? null,
        itemCount: items.length,
        labels: items.map((node) => node.textContent?.trim() ?? ''),
        testIds: items.map((node) => node.getAttribute('data-testid') ?? ''),
        withIcon: items.map((node) => node.querySelector('svg') !== null),
        text: menu?.innerText ?? '',
        menu: box(menu),
        button: box(document.querySelector('[data-testid="global-settings-button"]')),
        sidebar: box(document.querySelector('[data-testid="session-sidebar"]')),
      };
    });
    obs('菜单实测（项数 / 标签 / 几何）', {
      itemCount: menuState.itemCount,
      labels: menuState.labels,
      expanded: menuState.expanded,
      menuRect: menuState.menu,
      buttonRect: menuState.button,
      sidebarRect: menuState.sidebar,
    });
    assert(
      menuState.expanded === 'true',
      `菜单打开后按钮必须 aria-expanded="true"，实测 ${menuState.expanded}`,
    );
    assert(menuState.role === 'menu', `菜单必须 role="menu"，实测 ${menuState.role}`);
    assert(
      menuState.ariaLabel === '全局设置',
      `菜单 aria-label 必须是「全局设置」，实测 ${menuState.ariaLabel}`,
    );
    assert(
      menuState.itemCount === 2,
      `菜单项必须恰好 2 项，实测 ${menuState.itemCount} 项：${JSON.stringify(menuState.labels)}`,
    );
    assert(
      JSON.stringify(menuState.labels) === JSON.stringify(['Provider 配置', '模板配置']),
      `菜单项文字必须逐字为 Provider 配置 / 模板配置，实测 ${JSON.stringify(menuState.labels)}`,
    );
    assert(
      JSON.stringify(menuState.testIds) ===
        JSON.stringify(['global-settings-item-providers', 'global-settings-item-templates']),
      `菜单项 testid 必须固定，实测 ${JSON.stringify(menuState.testIds)}`,
    );
    assert(
      menuState.withIcon.every(Boolean),
      `每个菜单项都必须带图标，实测 ${JSON.stringify(menuState.withIcon)}`,
    );
    for (const word of ['关于', '反馈', '登录', '用户资料']) {
      assert(
        !menuState.text.includes(word),
        `菜单里不得出现「${word}」类入口，实测「${menuState.text}」`,
      );
    }
    assert(menuState.menu !== null && menuState.button !== null, '菜单与按钮都必须可测几何');
    assert(
      menuState.menu.bottom <= menuState.button.top + 1,
      `菜单必须向上浮出（菜单 bottom=${menuState.menu?.bottom} / 按钮 top=${menuState.button?.top}）`,
    );
    assert(
      menuState.menu.left >= menuState.sidebar.left - 0.5 &&
        menuState.menu.right <= menuState.sidebar.right + 0.5,
      `菜单左右不得超出左栏（菜单 ${menuState.menu?.left}..${menuState.menu?.right} / 左栏 ${menuState.sidebar?.left}..${menuState.sidebar?.right}）`,
    );

    // ⑧ 单聊菜单打开：留图给主循环做视觉验收。
    if (process.env.SETTINGS_SHOT) {
      const target = process.env.SETTINGS_SHOT;
      await page.screenshot({ path: target, fullPage: false });
      console.log(`[SHOT] captured ${target}`);
    }

    // ④ 点「Provider 配置」⇒ 管理页打开、菜单关闭；关闭后回到原会话且标题 / 消息不变。
    await page.click('[data-testid="global-settings-item-providers"]');
    await page.waitForSelector('[data-testid="providers-page"]', { timeout: 15000 });
    const providerOpen = await page.evaluate(() => {
      const sidebar = document.querySelector('[data-testid="session-sidebar"]');
      return {
        menu: document.querySelector('[data-testid="global-settings-menu"]') !== null,
        overlay: document.querySelector('[data-testid="panel-overlay"]') !== null,
        sidebar: sidebar !== null,
        sidebarWidth: sidebar?.getBoundingClientRect().width ?? null,
        settingsButton: document.querySelector('[data-testid="global-settings-button"]') !== null,
      };
    });
    obs('单聊打开 Provider 配置后', providerOpen);
    assert(!providerOpen.menu, '点菜单项后菜单必须关闭');
    assert(providerOpen.overlay, 'Provider 管理页必须挂在 panel-overlay 里（只盖主区）');
    assert(
      providerOpen.sidebar && providerOpen.sidebarWidth === 224,
      `管理页打开时左栏必须仍可见且宽度 224，实测 ${providerOpen.sidebarWidth}`,
    );
    assert(providerOpen.settingsButton, '管理页打开时左栏底部的设置按钮仍必须在（左栏不被覆盖）');

    await page.click('[data-testid="providers-close"]');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="providers-page"]') === null,
      { timeout: 15000 },
    );
    const providerClosed = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      messageRows: document.querySelectorAll('[data-testid="message-row"]').length,
      messageList: document.querySelector('[data-testid="message-list"]') !== null,
    }));
    obs('关闭 Provider 配置后', providerClosed);
    assert(providerClosed.messageList, '关闭管理页后必须回到聊天屏');
    assert(
      providerClosed.title === before.title,
      `关闭后标题必须不变（前「${before.title}」/ 后「${providerClosed.title}」）`,
    );
    assert(
      providerClosed.messageRows === before.messageRows,
      `关闭后消息条数必须不变（前 ${before.messageRows} / 后 ${providerClosed.messageRows}）`,
    );

    // ⑤ 群视图：入口仍在，点「模板配置」打开模板页（本 change 的核心修复）。
    await clickSessionRow(page, '设置菜单群');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="timeline-item"]', { timeout: 15000 });
    const groupBefore = await page.evaluate(() => ({
      title: document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      timelineItems: document.querySelectorAll('[data-testid="timeline-item"]').length,
      settingsButton: document.querySelector('[data-testid="global-settings-button"]') !== null,
      buttonTop:
        document.querySelector('[data-testid="global-settings-button"]')?.getBoundingClientRect()
          .top ?? null,
      avatarTop:
        document.querySelector('[data-testid="user-avatar-block"]')?.getBoundingClientRect().top ??
        null,
    }));
    obs('群视图下的设置按钮', groupBefore);
    assert(groupBefore.settingsButton, '群视图下左栏底部的设置按钮必须仍可见（修复群视图无入口）');
    assert(
      groupBefore.buttonTop < groupBefore.avatarTop,
      `群视图下按钮仍必须在用户头像块上方（按钮 top=${groupBefore.buttonTop} / 头像块 top=${groupBefore.avatarTop}）`,
    );
    await clickByTestId(page, 'global-settings-button');
    await page.waitForSelector('[data-testid="global-settings-menu"]', { timeout: 15000 });
    // ⑧ 群聊菜单打开：留图。
    if (process.env.SETTINGS_SHOT_GROUP) {
      const target = process.env.SETTINGS_SHOT_GROUP;
      await page.screenshot({ path: target, fullPage: false });
      console.log(`[SHOT] captured ${target}`);
    }
    await page.click('[data-testid="global-settings-item-templates"]');
    await page.waitForSelector('[data-testid="templates-page"]', { timeout: 15000 });
    const templateOpen = await page.evaluate(() => ({
      menu: document.querySelector('[data-testid="global-settings-menu"]') !== null,
      overlay: document.querySelector('[data-testid="panel-overlay"]') !== null,
      sidebar: document.querySelector('[data-testid="session-sidebar"]') !== null,
    }));
    obs('群视图打开模板配置后', templateOpen);
    assert(!templateOpen.menu, '点「模板配置」后菜单必须关闭');
    assert(templateOpen.overlay && templateOpen.sidebar, '模板页必须只盖主区，左栏仍可见');

    await page.click('[data-testid="templates-close"]');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="templates-page"]') === null,
      { timeout: 15000 },
    );
    const groupAfter = await page.evaluate(() => ({
      groupView: document.querySelector('[data-testid="group-view"]') !== null,
      title: document.querySelector('[data-testid="group-view"] h1')?.textContent ?? '',
      timelineItems: document.querySelectorAll('[data-testid="timeline-item"]').length,
    }));
    obs('关闭模板配置后的群视图', groupAfter);
    assert(groupAfter.groupView, '关闭模板页后必须仍在群视图（群不因打开管理页卸载）');
    assert(
      groupAfter.title === groupBefore.title,
      `群标题必须不变（前「${groupBefore.title}」/ 后「${groupAfter.title}」）`,
    );
    assert(
      groupAfter.timelineItems === groupBefore.timelineItems,
      `群时间线行数必须不变（前 ${groupBefore.timelineItems} / 后 ${groupAfter.timelineItems}）`,
    );

    // ⑥ 开合：Escape 关闭并把焦点还给按钮；点菜单外关闭；连点两次按钮是开 → 关。
    await clickByTestId(page, 'global-settings-button');
    await page.waitForSelector('[data-testid="global-settings-menu"]', { timeout: 15000 });
    await page.keyboard.press('Escape');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="global-settings-menu"]') === null,
      { timeout: 15000 },
    );
    const afterEscape = await page.evaluate(() => ({
      menu: document.querySelector('[data-testid="global-settings-menu"]') !== null,
      focused:
        document.activeElement?.getAttribute('data-testid') ??
        document.activeElement?.tagName ??
        null,
      expanded:
        document
          .querySelector('[data-testid="global-settings-button"]')
          ?.getAttribute('aria-expanded') ?? null,
    }));
    obs('Escape 之后', afterEscape);
    assert(!afterEscape.menu, 'Escape 必须关闭菜单');
    assert(
      afterEscape.focused === 'global-settings-button',
      `Escape 后焦点必须回到设置按钮，实测 ${afterEscape.focused}`,
    );
    assert(
      afterEscape.expanded === 'false',
      `Escape 后 aria-expanded 必须是 false，实测 ${afterEscape.expanded}`,
    );

    // 点菜单外（主区中部空白处）⇒ 关闭。
    await clickByTestId(page, 'global-settings-button');
    await page.waitForSelector('[data-testid="global-settings-menu"]', { timeout: 15000 });
    const mainBox = await page.evaluate(() => {
      const rect = document.querySelector('[data-testid="main-area"]')?.getBoundingClientRect();
      return rect === undefined
        ? null
        : { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    });
    assert(mainBox !== null, '必须能测到主区几何');
    await page.mouse.click(mainBox.left + mainBox.width / 2, mainBox.top + mainBox.height / 2);
    await page.waitForFunction(
      () => document.querySelector('[data-testid="global-settings-menu"]') === null,
      { timeout: 15000 },
    );
    const afterOutside = await page.evaluate(() => ({
      menu: document.querySelector('[data-testid="global-settings-menu"]') !== null,
      groupView: document.querySelector('[data-testid="group-view"]') !== null,
    }));
    obs('点菜单外之后', afterOutside);
    assert(!afterOutside.menu, '点菜单外必须关闭菜单');
    assert(afterOutside.groupView, '点菜单外不得切走群视图（点在主区中部是惰性的）');

    // 连点两次：开 → 关。
    await clickByTestId(page, 'global-settings-button');
    await page.waitForSelector('[data-testid="global-settings-menu"]', { timeout: 15000 });
    const firstClickOpened = await page.evaluate(
      () => document.querySelector('[data-testid="global-settings-menu"]') !== null,
    );
    await clickByTestId(page, 'global-settings-button');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="global-settings-menu"]') === null,
      { timeout: 15000 },
    );
    const secondClickClosed = await page.evaluate(
      () => document.querySelector('[data-testid="global-settings-menu"]') === null,
    );
    obs('连点两次按钮（第一次开 / 第二次关）', { firstClickOpened, secondClickClosed });
    assert(firstClickOpened && secondClickClosed, '连点两次按钮必须是开 → 关');

    // ⑦（复核）群视图下旧入口仍为 0。
    const legacyAfter = await page.evaluate(() => ({
      providers: document.querySelectorAll('[data-testid="open-providers"]').length,
      templates: document.querySelectorAll('[data-testid="open-templates"]').length,
    }));
    obs('群视图下的旧入口节点数', legacyAfter);
    assert(
      legacyAfter.providers === 0 && legacyAfter.templates === 0,
      `群视图下也不得出现旧入口（实测 ${JSON.stringify(legacyAfter)}）`,
    );
    assert(group.id, '夹具组必须存在');
  } finally {
    await page.close();
    await resetToBaseSingle('设置菜单清场单聊');
    // GROUP_DEFAULT 审计种子：与 1.4b 同一约定 —— 清场后重建一个组并排到首位，
    // 保证 `GROUP_KEEP=1` 之后的 design_audit 仍直接落在群聊主区。
    if (process.env.GROUP_DEFAULT === '1') {
      const seeded = await seedReactionGroup('审计组');
      auditGroupId = seeded.id;
    }
  }
});

// ---------------------------------------------------------------------------
// 工作路径（change `custom-workspace` 任务 8.3；返工任务 12.5 改成文件夹选择对话框）
//
// 判据以 **payload / 几何 / DOM 值**为准：假核心把每个 RPC 的 method+params 记进
// `rpcLog`；路径显示读元素文本与 `title`；截断读 scrollWidth/clientWidth 与行高；
// 目录列举读 `workspace.listDirs` 的请求形状；确认后的写 RPC payload 逐字断言。
//
// 用户明令「不喜欢手输路径」：交互是**点选** —— 点「切换」弹框 → 点目录进下一层 →
// 「上级」回退 → 「选择此目录」确认。返工 12.13 用户又明确要「像 Windows 资源管理器的
// 地址栏」：框内**有且仅有一个**可编辑路径输入框（`folder-picker-path`），它与当前显示的
// 文件夹双向同步，回车 / 「跳转」会把输入路径交给 `workspace.listDirs` 校验后导航。
// 所以这里断言的是「恰好一个地址栏 input」+ 同步 / 跳转行为，而不再是「框内没有任何输入」。
// 假目录树的常量（`LONG_WORKSPACE` / `WORKSPACE_NEW` / `PICKER_HOME` 等）在假核心
// 附近定义（`workspace.listDirs` 的 handler 与用例共用同一份夹具）。
// ---------------------------------------------------------------------------

/**
 * 点「切换」打开文件夹选择框，并等目录列表就绪（返工任务 12.5）。
 *
 * 单聊入口 `workspace-edit`、群入口 `group-workspace-edit` 共用同一套框内 testid。
 * 12.13 起当前路径是可编辑 input（读 `value`，不再是 `textContent`）。这里的 helper 保留
 * 旧只读 span 的 `textContent` 兜底，只为红跑期能先量到框高（12.12 的缺陷与地址栏无关）；
 * 框内形状由 WS.1 / WS.4 / WS.9 的「恰好一个可编辑 input」断言钉死，兜底不构成放松。
 */
async function openFolderPicker(page, editTestId) {
  await clickByTestId(page, editTestId);
  await page.waitForSelector('[data-testid="folder-picker"]', { timeout: 15000 });
  await page.waitForFunction(
    () => {
      const node = document.querySelector('[data-testid="folder-picker-path"]');
      const value = node instanceof HTMLInputElement ? node.value : (node?.textContent ?? '');
      return value.length > 0;
    },
    { timeout: 15000 },
  );
}

/** 读框内状态：当前路径（地址栏 value）/ 子目录按钮 / 输入框数量 / 上级按钮是否禁用。 */
async function readFolderPicker(page) {
  return page.evaluate(() => {
    const dialog = document.querySelector('[data-testid="folder-picker-dialog"]');
    const path = document.querySelector('[data-testid="folder-picker-path"]');
    return {
      role: dialog?.getAttribute('role') ?? null,
      ariaModal: dialog?.getAttribute('aria-modal') ?? null,
      path: path instanceof HTMLInputElement ? path.value : (path?.textContent ?? ''),
      title: path?.getAttribute('title') ?? null,
      pathTag: path?.tagName?.toLowerCase() ?? null,
      pathEditable:
        path instanceof HTMLInputElement && !path.readOnly && !path.disabled,
      entries: [...document.querySelectorAll('[data-testid="folder-picker-entry"]')].map(
        (button) => ({
          // 按钮里还有一个装饰性的「›」，名字用 `data-name`（与显示文本同源）。
          name: button.getAttribute('data-name') ?? (button.textContent ?? '').trim(),
          path: button.getAttribute('data-path'),
        }),
      ),
      inputs: dialog?.querySelectorAll('input, textarea').length ?? -1,
      empty: document.querySelector('[data-testid="folder-picker-empty"]') !== null,
      upDisabled: document.querySelector('[data-testid="folder-picker-up"]')?.disabled ?? null,
      confirmDisabled:
        document.querySelector('[data-testid="folder-picker-confirm"]')?.disabled ?? null,
      drivesHint:
        document.querySelector('[data-testid="folder-picker-drives-hint"]')?.textContent ?? null,
      loadError:
        document.querySelector('[data-testid="folder-picker-load-error"]')?.textContent ?? null,
      crumbs: [...document.querySelectorAll('[data-testid="folder-picker-crumb"]')].map(
        (button) => ({
          label: (button.textContent ?? '').trim(),
          path: button.getAttribute('data-path'),
        }),
      ),
    };
  });
}

/** 等框内地址栏显示成给定文本（盘符 / 「此电脑」/目录都走这一条）。 */
async function waitFolderPath(page, expected) {
  await page.waitForFunction(
    (value) => {
      const node = document.querySelector('[data-testid="folder-picker-path"]');
      const current = node instanceof HTMLInputElement ? node.value : (node?.textContent ?? '');
      return current === value;
    },
    { timeout: 15000 },
    expected,
  );
}

/** 点面包屑里 path 等于给定值的一段（返工任务 12.11：「此电脑」/盘符跳转）。 */
async function clickFolderCrumb(page, crumbPath) {
  const clicked = await page.evaluate((target) => {
    const button = [...document.querySelectorAll('[data-testid="folder-picker-crumb"]')].find(
      (entry) => entry.getAttribute('data-path') === target,
    );
    if (!button) return false;
    button.click();
    return true;
  }, crumbPath);
  assert(clicked, `面包屑里找不到「${crumbPath}」`);
}

/** 点框里的某个子目录（按名字）并等当前路径变成它的 `data-path`。 */
async function enterFolder(page, name) {
  const target = await page.evaluate((label) => {
    const button = [...document.querySelectorAll('[data-testid="folder-picker-entry"]')].find(
      (entry) => entry.getAttribute('data-name') === label,
    );
    if (!button) return null;
    button.click();
    return button.getAttribute('data-path');
  }, name);
  assert(target !== null, `文件夹选择框里找不到子目录「${name}」`);
  await page.waitForFunction(
    (expected) => {
      const node = document.querySelector('[data-testid="folder-picker-path"]');
      const current = node instanceof HTMLInputElement ? node.value : (node?.textContent ?? '');
      return current === expected;
    },
    { timeout: 15000 },
    target,
  );
  return target;
}

/** 把地址栏整体换成给定文本（聚焦 → Ctrl+A 全选 → 键入；受控 input 走键盘输入事件）。 */
async function replaceAddress(page, value) {
  await page.focus('[data-testid="folder-picker-path"]');
  await page.keyboard.down('Control');
  await page.keyboard.press('KeyA');
  await page.keyboard.up('Control');
  await page.keyboard.type(value);
}

await run('WS.1 单聊头部：路径逐字 + title 全文 + 单行截断 + 「切换」弹出文件夹选择框', async () => {
  await resetToBaseSingle('WS1 基础单聊');
  const withWorkspace = await seedSingle('WS1 长路径单聊', { workspace: LONG_WORKSPACE });
  await seedSingle('WS1 无路径单聊');
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS1 长路径单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    const displayed = await page.evaluate(() => {
      const element = document.querySelector('[data-testid="workspace-path"]');
      const header = element?.closest('header');
      const rect = element.getBoundingClientRect();
      return {
        text: element?.textContent ?? '',
        title: element?.getAttribute('title'),
        height: rect.height,
        whiteSpace: getComputedStyle(element).whiteSpace,
        scrollWidth: element?.scrollWidth ?? 0,
        clientWidth: element?.clientWidth ?? 0,
        headerOverflow: header ? header.scrollWidth - header.clientWidth : null,
      };
    });
    obs('单聊工作路径显示', displayed);
    assert(withWorkspace.id, '夹具必须返回会话 id');
    assert(displayed.text === LONG_WORKSPACE, `路径必须逐字显示，实测「${displayed.text}」`);
    assert(displayed.title === LONG_WORKSPACE, `title 必须是全文，实测「${displayed.title}」`);
    assert(
      displayed.whiteSpace === 'nowrap',
      `路径必须单行（nowrap），实测 ${displayed.whiteSpace}`,
    );
    assert(displayed.height <= 24, `路径必须单行不换行，实测高度 ${displayed.height}`);
    assert(
      displayed.scrollWidth > displayed.clientWidth,
      `长路径必须真的被截断（scrollWidth ${displayed.scrollWidth} / clientWidth ${displayed.clientWidth}）`,
    );
    assert(
      displayed.headerOverflow !== null && displayed.headerOverflow <= 1,
      `头部不得横向溢出，实测 ${displayed.headerOverflow}`,
    );

    // 「切换」= 弹文件夹选择框（起点 = 该会话的工作路径），不是展开输入框。
    const start = rpcLog.length;
    await openFolderPicker(page, 'workspace-edit');
    const picker = await readFolderPicker(page);
    const listCall = rpcLog.slice(start).find((entry) => entry.method === 'workspace.listDirs');
    obs('文件夹选择框', picker);
    obs('workspace.listDirs 请求', listCall?.params);
    assert(
      picker.role === 'dialog' && picker.ariaModal === 'true',
      `必须是模态对话框（role=dialog / aria-modal=true），实测 ${picker.role}/${picker.ariaModal}`,
    );
    assert(
      picker.path === LONG_WORKSPACE,
      `框内当前路径必须是会话的工作路径，实测「${picker.path}」`,
    );
    assert(picker.title === LONG_WORKSPACE, '框内当前路径的 title 必须是全文');
    // 返工 12.13（用户要求可编辑地址栏）：框内有且仅有一个 input，就是地址栏且可编辑。
    assert(picker.inputs === 1, `框内必须恰好一个输入框（地址栏），实测 ${picker.inputs}`);
    assert(
      picker.pathTag === 'input' && picker.pathEditable,
      `框内当前路径必须是可编辑 input，实测 ${picker.pathTag}/${picker.pathEditable}`,
    );
    assert(
      JSON.stringify(picker.entries.map((entry) => entry.name)) ===
        JSON.stringify(['alpha', 'beta', 'locked']),
      `框内必须列出子目录（按名字排序），实测 ${JSON.stringify(picker.entries.map((entry) => entry.name))}`,
    );
    assert(
      listCall?.params?.path === LONG_WORKSPACE,
      `列举请求必须带该会话的工作路径，实测 ${JSON.stringify(listCall?.params)}`,
    );

    // 「取消」关框，且不发任何写请求。
    const writesBefore = rpcLog.length;
    await clickByTestId(page, 'folder-picker-cancel');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="folder-picker"]') === null,
      { timeout: 15000 },
    );
    const writes = rpcLog.slice(writesBefore).map((entry) => entry.method);
    obs('取消后的请求', writes);
    assert(!writes.some((method) => method.endsWith('setWorkspace')), '取消不得发写请求');
  } finally {
    await page.close();
  }
});

await run('WS.2 单聊切换：浏览 → 上级 → 选择此目录 → session.setWorkspace payload；失败在框内可归因', async () => {
  await resetToBaseSingle('WS2 基础单聊');
  const withWorkspace = await seedSingle('WS2 长路径单聊', { workspace: LONG_WORKSPACE });
  await seedSingle('WS2 无路径单聊');
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS2 长路径单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    const before = await page.evaluate((sessionId) => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      selected:
        document
          .querySelector(`[data-session-id="${sessionId}"]`)
          ?.getAttribute('aria-current') ?? null,
      messages: document.querySelectorAll('[data-testid="message-row"]').length,
    }), withWorkspace.id);

    // 点选：进入子目录（叶子显示空态）→「上级」回到起点。
    await openFolderPicker(page, 'workspace-edit');
    const entered = await enterFolder(page, 'beta');
    obs('进入子目录后的当前路径', entered);
    assert(
      entered === `${LONG_WORKSPACE}\\beta`,
      `进入子目录后的路径必须逐字，实测「${entered}」`,
    );
    const insideLeaf = await readFolderPicker(page);
    obs('叶子目录的框内状态', insideLeaf);
    assert(insideLeaf.empty, '叶子目录必须显示「没有子文件夹」的空态');
    assert(insideLeaf.entries.length === 0, '叶子目录的子目录列表必须为空');
    await clickByTestId(page, 'folder-picker-up');
    await waitFolderPath(page, LONG_WORKSPACE);
    const afterUp = await readFolderPicker(page);
    obs('上级回退后', afterUp);
    assert(afterUp.path === LONG_WORKSPACE, '「上级」必须回到上一级目录');
    assert(
      afterUp.entries.length === 3,
      `上级回退后必须重新列出子目录，实测 ${afterUp.entries.length}`,
    );

    // 选中 alpha 并确认：payload 逐字、界面更新、选中/消息不变、框关闭。
    await enterFolder(page, 'alpha');
    const start = rpcLog.length;
    await clickByTestId(page, 'folder-picker-confirm');
    await waitFor(
      () => rpcLog.slice(start).some((entry) => entry.method === 'session.setWorkspace'),
      '发出 session.setWorkspace',
    );
    const call = rpcLog.slice(start).find((entry) => entry.method === 'session.setWorkspace');
    obs('session.setWorkspace payload', call.params);
    assert(
      call.params.sessionId === withWorkspace.id,
      `payload.sessionId 必须是当前会话，实测 ${call.params.sessionId}`,
    );
    assert(
      call.params.workspace === WORKSPACE_NEW,
      `payload.workspace 必须逐字，实测 ${call.params.workspace}`,
    );
    await page.waitForFunction(
      (expected) =>
        document.querySelector('[data-testid="workspace-path"]')?.textContent === expected,
      { timeout: 15000 },
      WORKSPACE_NEW,
    );
    const pickerClosed = (await page.$('[data-testid="folder-picker"]')) === null;
    const after = await page.evaluate((sessionId) => ({
      title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
      selected:
        document
          .querySelector(`[data-session-id="${sessionId}"]`)
          ?.getAttribute('aria-current') ?? null,
      messages: document.querySelectorAll('[data-testid="message-row"]').length,
    }), withWorkspace.id);
    obs('切换成功后', { before, after, pickerClosed });
    assert(pickerClosed, '确认成功后对话框必须关闭');
    assert(after.title === before.title, '切换不得改变当前选中会话 / 标题');
    assert(after.selected === 'true', '切换不得丢选中态');
    assert(after.messages === before.messages, '切换不得改变消息列表');

    // 核心拒绝（目录不可用）：框内就地错误、框不关、已保存路径不变。
    // 当前工作路径已是 alpha（叶子），先「上级」回到含 locked 的那一层再点进去。
    await setGroupFlags(`workspaceFailPath=${encodeURIComponent(WORKSPACE_BAD)}`);
    await openFolderPicker(page, 'workspace-edit');
    await clickByTestId(page, 'folder-picker-up');
    await waitFolderPath(page, LONG_WORKSPACE);
    await enterFolder(page, 'locked');
    await clickByTestId(page, 'folder-picker-confirm');
    await page.waitForSelector('[data-testid="folder-picker-error"]', { timeout: 15000 });
    const failure = await page.evaluate(() => ({
      error: document.querySelector('[data-testid="folder-picker-error"]')?.textContent ?? '',
      path: document.querySelector('[data-testid="folder-picker-path"]')?.value ?? '',
      open: document.querySelector('[data-testid="folder-picker"]') !== null,
      saved: document.querySelector('[data-testid="workspace-path"]')?.textContent ?? '',
    }));
    obs('保存失败后', failure);
    assert(failure.error.includes(WORKSPACE_BAD), `错误必须含路径，实测「${failure.error}」`);
    assert(failure.error.includes('不可用'), `错误必须含原因，实测「${failure.error}」`);
    assert(failure.open, '保存失败时对话框必须保持打开');
    assert(failure.saved === WORKSPACE_NEW, '保存失败时已保存路径的显示必须不变');
    assert(failure.path === WORKSPACE_BAD, '失败时框内仍停在选中的目录（不偷偷改写）');
    await clickByTestId(page, 'folder-picker-cancel');

    // 切到另一个未设置工作区的会话：显示缺省文案；框的起点是核心的主目录。
    await clickSessionRow(page, 'WS2 无路径单聊');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="workspace-path"]')?.textContent === '缺省（应用主目录）',
      { timeout: 15000 },
    );
    const defaultLabel = await page.$eval(
      '[data-testid="workspace-path"]',
      (element) => element.textContent,
    );
    obs('未设置会话的缺省文案', defaultLabel);
    assert(defaultLabel === '缺省（应用主目录）', '未设置工作区必须显示缺省文案');

    const homeStart = rpcLog.length;
    await openFolderPicker(page, 'workspace-edit');
    const homePicker = await readFolderPicker(page);
    const homeCall = rpcLog.slice(homeStart).find((entry) => entry.method === 'workspace.listDirs');
    obs('未设置会话的框起点', { path: homePicker.path, params: homeCall?.params });
    assert(
      homePicker.path === PICKER_HOME,
      `未设置工作区时框的起点必须是核心主目录，实测「${homePicker.path}」`,
    );
    assert(
      homeCall?.params?.path === undefined,
      `未设置时列举请求必须省略 path（起点由核心给），实测 ${JSON.stringify(homeCall?.params)}`,
    );
    assert(
      JSON.stringify(homePicker.entries.map((entry) => entry.name)) ===
        JSON.stringify(['Documents', 'Projects']),
      `主目录的子目录必须列出来，实测 ${JSON.stringify(homePicker.entries.map((entry) => entry.name))}`,
    );
    await clickByTestId(page, 'folder-picker-cancel');
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

await run('WS.3 空选中：单聊工作路径控件不渲染（节点数 0）', async () => {
  await resetToBaseSingle('WS3 唯一单聊');
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await deleteFirstSessionRow(page);
    await page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="current-session-title"]')
          ?.textContent?.includes('（未选择会话）') === true,
      { timeout: 15000 },
    );
    const counts = await page.evaluate(() => ({
      path: document.querySelectorAll('[data-testid="workspace-path"]').length,
      edit: document.querySelectorAll('[data-testid="workspace-edit"]').length,
      picker: document.querySelectorAll('[data-testid="folder-picker"]').length,
      legacyInput: document.querySelectorAll('[data-testid="workspace-input"]').length,
    }));
    obs('空选中的单聊工作路径控件', counts);
    assert(counts.path === 0, '空选中不得渲染 workspace-path');
    assert(counts.edit === 0, '空选中不得渲染切换按钮');
    assert(counts.picker === 0, '空选中不得渲染文件夹选择框');
    assert(counts.legacyInput === 0, '手输路径的旧编辑器必须已撤除');
  } finally {
    await page.close();
  }
});

await run('WS.4 群右栏「群工作路径」：在成员名单之上 + 切换 payload + 刷新不丢 + 只装工作路径', async () => {
  await resetToBaseSingle('WS4 基础单聊');
  const seeded = await seedWorkspaceGroup('WS4 工作区组', LONG_WORKSPACE);
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS4 工作区组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="group-workspace"]', { timeout: 15000 });
    const layout = await page.evaluate(() => {
      const card = document.querySelector('[data-testid="group-workspace"]');
      const list = document.querySelector('[data-testid="group-members-list"]');
      const aside = document.querySelector('#group-members');
      const path = document.querySelector('[data-testid="group-workspace-path"]');
      return {
        cardTop: card.getBoundingClientRect().top,
        listTop: list.getBoundingClientRect().top,
        insideAside: aside?.contains(card) ?? false,
        path: path?.textContent ?? '',
        title: path?.getAttribute('title'),
      };
    });
    obs('群工作路径栏几何与显示', layout);
    assert(layout.path === LONG_WORKSPACE, `群路径必须逐字显示，实测「${layout.path}」`);
    assert(layout.title === LONG_WORKSPACE, `群路径 title 必须是全文，实测「${layout.title}」`);
    assert(layout.cardTop < layout.listTop, '「群工作路径」栏必须在成员名单之上');
    assert(layout.insideAside, '该栏必须在 id=group-members 的右栏内');

    // 这一栏只装工作路径：没有多行输入 / 可编辑块 / 公告类按钮。
    const shape = await page.evaluate(() => {
      const card = document.querySelector('[data-testid="group-workspace"]');
      return {
        textareas: card.querySelectorAll('textarea').length,
        editables: card.querySelectorAll('[contenteditable]').length,
        buttons: [...card.querySelectorAll('button')].map((button) => button.textContent?.trim() ?? ''),
      };
    });
    obs('群工作路径栏的元素形状', shape);
    assert(shape.textareas === 0, '该栏不得有 textarea（不是公告正文）');
    assert(shape.editables === 0, '该栏不得有 contenteditable 元素');
    assert(
      JSON.stringify(shape.buttons) === JSON.stringify(['切换']),
      `这一栏的按钮只允许「切换」（浏览在对话框里），实测 ${JSON.stringify(shape.buttons)}`,
    );

    const before = await page.evaluate(() => ({
      members: document.querySelectorAll('[data-testid^="member-name-"]').length,
      timeline: document.querySelectorAll('[data-testid="timeline-item"]').length,
    }));
    const listStart = rpcLog.length;
    await openFolderPicker(page, 'group-workspace-edit');
    const listCall = rpcLog.slice(listStart).find((entry) => entry.method === 'workspace.listDirs');
    const picker = await readFolderPicker(page);
    obs('群工作路径的文件夹选择框', picker);
    obs('群的 workspace.listDirs 请求', listCall?.params);
    assert(
      picker.path === LONG_WORKSPACE,
      `群选择框的起点必须是组的工作路径，实测「${picker.path}」`,
    );
    assert(picker.inputs === 1, `框内必须恰好一个输入框（地址栏），实测 ${picker.inputs}`);
    assert(
      listCall?.params?.path === LONG_WORKSPACE,
      `群的列举请求必须带组的工作路径，实测 ${JSON.stringify(listCall?.params)}`,
    );

    // 模态层级：必须盖住群视图顶栏（`relative z-30`），否则顶栏会画在框上面。
    const covered = await page.evaluate(() => {
      const header = document.querySelector('[data-testid="group-view"] header');
      const dialog = document.querySelector('[data-testid="folder-picker"]');
      if (!header || !dialog) return { hitInsideDialog: false, headerZ: null, dialogZ: null };
      const rect = header.getBoundingClientRect();
      const hit = document.elementFromPoint(
        rect.left + rect.width / 2,
        rect.top + rect.height / 2,
      );
      return {
        hitInsideDialog: dialog.contains(hit),
        headerZ: getComputedStyle(header).zIndex,
        dialogZ: getComputedStyle(dialog).zIndex,
      };
    });
    obs('选择框与群顶栏的层级', covered);
    assert(
      covered.hitInsideDialog,
      '文件夹选择框必须盖住群视图顶栏（顶栏中心的命中元素必须在框内）',
    );
    assert(
      Number(covered.dialogZ) > Number(covered.headerZ),
      `选择框 z-index 必须高于群顶栏，实测 ${covered.dialogZ} / ${covered.headerZ}`,
    );

    const start = rpcLog.length;
    await enterFolder(page, 'beta');
    await clickByTestId(page, 'folder-picker-confirm');
    await waitFor(
      () => rpcLog.slice(start).some((entry) => entry.method === 'group.setWorkspace'),
      '发出 group.setWorkspace',
    );
    const call = rpcLog.slice(start).find((entry) => entry.method === 'group.setWorkspace');
    obs('group.setWorkspace payload', call.params);
    assert(call.params.groupId === seeded.id, `payload.groupId 必须是该组，实测 ${call.params.groupId}`);
    assert(
      call.params.workspace === WORKSPACE_GROUP_NEW,
      `payload.workspace 必须逐字，实测 ${call.params.workspace}`,
    );
    await page.waitForFunction(
      (expected) =>
        document.querySelector('[data-testid="group-workspace-path"]')?.textContent === expected,
      { timeout: 15000 },
      WORKSPACE_GROUP_NEW,
    );
    const after = await page.evaluate(() => ({
      members: document.querySelectorAll('[data-testid^="member-name-"]').length,
      timeline: document.querySelectorAll('[data-testid="timeline-item"]').length,
    }));
    obs('切换成功后成员/时间线', { before, after });
    const pickerClosed = (await page.$('[data-testid="folder-picker"]')) === null;
    assert(pickerClosed, '群确认成功后对话框必须关闭');
    assert(after.members === before.members, '切换工作路径不得丢成员名单');
    assert(after.timeline === before.timeline, '切换工作路径不得丢时间线');

    const methods = rpcLog.slice(listStart).map((entry) => entry.method);
    assert(!methods.includes('session.setWorkspace'), '群切换不得发出 session.setWorkspace');
    assert(
      !methods.some((method) => method.includes('announce')),
      `群切换不得发公告类 RPC，实测 ${JSON.stringify(methods)}`,
    );
    const singleControlCount = (await page.$$('[data-testid="workspace-path"]')).length;
    assert(singleControlCount === 0, '群聊主区不得渲染单聊的工作路径控件');
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

await run('WS.5 群工作路径：选择框内失败可归因；链运行中「切换」禁用且不发写请求', async () => {
  await resetToBaseSingle('WS5 基础单聊');
  const seeded = await seedWorkspaceGroup('WS5 工作区组', LONG_WORKSPACE);
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS5 工作区组');
    await page.waitForSelector('[data-testid="group-workspace-path"]', { timeout: 15000 });

    // 失败态：框内就地错误、框保持打开、已保存路径不变。
    await setGroupFlags(`workspaceFailPath=${encodeURIComponent(WORKSPACE_BAD)}`);
    await openFolderPicker(page, 'group-workspace-edit');
    await enterFolder(page, 'locked');
    await clickByTestId(page, 'folder-picker-confirm');
    await page.waitForSelector('[data-testid="folder-picker-error"]', { timeout: 15000 });
    const failure = await page.evaluate(() => ({
      error: document.querySelector('[data-testid="folder-picker-error"]')?.textContent ?? '',
      path: document.querySelector('[data-testid="group-workspace-path"]')?.textContent ?? '',
      open: document.querySelector('[data-testid="folder-picker"]') !== null,
    }));
    obs('群保存失败后', failure);
    assert(failure.error.includes(WORKSPACE_BAD), '群错误必须含路径');
    assert(failure.error.includes('不可用'), '群错误必须含原因');
    assert(failure.open, '群保存失败时对话框必须保持打开');
    assert(failure.path === LONG_WORKSPACE, '群保存失败时已保存路径不变');
    await clickByTestId(page, 'folder-picker-cancel');

    // 链运行中：切换按钮禁用且有可读原因；点击不发写请求。
    await setGroupFlags(`busyFor=${encodeURIComponent(seeded.id)}`);
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS5 工作区组');
    await page.waitForSelector('[data-testid="group-workspace"]', { timeout: 15000 });
    const disabled = await page.$eval('[data-testid="group-workspace-edit"]', (element) => ({
      disabled: element.disabled === true,
      ariaDisabled: element.getAttribute('aria-disabled'),
      title: element.getAttribute('title'),
    }));
    obs('链运行中的切换按钮', disabled);
    assert(disabled.disabled, '链运行中「切换」必须禁用');
    assert(disabled.title !== null && disabled.title.length > 0, '禁用必须给出可读原因（title）');
    const start = rpcLog.length;
    await page.click('[data-testid="group-workspace-edit"]');
    await new Promise((resolve) => setTimeout(resolve, 200));
    const writes = rpcLog.slice(start).filter((entry) => entry.method === 'group.setWorkspace');
    obs('链运行中点击后的写请求', writes);
    assert(writes.length === 0, '链运行中点击不得发出 group.setWorkspace');
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

await run('WS.6 窄屏 720px：群工作路径栏随成员抽屉可见、页面无横向溢出', async () => {
  await resetToBaseSingle('WS6 基础单聊');
  await seedWorkspaceGroup('WS6 工作区组', LONG_WORKSPACE);
  await setGroupFlags('reset=1');
  const page = await openPage(720, 900);
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS6 工作区组');
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 15000 });
    const hiddenBefore = await page.evaluate(() => {
      const card = document.querySelector('[data-testid="group-workspace"]');
      const aside = document.querySelector('#group-members');
      return {
        cardVisible: card !== null && card.getBoundingClientRect().width > 0,
        asideDisplay: aside ? getComputedStyle(aside).display : null,
      };
    });
    obs('窄屏抽屉打开前', hiddenBefore);
    await clickByTestId(page, 'group-members-toggle');
    await page.waitForFunction(
      () => {
        const card = document.querySelector('[data-testid="group-workspace"]');
        const aside = document.querySelector('#group-members');
        return (
          card !== null &&
          card.getBoundingClientRect().width > 0 &&
          aside !== null &&
          getComputedStyle(aside).display !== 'none'
        );
      },
      { timeout: 15000 },
    );
    const drawer = await page.evaluate(() => {
      const card = document.querySelector('[data-testid="group-workspace"]');
      const aside = document.querySelector('#group-members');
      const overview = document.querySelector('[data-testid="session-list"]');
      const rect = card.getBoundingClientRect();
      return {
        insideAside: aside?.contains(card) ?? false,
        width: rect.width,
        docScrollWidth: document.documentElement.scrollWidth,
        innerWidth: window.innerWidth,
        listVisible: overview !== null && overview.getBoundingClientRect().width > 0,
      };
    });
    obs('窄屏抽屉里的工作路径栏', drawer);
    assert(drawer.insideAside, '窄屏时栏必须在成员抽屉（#group-members）里');
    assert(drawer.width > 0, '窄屏抽屉里的栏必须可见（有宽度）');
    assert(
      drawer.docScrollWidth <= drawer.innerWidth + 1,
      `页面不得横向溢出（${drawer.docScrollWidth} > ${drawer.innerWidth}）`,
    );
    assert(drawer.listVisible, '打开成员抽屉不得覆盖 / 隐藏会话列表');
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

await run('WS.7 文件夹很多时：选择框高度受视口限制（不撑满）+ 列表框内滚动', async () => {
  await resetToBaseSingle('WS7 基础单聊');
  await seedSingle('WS7 多子目录单聊', { workspace: PICKER_CROWDED });
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS7 多子目录单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    await openFolderPicker(page, 'workspace-edit');
    const geometry = await page.evaluate(() => {
      const dialog = document.querySelector('[data-testid="folder-picker-dialog"]');
      const list = document.querySelector('[data-testid="folder-picker-list"]');
      const rect = dialog.getBoundingClientRect();
      const listRect = list.getBoundingClientRect();
      return {
        dialogHeight: rect.height,
        dialogWidth: rect.width,
        dialogTop: rect.top,
        dialogBottom: rect.bottom,
        dialogCenter: rect.top + rect.height / 2,
        viewportHeight: window.innerHeight,
        viewportWidth: window.innerWidth,
        viewportCenter: window.innerHeight / 2,
        listHeight: listRect.height,
        listClientHeight: list.clientHeight,
        listScrollHeight: list.scrollHeight,
        entries: document.querySelectorAll('[data-testid="folder-picker-entry"]').length,
      };
    });
    obs('多目录选择框几何（框高 / 视口高 / 列表滚动量）', geometry);
    assert(
      geometry.entries === PICKER_CROWDED_CHILDREN.length,
      `夹具必须渲染 ${PICKER_CROWDED_CHILDREN.length} 个子目录，实测 ${geometry.entries}`,
    );
    assert(
      geometry.dialogHeight <= geometry.viewportHeight * 0.8,
      `选择框高度必须明显小于视口（≤0.8×${geometry.viewportHeight}px），实测 ${geometry.dialogHeight}px`,
    );
    assert(
      geometry.dialogBottom <= geometry.viewportHeight,
      `选择框底边不得超出视口，实测底边 ${geometry.dialogBottom} / 视口 ${geometry.viewportHeight}`,
    );
    assert(
      Math.abs(geometry.dialogCenter - geometry.viewportCenter) <= 1,
      `选择框必须垂直居中（中心 ${geometry.dialogCenter} / 视口中心 ${geometry.viewportCenter}）`,
    );
    assert(
      geometry.listScrollHeight > geometry.listClientHeight + 1,
      `子目录多时列表必须在框内滚动（scrollHeight ${geometry.listScrollHeight} / clientHeight ${geometry.listClientHeight}）`,
    );
    assert(
      geometry.listHeight > 0 && geometry.listHeight <= geometry.dialogHeight,
      `列表必须真实占据框内高度，实测列表 ${geometry.listHeight} / 框 ${geometry.dialogHeight}`,
    );
    assert(
      geometry.dialogWidth < geometry.viewportWidth * 0.8,
      `选择框宽度必须紧凑（≤0.8×${geometry.viewportWidth}px），实测 ${geometry.dialogWidth}px`,
    );

    // 返工 12.12：框高必须**固定**，不能随子目录数量伸缩（max-height 会随内容跳变）。
    // 40 个子目录 → 点进一个空叶子 → 再「上级」回来，三次框高必须一致。
    const crowdedHeight = geometry.dialogHeight;
    await enterFolder(page, PICKER_CROWDED_CHILDREN[0]);
    const leaf = await page.evaluate(() => {
      const dialog = document.querySelector('[data-testid="folder-picker-dialog"]');
      const list = document.querySelector('[data-testid="folder-picker-list"]');
      return {
        dialogHeight: dialog.getBoundingClientRect().height,
        entries: document.querySelectorAll('[data-testid="folder-picker-entry"]').length,
        listScrollHeight: list.scrollHeight,
        listClientHeight: list.clientHeight,
      };
    });
    obs('空叶子目录的框高（12.12 固定高度）', {
      dialogHeight: leaf.dialogHeight,
      crowdedHeight,
      viewportHeight: geometry.viewportHeight,
      entries: leaf.entries,
      listScrollHeight: leaf.listScrollHeight,
      listClientHeight: leaf.listClientHeight,
    });
    assert(leaf.entries === 0, `叶子目录必须没有子目录，实测 ${leaf.entries}`);
    assert(
      Math.abs(leaf.dialogHeight - crowdedHeight) <= 1,
      `导航到子目录少的文件夹后框高必须不变（多目录 ${crowdedHeight}px / 空叶子 ${leaf.dialogHeight}px）`,
    );
    assert(
      leaf.listScrollHeight <= leaf.listClientHeight + 1,
      `空叶子目录列表不该有滚动量（${leaf.listScrollHeight}/${leaf.listClientHeight}）`,
    );
    await clickByTestId(page, 'folder-picker-up');
    await waitFolderPath(page, PICKER_CROWDED);
    const backHeight = await page.evaluate(
      () =>
        document.querySelector('[data-testid="folder-picker-dialog"]').getBoundingClientRect()
          .height,
    );
    obs('「上级」返回多目录后的框高（12.12 固定高度）', {
      backHeight,
      crowdedHeight,
      viewportHeight: geometry.viewportHeight,
    });
    assert(
      Math.abs(backHeight - crowdedHeight) <= 1,
      `「上级」返回多目录后框高必须仍不变（首次 ${crowdedHeight}px / 返回 ${backHeight}px）`,
    );

    if (process.env.WORKSPACE_SHOT_CROWDED) {
      await new Promise((resolve) => setTimeout(resolve, 300));
      const target = process.env.WORKSPACE_SHOT_CROWDED;
      await page.screenshot({ path: target, fullPage: false });
      console.log(`[SHOT] captured ${target}`);
    }
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

await run('WS.8 Windows 多盘：盘符根 →「此电脑」→ 盘符列表 → 点盘进入；drives 根不可选', async () => {
  await resetToBaseSingle('WS8 基础单聊');
  await seedSingle('WS8 浅路径单聊', { workspace: 'C:\\work' });
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS8 浅路径单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    await openFolderPicker(page, 'workspace-edit');
    const atWork = await readFolderPicker(page);
    obs('C:\\work 的框内状态', atWork);
    assert(atWork.path === 'C:\\work', `起点必须是 C:\\work，实测「${atWork.path}」`);
    assert(
      atWork.entries.some((entry) => entry.name === LONG_SEGMENTS[0]),
      'C:\\work 必须列出它的子目录',
    );

    // ① 盘符根：上级从 C:\work 回到 C:\（盘符根，不再是「到顶」）。
    await clickByTestId(page, 'folder-picker-up');
    await waitFolderPath(page, 'C:\\');
    const atDriveRoot = await readFolderPicker(page);
    obs('C:\\（盘符根）的框内状态', atDriveRoot);
    assert(atDriveRoot.upDisabled === false, '盘符根必须还能「上级」到「此电脑」');
    assert(
      JSON.stringify(atDriveRoot.entries.map((entry) => entry.name)) ===
        JSON.stringify(['crowded', 'work']),
      `C:\\ 必须列出盘符根子目录，实测 ${JSON.stringify(atDriveRoot.entries.map((entry) => entry.name))}`,
    );

    // ② 再上级 → 「此电脑」：列出 C:/D:，drives 根不可被选成工作路径。
    const upStart = rpcLog.length;
    await clickByTestId(page, 'folder-picker-up');
    await waitFolderPath(page, '此电脑');
    const drives = await readFolderPicker(page);
    const drivesCall = rpcLog.slice(upStart).find((entry) => entry.method === 'workspace.listDirs');
    obs('「此电脑」的框内状态与请求', { drives, params: drivesCall?.params });
    assert(
      JSON.stringify(drives.entries.map((entry) => entry.name)) ===
        JSON.stringify(['C:', 'D:']),
      `「此电脑」必须列出各盘，实测 ${JSON.stringify(drives.entries.map((entry) => entry.name))}`,
    );
    assert(
      drivesCall?.params?.path === PICKER_DRIVES_ROOT,
      `「此电脑」的列举请求必须带 sentinel，实测 ${JSON.stringify(drivesCall?.params)}`,
    );
    assert(drives.upDisabled === true, '「此电脑」再往上没有层：上级必须禁用');
    assert(
      JSON.stringify(drives.crumbs) ===
        JSON.stringify([{ label: '此电脑', path: PICKER_DRIVES_ROOT }]),
      `「此电脑」的面包屑必须是单段，实测 ${JSON.stringify(drives.crumbs)}`,
    );
    assert(drives.confirmDisabled === true, '「此电脑」不是目录：确认按钮必须禁用');
    assert(
      (drives.drivesHint ?? '').includes('不是目录'),
      `「此电脑」必须给出不可选的原因提示，实测「${drives.drivesHint}」`,
    );
    const writesBefore = rpcLog.length;
    await page.evaluate(() => {
      document.querySelector('[data-testid="folder-picker-confirm"]')?.click();
    });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const blockedWrites = rpcLog
      .slice(writesBefore)
      .filter((entry) => entry.method.endsWith('setWorkspace'));
    obs('drives 根点确认后的写请求', blockedWrites);
    assert(blockedWrites.length === 0, '「此电脑」不得被选成工作路径（不发写请求）');

    // ③ 点 D: 进入；面包屑回到「此电脑」；再从 C: 回来，验证多盘可达。
    await enterFolder(page, 'D:');
    const atD = await readFolderPicker(page);
    obs('D:\\ 的框内状态', atD);
    assert(atD.path === 'D:\\', `点盘符必须进入 D:\\，实测「${atD.path}」`);
    assert(
      JSON.stringify(atD.entries.map((entry) => entry.name)) === JSON.stringify(['projects']),
      `D:\\ 必须列出它的子目录，实测 ${JSON.stringify(atD.entries.map((entry) => entry.name))}`,
    );
    assert(
      JSON.stringify(atD.crumbs) ===
        JSON.stringify([
          { label: '此电脑', path: PICKER_DRIVES_ROOT },
          { label: 'D:', path: 'D:\\' },
        ]),
      `D:\\ 的面包屑必须是「此电脑 → D:」，实测 ${JSON.stringify(atD.crumbs)}`,
    );

    await clickFolderCrumb(page, PICKER_DRIVES_ROOT);
    await waitFolderPath(page, '此电脑');
    const backAtDrives = await readFolderPicker(page);
    assert(
      backAtDrives.entries.length === 2,
      `点面包屑「此电脑」必须回到盘符列表，实测 ${backAtDrives.entries.length} 项`,
    );

    // ④ 跨盘切换真的写进工作路径：D:\projects → session.setWorkspace payload。
    await enterFolder(page, 'D:');
    await enterFolder(page, 'projects');
    const start = rpcLog.length;
    await clickByTestId(page, 'folder-picker-confirm');
    await waitFor(
      () => rpcLog.slice(start).some((entry) => entry.method === 'session.setWorkspace'),
      '发出跨盘 session.setWorkspace',
    );
    const call = rpcLog.slice(start).find((entry) => entry.method === 'session.setWorkspace');
    obs('跨盘 session.setWorkspace payload', call.params);
    assert(
      call.params.workspace === 'D:\\projects',
      `跨盘选择必须逐字提交 D:\\projects，实测 ${call.params.workspace}`,
    );
    await page.waitForFunction(
      (expected) =>
        document.querySelector('[data-testid="workspace-path"]')?.textContent === expected,
      { timeout: 15000 },
      'D:\\projects',
    );
    assert(
      (await page.$('[data-testid="folder-picker"]')) === null,
      '跨盘确认成功后对话框必须关闭',
    );
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

// 返工 12.13（2026-11-28 用户原话「你仍然需要给我一个路径输入框，和一个真正的 windows
// 文件浏览器一样，路径输入和显示的文件夹对应」）：地址栏 input 与当前文件夹双向同步；
// 合法路径回车 / 「跳转」导航，非法路径就地报错、不跳、地址栏回到当前文件夹。
await run('WS.9 可编辑地址栏：值与当前文件夹同步；合法路径跳转；非法路径报错不跳（12.13）', async () => {
  await resetToBaseSingle('WS9 基础单聊');
  await seedSingle('WS9 地址栏单聊', { workspace: LONG_WORKSPACE });
  await setGroupFlags('reset=1');
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS9 地址栏单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    await openFolderPicker(page, 'workspace-edit');

    const opened = await readFolderPicker(page);
    obs('打开时的地址栏', {
      value: opened.path,
      tag: opened.pathTag,
      editable: opened.pathEditable,
      inputs: opened.inputs,
      title: opened.title,
    });
    assert(opened.inputs === 1, `框内必须恰好一个输入框（地址栏），实测 ${opened.inputs}`);
    assert(
      opened.pathTag === 'input' && opened.pathEditable,
      `地址栏必须是可编辑 input，实测 ${opened.pathTag}/${opened.pathEditable}`,
    );
    assert(
      opened.path === LONG_WORKSPACE,
      `地址栏初值必须是当前文件夹路径，实测「${opened.path}」`,
    );
    assert(opened.title === LONG_WORKSPACE, `地址栏 title 必须是全文，实测「${opened.title}」`);

    // ① 点文件夹：地址栏跟着变（浏览 → 地址栏自动同步）。
    const entered = await enterFolder(page, 'beta');
    const afterEnter = await readFolderPicker(page);
    obs('点 beta 后的地址栏', {
      value: afterEnter.path,
      expected: entered,
      crumbs: afterEnter.crumbs,
    });
    assert(
      afterEnter.path === entered,
      `点文件夹后地址栏必须同步，实测「${afterEnter.path}」/ 期望「${entered}」`,
    );

    // ② 合法路径 + Enter：导航（列表 / 面包屑 / 请求参数一起变），不发写请求。
    const legal = `${PICKER_CROWDED}\\${PICKER_CROWDED_CHILDREN[1]}`;
    await replaceAddress(page, legal);
    const typedLegal = await page.$eval(
      '[data-testid="folder-picker-path"]',
      (element) => element.value,
    );
    obs('键入后的地址栏', { value: typedLegal, expected: legal });
    assert(typedLegal === legal, `地址栏必须接受键入并整体替换，实测「${typedLegal}」`);
    const jumpStart = rpcLog.length;
    await page.keyboard.press('Enter');
    await waitFor(
      () => rpcLog.slice(jumpStart).some((entry) => entry.method === 'workspace.listDirs'),
      '回车后发出 workspace.listDirs（地址栏跳转）',
    );
    await waitFolderPath(page, legal);
    // 地址栏的值在键入时就等于目标路径，光等它会被"输入中"骗过：必须等列举完成
    // （面包屑出现该目录）才能断言列表 / 面包屑真的跟着跳了。错误也放行，交给下面的断言归因。
    await page.waitForFunction(
      (expected) => {
        const crumb = [...document.querySelectorAll('[data-testid="folder-picker-crumb"]')].some(
          (button) => button.getAttribute('data-path') === expected,
        );
        return crumb || document.querySelector('[data-testid="folder-picker-load-error"]') !== null;
      },
      { timeout: 15000 },
      legal,
    );
    const jumped = await readFolderPicker(page);
    const jumpCall = rpcLog.slice(jumpStart).find((entry) => entry.method === 'workspace.listDirs');
    obs('地址栏跳转后', {
      value: jumped.path,
      entries: jumped.entries.map((entry) => entry.name),
      request: jumpCall?.params,
      crumbs: jumped.crumbs,
      loadError: jumped.loadError,
    });
    assert(
      jumped.loadError === null,
      `合法路径跳转不得报错，实测「${jumped.loadError}」`,
    );
    assert(
      jumped.path === legal,
      `合法路径回车后地址栏必须显示该路径，实测「${jumped.path}」`,
    );
    assert(
      jumpCall?.params?.path === legal,
      `跳转必须用地址栏路径列举，实测 ${JSON.stringify(jumpCall?.params)}`,
    );
    assert(
      jumped.crumbs.some((crumb) => crumb.path === legal),
      `跳转后面包屑必须包含新目录，实测 ${JSON.stringify(jumped.crumbs)}`,
    );
    assert(
      jumped.crumbs.some((crumb) => crumb.path === PICKER_CROWDED),
      `跳转后面包屑必须跟着变（含 ${PICKER_CROWDED}），实测 ${JSON.stringify(jumped.crumbs)}`,
    );
    assert(
      jumped.entries.length === 0,
      `跳转后必须显示该目录内容（夹具叶子应为空），实测 ${jumped.entries.length}`,
    );
    const writesAfterJump = rpcLog
      .slice(jumpStart)
      .filter((entry) => entry.method.endsWith('setWorkspace'));
    obs('地址栏跳转的写请求', writesAfterJump);
    assert(
      writesAfterJump.length === 0,
      `地址栏跳转不得发写请求，实测 ${JSON.stringify(writesAfterJump)}`,
    );

    // ③「跳转」按钮与回车等价：跳回 40 个子目录的文件夹。
    await replaceAddress(page, PICKER_CROWDED);
    await clickByTestId(page, 'folder-picker-go');
    await waitFolderPath(page, PICKER_CROWDED);
    // 地址栏的值在键入时就等于目标路径，必须等列举结果真的渲染出来（40 项）再断言。
    await page.waitForFunction(
      (count) =>
        document.querySelectorAll('[data-testid="folder-picker-entry"]').length === count,
      { timeout: 15000 },
      PICKER_CROWDED_CHILDREN.length,
    );
    const viaButton = await readFolderPicker(page);
    obs('「跳转」按钮跳转后', {
      value: viaButton.path,
      entries: viaButton.entries.length,
    });
    assert(viaButton.path === PICKER_CROWDED, '「跳转」按钮必须与回车等价');
    assert(
      viaButton.entries.length === PICKER_CROWDED_CHILDREN.length,
      `按钮跳转后必须列出 ${PICKER_CROWDED_CHILDREN.length} 个子目录，实测 ${viaButton.entries.length}`,
    );

    // ④ 非法路径 + Enter：框内错误含路径 / 原因、不跳、地址栏回到当前文件夹。
    const bad = 'C:\\work\\nope';
    await replaceAddress(page, bad);
    await page.keyboard.press('Enter');
    await page.waitForFunction(
      () => document.querySelector('[data-testid="folder-picker-load-error"]') !== null,
      { timeout: 15000 },
    );
    // 错误与「地址栏恢复成当前文件夹」可能不在同一帧：给一个短稳定窗口，超时也继续，
    // 让下面的显式断言带着实测值失败（而不是只抛一个笼统的等待超时）。
    await page
      .waitForFunction(
        (expected) =>
          document.querySelector('[data-testid="folder-picker-path"]')?.value === expected,
        { timeout: 2000 },
        PICKER_CROWDED,
      )
      .catch(() => {});
    const failed = await page.evaluate(() => {
      const input = document.querySelector('[data-testid="folder-picker-path"]');
      return {
        value: input?.value ?? '',
        error: document.querySelector('[data-testid="folder-picker-load-error"]')?.textContent ?? '',
        entries: document.querySelectorAll('[data-testid="folder-picker-entry"]').length,
        open: document.querySelector('[data-testid="folder-picker"]') !== null,
      };
    });
    obs('非法路径回车后', { ...failed, attempted: bad });
    assert(failed.error.includes(bad), `错误必须含输入的路径，实测「${failed.error}」`);
    assert(failed.error.includes('不存在'), `错误必须含原因，实测「${failed.error}」`);
    assert(
      failed.value === PICKER_CROWDED,
      `非法路径不得跳转：地址栏必须回到当前文件夹，实测「${failed.value}」/ 期望「${PICKER_CROWDED}」`,
    );
    assert(
      failed.entries === PICKER_CROWDED_CHILDREN.length,
      `非法路径不得改变列表（仍应显示 ${PICKER_CROWDED_CHILDREN.length} 项），实测 ${failed.entries}`,
    );
    assert(failed.open, '非法路径不得关闭对话框');
    const writesAfterFail = rpcLog
      .slice(jumpStart)
      .filter((entry) => entry.method.endsWith('setWorkspace'));
    assert(writesAfterFail.length === 0, '非法路径跳转不得发写请求');
  } finally {
    await page.close();
    await setGroupFlags('reset=1');
  }
});

// WORKSPACE_SHOT_SINGLE / WORKSPACE_SHOT_GROUP：各留一张视觉验收截图（change
// `custom-workspace` 任务 8.3 ④；返工任务 12.5 改成截**打开状态的文件夹选择框**；
// 图由主循环 read_image 判读：框内路径 / 子目录 / 两个按钮可读、层级盖住主区）。
if (process.env.WORKSPACE_SHOT_SINGLE) {
  await resetToBaseSingle('WS 截图基础单聊');
  await seedSingle('WS 截图单聊', { workspace: LONG_WORKSPACE });
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS 截图单聊');
    await page.waitForSelector('[data-testid="workspace-path"]', { timeout: 15000 });
    await openFolderPicker(page, 'workspace-edit');
    await new Promise((resolve) => setTimeout(resolve, 600));
    const target = process.env.WORKSPACE_SHOT_SINGLE;
    await page.screenshot({ path: target, fullPage: false });
    console.log(`[SHOT] captured ${target}`);
  } finally {
    await page.close();
  }
}

if (process.env.WORKSPACE_SHOT_GROUP) {
  await resetToBaseSingle('WS 截图基础单聊');
  await seedWorkspaceGroup('WS 截图工作区组', LONG_WORKSPACE);
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
    await clickSessionRow(page, 'WS 截图工作区组');
    await page.waitForSelector('[data-testid="group-workspace"]', { timeout: 15000 });
    await openFolderPicker(page, 'group-workspace-edit');
    await new Promise((resolve) => setTimeout(resolve, 600));
    const target = process.env.WORKSPACE_SHOT_GROUP;
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
