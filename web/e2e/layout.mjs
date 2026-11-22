// 布局 / 滚动断言的真实渲染通道（change `web-chat-screen` 任务 2.1 / design D13）。
//
// 为什么是 puppeteer 而不是 vitest+jsdom：jsdom 没有布局引擎，`offsetHeight` /
// `getBoundingClientRect()` 恒为 0，`scrollTop` 不产生滚动 —— 折叠卡"严格单行 24px"、
// 贴底跟随、上翻不打扰、跳底这些断言只能在真实渲染里量。
//
// 被驱动的页面是 `test/harness`（`vite build --config vite.harness.config.ts` 的
// 产物 `web/dist-test/`）：真实组件 + 可编程假数据源，不连核心、不碰数据库。
//
// 用法：
//   cd web
//   npm run build:harness
//   node e2e/layout.mjs            # EDGE_PATH 可覆盖（默认找本机 Edge）
//
// 输出：逐条 [PASS]/[FAIL] + 实测数字（TESTING.md §3.1 可观察性），末尾 JSON 摘要；
// 有失败则退出码 1。每条断言都把**量到的值**打出来，失败可直接归因。
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const DIST = path.join(ROOT, 'dist-test');

const results = [];
let failureCount = 0;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertNumber(actual, expected, label, tolerance = 0) {
  assert(
    typeof actual === 'number' && Math.abs(actual - expected) <= tolerance,
    `${label}：期望 ${expected}±${tolerance}，实测 ${actual}`,
  );
  console.log(`  [量] ${label} = ${actual}`);
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
    results.push({ name, ok: false, error: String(error && error.message ? error.message : error) });
    console.log(`[FAIL] ${name}：${error && error.message ? error.message : error}`);
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

/** 极小的静态服务器：只把 dist-test 目录按路径喂给浏览器（无缓存、无目录列表）。 */
function startStaticServer(root) {
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent((request.url ?? '/').split('?')[0]);
    const relative = requestPath === '/' ? 'index.html' : requestPath.replace(/^\/+/, '');
    const target = path.join(root, relative);
    if (!target.startsWith(root)) {
      response.writeHead(403).end('forbidden');
      return;
    }
    fs.readFile(target, (error, data) => {
      if (error) {
        if (relative === 'favicon.ico') {
          response.writeHead(204).end();
          return;
        }
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
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({
        server,
        url: `http://127.0.0.1:${address.port}/`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
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

if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.error('缺少 web/dist-test/index.html：先跑 `npm run build:harness`。');
  process.exit(2);
}

const edgePath = findEdge();
if (!edgePath) {
  console.error('找不到 msedge.exe：设置 EDGE_PATH 指向本机 Edge。');
  process.exit(2);
}

const staticServer = await startStaticServer(DIST);
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
console.log(
  `[布局测试] harness=${staticServer.url} edge=${edgePath} ` +
    `headless=true viewport=1280x900`,
);

/** 打开一次 harness 页面（每条用例新开页，避免状态串味）。 */
async function openPage(scenario = null) {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });
  if (scenario) {
    await page.evaluateOnNewDocument((data) => {
      window.__HARNESS_SCENARIO__ = data;
    }, scenario);
  }
  page.on('console', (message) => {
    if (message.type() === 'error') console.log(`  [页面错误] ${message.text()}`);
  });
  page.on('pageerror', (error) => console.log(`  [页面异常] ${error.message}`));
  await page.goto(staticServer.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  return page;
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

await run('基建自检：真实布局引擎能量单行高度与滚动（jsdom 做不到）', async () => {
  const page = await openPage();
  try {
    await page.waitForSelector('[data-testid="canary-single-line"]', { timeout: 15000 });
    const height = await page.$eval(
      '[data-testid="canary-single-line"]',
      (element) => element.getBoundingClientRect().height,
    );
    assertNumber(height, 24, 'canary 单行盒子高度', 0.01);

    const scrollTop = await page.evaluate(() => {
      const container = document.querySelector('[data-testid="canary-scroll"]');
      container.scrollTop = 300;
      return container.scrollTop;
    });
    assertNumber(scrollTop, 300, 'canary 容器 scrollTop', 0.01);
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 3.2 折叠：工具卡/思考卡默认折叠、折叠态严格单行 24px、展开看全文（F-002）
// ---------------------------------------------------------------------------

const LONG_RESULT =
  '第一段结果（这一段会被折叠态截断，展开后必须能看全）。' +
  '中间填充内容 '.repeat(12) +
  '结果末尾标记 RESULT_TAIL_987';

const foldScenario = {
  sessions: [
    { id: 's-1', title: '折叠用例会话', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
  ],
  messages: [
    { id: 'u-1', role: 'user', content: '帮我读一下 a.txt 再 grep 一下' },
    {
      id: 'a-tool',
      role: 'assistant',
      content: '',
      thinking: [{ type: 'thinking', thinking: '先读文件\n再 grep 模式\n（第二行折叠态不该出现）' }],
      toolCalls: [
        {
          id: 'tool-1',
          toolName: 'read_file',
          input: { path: 'a.txt' },
          status: 'done',
          result: LONG_RESULT,
          resultPreview: '第一段结果…',
        },
        {
          id: 'tool-2',
          toolName: 'grep_file',
          input: { pattern: 'TODO', path: '.' },
          status: 'error',
          result: 'grep 失败：没有权限',
        },
      ],
    },
    { id: 'a-final', role: 'assistant', content: '读完了，结论在这里。' },
  ],
};

await run('折叠卡：默认折叠且折叠态严格单行 24px，展开看全文', async () => {
  const page = await openPage(foldScenario);
  try {
    await page.waitForSelector('[data-testid="tool-card"]', { timeout: 15000 });
    await page.waitForSelector('[data-testid="thinking-card"]', { timeout: 15000 });
    // 等贴底跟随滚完（首屏应停在最新一条）。
    await new Promise((resolve) => setTimeout(resolve, 300));

    const cards = await page.$$eval('[data-testid="tool-card"]', (nodes) =>
      nodes.map((node) => ({
        collapsed: node.dataset.collapsed,
        height: node.getBoundingClientRect().height,
        text: node.innerText,
      })),
    );
    obs('折叠态工具卡', cards.map((card) => ({ collapsed: card.collapsed, height: card.height })));
    assert(cards.length === 2, `应有 2 张工具卡（每个 toolCall 一张），实测 ${cards.length}`);
    for (const [index, card] of cards.entries()) {
      assert(card.collapsed === 'true', `第 ${index + 1} 张工具卡默认必须折叠`);
      assertNumber(card.height, 24, `第 ${index + 1} 张折叠工具卡高度`, 0.01);
    }
    assert(cards[0].text.includes('read_file'), `折叠态必须露出工具名，实测：「${cards[0].text}」`);
    assert(cards[0].text.includes('完成'), `折叠态必须露出状态，实测：「${cards[0].text}」`);
    assert(cards[1].text.includes('grep_file'), '第二张卡必须是第二个工具（不是一卡只露一个）');
    assert(cards[1].text.includes('失败'), '第二张卡必须露出自己的状态');

    const thinking = await page.$eval('[data-testid="thinking-card"]', (node) => ({
      collapsed: node.dataset.collapsed,
      height: node.getBoundingClientRect().height,
      text: node.innerText,
    }));
    obs('折叠态思考卡', { collapsed: thinking.collapsed, height: thinking.height });
    assert(thinking.collapsed === 'true', '思考卡默认必须折叠');
    assertNumber(thinking.height, 24, '折叠思考卡高度', 0.01);
    assert(thinking.text.includes('思考'), '折叠态必须露出"思考"标识');

    // 展开第一个工具卡：高度变大 + 全文可见（结果超出折叠态摘要的部分必须出现）。
    await page.click('[data-testid="tool-card"] button');
    await new Promise((resolve) => setTimeout(resolve, 150));
    const expanded = await page.$eval('[data-testid="tool-card"]', (node) => ({
      collapsed: node.dataset.collapsed,
      height: node.getBoundingClientRect().height,
      text: node.innerText,
    }));
    obs('展开后的工具卡', { collapsed: expanded.collapsed, height: expanded.height });
    assert(expanded.collapsed === 'false', '点击后必须展开');
    assert(expanded.height > 24, `展开后高度应大于单行 24px，实测 ${expanded.height}`);
    assert(
      expanded.text.includes('RESULT_TAIL_987'),
      '展开后必须能看到结果的末尾（折叠≠丢弃），实测文本末尾：' +
        expanded.text.slice(-80),
    );

    // 展开思考卡：多行全文可见。
    await page.click('[data-testid="thinking-card"] button');
    await new Promise((resolve) => setTimeout(resolve, 150));
    const expandedThinking = await page.$eval('[data-testid="thinking-card"]', (node) => ({
      height: node.getBoundingClientRect().height,
      text: node.innerText,
    }));
    obs('展开后的思考卡', { height: expandedThinking.height });
    assert(
      expandedThinking.text.includes('第二行折叠态不该出现'),
      '展开思考卡必须看到全部行（含第二行）',
    );
    assert(expandedThinking.height > 24, '展开的思考卡应高于单行');
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 4.1 / 4.2 滚动：贴底跟随、上翻不打扰、悬浮跳底（F-003 / F-004 / design D9）
// ---------------------------------------------------------------------------

const BOTTOM_THRESHOLD = 24;

const scrollScenario = {
  sessions: [
    { id: 's-1', title: '滚动用例会话', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
  ],
  messages: Array.from({ length: 40 }, (_, index) => ({
    id: `m-${index}`,
    role: index % 2 === 0 ? 'user' : 'assistant',
    content: `第 ${index} 条消息：${'填充内容 '.repeat(8)}`,
  })),
};

async function scrollMetrics(page) {
  return page.evaluate(() => {
    const list = document.querySelector('[data-testid="message-list"]');
    return {
      scrollTop: list.scrollTop,
      scrollHeight: list.scrollHeight,
      clientHeight: list.clientHeight,
      distance: list.scrollHeight - list.scrollTop - list.clientHeight,
    };
  });
}

await run('贴底跟随：首屏贴底，新消息到达自动滚到底', async () => {
  const page = await openPage(scrollScenario);
  try {
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const initial = await scrollMetrics(page);
    obs('首屏滚动量', initial);
    assert(
      initial.distance <= BOTTOM_THRESHOLD,
      `打开会话应停在底部（distance<=${BOTTOM_THRESHOLD}），实测 ${initial.distance}`,
    );

    await page.evaluate(() => {
      window.__harness.pushMessage({
        id: 'm-live',
        role: 'assistant',
        content: '这一条是新的实时消息，应该自动滚到底。',
      });
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const after = await scrollMetrics(page);
    obs('新消息后的滚动量', after);
    assert(
      after.scrollHeight > initial.scrollHeight,
      `新消息应让内容变高（before=${initial.scrollHeight}, after=${after.scrollHeight}）`,
    );
    assert(
      after.distance <= BOTTOM_THRESHOLD,
      `贴底时新消息到达必须自动滚到底，实测 distance=${after.distance}`,
    );
  } finally {
    await page.close();
  }
});

await run('上翻不打扰：离开底部后新消息到达不自动滚', async () => {
  const page = await openPage(scrollScenario);
  try {
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const scrolled = await page.evaluate(() => {
      const list = document.querySelector('[data-testid="message-list"]');
      list.scrollTop = 0;
      return list.scrollTop;
    });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const atTop = await scrollMetrics(page);
    obs('上翻后的滚动量', atTop);
    assert(scrolled === 0 && atTop.distance > BOTTOM_THRESHOLD, '上翻后应处于非贴底态');

    await page.evaluate(() => {
      window.__harness.pushMessage({
        id: 'm-live-2',
        role: 'assistant',
        content: '上翻阅读时来的新消息，不该把阅读位置拖走。',
      });
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const after = await scrollMetrics(page);
    obs('新消息后的滚动量', after);
    assert(
      Math.abs(after.scrollTop - atTop.scrollTop) <= 1,
      `上翻时新消息到达不得自动滚动（before=${atTop.scrollTop}, after=${after.scrollTop}）`,
    );
    assert(after.distance > BOTTOM_THRESHOLD, '仍应保持非贴底态（阅读位置未被拖到底）');
  } finally {
    await page.close();
  }
});

await run('悬浮跳底按钮：贴底隐藏 / 非贴底显示及右对齐在输入框上方 / 点击回底', async () => {
  const page = await openPage(scrollScenario);
  try {
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const hiddenAtBottom = (await page.$('[data-testid="jump-to-bottom"]')) === null;
    obs('贴底时跳底按钮存在', !hiddenAtBottom);
    assert(hiddenAtBottom, '贴底时跳底按钮必须隐藏');

    await page.evaluate(() => {
      const list = document.querySelector('[data-testid="message-list"]');
      list.scrollTop = Math.floor((list.scrollHeight - list.clientHeight) / 2);
    });
    await page.waitForSelector('[data-testid="jump-to-bottom"]', { timeout: 5000 });
    const geometry = await page.evaluate(() => {
      const button = document.querySelector('[data-testid="jump-to-bottom"]');
      const composer = document.querySelector('[data-testid="composer"]');
      const rect = button.getBoundingClientRect();
      const composerRect = composer.getBoundingClientRect();
      return {
        width: rect.width,
        height: rect.height,
        rightGap: window.innerWidth - rect.right,
        aboveComposer: rect.bottom <= composerRect.top,
        radius: getComputedStyle(button).borderRadius,
      };
    });
    obs('跳底按钮几何', geometry);
    assert(geometry.width > 0 && geometry.height > 0, '跳底按钮必须可点（有尺寸）');
    assert(
      Math.abs(geometry.width - geometry.height) <= 1,
      `按钮应为圆形（宽高相等），实测 ${geometry.width}x${geometry.height}`,
    );
    assert(geometry.aboveComposer, '跳底按钮必须在输入框上方');
    assert(geometry.rightGap <= 100, `按钮应右对齐，实测右侧留白 ${geometry.rightGap}px`);

    await page.click('[data-testid="jump-to-bottom"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const after = await scrollMetrics(page);
    const stillVisible = (await page.$('[data-testid="jump-to-bottom"]')) !== null;
    obs('点击后滚动量', after);
    obs('点击后按钮仍可见', stillVisible);
    assert(after.distance <= BOTTOM_THRESHOLD, `点击跳底后应回到底部，实测 distance=${after.distance}`);
    assert(!stillVisible, '回到底部后跳底按钮必须隐藏（恢复贴底跟随）');
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 5.1 会话列表虚拟滚动（design D11）
// ---------------------------------------------------------------------------

const manySessions = Array.from({ length: 500 }, (_, index) => ({
  id: `s-${index}`,
  title: `长会话标题 ${index}`,
  agentType: 'general',
  parentSessionId: null,
  createdAt: index,
  updatedAt: index,
}));

await run('会话列表虚拟滚动：500 条会话只渲染可视区', async () => {
  const page = await openPage({
    sessions: manySessions,
    messages: [{ id: 'm-1', role: 'user', content: '虚拟滚动用例' }],
  });
  try {
    await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const rendered = await page.$$eval('[data-testid="session-row"]', (nodes) => nodes.length);
    obs('渲染的会话行数', rendered);
    assert(rendered > 0, '会话列表必须渲染出可视区行');
    assert(
      rendered < 60,
      `500 条会话只应渲染可视区（<60 行），实测 ${rendered} 行——虚拟滚动失效`,
    );

    await page.evaluate(() => {
      const list = document.querySelector('[data-testid="session-list"]');
      list.scrollTop = list.scrollHeight;
    });
    await new Promise((resolve) => setTimeout(resolve, 400));
    const titles = await page.$$eval('[data-testid="session-row"]', (nodes) =>
      nodes.map((node) => node.textContent ?? ''),
    );
    obs('滚到底后的最后一行', titles[titles.length - 1]);
    assert(
      titles.some((title) => title.includes('499')),
      `滚到底必须能看到最后一条会话，实测末尾：${titles.slice(-3).join(' / ')}`,
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 5.2 消息分页：首屏最新页 + 上翻加载更早（位置不跳）+ 动态高度虚拟化
// ---------------------------------------------------------------------------

function makeMessage(index) {
  return {
    id: `m-${index}`,
    role: index % 2 === 0 ? 'user' : 'assistant',
    content: `msg-${index} 的内容：${'这一条用于撑高动态行高 '.repeat(index % 3 === 0 ? 4 : 1)}`,
  };
}

/** 首屏：最新一页 msg-90..msg-119；更早页按 30 条一批。 */
const pagingScenario = {
  sessions: [
    { id: 's-1', title: '分页用例会话', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
  ],
  messages: Array.from({ length: 30 }, (_, index) => makeMessage(90 + index)),
  hasEarlier: true,
  earlierChunks: [
    Array.from({ length: 30 }, (_, index) => makeMessage(60 + index)),
    Array.from({ length: 30 }, (_, index) => makeMessage(30 + index)),
    Array.from({ length: 30 }, (_, index) => makeMessage(index)),
  ],
  earlierDelayMs: 60,
};

await run('消息分页：首屏最新页（非最旧）+ 上翻加载更早位置不跳 + 虚拟化受控', async () => {
  const page = await openPage(pagingScenario);
  try {
    await page.waitForSelector('[data-testid="message-list"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 700));

    const rows = await page.$$eval('[data-testid="message-row"]', (nodes) => nodes.length);
    const visible = await page.$$eval(
      '[data-testid="assistant-message"],[data-testid="user-message"]',
      (nodes) => nodes.map((node) => node.innerText),
    );
    obs('首屏渲染的消息行数', rows);
    obs('首屏可见消息（末 3 条）', visible.slice(-3));
    assert(rows > 0 && rows < 80, `首屏只应渲染可视区（<80 行），实测 ${rows}`);
    assert(
      visible.some((text) => text.includes('msg-119 的内容')),
      '首屏必须显示最新一条（msg-119）：打开会话即在最新页',
    );
    assert(
      !visible.some((text) => text.includes('msg-0 的内容')),
      '首屏不得显示最旧页的消息',
    );

    const listTopBefore = await page.evaluate(() => {
      const list = document.querySelector('[data-testid="message-list"]');
      list.scrollTop = 0;
      return list.scrollTop;
    });
    assert(listTopBefore === 0, '上翻到顶（scrollTop=0）');
    await new Promise((resolve) => setTimeout(resolve, 1000));

    const state = await page.evaluate(() => {
      const list = document.querySelector('[data-testid="message-list"]');
      const nodes = [
        ...document.querySelectorAll(
          '[data-testid="assistant-message"],[data-testid="user-message"]',
        ),
      ];
      const anchor = nodes.find((node) => node.innerText.includes('msg-90 的内容'));
      const listRect = list.getBoundingClientRect();
      return {
        scrollTop: list.scrollTop,
        distance: list.scrollHeight - list.scrollTop - list.clientHeight,
        anchorOffsetTop: anchor ? anchor.getBoundingClientRect().top - listRect.top : null,
        anchorText: anchor ? anchor.innerText.slice(0, 12) : null,
        messageCount: window.__harness.messageCount(),
        chunksLeft: window.__harness.remainingEarlierChunks(),
      };
    });
    obs('上翻加载后的状态', state);
    assert(state.chunksLeft === 2, `应恰好加载一批更早消息（剩余批数 2），实测 ${state.chunksLeft}`);
    assert(
      state.messageCount === 60,
      `加载更早后消息总数应为 60（30+30，且不重叠），实测 ${state.messageCount}`,
    );
    assert(
      state.anchorText !== null,
      '加载更早后锚点消息（msg-90，加载前处于顶部）必须仍在可视区：位置不跳',
    );
    assert(
      state.anchorOffsetTop >= -120 && state.anchorOffsetTop <= 160,
      `锚点应仍靠列表顶部（位置不跳），实测 offsetTop=${state.anchorOffsetTop}`,
    );
    assert(
      state.scrollTop > 100,
      `加载更早后 scrollTop 应变大（把插入的高度让给上面），实测 ${state.scrollTop}`,
    );
    assert(
      state.distance > BOTTOM_THRESHOLD,
      `上翻加载不得把视图拽回底部，实测 distance=${state.distance}`,
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------

await browser.close();
await staticServer.close();

const summary = {
  total: results.length,
  passed: results.length - failureCount,
  failed: failureCount,
  results,
};
console.log(JSON.stringify(summary));
process.exit(failureCount === 0 ? 0 : 1);
