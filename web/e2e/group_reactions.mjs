// 自发反应的**真实核心**页驱动：无头 Edge 打开真实 web 页面，先确认「自发反应」开关
// 为开启，再通过**界面**发两条消息（都不选发言人）：一条普通触发、一条 `@乙` 定向，
// 等链收敛后收集时间线/分栏/steps 并截图。
//
// change `group-reactive-mode` 任务 5.3。它**只用于真实核心**（不是假核心 e2e）：
//   - 页面上的选择器与真实 `GroupView` 不一致时必须失败；
//   - 页面没有组时，脚本先用 WS **自建组与甲乙丙成员**（不依赖外部种子）。
//
// 用法：
//   node e2e/group_reactions.mjs \
//     --coreUrl=http://127.0.0.1:64521 \
//     --shotPath=../test/live_visual/group_reactions_live.png \
//     --prompt="甲讲个笑话，乙和丙评价一下" \
//     --mentionPrompt="乙具体说说哪里好笑"
//
// 末行输出 JSON 摘要（供主循环收集读数）。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
import WebSocket from 'ws';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');

function arg(name, fallback) {
  const prefix = `--${name}=`;
  const hit = process.argv.find((entry) => entry.startsWith(prefix));
  if (hit) return hit.slice(prefix.length);
  return process.env[name.toUpperCase()] ?? fallback;
}

const CORE_URL = arg('coreUrl', 'http://127.0.0.1:64521').replace(/\/+$/, '');
const SHOT_PATH = path.resolve(
  ROOT,
  arg('shotPath', path.join('..', 'test', 'live_visual', 'group_reactions_live.png')),
);
const PROMPT = arg('prompt', '甲讲个笑话，乙和丙评价一下，别只说好话');
const MENTION_PROMPT = arg('mentionPrompt', '@乙 具体说说哪里好笑');
const WS_URL = `${CORE_URL.replace(/^http/, 'ws')}/ws`;

function log(label, value) {
  console.log(`  [${label}] ${typeof value === 'string' ? value : JSON.stringify(value)}`);
}

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

/** 最小 WS JSON-RPC 客户端（脚本自己建组/查数据用；页面另有一条连接）。 */
class Rpc {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    socket.on('message', (raw) => {
      let message;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (message.method === 'agent.event') {
        this.events.push(message.params);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
  }

  static async connect(url) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      socket.once('open', resolve);
      socket.once('error', reject);
    });
    return new Rpc(socket);
  }

  request(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }

  close() {
    this.socket.close();
  }
}

async function ensureGroup(rpc) {
  const sessions = (await rpc.request('session.list')).sessions ?? [];
  const existing = sessions.find((session) => session.kind === 'group');
  if (existing) {
    log('已有组', { id: existing.id, title: existing.title });
    return existing;
  }
  const templates = (await rpc.request('template.list')).templates ?? [];
  const templateName = templates[0]?.name ?? 'general';
  const created = (await rpc.request('group.create', { title: '反应验收组' })).group;
  log('自建组', { id: created.id, title: created.title });
  for (const name of ['甲', '乙', '丙']) {
    await rpc.request('group.member.add', {
      groupId: created.id,
      name,
      templateName,
    });
  }
  return created;
}

async function groupSummary(rpc, groupId) {
  const list = (await rpc.request('group.list')).groups ?? [];
  return list.find((entry) => entry.id === groupId) ?? null;
}

async function main() {
  const edge = findEdge();
  if (!edge) throw new Error('找不到 msedge.exe：设置 EDGE_PATH');
  const rpc = await Rpc.connect(WS_URL);
  const browser = await puppeteer.launch({
    executablePath: edge,
    headless: true,
    args: [
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
      '--hide-scrollbars',
      '--force-device-scale-factor=1',
    ],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 960 });
  // 收集**页面收到的** JSON-RPC 响应（异步契约下 `group.send` 只回 started；
  // 链的 steps/rounds/stopReason 在 `group.chain` 的响应里 —— 用 CDP 的 WS 帧接收，
  // 不靠改产品代码加钩子）。
  const cdp = await page.target().createCDPSession();
  await cdp.send('Network.enable');
  const startedResults = [];
  const chainResults = [];
  cdp.on('Network.webSocketFrameReceived', ({ response }) => {
    try {
      const message = JSON.parse(response.payloadData);
      const result = message?.result;
      if (result?.status === 'started') startedResults.push(result);
      if (Array.isArray(result?.steps)) chainResults.push(result);
    } catch {
      // 非 JSON 帧忽略。
    }
  });

  const summary = await (async () => {
    const group = await ensureGroup(rpc);
    await page.goto(`${CORE_URL}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForSelector('[data-testid="session-list"]', { timeout: 30000 });
    // 会话列表按标题找到该组并点开（真实路由：kind=group ⇒ 组视图）。
    await page.evaluate((title) => {
      const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
      rows.find((row) => row.textContent?.includes(title))?.click();
    }, group.title);
    await page.waitForSelector('[data-testid="group-view"]', { timeout: 30000 });

    const toggle = await page.$eval(
      '[data-testid="reactions-toggle"]',
      (element) => element.checked,
    );
    log('自发反应开关', toggle);
    if (toggle !== true) {
      throw new Error('「自发反应」开关不是开启状态：新建组默认必须开启');
    }

    const sendOnce = async (label, text, expectedSteps) => {
      const beforeStarted = startedResults.length;
      // 不选发言人（默认空 = 纯触发）；这里显式确保下拉是空值。
      await page.select('[data-testid="speaker-select"]', '');
      await page.type('[data-testid="group-input"]', text);
      await page.click('[data-testid="group-send"]');

      // ① **先等本次发送的 started 回包**（异步契约：send 只回 started）。
      // 这一步必须排在"找终态链"之前：页面刚加载时 App 会先拉一次**上一条**链的
      // `group.chain`（可能是已终态的旧链），若先找终态就会误取旧链（2026-11-22
      // live 复跑的实际故障：第二次发送把上一段链当成自己的结果，随后被 busy 挡住）。
      let started = null;
      for (let waited = 0; waited < 600; waited += 1) {
        started = startedResults[beforeStarted] ?? null;
        if (started) break;
        await new Promise((done) => setTimeout(done, 100));
      }
      if (!started) {
        throw new Error(`${label}：页面上没有观察到 group.send 的 started 回包`);
      }
      // ② 从**看到 started 之后**才开始找终态链（旧链快照不可能再进来）。
      //
      //    不再用"时间线行数必须增长"做前置判据：App 的组时间线来自**尾页 30 条
      //    原始消息**（私有行也占页），真实模型每轮都会写私有行，所以一次重拉后
      //    可见公开行数可能**减少**，那个判据会把正常链误判为"时间线没动"
      //    （2026-11-22 live 复跑的实际故障：链已写出 20+ 条消息，脚本仍在等行数增长）。
      const beforeChains = chainResults.length;
      // 链终态上界：产品模型请求超时 120s × 最多步数（本组上限 4 ⇒ 3+2×3=9 步）
      // = 18min；正常在几分钟内结束，这只是不被"慢但仍在推进"误杀的兜底。
      let result = null;
      for (let waited = 0; waited < 5400; waited += 1) {
        result = chainResults
          .slice(beforeChains)
          .filter((chain) => chain.status !== 'running' && chain.status !== 'idle')
          .at(-1);
        if (result) break;
        await new Promise((done) => setTimeout(done, 200));
      }
      log(`${label} 结果`, {
        started,
        status: result?.status,
        stopReason: result?.stopReason,
        rounds: result?.rounds,
        triggerSeq: result?.triggerSeq,
        steps: (result?.steps ?? []).map(
          (step) => `${step.memberId}/${step.source}/${step.status}/public=${step.publicSeq}`,
        ),
      });
      if (!result || !Array.isArray(result.steps)) {
        throw new Error(`${label}：页面上没有观察到 group.chain 的终态响应`);
      }
      if (result.steps.length < expectedSteps) {
        throw new Error(`${label}：steps 少于预期（${result.steps.length} < ${expectedSteps}）`);
      }
      return result;
    };

    const first = await sendOnce('普通触发', PROMPT, 1);
    const second = await sendOnce('@定向', MENTION_PROMPT, 1);

    // 定向的验收口径：source=mention、status=replied、publicSeq 非空、无 forced_*。
    const mentionSteps = second.steps.filter((step) => step.source === 'mention');
    const forced = second.steps.filter(
      (step) => step.status === 'forced_pass' || step.status === 'forced_empty',
    );
    log('定向步骤', mentionSteps);
    if (mentionSteps.length === 0) {
      throw new Error('@定向 的 steps 里没有任何 source=mention 的步骤');
    }
    for (const step of mentionSteps) {
      if (step.status !== 'replied' || step.publicSeq === null) {
        throw new Error(
          `@定向 的成员没有回应：source=${step.source} status=${step.status} publicSeq=${step.publicSeq}`,
        );
      }
    }
    if (forced.length > 0) {
      // 只记录：真实模型可能仍不服从必应，但那是 live 报告要写的内容，不是脚本崩溃点。
      log('注意：出现 forced_* 步骤', forced);
    }

    // 时间线 / 分栏读数（视觉验收的人读材料）。
    const timeline = await page.$$eval('[data-testid="timeline-item"]', (nodes) =>
      nodes.map((node) => node.textContent ?? ''),
    );
    const lanes = await page.$$eval('[data-testid="lane-item"]', (nodes) => nodes.length);
    const laneHeaders = await page.$$eval(
      '[data-testid^="lane-mem"], [data-testid^="lane-"]',
      (nodes) =>
        nodes
          .filter((node) => node.getAttribute('data-testid')?.startsWith('lane-mem') ||
            node.tagName === 'ARTICLE')
          .map((node) => node.querySelector('header')?.textContent ?? ''),
    );
    log('公开时间线', timeline);
    log('私有分栏行数', lanes);

    fs.mkdirSync(path.dirname(SHOT_PATH), { recursive: true });
    await page.screenshot({ path: SHOT_PATH, fullPage: false });
    const size = fs.statSync(SHOT_PATH).size;
    log('截图', `${SHOT_PATH}（${size} bytes）`);
    if (size === 0) throw new Error('截图字节数为 0');

    return {
      coreUrl: CORE_URL,
      group: { id: group.id, title: group.title },
      reactionsEnabled: toggle,
      firstSteps: first.steps,
      secondSteps: second.steps,
      mentionSteps,
      forcedSteps: forced,
      timeline,
      laneRows: lanes,
      laneHeaders,
      shotPath: SHOT_PATH,
      shotBytes: size,
    };
  })();

  await browser.close();
  rpc.close();
  console.log(`\n[group_reactions] ${JSON.stringify(summary)}`);
}

main().catch((error) => {
  console.error(`[group_reactions][FAIL] ${error?.message ?? error}`);
  process.exit(1);
});
