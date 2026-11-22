// 管理屏纯逻辑（change `web-management-ui` 1.3 / 3.x）：可 vitest 直接覆盖，不碰 DOM。
//
// 任务 1.3：切换模板失败的错误文本解析 —— 核心给的错误消息形如
//   `模板切换失败（阶段：preflight / 候选预检，候选 "broken"）：<原因>`
// 界面必须显示**阶段 + 候选名**，不能只显示"切换失败"。
import { describe, expect, it } from 'vitest';

import {
  formatSwitchFailure,
  parseAgentSwitchError,
  pickDefaultModel,
  providerDeletePayload,
  providerSavePayload,
  templateSavePayload,
  wizardProviderPayload,
  wizardTemplatePayload,
} from './logic';

const preflightMessage =
  '模板切换失败（阶段：preflight / 候选预检，候选 "broken"）：' +
  'Agent 模板 "broken" 引用的 provider "no-such-provider" 未定义：拒绝创建实例。';

const deletingMessage =
  '模板切换失败（阶段：deleting / 会话正在删除，候选 "alt"）：' +
  '会话 "s-1" 正在删除：拒绝切换模板。';

describe('parseAgentSwitchError', () => {
  it('解析阶段机器名 / 阶段中文名 / 候选模板名 / 原因', () => {
    const failure = parseAgentSwitchError(preflightMessage);
    console.log('[解析]', JSON.stringify(failure));
    expect(failure.stage).toBe('preflight');
    expect(failure.stageLabel).toBe('候选预检');
    expect(failure.candidate).toBe('broken');
    expect(failure.detail).toContain('provider "no-such-provider" 未定义');
  });

  it('deleting 阶段也能解析（删除进行中的切换）', () => {
    const failure = parseAgentSwitchError(deletingMessage);
    expect(failure.stage).toBe('deleting');
    expect(failure.stageLabel).toBe('会话正在删除');
    expect(failure.candidate).toBe('alt');
  });

  it('不像核心错误文本时保留原文、不假装解析成功', () => {
    const failure = parseAgentSwitchError('WebSocket 已断开');
    console.log('[不支持]', JSON.stringify(failure));
    expect(failure.stage).toBe('unknown');
    expect(failure.candidate).toBe('');
    expect(failure.detail).toBe('WebSocket 已断开');
  });

  it('格式化成用户可读一句：含阶段与候选名', () => {
    const text = formatSwitchFailure(parseAgentSwitchError(deletingMessage));
    console.log('[格式化]', text);
    expect(text).toContain('会话正在删除');
    expect(text).toContain('alt');
    expect(text).toContain('切换失败');
  });
});

describe('provider 保存表（3.3 / design D8）', () => {
  const existing = {
    p: { baseUrl: 'http://127.0.0.1:1', hasApiKey: true },
  };

  it('新增：现存 provider 原样带上（不被删除），新条目带密钥', () => {
    const table = providerSavePayload({
      existing,
      draft: { originalName: null, name: 'q', baseUrl: 'http://127.0.0.1:9', apiKey: 'key-q' },
    });
    console.log('[新增表]', JSON.stringify(table));
    expect(table).toEqual({
      p: { base_url: 'http://127.0.0.1:1' },
      q: { base_url: 'http://127.0.0.1:9', api_key: 'key-q' },
    });
  });

  it('编辑但密钥留空：payload 里没有 api_key（核心据此沿用原密钥）', () => {
    const table = providerSavePayload({
      existing,
      draft: { originalName: 'p', name: 'p', baseUrl: 'http://127.0.0.1:2', apiKey: '   ' },
    });
    console.log('[留空表]', JSON.stringify(table));
    expect(table).toEqual({ p: { base_url: 'http://127.0.0.1:2' } });
    expect(Object.prototype.hasOwnProperty.call(table.p, 'api_key')).toBe(false);
  });

  it('改名：旧键不提交，新键带 rename_from（核心据此级联改写模板引用）', () => {
    const table = providerSavePayload({
      existing,
      draft: { originalName: 'p', name: 'p-renamed', baseUrl: 'http://127.0.0.1:1', apiKey: '' },
    });
    console.log('[改名表]', JSON.stringify(table));
    expect(table['p']).toBeUndefined();
    expect(table['p-renamed']).toEqual({
      base_url: 'http://127.0.0.1:1',
      rename_from: 'p',
    });
  });

  it('删除：整表去掉该 provider（其余保留）', () => {
    const table = providerDeletePayload(
      { p: { baseUrl: 'http://1', hasApiKey: true }, q: { baseUrl: 'http://2', hasApiKey: true } },
      'p',
    );
    console.log('[删除表]', JSON.stringify(table));
    expect(table).toEqual({ q: { base_url: 'http://2' } });
  });
});

describe('模板保存 payload（3.4 / design D9）', () => {
  it('五个必填字段 + 模态 + 工具 + 阈值映射到 RPC 参数', () => {
    const payload = templateSavePayload({
      originalName: 'alt',
      name: 'alt',
      provider: 'p',
      model: 'm2',
      thinkingEffort: 'max',
      systemPrompt: 'hi',
      tools: ['read_file'],
      maxContextTokens: '200000',
      inputModalities: ['text', 'image'],
      compactionThresholdPercent: '40',
      compactionWaitThresholdPercent: '80',
    });
    console.log('[模板 payload]', JSON.stringify(payload));
    expect(payload).toEqual({
      originalName: 'alt',
      name: 'alt',
      provider: 'p',
      model: 'm2',
      thinkingEffort: 'max',
      systemPrompt: 'hi',
      tools: ['read_file'],
      maxContextTokens: '200000',
      inputModalities: ['text', 'image'],
      compactionThresholdPercent: 40,
      compactionWaitThresholdPercent: 80,
    });
  });

  it('阈值留空 = 不提交（沿用既有值）', () => {
    const payload = templateSavePayload({
      originalName: null,
      name: 'fresh',
      provider: 'p',
      model: 'm',
      thinkingEffort: '',
      systemPrompt: '',
      tools: [],
      maxContextTokens: '',
      inputModalities: ['text'],
      compactionThresholdPercent: '',
      compactionWaitThresholdPercent: '',
    });
    expect(payload.originalName).toBeUndefined();
    expect('compactionThresholdPercent' in payload).toBe(false);
  });

  it('阈值不是整数时抛错（不许把 NaN 序列化成 null 静默当作"没填"）', () => {
    const base = {
      originalName: null,
      name: 'x',
      provider: 'p',
      model: 'm',
      thinkingEffort: '',
      systemPrompt: '',
      tools: [] as string[],
      maxContextTokens: '',
      inputModalities: ['text'],
      compactionWaitThresholdPercent: '',
    };
    expect(() => templateSavePayload({ ...base, compactionThresholdPercent: 'abc' })).toThrow(
      /压缩阈值/,
    );
    expect(() => templateSavePayload({ ...base, compactionThresholdPercent: '101' })).toThrow(
      /压缩阈值/,
    );
  });
});

describe('首启向导（3.5 / design D11）', () => {
  it('模型取 catalog 首项：两份首项不同的目录 ⇒ 选中的模型跟着变（不写死）', () => {
    const catalogA = [{ id: 'model-alpha' }, { id: 'model-beta' }];
    const catalogB = [{ id: 'model-x' }, { id: 'model-y' }];
    const first = pickDefaultModel(catalogA);
    const second = pickDefaultModel(catalogB);
    console.log('[首项]', first, second);
    expect(first).toBe('model-alpha');
    expect(second).toBe('model-x');
    expect(wizardTemplatePayload({
      providerName: 'magpie',
      model: first!,
      includeImage: false,
      defaultTools: ['read_file'],
    }).model).toBe('model-alpha');
    expect(wizardTemplatePayload({
      providerName: 'magpie',
      model: second!,
      includeImage: false,
      defaultTools: ['read_file'],
    }).model).toBe('model-x');
  });

  it('目录为空 / 条目缺 id ⇒ null（向导必须拦住，不硬编码兜底模型）', () => {
    expect(pickDefaultModel([])).toBeNull();
    expect(pickDefaultModel([{ id: '' }, {}])).toBeNull();
  });

  it('建 general：模态可选 image，工具用核心给的默认清单', () => {
    const withImage = wizardTemplatePayload({
      providerName: 'magpie',
      model: 'm',
      includeImage: true,
      defaultTools: ['read_file', 'list_dir'],
    });
    console.log('[向导 general]', JSON.stringify(withImage));
    expect(withImage.name).toBe('general');
    expect(withImage.provider).toBe('magpie');
    expect(withImage.tools).toEqual(['read_file', 'list_dir']);
    expect(withImage.inputModalities).toEqual(['text', 'image']);
    const withoutImage = wizardTemplatePayload({
      providerName: 'magpie',
      model: 'm',
      includeImage: false,
      defaultTools: [],
    });
    expect(withoutImage.inputModalities).toEqual(['text']);
  });

  it('provider payload 带 probeFetch 的目录（Start 一次写盘，不联网二次探测）', () => {
    const payload = wizardProviderPayload({
      name: 'magpie',
      baseUrl: ' http://127.0.0.1:3425 ',
      apiKey: ' k ',
      models: [{ id: 'm' }],
    });
    console.log('[向导 provider]', JSON.stringify(payload));
    expect(payload.providers.magpie.base_url).toBe('http://127.0.0.1:3425');
    expect(payload.providers.magpie.api_key).toBe('k');
    expect(payload.providers.magpie.models).toEqual([{ id: 'm' }]);
  });
});
