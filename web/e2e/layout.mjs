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
async function openPage(scenario = null, width = 1280, height = 900) {
  const page = await browser.newPage();
  await page.setViewport({ width, height });
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
// 1.1 应用壳层：常驻会话列表 + 主区（change `group-chat-layout`）
// ---------------------------------------------------------------------------

const shellScenario = {
  sessions: Array.from({ length: 500 }, (_, index) => ({
    id: `s-${index}`,
    title: `壳层会话 ${index}`,
    agentType: 'general',
    parentSessionId: null,
    createdAt: index,
    updatedAt: index,
    kind: index % 5 === 0 ? 'group' : 'single',
  })),
  messages: [{ id: 'shell-m-1', role: 'user', content: '壳层用例消息' }],
  error: '壳层错误横幅',
  notice: '壳层提示横幅',
  skillFailures: ['技能 A 未生效'],
};

await run('壳层：列表常驻唯一在左、主区在右、唯一 main、滚动/选中不丢、三横幅保留', async () => {
  for (const width of [1280, 720]) {
    const page = await openPage(shellScenario, width, 900);
    try {
      await page.waitForSelector('[data-testid="session-list"]', { timeout: 15000 });
      await new Promise((resolve) => setTimeout(resolve, 400));
      const shell = await page.evaluate(() => {
        const lists = [...document.querySelectorAll('[data-testid="session-list"]')];
        const list = lists[0] ?? null;
        const sidebar = document.querySelector('[data-testid="session-sidebar"]');
        const main = document.querySelector('[data-testid="main-area"]');
        const sidebarRect = sidebar?.getBoundingClientRect();
        const mainRect = main?.getBoundingClientRect();
        const row = document.querySelector('[data-testid="session-row"]');
        const rowRect = row?.getBoundingClientRect();
        const hit = rowRect
          ? document.elementFromPoint(
              rowRect.left + rowRect.width / 2,
              rowRect.top + rowRect.height / 2,
            )
          : null;
        return {
          listCount: lists.length,
          inSidebar: list !== null && list.closest('[data-testid="session-sidebar"]') !== null,
          sidebarWidth: sidebarRect?.width ?? null,
          sidebarRight: sidebarRect?.right ?? null,
          mainLeft: mainRect?.left ?? null,
          mainCount: document.querySelectorAll('main').length,
          hitInList: hit !== null && list?.contains(hit) === true,
          hitTestId: hit?.getAttribute('data-testid') ?? hit?.tagName ?? null,
          scrollWidth: document.documentElement.scrollWidth,
          innerWidth: window.innerWidth,
          errorBanner: document.querySelector('[data-testid="error-banner"]') !== null,
          noticeBanner: document.querySelector('[data-testid="notice-banner"]') !== null,
          skillFailures: document.querySelector('[data-testid="skill-failures"]') !== null,
        };
      });
      obs(`${width}px 壳层`, shell);
      assert(shell.listCount === 1, `${width}px：全页必须恰好一个 session-list，实测 ${shell.listCount}`);
      assert(shell.inSidebar, `${width}px：session-list 的祖先链必须含 session-sidebar`);
      assertNumber(shell.sidebarWidth, 224, `${width}px 左侧会话列表宽度`, 0.5);
      assert(shell.sidebarRight !== null && shell.mainLeft !== null, `${width}px：左列与主区都必须存在`);
      assert(
        shell.mainLeft >= shell.sidebarRight - 0.5,
        `${width}px：主区必须从列表右侧开始（mainLeft=${shell.mainLeft} / sidebarRight=${shell.sidebarRight}）`,
      );
      assert(shell.mainCount === 1, `${width}px：页面必须恰好一个 main，实测 ${shell.mainCount}`);
      assert(
        shell.hitInList,
        `${width}px：elementFromPoint 必须命中会话列表（实测 ${shell.hitTestId}）`,
      );
      assert(
        shell.scrollWidth <= shell.innerWidth + 1,
        `${width}px：出现横向溢出（scrollWidth=${shell.scrollWidth} > innerWidth=${shell.innerWidth}）`,
      );
      assert(shell.errorBanner, `${width}px：ChatScreen 的 error 横幅不得被壳吞掉`);
      assert(shell.noticeBanner, `${width}px：ChatScreen 的 notice 横幅不得被壳吞掉`);
      assert(shell.skillFailures, `${width}px：ChatScreen 的 skillFailures 横幅不得被壳吞掉`);

      // 列表滚到中段 → 切会话 → scrollTop 不变、选中态跟随。
      await page.evaluate(() => {
        const list = document.querySelector('[data-testid="session-list"]');
        list.scrollTop = 600;
      });
      await new Promise((resolve) => setTimeout(resolve, 250));
      const scrollBefore = await page.$eval(
        '[data-testid="session-list"]',
        (element) => element.scrollTop,
      );
      const clicked = await page.evaluate(() => {
        const rows = [...document.querySelectorAll('[data-testid="session-row"]')];
        const target = rows[Math.min(2, rows.length - 1)];
        const label = target?.getAttribute('data-session-id') ?? null;
        target?.click();
        return label;
      });
      await new Promise((resolve) => setTimeout(resolve, 300));
      const afterClick = await page.evaluate(() => {
        const list = document.querySelector('[data-testid="session-list"]');
        const selected = [...document.querySelectorAll('[data-testid="session-row"][aria-current="true"]')];
        return {
          scrollTop: list?.scrollTop ?? null,
          selectedIds: selected.map((row) => row.getAttribute('data-session-id')),
          title: document.querySelector('[data-testid="current-session-title"]')?.textContent ?? '',
        };
      });
      obs(`${width}px 切会话后`, { scrollBefore, ...afterClick, clicked });
      assert(
        afterClick.scrollTop === scrollBefore,
        `${width}px：切会话不得重置列表滚动位置（前 ${scrollBefore} / 后 ${afterClick.scrollTop}）`,
      );
      assert(
        clicked !== null && afterClick.selectedIds.includes(clicked),
        `${width}px：选中态必须跟随被点的会话（点了 ${clicked}，选中 ${JSON.stringify(afterClick.selectedIds)}）`,
      );
      assert(
        afterClick.title.includes(clicked.replace('s-', '壳层会话 ')),
        `${width}px：主区标题必须跟着切到被点会话，实测「${afterClick.title}」`,
      );
    } finally {
      await page.close();
    }
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
// 1.3 会话侧栏交互（change `web-management-ui` 任务 1.3 / design D7）
// ---------------------------------------------------------------------------

const sidebarScenario = {
  sessions: [
    { id: 's-1', title: '原始会话', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
  ],
  messages: [{ id: 'm-1', role: 'user', content: '会话管理用例' }],
  templates: ['general', 'alt'],
  switchFailure: {
    templateName: 'alt',
    message:
      '模板切换失败（阶段：preflight / 候选预检，候选 "alt"）：' +
      'Agent 模板 "alt" 引用的 provider "q" 未定义：拒绝创建实例。',
  },
};

await run('会话侧栏：新建 / 内联重命名 / 删除确认 / 切换模板失败显示阶段与候选名', async () => {
  const page = await openPage(sidebarScenario);
  try {
    await page.waitForSelector('[data-testid="session-row"]', { timeout: 15000 });
    await new Promise((resolve) => setTimeout(resolve, 300));

    const snapshot = () =>
      page.evaluate(() => ({
        calls: window.__harness.calls(),
        titles: window.__harness.sessionTitles(),
      }));

    // ① 新建
    await page.click('[data-testid="session-create"]');
    await new Promise((resolve) => setTimeout(resolve, 200));
    let state = await snapshot();
    obs('新建后的标题 / 调用', state);
    assert(state.calls.includes('session.create'), '新建必须调用 session.create');
    assert(state.titles.length === 2, `新建后应有 2 条会话，实测 ${state.titles.length}`);
    assert(
      state.titles[0].includes('新建会话'),
      `新会话应出现在列表首位，实测首位「${state.titles[0]}」`,
    );

    // ② 内联重命名（第一行 = 刚建的新会话）
    await page.click('[data-testid="session-rename"]');
    await page.waitForSelector('[data-testid="session-rename-input"]', { timeout: 5000 });
    await page.click('[data-testid="session-rename-input"]');
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyA');
    await page.keyboard.up('Control');
    await page.type('[data-testid="session-rename-input"]', '改名的会话');
    await page.keyboard.press('Enter');
    await new Promise((resolve) => setTimeout(resolve, 200));
    state = await snapshot();
    obs('重命名后的标题 / 调用', state);
    assert(
      state.calls.some((call) => call.startsWith('session.rename:')),
      '重命名必须调用 session.rename',
    );
    assert(state.titles.includes('改名的会话'), '列表必须显示新标题');

    // ③ 删除需要确认：先弹浮层，取消不删
    await page.click('[data-testid="session-delete"]');
    await page.waitForSelector('[data-testid="delete-confirm"]', { timeout: 5000 });
    const confirmText = await page.$eval('[data-testid="delete-confirm"]', (node) => node.innerText);
    obs('删除确认浮层文案', confirmText);
    assert(confirmText.includes('删除会话'), '删除必须先弹确认浮层（不能直接删）');
    await page.click('[data-testid="delete-cancel"]');
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert(
      (await page.$('[data-testid="delete-confirm"]')) === null,
      '取消后确认浮层必须消失',
    );
    state = await snapshot();
    assert(!state.calls.some((call) => call.startsWith('session.delete:')), '取消后不得发起删除');

    // ④ 确认删除
    await page.click('[data-testid="session-delete"]');
    await page.waitForSelector('[data-testid="delete-confirm-button"]', { timeout: 5000 });
    await page.click('[data-testid="delete-confirm-button"]');
    await new Promise((resolve) => setTimeout(resolve, 250));
    state = await snapshot();
    obs('删除后的标题 / 调用', state);
    assert(
      state.calls.some((call) => call.startsWith('session.delete:')),
      '确认后必须调用 session.delete',
    );
    assert(state.titles.length === 1, `删除后应剩 1 条会话，实测 ${state.titles.length}`);
    assert(state.titles.includes('原始会话'), '剩下的必须是被删之外的那条');

    // ⑤ 切换模板失败：界面显示阶段 + 候选名
    await page.select('[data-testid="template-select"]', 'alt');
    await page.waitForSelector('[data-testid="switch-failure"]', { timeout: 5000 });
    const failure = await page.$eval('[data-testid="switch-failure"]', (node) => node.innerText);
    obs('切换失败提示', failure);
    assert(failure.includes('切换失败'), `失败提示必须出现，实测「${failure}」`);
    assert(failure.includes('候选预检'), `必须显示失败阶段，实测「${failure}」`);
    assert(failure.includes('alt'), `必须显示候选模板名，实测「${failure}」`);
    state = await snapshot();
    assert(
      state.calls.includes('session.switchTemplate:alt'),
      '必须真的调用 session.switchTemplate',
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 2.2 图片输入与渲染（change `web-management-ui` 任务 2.2 / design D12）
// ---------------------------------------------------------------------------

const PIXEL_PNG = path.join(ROOT, 'test', 'fixtures', 'pixel.png');
const PIXEL_DATA_URL =
  'data:image/png;base64,' +
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/wD/2y6JAAAAAElFTkSuQmCC';

await run('图片输入：选择图片→预览→可移除→发送带附件→消息渲染缩略图', async () => {
  const page = await openPage({
    sessions: [
      { id: 's-1', title: '图片用例', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
    ],
    messages: [],
    imagesSupported: true,
    attachments: {},
  });
  try {
    await page.waitForSelector('[data-testid="image-input"]', { timeout: 15000 });
    const input = await page.$('[data-testid="image-input"]');
    await input.uploadFile(PIXEL_PNG);
    await page.waitForSelector('[data-testid="pending-image"]', { timeout: 5000 });
    let count = await page.$$eval('[data-testid="pending-image"]', (nodes) => nodes.length);
    obs('选择图片后的预览数', count);
    assert(count === 1, `选一张图片应出现 1 个预览，实测 ${count}`);
    const previewSrc = await page.$eval('[data-testid="pending-image"] img', (node) =>
      node.getAttribute('src'),
    );
    assert(
      typeof previewSrc === 'string' && previewSrc.startsWith('data:image/png'),
      `预览必须是本地 data URL，实测 ${String(previewSrc).slice(0, 30)}`,
    );

    // 移除
    await page.click('[data-testid="pending-image-remove"]');
    await new Promise((resolve) => setTimeout(resolve, 150));
    count = await page.$$eval('[data-testid="pending-image"]', (nodes) => nodes.length);
    obs('移除后的预览数', count);
    assert(count === 0, '点移除后预览必须消失');

    // 重新选择 + 发送
    await input.uploadFile(PIXEL_PNG);
    await page.waitForSelector('[data-testid="pending-image"]', { timeout: 5000 });
    await page.type('[data-testid="composer"]', '看这张图');
    await page.click('[data-testid="send"]');
    await new Promise((resolve) => setTimeout(resolve, 400));
    const state = await page.evaluate(() => ({ calls: window.__harness.calls() }));
    obs('发送调用', state.calls);
    assert(
      state.calls.some((call) => call === 'agent.send:看这张图:1'),
      `发送必须带 1 张图片，实测 ${JSON.stringify(state.calls)}`,
    );
    const thumbnails = await page.$$eval('[data-testid="attachment-thumbnail"]', (nodes) => nodes.length);
    obs('消息里的缩略图数', thumbnails);
    assert(thumbnails === 1, `发送后用户消息必须渲染附件缩略图，实测 ${thumbnails}`);
    assert(
      (await page.$$eval('[data-testid="pending-image"]', (nodes) => nodes.length)) === 0,
      '发送后预览必须清空',
    );
  } finally {
    await page.close();
  }
});

await run('模型未声明 image：消息下方显示「图片未发送」提示行（不静默丢图）', async () => {
  const page = await openPage({
    sessions: [
      { id: 's-1', title: '模态用例', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
    ],
    messages: [{ id: 'u-1', role: 'user', content: '贴了张图', attachments: ['/x/a.png'] }],
    attachments: { '/x/a.png': PIXEL_DATA_URL },
    imagesSupported: false,
  });
  try {
    await page.waitForSelector('[data-testid="attachment-not-sent"]', { timeout: 15000 });
    const text = await page.$eval('[data-testid="attachment-not-sent"]', (node) => node.innerText);
    obs('未发送提示', text);
    assert(text.includes('图片未发送'), `提示必须写明图片未发送，实测「${text}」`);
    const thumbnails = await page.$$eval('[data-testid="attachment-thumbnail"]', (nodes) => nodes.length);
    assert(thumbnails === 1, '本地有字节时仍显示缩略图（提示是附加信息，不是隐藏图片）');
  } finally {
    await page.close();
  }
});

await run('附件文件丢失：消息下方显示「图片已丢失」提示行', async () => {
  const page = await openPage({
    sessions: [
      { id: 's-1', title: '丢失用例', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
    ],
    messages: [{ id: 'u-1', role: 'user', content: '这张图没了', attachments: ['/x/gone.png'] }],
    attachments: { '/x/gone.png': null },
    imagesSupported: true,
  });
  try {
    await page.waitForSelector('[data-testid="attachment-missing"]', { timeout: 15000 });
    const text = await page.$eval('[data-testid="attachment-missing"]', (node) => node.innerText);
    obs('丢失提示', text);
    assert(text.includes('图片已丢失'), `提示必须写明图片已丢失，实测「${text}」`);
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 2.3 占用环 + 真实上下文视图（change `web-management-ui` 任务 2.3 / design D13）
// ---------------------------------------------------------------------------

const FULL_TURN = Math.PI * 2;

const ringScenario = {
  sessions: [
    { id: 's-1', title: '占用环用例', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
  ],
  messages: [{ id: 'm-1', role: 'user', content: '环用例' }],
  snapshot: {
    sessionId: 's-1',
    model: 'm',
    thinkingMode: 'thinking',
    thinkingEffort: 'max',
    capturedAt: '2026-11-22T00:00:00.000Z',
    windowTokens: 100,
    agentType: 'general',
    breakdown: {
      level2Tokens: 80,
      level1Tokens: 80,
      rawTokens: 80,
      fixedOverheadTokens: 10,
      windowTokens: 100,
      usedTokens: 250,
      conversationTokens: 240,
    },
    messages: [{ role: 'user', content: 'hello' }],
    system: 'SYSTEM_PROMPT_MARK_777',
    tools: '[{"name":"read_file"}]',
    skillFailures: [],
    skillFailureNotice: null,
  },
};

await run('占用环：三瓣比例 + 超窗口整圈钳制（超出不画、tokens 保留）', async () => {
  const page = await openPage(ringScenario);
  try {
    await page.waitForSelector('[data-testid="context-ring"]', { timeout: 15000 });
    const svgBox = await page.$eval('[data-testid="context-ring"]', (node) => {
      const rect = node.getBoundingClientRect();
      return { width: rect.width, height: rect.height };
    });
    obs('环的尺寸', svgBox);
    assert(svgBox.width > 0 && svgBox.height > 0, '占用环必须有可见尺寸');

    const slices = await page.$$eval('[data-testid="ring-slice"]', (nodes) =>
      nodes.map((node) => ({
        tokens: Number(node.dataset.tokens),
        sweep: Number(node.dataset.sweep),
        hasPath: (node.getAttribute('d') ?? '').length > 0,
      })),
    );
    obs('三瓣实测', slices);
    const sweeps = slices.map((slice) => slice.sweep);
    const total = sweeps.reduce((sum, value) => sum + value, 0);
    obs('弧度之和 / 整圈', { total, FULL_TURN });
    assert(total <= FULL_TURN + 1e-6, `整圈不得被画过：实测总弧度 ${total} > 2π`);
    assert(
      Math.abs(total - FULL_TURN) < 1e-6,
      `三段之和超窗口时必须累加到整圈为止（总弧度 ${total}）`,
    );
    assert(slices.every((slice) => slice.hasPath), '画出来的每一瓣都必须有路径');
    assert(slices[0].tokens === 80, `第一瓣 tokens 必须保留原值，实测 ${slices[0].tokens}`);
    assert(
      slices.length === 2,
      `第三段被钳制成 0 弧度不应画出来，实测 ${slices.length} 瓣`,
    );

    const legend = await page.$$eval('[data-testid="ring-legend"]', (nodes) =>
      nodes.map((node) => ({ tokens: Number(node.dataset.tokens), text: node.innerText })),
    );
    obs('图例', legend);
    assert(legend.length === 3, `图例必须三瓣（tokens 保留原值），实测 ${legend.length}`);
    assert(
      legend.map((item) => item.tokens).join(',') === '80,80,80',
      `tokens 原值必须保留，实测 ${legend.map((item) => item.tokens).join(',')}`,
    );
    const totalText = await page.$eval('[data-testid="ring-total"]', (node) => node.innerText);
    obs('合计文案', totalText);
    assert(totalText.includes('240'), `合计应显示对话 240 tokens，实测「${totalText}」`);
    assert(totalText.includes('100'), `合计应显示窗口 100 tokens，实测「${totalText}」`);
  } finally {
    await page.close();
  }
});

await run('真实上下文视图：显示 system/messages/tools 原始 JSON 且可复制', async () => {
  const page = await openPage(ringScenario);
  try {
    await page.waitForSelector('[data-testid="toggle-real-context"]', { timeout: 15000 });
    assert(
      (await page.$('[data-testid="real-context"]')) === null,
      '真实上下文视图默认收起（不占屏）',
    );
    await page.click('[data-testid="toggle-real-context"]');
    await page.waitForSelector('[data-testid="real-context"]', { timeout: 5000 });
    const json = await page.$eval('[data-testid="real-context-json"]', (node) => node.innerText);
    obs('真实上下文 JSON（前 120 字）', json.slice(0, 120));
    for (const anchor of ['"system"', '"messages"', '"tools"', 'SYSTEM_PROMPT_MARK_777', 'read_file']) {
      assert(json.includes(anchor), `真实上下文 JSON 必须包含 ${anchor}`);
    }
    const copyButton = await page.$('[data-testid="copy-real-context"]');
    assert(copyButton !== null, '真实上下文必须提供复制按钮');
    const scrollable = await page.$eval('[data-testid="real-context-json"]', (node) => {
      const style = getComputedStyle(node);
      return { overflow: style.overflow, maxHeight: style.maxHeight };
    });
    obs('真实上下文滚动样式', scrollable);
    assert(scrollable.overflow === 'auto', `内容区必须可滚，实测 overflow=${scrollable.overflow}`);
  } finally {
    await page.close();
  }
});

await run('快照没有 breakdown：显式提示不渲染环（不静默当成 0）', async () => {
  const page = await openPage({
    sessions: [
      { id: 's-1', title: '无拆解用例', agentType: 'general', parentSessionId: null, createdAt: 1, updatedAt: 1 },
    ],
    messages: [{ id: 'm-1', role: 'user', content: 'hi' }],
    snapshot: {
      sessionId: 's-1',
      model: 'm',
      thinkingMode: 'thinking',
      thinkingEffort: 'max',
      capturedAt: '2026-11-22T00:00:00.000Z',
      windowTokens: 100,
      agentType: 'general',
      breakdown: null,
      messages: [],
      skillFailures: [],
      skillFailureNotice: null,
    },
  });
  try {
    await page.waitForSelector('[data-testid="no-breakdown"]', { timeout: 15000 });
    assert((await page.$('[data-testid="context-ring"]')) === null, '没有拆解时不得渲染环');
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 3.3 Provider 管理页（change `web-management-ui` 任务 3.3 / design D8）
// ---------------------------------------------------------------------------

const providersScenario = {
  mode: 'providers',
  fake: {
    config: {
      missing: false,
      configPath: 'C:\\tmp\\config.json',
      providers: {
        p: {
          baseUrl: 'http://127.0.0.1:1',
          hasApiKey: true,
          models: [{ id: 'm1' }],
          discoveredAt: '2026-01-01T00:00:00Z',
        },
        q: {
          baseUrl: 'http://127.0.0.1:2',
          hasApiKey: true,
          models: [],
          discoveredAt: null,
        },
      },
      agentTypes: { general: { provider: 'p' } },
      tools: ['read_file'],
    },
    templates: {
      templates: [{ name: 'general', provider: 'p' }],
      tools: ['read_file'],
      providers: ['p', 'q'],
      defaultTools: ['read_file'],
      thinkingEfforts: ['max'],
      allowedModalities: ['text', 'image'],
      effectiveNote: '',
    },
    probeResults: {
      p: {
        ok: true,
        providerName: 'p',
        entries: [{ id: 'm3' }, { id: 'm4' }],
        added: 2,
        updated: 0,
        removed: 0,
        dropped: 0,
        discoveredAt: '2026-11-22T00:00:00Z',
        error: null,
      },
    },
  },
};

await run('Provider 页：列表（密钥不回显）+ 探测 + 编辑留空沿用 + 删除被引用拒绝显示名单', async () => {
  const page = await openPage(providersScenario);
  try {
    await page.waitForSelector('[data-testid="provider-row"]', { timeout: 15000 });
    const rows = await page.$$eval('[data-testid="provider-row"]', (nodes) =>
      nodes.map((node) => ({ name: node.dataset.name, text: node.innerText })),
    );
    obs('provider 行', rows.map((row) => row.name));
    assert(rows.length === 2, `应有 2 个 provider，实测 ${rows.length}`);
    const pageText = await page.$eval('[data-testid="providers-page"]', (node) => node.innerText);
    assert(pageText.includes('已配置（不回显）'), '列表必须说明密钥不回显');
    assert(!pageText.includes('key-'), '列表不得出现任何密钥内容');

    // 探测
    await page.click('[data-testid="provider-row"][data-name="p"] [data-testid="provider-probe"]');
    await page.waitForSelector('[data-testid="provider-report"]', { timeout: 5000 });
    const report = await page.$eval('[data-testid="provider-report"]', (node) => node.innerText);
    obs('探测报告', report);
    assert(report.includes('新增 2'), `探测报告必须显示四类计数，实测「${report}」`);
    assert(report.includes('discovered_at'), '探测成功必须显示 discovered_at');

    // 编辑：密钥框不回填原值；留空保存 = payload 不带 api_key
    await page.click('[data-testid="provider-row"][data-name="p"] [data-testid="provider-edit"]');
    await page.waitForSelector('[data-testid="provider-form-api-key"]', { timeout: 5000 });
    const prefilled = await page.$eval('[data-testid="provider-form-api-key"]', (node) => node.value);
    obs('编辑时密钥框的值长度', prefilled.length);
    assert(prefilled === '', '编辑时密钥框不得回填原密钥');
    await page.click('[data-testid="provider-form-base-url"]');
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyA');
    await page.keyboard.up('Control');
    await page.type('[data-testid="provider-form-base-url"]', 'http://127.0.0.1:5');
    await page.click('[data-testid="provider-form-save"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const afterSave = await page.evaluate(() => window.__harness.calls());
    const saveCall = afterSave.find((call) => call.startsWith('config.save:'));
    obs('config.save 调用', saveCall);
    assert(saveCall !== undefined, '保存必须调用 config.save');
    assert(saveCall.includes('http://127.0.0.1:5'), '保存必须带上新的 base_url');
    assert(!saveCall.includes('api_key'), '密钥留空时 payload 不得带 api_key（核心沿用原密钥）');
    assert(
      afterSave.some((call) => call.startsWith('provider.probe:')),
      '保存成功后必须自动探测一次（D8）',
    );

    // 删除无引用 provider（q）
    await page.click('[data-testid="provider-row"][data-name="q"] [data-testid="provider-delete"]');
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert(
      (await page.$('[data-testid="provider-row"][data-name="q"]')) === null,
      '无引用 provider 删除后必须从列表消失',
    );

    // 删除被 general 引用的 p：拒绝并显示引用名单
    await page.click('[data-testid="provider-row"][data-name="p"] [data-testid="provider-delete"]');
    await page.waitForSelector('[data-testid="provider-delete-error"]', { timeout: 5000 });
    const deleteError = await page.$eval(
      '[data-testid="provider-delete-error"]',
      (node) => node.innerText,
    );
    obs('删除被引用 provider 的提示', deleteError);
    assert(deleteError.includes('general'), `必须显示引用名单，实测「${deleteError}」`);
    assert(deleteError.includes('不能删除'), '必须说明为什么不能删');
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 3.4 模板编辑页（change `web-management-ui` 任务 3.4 / design D9）
// ---------------------------------------------------------------------------

const templatesScenario = {
  mode: 'templates',
  fake: {
    config: {
      missing: false,
      configPath: 'C:\\tmp\\config.json',
      providers: {
        p: {
          baseUrl: 'http://127.0.0.1:1',
          hasApiKey: true,
          models: [
            {
              id: 'catalog-model',
              display_name: '目录模型',
              context_window: 1048576,
              modalities: { input: ['text', 'image'] },
            },
          ],
          discoveredAt: null,
        },
      },
      agentTypes: { general: { provider: 'p' } },
      tools: ['read_file'],
    },
    templates: {
      templates: [
        {
          name: 'general',
          provider: 'p',
          model: 'm',
          thinking_effort: 'low',
          tools: ['read_file'],
          input_modalities: ['text'],
        },
        {
          name: 'alt',
          provider: 'p',
          model: 'm2',
          thinking_effort: 'max',
          tools: ['read_file'],
          input_modalities: ['text', 'image'],
        },
      ],
      tools: ['read_file', 'list_dir'],
      providers: ['p'],
      defaultTools: ['read_file'],
      thinkingEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      allowedModalities: ['text', 'image'],
      effectiveNote: '只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。',
    },
  },
};

await run('模板页：字段齐全 + 生效时机提示 + 目录回填 + 模态勾选 + general 不可删', async () => {
  const page = await openPage(templatesScenario);
  try {
    await page.waitForSelector('[data-testid="template-row"]', { timeout: 15000 });
    const rows = await page.$$eval('[data-testid="template-row"]', (nodes) =>
      nodes.map((node) => node.dataset.name),
    );
    obs('模板行', rows);
    assert(rows.length === 2, `应有 2 个模板，实测 ${rows.length}`);
    const note = await page.$eval('[data-testid="template-effective-note"]', (node) => node.innerText);
    obs('生效时机提示', note);
    assert(note.includes('只有推理强度'), '必须显示生效时机提示（复刻 kAgentTemplateEffectiveNote）');

    // 编辑 general：名字只读；模态勾选存在
    await page.click('[data-testid="template-row"][data-name="general"] [data-testid="template-edit"]');
    await page.waitForSelector('[data-testid="template-form-name"]', { timeout: 5000 });
    const readonly = await page.$eval('[data-testid="template-form-name"]', (node) => ({
      ro: node.getAttribute('readonly'),
      flag: node.dataset.readonly,
    }));
    obs('模板名只读状态', readonly);
    assert(readonly.ro !== null && readonly.flag === 'true', '编辑既有模板时模板名必须只读');
    assert(
      (await page.$('[data-testid="template-modality-image"]')) !== null,
      '必须有 input_modalities 的 image 勾选框',
    );

    // 目录选模型 → 回填窗口 + 模态
    await page.select('[data-testid="template-form-catalog-model"]', 'catalog-model');
    await new Promise((resolve) => setTimeout(resolve, 150));
    const filled = await page.evaluate(() => ({
      model: document.querySelector('[data-testid="template-form-model"]').value,
      window: document.querySelector('[data-testid="template-form-max-context"]').value,
      image: document.querySelector('[data-testid="template-modality-image"]').checked,
    }));
    obs('目录回填结果', filled);
    assert(filled.model === 'catalog-model', '选目录模型必须填模型名');
    assert(filled.window === '1048576', `必须回填目录窗口，实测「${filled.window}」`);
    assert(filled.image === true, '目录声明 image 时必须勾上 image 模态');

    // 取消 image + 改推理强度 → 保存 payload
    await page.click('[data-testid="template-modality-image"]');
    await page.select('[data-testid="template-form-thinking"]', 'max');
    await page.click('[data-testid="template-form-save"]');
    await new Promise((resolve) => setTimeout(resolve, 400));
    const calls = await page.evaluate(() => window.__harness.calls());
    const saveCall = calls.find((call) => call.startsWith('template.save:'));
    obs('template.save 调用', saveCall);
    assert(saveCall !== undefined, '保存必须调用 template.save');
    assert(saveCall.includes('"model":"catalog-model"'), 'payload 必须带模型名');
    assert(saveCall.includes('"thinkingEffort":"max"'), 'payload 必须带推理强度');
    assert(saveCall.includes('"inputModalities":["text"]'), '取消勾选后 modal 只能剩 text');
    assert(saveCall.includes('"originalName":"general"'), '编辑必须带 originalName');

    // 删除 general 被拒
    await page.click('[data-testid="template-row"][data-name="general"] [data-testid="template-delete"]');
    await page.waitForSelector('[data-testid="template-delete-error"]', { timeout: 5000 });
    const deleteError = await page.$eval(
      '[data-testid="template-delete-error"]',
      (node) => node.innerText,
    );
    obs('删 general 提示', deleteError);
    assert(deleteError.includes('不可删'), `general 必须不可删，实测「${deleteError}」`);

    // 删除 alt 成功
    await page.click('[data-testid="template-row"][data-name="alt"] [data-testid="template-delete"]');
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert(
      (await page.$('[data-testid="template-row"][data-name="alt"]')) === null,
      '删除后模板必须从列表消失',
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 3.5 首启向导（change `web-management-ui` 任务 3.5 / design D11）
// ---------------------------------------------------------------------------

function wizardScenario(firstModelId) {
  return {
    mode: 'wizard',
    fake: {
      config: {
        missing: true,
        configPath: 'C:\\tmp\\config.json',
        providers: {},
        agentTypes: {},
        tools: [],
      },
      templates: {
        templates: [],
        tools: ['read_file', 'list_dir'],
        providers: [],
        defaultTools: ['read_file', 'list_dir'],
        thinkingEfforts: ['max'],
        allowedModalities: ['text', 'image'],
        effectiveNote: '',
      },
      probeFetchQueue: [
        {
          ok: true,
          entries: [{ id: firstModelId }, { id: 'another-model' }],
          dropped: 0,
          error: null,
        },
      ],
    },
  };
}

async function fillWizard(page) {
  await page.waitForSelector('[data-testid="wizard"]', { timeout: 15000 });
  await page.click('[data-testid="wizard-base-url"]');
  await page.type('[data-testid="wizard-base-url"]', 'http://127.0.0.1:3425');
  await page.click('[data-testid="wizard-api-key"]');
  await page.type('[data-testid="wizard-api-key"]', 'wizard-key');
  await page.click('[data-testid="wizard-next"]');
  await page.waitForSelector('[data-testid="wizard-model-select"]', { timeout: 5000 });
}

await run('首启向导：probeFetch 首项即默认模型 + Start 一次写盘（config.save + template.save）', async () => {
  const page = await openPage(wizardScenario('model-alpha'));
  try {
    await page.waitForSelector('[data-testid="wizard-provider-name"]', { timeout: 15000 });
    const defaultName = await page.$eval(
      '[data-testid="wizard-provider-name"]',
      (node) => node.value,
    );
    obs('默认 provider 名', defaultName);
    assert(defaultName === 'magpie', `默认 provider 名应为 magpie（可改），实测「${defaultName}」`);

    await fillWizard(page);
    const selected = await page.$eval('[data-testid="wizard-model-select"]', (node) => node.value);
    obs('默认选中的模型', selected);
    assert(selected === 'model-alpha', `默认必须选目录首项 model-alpha，实测「${selected}」`);

    await page.click('[data-testid="wizard-include-image"]');
    await page.click('[data-testid="wizard-start"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const calls = await page.evaluate(() => window.__harness.calls());
    obs('向导调用序列', calls.map((call) => call.slice(0, 40)));
    const configCall = calls.find((call) => call.startsWith('config.save:'));
    const templateCall = calls.find((call) => call.startsWith('template.save:'));
    assert(configCall !== undefined, 'Start 必须写 provider（config.save）');
    assert(configCall.includes('"models":[{"id":"model-alpha"}'), 'config.save 必须带上探测到的目录');
    assert(templateCall !== undefined, 'Start 必须建 general（template.save）');
    assert(templateCall.includes('"name":"general"'), 'Start 必须建 general 模板');
    assert(templateCall.includes('"model":"model-alpha"'), 'general 的模型必须取目录首项');
    assert(templateCall.includes('"inputModalities":["text","image"]'), '勾选后模态必须含 image');
    assert(calls.includes('wizard.done'), 'Start 成功后必须通知上层重载');
  } finally {
    await page.close();
  }
});

await run('首启向导：假 catalog 首项变化 ⇒ 选中模型跟着变（不写死，变异②红靶）', async () => {
  const page = await openPage(wizardScenario('model-x'));
  try {
    await fillWizard(page);
    const selected = await page.$eval('[data-testid="wizard-model-select"]', (node) => node.value);
    obs('第二份 catalog 的首项 / 选中', selected);
    assert(selected === 'model-x', `选中模型必须跟随 catalog 首项 model-x，实测「${selected}」`);
    assert(selected !== 'model-alpha', '不得写死任何模型名');

    // 探测阶段（还没点 Start）不得写盘。注意：这条必须在点 Start **之前**断言 ——
    // 点 Start 之后写盘是正确行为。
    const beforeStart = await page.evaluate(() => window.__harness.calls());
    const probeCall = beforeStart.find((call) => call.startsWith('provider.probeFetch:'));
    assert(probeCall !== undefined, '下一步必须走 probeFetch（只探测不写盘）');
    assert(
      !beforeStart.some((call) => call.startsWith('config.save:')),
      '仅探测阶段不得写盘（不写半份配置）',
    );

    // 红靶的真正判据在 **payload 通道**：React 受控 select 的 DOM value 在"state 与
    // 选项不匹配"时会自动回退显示首项，`node.value` 会被 DOM 掩盖（实测：把
    // pickDefaultModel 写死返回 model-alpha 后，这里仍读到 model-x 而全绿）。真实损害
    // 是 state 里的 selectedModel 被写进 general —— 所以必须点 Start 后查 payload。
    await page.click('[data-testid="wizard-start"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const calls = await page.evaluate(() => window.__harness.calls());
    obs('向导调用序列', calls.map((call) => call.slice(0, 48)));
    const configCall = calls.find((call) => call.startsWith('config.save:'));
    const templateCall = calls.find((call) => call.startsWith('template.save:'));
    assert(configCall !== undefined, 'Start 必须写 provider（config.save）');
    assert(
      configCall.includes('"models":[{"id":"model-x"},{"id":"another-model"}]'),
      `config.save 必须带上第二份 catalog（首项 model-x），实测：${configCall}`,
    );
    assert(templateCall !== undefined, 'Start 必须建 general（template.save）');
    assert(
      templateCall.includes('"model":"model-x"'),
      `general 的模型必须取第二份 catalog 的首项 model-x（payload 通道，实测：${templateCall}）`,
    );
    assert(
      !templateCall.includes('"model":"model-alpha"'),
      '不得把写死的模型名写进 general',
    );
    assert(calls.includes('wizard.done'), 'Start 成功后必须通知上层重载');
  } finally {
    await page.close();
  }
});

await run('首启向导：探测失败可归因且不写盘', async () => {
  const failureScenario = wizardScenario('model-alpha');
  failureScenario.fake.probeFetchQueue = [
    { ok: false, entries: [], dropped: 0, error: 'HTTP 500', errorFilePath: 'C:/tmp/e.txt' },
  ];
  const page = await openPage(failureScenario);
  try {
    await fillWizard(page).catch(() => {});
    await page.waitForSelector('[data-testid="wizard-error"]', { timeout: 5000 });
    const error = await page.$eval('[data-testid="wizard-error"]', (node) => node.innerText);
    obs('探测失败提示', error);
    assert(error.includes('HTTP 500'), `错误必须可归因，实测「${error}」`);
    assert(error.includes('C:/tmp/e.txt'), '必须回显错误落盘路径');
    const calls = await page.evaluate(() => window.__harness.calls());
    assert(
      !calls.some((call) => call.startsWith('config.save:')),
      '探测失败不得写盘',
    );
  } finally {
    await page.close();
  }
});

// ---------------------------------------------------------------------------
// 4.1 单聊气泡与头像（change `chat-bubbles-avatars` / design D4）
//
// 度量落点钉死：`user-message` / `assistant-message` / `streaming-message` 是**整行容器**
// （含头像），内层气泡 `data-testid="bubble"` + `data-bubble-side` 是**纯气泡**。
// 只量内层气泡的左缘；不量右缘（头像 + 间距在它右边，永远贴不上容器边）、也不量
// "宽度 < 容器一半"（短文本宽度与侧别无关）。
// ---------------------------------------------------------------------------

const AVATAR_IMAGE_PATH = 'C:/tmp/agent-avatar.png';

function bubbleScenario(overrides = {}) {
  return {
    sessions: [
      {
        id: 's-bubble',
        title: '气泡用例会话',
        agentType: 'general',
        parentSessionId: null,
        createdAt: 1,
        updatedAt: 1,
      },
    ],
    messages: [
      {
        id: 'u-bubble',
        role: 'user',
        content: '用户这一句不长',
        attachments: ['/x/att.png'],
      },
      { id: 'a-bubble', role: 'assistant', content: '助手回复一句。' },
    ],
    // 让「图片未发送」提示行出现（既有内容不许因改气泡而消失）。
    imagesSupported: false,
    attachments: { '/x/att.png': PIXEL_DATA_URL },
    profile: { avatarPath: null, userId: null, identitySeed: 'local-user' },
    templateAvatars: { general: AVATAR_IMAGE_PATH },
    avatarReads: { [AVATAR_IMAGE_PATH]: PIXEL_DATA_URL },
    ...overrides,
  };
}

async function readBubbleGeometry(page) {
  return page.evaluate(() => {
    const rect = (node) => {
      const box = node.getBoundingClientRect();
      return { left: box.left, right: box.right, width: box.width, height: box.height };
    };
    const area = document.querySelector('[data-testid="message-list"]');
    const userRow = document.querySelector('[data-testid="user-message"]');
    const assistantRow = document.querySelector('[data-testid="assistant-message"]');
    const userBubble = userRow.querySelector('[data-testid="bubble"]');
    const assistantBubble = assistantRow.querySelector('[data-testid="bubble"]');
    const userColumn = userRow.querySelector('[data-testid="bubble-column"]');
    const assistantColumn = assistantRow.querySelector('[data-testid="bubble-column"]');
    const userAvatar = userRow.querySelector('[data-avatar-source]');
    const assistantAvatar = assistantRow.querySelector('[data-avatar-source]');
    return {
      area: rect(area),
      userRow: rect(userRow),
      assistantRow: rect(assistantRow),
      userSide: userBubble.dataset.bubbleSide,
      userBubble: rect(userBubble),
      userColumn: rect(userColumn),
      userAvatar: rect(userAvatar),
      assistantSide: assistantBubble.dataset.bubbleSide,
      assistantBubble: rect(assistantBubble),
      assistantColumn: rect(assistantColumn),
      assistantAvatar: rect(assistantAvatar),
      userAvatarSource: userAvatar.dataset.avatarSource,
      userAvatarSeed: userAvatar.dataset.seed,
      assistantAvatarSource: assistantAvatar.dataset.avatarSource,
      assistantAvatarSeed: assistantAvatar.dataset.seed,
      userText: userRow.innerText,
      assistantText: assistantRow.innerText,
    };
  });
}

await run('单聊气泡与头像：用户靠右 / 助手靠左 / 头像在正确一侧 / 无角色标签', async () => {
  const page = await openPage(bubbleScenario());
  try {
    await page.waitForSelector('[data-testid="bubble"]', { timeout: 8000 });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const geo = await readBubbleGeometry(page);
    obs('单聊气泡几何', geo);

    // ① 用户内层气泡的**左缘**在消息区右半区。
    assert(geo.userSide === 'user', `用户内层气泡的 data-bubble-side 必须是 user，实测 ${geo.userSide}`);
    assert(
      geo.userBubble.left > geo.area.left + geo.area.width / 2,
      `用户气泡左缘必须落在消息区右半区（气泡 left=${geo.userBubble.left}，` +
        `中点=${geo.area.left + geo.area.width / 2}）`,
    );
    // ② 助手内层气泡贴着它自己那一列的左缘（≤1px），且整行靠左。
    assert(
      geo.assistantSide === 'agent',
      `助手内层气泡的 data-bubble-side 必须是 agent，实测 ${geo.assistantSide}`,
    );
    assert(
      Math.abs(geo.assistantBubble.left - geo.assistantColumn.left) <= 1,
      `助手气泡左缘必须贴着自己的列左缘（≤1px）：气泡 ${geo.assistantBubble.left} / 列 ${geo.assistantColumn.left}`,
    );
    // 助手整行靠左：头像贴消息行左缘（气泡列紧跟在头像右侧，所以列为 头像+间距）。
    assert(
      geo.assistantAvatar.left - geo.assistantRow.left <= 1,
      `助手头像必须贴消息行左缘（≤1px）：头像 ${geo.assistantAvatar.left} / 行 ${geo.assistantRow.left}`,
    );

    // ④ 头像位置：用户在行最右端、助手在行最左端（头像节点在气泡之外）。
    assert(
      geo.userAvatar.left >= geo.userBubble.right - 0.5,
      `用户头像必须在气泡右侧（头像 left=${geo.userAvatar.left} / 气泡 right=${geo.userBubble.right}）`,
    );
    assert(
      geo.userRow.right - geo.userAvatar.right <= 1,
      `用户头像必须贴消息行右缘（≤1px）：行 right=${geo.userRow.right} / 头像 right=${geo.userAvatar.right}`,
    );
    assert(
      geo.assistantAvatar.right <= geo.assistantBubble.left + 0.5,
      `助手头像必须在气泡左侧（头像 right=${geo.assistantAvatar.right} / 气泡 left=${geo.assistantBubble.left}）`,
    );

    // ⑤ 去掉 You / Assistant 角色标签。
    for (const [label, text] of [['用户', geo.userText], ['助手', geo.assistantText]]) {
      assert(!text.includes('You'), `${label}消息里不得再有「You」标签，实测「${text}」`);
      assert(
        !text.includes('Assistant'),
        `${label}消息里不得再有「Assistant」标签，实测「${text}」`,
      );
    }

    // ⑦ 上传图真显示：data URL、可解码、尺寸等于头像令牌值 24。
    assert(
      geo.assistantAvatarSource === 'upload',
      `模板有可读头像时助手头像来源必须是 upload，实测 ${geo.assistantAvatarSource}`,
    );
    const image = await page.$eval('[data-testid="assistant-message"] img[data-avatar-source]', (node) => ({
      src: node.getAttribute('src') ?? '',
      width: node.getBoundingClientRect().width,
      naturalWidth: node.naturalWidth,
      complete: node.complete,
    }));
    obs('上传头像的 img', image);
    assert(image.src.startsWith('data:'), `头像 <img> 的 src 必须是 data URL，实测 ${image.src.slice(0, 24)}`);
    assert(image.complete && image.naturalWidth > 0, '头像 <img> 必须真的解码出来（不是破图）');
    assertNumber(image.width, 24, '气泡内头像尺寸', 0.5);

    // ⑨ 既有附件缩略图与「图片未发送」提示行仍在。
    const attachments = await page.evaluate(() => ({
      thumbnails: document.querySelectorAll('[data-testid="attachment-thumbnail"]').length,
      notSent: document.querySelector('[data-testid="attachment-not-sent"]')?.innerText ?? '',
      missing: document.querySelector('[data-testid="attachment-missing"]') !== null,
    }));
    obs('附件渲染', attachments);
    assert(attachments.thumbnails === 1, `用户消息的附件缩略图必须仍在，实测 ${attachments.thumbnails}`);
    assert(
      attachments.notSent.includes('图片未发送'),
      `「图片未发送」提示行必须仍在且文案不变，实测「${attachments.notSent}」`,
    );
    assert(!attachments.missing, '不该出现「图片已丢失」提示（文件其实在）');

    if (process.env.LAYOUT_SHOT) {
      await page.screenshot({ path: process.env.LAYOUT_SHOT, fullPage: false });
      console.log(`[SHOT] captured ${process.env.LAYOUT_SHOT}`);
    }
  } finally {
    await page.close();
  }
});

await run('单聊头像：身份图案种子 = 会话 id；上传图读不到时回落身份图案且不阻断', async () => {
  // ⑥ 没有上传覆盖：助手身份图案的种子必须是会话 id。
  const identiconPage = await openPage(bubbleScenario({ templateAvatars: {} }));
  try {
    await identiconPage.waitForSelector('[data-testid="assistant-message"] [data-avatar-source]', {
      timeout: 8000,
    });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const avatar = await identiconPage.$eval(
      '[data-testid="assistant-message"] [data-avatar-source]',
      (node) => ({ source: node.dataset.avatarSource, seed: node.dataset.seed }),
    );
    obs('身份图案头像', avatar);
    assert(avatar.source === 'identicon', `无上传图时来源必须是 identicon，实测 ${avatar.source}`);
    assert(avatar.seed === 's-bubble', `身份图案种子必须是会话 id（s-bubble），实测 ${avatar.seed}`);
    const userAvatar = await identiconPage.$eval(
      '[data-testid="user-message"] [data-avatar-source]',
      (node) => ({ source: node.dataset.avatarSource, seed: node.dataset.seed }),
    );
    obs('用户身份图案头像', userAvatar);
    assert(userAvatar.source === 'identicon', '用户没有头像时也画身份图案');
    assert(userAvatar.seed === 'local-user', `用户身份图案种子必须是 identitySeed，实测 ${userAvatar.seed}`);
  } finally {
    await identiconPage.close();
  }

  // ⑧ 上传路径读不到（文件被删）：助手头像回落身份图案，正文与附件照常、无错误横幅。
  const missingPage = await openPage(
    bubbleScenario({ avatarReads: { [AVATAR_IMAGE_PATH]: null } }),
  );
  try {
    await missingPage.waitForSelector('[data-testid="assistant-message"]', { timeout: 8000 });
    await new Promise((resolve) => setTimeout(resolve, 400));
    const state = await missingPage.evaluate(() => ({
      source: document.querySelector('[data-testid="assistant-message"] [data-avatar-source]')
        ?.dataset.avatarSource,
      assistantText:
        document.querySelector('[data-testid="assistant-message"]')?.innerText ?? '',
      userText: document.querySelector('[data-testid="user-message"]')?.innerText ?? '',
      thumbnails: document.querySelectorAll('[data-testid="attachment-thumbnail"]').length,
      errorBanner: document.querySelector('[data-testid="error-banner"]') !== null,
    }));
    obs('头像文件丢失后的单聊', state);
    assert(state.source === 'identicon', `读不到头像字节时必须回落身份图案，实测 ${state.source}`);
    assert(state.assistantText.includes('助手回复一句'), '助手正文必须照常渲染');
    assert(state.userText.includes('用户这一句不长'), '用户正文必须照常渲染');
    assert(state.thumbnails === 1, '附件缩略图必须照常渲染');
    assert(!state.errorBanner, '头像读失败是装饰性资源，不得弹错误横幅');
  } finally {
    await missingPage.close();
  }
});

// ---------------------------------------------------------------------------
// 6.1 头像上传：模板页与侧栏用户头像（change `chat-bubbles-avatars` / design D3）
// ---------------------------------------------------------------------------

const AVATAR_PICK_FILENAME = 'pixel.png';
/** 假核心的 attachment.upload 返回的确定性路径（见 web/test/harness/main.tsx）。 */
const AVATAR_UPLOADED_PATH = `uploaded/${AVATAR_PICK_FILENAME}`;

function callsOf(calls, prefix) {
  return calls.filter((call) => call.startsWith(prefix));
}

function payloadOf(call) {
  const at = call.indexOf(':');
  return JSON.parse(call.slice(at + 1));
}

await run('模板页头像：选择→attachment.upload→template.save 带 avatarPath；清除提交空串；没碰不带字段', async () => {
  const scenario = {
    mode: 'templates',
    fake: templatesScenario.fake,
    avatarReads: {},
  };
  const page = await openPage(scenario);
  try {
    await page.waitForSelector('[data-testid="template-row"]', { timeout: 15000 });
    await page.click('[data-testid="template-row"][data-name="general"] [data-testid="template-edit"]');
    await page.waitForSelector('[data-testid="template-avatar-preview"]', { timeout: 8000 });
    assert(
      (await page.$('[data-testid="template-avatar-upload"]')) !== null,
      '模板页必须有头像选择入口 template-avatar-upload',
    );
    assert(
      (await page.$('[data-testid="template-avatar-clear"]')) !== null,
      '模板页必须有头像清除入口 template-avatar-clear',
    );

    // ① 选图 → attachment.upload → 保存带 avatarPath（等于上传返回路径）。
    await (await page.$('[data-testid="template-avatar-upload"]')).uploadFile(PIXEL_PNG);
    await page.waitForFunction(
      () => window.__harness.calls().some((call) => call.startsWith('attachment.upload:')),
      { timeout: 8000 },
    );
    await page.click('[data-testid="template-form-save"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const afterUpload = await page.evaluate(() => window.__harness.calls());
    const uploadCall = callsOf(afterUpload, 'attachment.upload:').at(-1);
    const saveCall = callsOf(afterUpload, 'template.save:').at(-1);
    obs('template.save payload（上传后）', saveCall);
    assert(uploadCall !== undefined, '选图必须走 attachment.upload');
    assert(saveCall !== undefined, '保存必须调用 template.save');
    assert(
      payloadOf(uploadCall).filename === AVATAR_PICK_FILENAME,
      `attachment.upload 必须带上文件名，实测 ${uploadCall}`,
    );
    assert(
      payloadOf(saveCall).avatarPath === AVATAR_UPLOADED_PATH,
      `template.save 的 avatarPath 必须等于上传返回路径（${AVATAR_UPLOADED_PATH}），` +
        `实测 ${JSON.stringify(payloadOf(saveCall))}`,
    );

    // ② 清除：提交空串。
    await page.click('[data-testid="template-row"][data-name="general"] [data-testid="template-edit"]');
    await page.waitForSelector('[data-testid="template-avatar-clear"]', { timeout: 8000 });
    await page.click('[data-testid="template-avatar-clear"]');
    await page.click('[data-testid="template-form-save"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const afterClear = await page.evaluate(() => window.__harness.calls());
    const clearSave = callsOf(afterClear, 'template.save:').at(-1);
    obs('template.save payload（清除后）', clearSave);
    assert(
      payloadOf(clearSave).avatarPath === '',
      `清除头像必须提交空串 avatarPath，实测 ${JSON.stringify(payloadOf(clearSave))}`,
    );

    // ③ 没碰头像的保存不带该字段。
    await page.click('[data-testid="template-row"][data-name="general"] [data-testid="template-edit"]');
    await page.waitForSelector('[data-testid="template-form-model"]', { timeout: 8000 });
    await page.click('[data-testid="template-form-model"]');
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyA');
    await page.keyboard.up('Control');
    await page.type('[data-testid="template-form-model"]', 'm-touched');
    await page.click('[data-testid="template-form-save"]');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const afterPlain = await page.evaluate(() => window.__harness.calls());
    const plainSave = callsOf(afterPlain, 'template.save:').at(-1);
    obs('template.save payload（没碰头像）', plainSave);
    assert(
      !Object.prototype.hasOwnProperty.call(payloadOf(plainSave), 'avatarPath'),
      `没碰头像的保存不得带 avatarPath，实测 ${JSON.stringify(payloadOf(plainSave))}`,
    );

    if (process.env.LAYOUT_SHOT_TEMPLATES) {
      await page.screenshot({ path: process.env.LAYOUT_SHOT_TEMPLATES, fullPage: false });
      console.log(`[SHOT] captured ${process.env.LAYOUT_SHOT_TEMPLATES}`);
    }
  } finally {
    await page.close();
  }
});

await run('侧栏用户头像：换头像走 profile.save 带路径；恢复默认提交空串；config.get 失败可见并可重试', async () => {
  const scenario = bubbleScenario({ templateAvatars: {} });
  const page = await openPage(scenario);
  try {
    await page.waitForSelector('[data-testid="user-avatar-block"]', { timeout: 8000 });
    assert((await page.$('[data-testid="user-avatar-change"]')) !== null, '侧栏必须有「换头像」入口');
    assert((await page.$('[data-testid="user-avatar-reset"]')) !== null, '侧栏必须有「恢复默认」入口');

    // ① 换头像：attachment.upload + profile.save（payload 带路径）。
    await (await page.$('[data-testid="user-avatar-file"]')).uploadFile(PIXEL_PNG);
    await page.waitForFunction(
      () => window.__harness.calls().some((call) => call.startsWith('profile.save:')),
      { timeout: 8000 },
    );
    const afterChange = await page.evaluate(() => window.__harness.calls());
    const profileSave = callsOf(afterChange, 'profile.save:').at(-1);
    obs('profile.save payload（换头像）', profileSave);
    assert(
      callsOf(afterChange, 'attachment.upload:').length >= 1,
      '换头像必须先走 attachment.upload',
    );
    const savedPath = payloadOf(profileSave).avatarPath;
    assert(savedPath && savedPath.length > 0, `profile.save 必须带上传路径，实测 ${profileSave}`);
    await page.waitForFunction(
      () =>
        document.querySelector('[data-testid="user-avatar-block"] [data-avatar-source]')
          ?.dataset.avatarSource === 'upload',
      { timeout: 8000 },
    );
    const changed = await page.$eval(
      '[data-testid="user-avatar-block"] [data-avatar-source]',
      (node) => node.dataset.avatarSource,
    );
    obs('换头像后侧栏头像来源', changed);
    assert(changed === 'upload', '换头像成功后侧栏头像必须立刻变成上传图（不刷新整页）');

    // ② 恢复默认：profile.save 的 avatarPath 为空串。
    await page.click('[data-testid="user-avatar-reset"]');
    await page.waitForFunction(
      () => {
        const calls = window.__harness.calls().filter((call) => call.startsWith('profile.save:'));
        return calls.length >= 2 && JSON.parse(calls.at(-1).slice('profile.save:'.length)).avatarPath === '';
      },
      { timeout: 8000 },
    );
    const afterReset = await page.evaluate(() =>
      window.__harness.calls().filter((call) => call.startsWith('profile.save:')).at(-1),
    );
    obs('profile.save payload（恢复默认）', afterReset);
    const resetSource = await page.$eval(
      '[data-testid="user-avatar-block"] [data-avatar-source]',
      (node) => node.dataset.avatarSource,
    );
    assert(resetSource === 'identicon', '恢复默认后回到身份图案');
  } finally {
    await page.close();
  }

  // ③ config.get 失败：头像块显示可归因提示 + 重试，聊天屏仍渲染。
  const failedPage = await openPage(bubbleScenario({ profileFail: true }));
  try {
    await failedPage.waitForSelector('[data-testid="user-avatar-error"]', { timeout: 8000 });
    await failedPage.waitForSelector('[data-testid="message-list"]', { timeout: 8000 });
    const state = await failedPage.evaluate(() => ({
      error: document.querySelector('[data-testid="user-avatar-error"]')?.innerText ?? '',
      retry: document.querySelector('[data-testid="user-avatar-retry"]') !== null,
      messageList: document.querySelector('[data-testid="message-list"]') !== null,
      avatarSource: document.querySelector('[data-testid="user-avatar-block"] [data-avatar-source]')
        ?.dataset.avatarSource,
    }));
    obs('config.get 失败时的头像块', state);
    assert(
      state.error.includes('头像资料读取失败'),
      `必须显示可归因的读取失败提示，实测「${state.error}」`,
    );
    assert(state.retry, '读取失败提示必须带重试入口');
    assert(state.messageList, 'config.get 失败不得挡住聊天屏');
    assert(state.avatarSource === 'identicon', '读取失败时头像按身份图案渲染');
  } finally {
    await failedPage.close();
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
