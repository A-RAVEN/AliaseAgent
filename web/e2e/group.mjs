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
  };
  sessions.push(session);
  groups.set(id, {
    session,
    members: [],
    messages: [],
    snapshots: {},
    seq: 0,
  });
  return session;
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
  };
}

function broadcast(event) {
  eventLog.push(event);
  const payload = JSON.stringify({ jsonrpc: '2.0', method: 'agent.event', params: event });
  for (const socket of sockets) socket.send(payload);
}

function reply(socket, id, result) {
  socket.send(JSON.stringify({ jsonrpc: '2.0', id, result }));
}

function fail(socket, id, message) {
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
  if (method === 'group.send') {
    const group = groups.get(params.groupId);
    if (!group) return fail(socket, id, `组 ${params.groupId} 不存在`);
    const speaker = group.members.find(
      (member) => member.id === params.speaker && member.removedAt === null,
    );
    if (!speaker || params.speaker === undefined) {
      return fail(socket, id, '群发送必须指定恰好一个发言者');
    }
    const userMessage = pushMessage(group, {
      role: 'user',
      content: params.text ?? '',
      author: null,
    });
    const privateMessage = pushMessage(group, {
      role: 'assistant',
      content: '',
      author: speaker.id,
      visibility: 'private-to-author',
    });
    const publicMessage = pushMessage(group, {
      role: 'assistant',
      content: `${speaker.name}的公开结论：已改完 lib/a.dart`,
      author: speaker.id,
    });
    group.snapshots[speaker.id] = {
      sessionId: group.session.id,
      model: 'fake-model',
      thinkingMode: 'disabled',
      thinkingEffort: '',
      capturedAt: new Date().toISOString(),
      windowTokens: speaker.window,
      agentType: 'general',
      breakdown: breakdown(speaker.window, 1200, 300, 100),
      messages: [{ role: 'user', content: params.text ?? '' }],
      system: '你是测试模板。',
      tools: '[]',
      skillFailures: [],
      skillFailureNotice: null,
    };
    broadcast({
      sessionId: group.session.id,
      groupId: group.session.id,
      memberId: speaker.id,
      type: 'user.message',
      data: userMessage,
    });
    broadcast({
      sessionId: group.session.id,
      groupId: group.session.id,
      memberId: speaker.id,
      type: 'assistant.message',
      data: publicMessage,
    });
    broadcast({
      sessionId: group.session.id,
      groupId: group.session.id,
      memberId: speaker.id,
      type: 'assistant.message',
      data: privateMessage,
    });
    reply(socket, id, {
      groupId: group.session.id,
      sessionId: group.session.id,
      status: 'completed',
      memberId: speaker.id,
      finalText: publicMessage.content,
      error: null,
    });
    return;
  }
  if (method === 'agent.cancel') return reply(socket, id, { cancelled: false });
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
    const relative = requestPath === '/' ? 'index.html' : requestPath.replace(/^\/+/, '');
    const target = path.join(DIST, relative);
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
    // DOM 选中值只作辅助：再次核对 payload 里 speaker 与事件 memberId 一致。
    const sendRpc = rpcLog.filter((entry) => entry.method === 'group.send').at(-1);
    assert(sendRpc?.params?.speaker === messageEvents.at(-1)?.memberId, 'speaker 与事件 memberId 必须一致');
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

// GROUP_SHOT=<path>：测试跑完后把真实组视图截一张图（视觉验收用）。
if (process.env.GROUP_SHOT) {
  const page = await openPage();
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
