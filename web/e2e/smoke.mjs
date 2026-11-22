// 无头浏览器驱动（live 视觉验收通道）：用本机 Edge + puppeteer-core 打开核心
// serve 的验证页，输入一句话并按 Enter 发送，等流式回复结束后截图并输出页面现场。
//
// 用法（由 `integration_test/web_core_shim_live_test.dart` 调起）：
//   EDGE_PATH=C:\...\msedge.exe node e2e/smoke.mjs <url> <screenshot> <prompt>
//
// 输出：一行 JSON（页面实际看到的状态）。断言在 Dart 侧做，这里只负责驱动与取证。
import puppeteer from 'puppeteer-core';

const [url, screenshotPath, prompt] = process.argv.slice(2);
const edgePath = process.env.EDGE_PATH;
if (!url || !screenshotPath || !prompt) {
  console.error('usage: node e2e/smoke.mjs <url> <screenshot> <prompt>');
  process.exit(2);
}
if (!edgePath) {
  console.error('EDGE_PATH 未设置（指向 msedge.exe）');
  process.exit(2);
}

const browser = await puppeteer.launch({
  executablePath: edgePath,
  headless: true,
  args: [
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--hide-scrollbars',
  ],
});

const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 900 });

const report = {
  url,
  steps: [],
};

try {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  report.steps.push('goto');

  await page.waitForSelector('[data-testid="connection-status"]', {
    timeout: 15000,
  });
  await page.waitForFunction(
    () =>
      (document.querySelector('[data-testid="connection-status"]')
        ?.textContent ?? '').includes('已连接'),
    { timeout: 15000 },
  );
  report.steps.push('ws-connected');

  report.sessions = await page.$$eval(
    '[data-testid="session-list"] button',
    (nodes) => nodes.map((node) => node.textContent),
  );

  await page.click('[data-testid="composer"]');
  await page.keyboard.type(prompt, { delay: 8 });
  await page.keyboard.press('Enter');
  report.steps.push('sent');

  // 先等到流式开始（工具轮期间 isStreaming 一直为 true，不会在两轮之间闪断）。
  // 极快的回复可能错过 true 的窗口：抓不到就继续等结束，不判失败。
  await page
    .waitForFunction(
      () =>
        document.querySelector('[data-streaming]')?.getAttribute(
          'data-streaming',
        ) === 'true',
      { timeout: 5000 },
    )
    .catch(() => {});
  report.steps.push('streaming-started');

  // 等到整轮结束（Agent 只在最后一轮 done 后推 streaming=false）。
  await page.waitForFunction(
    () =>
      document.querySelector('[data-streaming]')?.getAttribute(
        'data-streaming',
      ) === 'false',
    { timeout: 240000 },
  );
  report.steps.push('stream-finished');

  // 给 React 一次渲染时机（最后一条 assistant.message 可能在 streaming 结束前入列）。
  await new Promise((resolve) => setTimeout(resolve, 1200));

  // change web-chat-screen（审查 TC-5）：完整聊天屏自带贴底跟随，**不再手动滚底**——
  // 手动滚底会用人造状态掏空"贴底"断言。这里只**测量**列表是否自然停在底部，
  // 由 Dart 侧断言 distanceFromBottom ≤ 阈值（证明是产品自动跟随，不是驱动滚的）。
  report.scroll = await page.evaluate(() => {
    const list = document.querySelector('[data-testid="message-list"]');
    if (!list) return null;
    const distanceFromBottom =
      list.scrollHeight - list.scrollTop - list.clientHeight;
    return {
      scrollTop: list.scrollTop,
      scrollHeight: list.scrollHeight,
      clientHeight: list.clientHeight,
      distanceFromBottom,
    };
  });
  report.jumpButtonVisible = await page
    .$eval('[data-testid="jump-to-bottom"]', () => true)
    .catch(() => false);

  report.status = await page.$eval(
    '[data-testid="connection-status"]',
    (node) => node.textContent,
  );
  report.assistantText = await page.$$eval(
    '[data-testid="assistant-message"]',
    (nodes) => nodes.map((node) => node.innerText),
  );
  report.userText = await page.$$eval(
    '[data-testid="user-message"]',
    (nodes) => nodes.map((node) => node.innerText),
  );
  report.toolCards = await page.$$eval('[data-testid="tool-card"]', (nodes) =>
    nodes.map((node) => node.innerText),
  );
  report.snapshot = await page.$eval(
    '[data-testid="context-snapshot"]',
    (node) => node.innerText,
  );
  report.error = await page.$eval(
    '[data-testid="error-banner"]',
    (node) => node.innerText,
  ).catch(() => null);
  report.skillFailures = await page.$eval(
    '[data-testid="skill-failures"]',
    (node) => node.innerText,
  ).catch(() => null);

  await page.screenshot({ path: screenshotPath });
  report.screenshot = screenshotPath;
} finally {
  console.log(JSON.stringify(report));
  await browser.close();
}
