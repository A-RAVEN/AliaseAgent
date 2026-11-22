// 管理屏纯逻辑（change `web-management-ui`）：不碰 DOM，vitest 直接覆盖。
//
// 分层理由见 design D14：布局/交互走 puppeteer（真实布局引擎），凡是"能纯函数判定"
// 的规则（错误解析、表单校验、目录首项选择、红线钳制）都放这里，让它们能被便宜的
// 单测锁住。

/** 一次模板切换失败的可显示信息（阶段 + 候选名 + 原因，design D4）。 */
export interface AgentSwitchFailure {
  /** 阶段机器名（preflight / retire / persist / create / busy / deleting）。 */
  stage: string;
  /** 阶段中文名（核心给的 label，如「会话正在删除」）。 */
  stageLabel: string;
  /** 候选模板名。 */
  candidate: string;
  /** 失败原因正文。 */
  detail: string;
  /** 原始错误消息（无法解析时原文保留在这里，不丢内容）。 */
  raw: string;
}

/**
 * 解析核心的模板切换失败消息。
 *
 * 核心格式（`lib/core/headless_core.dart` 的 `session.switchTemplate` handler）：
 *   `模板切换失败（阶段：<机器名> / <中文名>，候选 "<名字>"）：<原因>`
 *
 * 解析不了时**不假装成功**：返回 stage='unknown' + 原文作 detail。
 */
export function parseAgentSwitchError(message: string): AgentSwitchFailure {
  const raw = typeof message === 'string' ? message : String(message ?? '');
  const match = /阶段：([A-Za-z]+)\s*\/\s*([^，,]+)[，,]\s*候选\s*"([^"]*)"）[：:]([\s\S]*)$/.exec(raw);
  if (!match) {
    return { stage: 'unknown', stageLabel: '', candidate: '', detail: raw, raw };
  }
  const [, stage, stageLabel, candidate, detail] = match;
  const trimmedDetail = detail.trim();
  return {
    stage,
    stageLabel: stageLabel.trim(),
    candidate,
    detail: trimmedDetail.length > 0 ? trimmedDetail : raw,
    raw,
  };
}

/** 把一次切换失败格式化成界面那一句（必须含阶段与候选名）。 */
export function formatSwitchFailure(failure: AgentSwitchFailure): string {
  const stage = failure.stageLabel || failure.stage;
  const candidate = failure.candidate || '(未知候选)';
  return `切换失败（阶段：${stage}，候选 "${candidate}"）：${failure.detail}`;
}

// ---------------------------------------------------------------------------
// provider 页（change `web-management-ui` 3.3 / design D8）
// ---------------------------------------------------------------------------

export interface ProviderSummary {
  baseUrl: string;
  hasApiKey: boolean;
}

export interface ProviderDraft {
  /** null = 新增；非空 = 编辑（与 name 不同时即改名）。 */
  originalName: string | null;
  name: string;
  baseUrl: string;
  /** 空串 = 沿用原密钥（不提交 api_key 字段）。 */
  apiKey: string;
}

/** `config.save` 的 providers 表（整份提交，缺省 = 删除）。 */
export type ProviderSaveTable = Record<
  string,
  { base_url: string; api_key?: string; rename_from?: string }
>;

/**
 * 一次 provider 保存的整表 payload。
 *
 * 语义（与核心 `config.save` 对齐）：整表 = 期望的完整 provider 表；密钥留空 ⇒ 不带
 * `api_key`（核心沿用原密钥）；改名 ⇒ 旧键不提交、新键带 `rename_from`（核心在同一
 * 保存动作里级联改写引用模板）。
 */
export function providerSavePayload(options: {
  existing: Record<string, ProviderSummary>;
  draft: ProviderDraft;
}): ProviderSaveTable {
  const { existing, draft } = options;
  const name = draft.name.trim();
  const renaming =
    draft.originalName !== null && draft.originalName.trim().length > 0 && draft.originalName !== name;
  const table: ProviderSaveTable = {};
  for (const [existingName, summary] of Object.entries(existing)) {
    if (existingName === name) continue;
    if (renaming && existingName === draft.originalName) continue;
    table[existingName] = { base_url: summary.baseUrl };
  }
  const entry: { base_url: string; api_key?: string; rename_from?: string } = {
    base_url: draft.baseUrl.trim(),
  };
  const typedKey = draft.apiKey.trim();
  if (typedKey.length > 0) entry.api_key = typedKey;
  if (renaming) entry.rename_from = draft.originalName as string;
  table[name] = entry;
  return table;
}

/** 删除一个 provider 的整表 payload（其余 provider 原样保留）。 */
export function providerDeletePayload(
  existing: Record<string, ProviderSummary>,
  name: string,
): ProviderSaveTable {
  const table: ProviderSaveTable = {};
  for (const [existingName, summary] of Object.entries(existing)) {
    if (existingName === name) continue;
    table[existingName] = { base_url: summary.baseUrl };
  }
  return table;
}

// ---------------------------------------------------------------------------
// 模板页（change `web-management-ui` 3.4 / design D9）
// ---------------------------------------------------------------------------

export interface TemplateFormState {
  originalName: string | null;
  name: string;
  provider: string;
  model: string;
  thinkingEffort: string;
  systemPrompt: string;
  tools: string[];
  maxContextTokens: string;
  inputModalities: string[];
  compactionThresholdPercent: string;
  compactionWaitThresholdPercent: string;
}

/** 解析一个百分比输入框：空串 = 不提交；非 1..100 整数 = 抛错（不当成"没填"）。 */
function parsePercentField(raw: string, label: string): number | undefined {
  const text = raw.trim();
  if (text.length === 0) return undefined;
  const value = Number(text);
  if (!Number.isInteger(value) || value < 1 || value > 100) {
    throw new Error(`${label}必须是 1 到 100 的整数（当前「${text}」）`);
  }
  return value;
}

/**
 * 模板页 → `template.save` 参数。
 *
 * 为什么在这里挡 NaN：`JSON.stringify(NaN)` 会变成 `null`，核心看到 null 会当成"没
 * 填"，于是用户输错一个阈值就被静默忽略 —— 那正是"静默降级"。
 */
export function templateSavePayload(form: TemplateFormState): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    name: form.name.trim(),
    provider: form.provider,
    model: form.model.trim(),
    thinkingEffort: form.thinkingEffort,
    systemPrompt: form.systemPrompt,
    tools: form.tools,
    maxContextTokens: form.maxContextTokens.trim(),
    inputModalities: form.inputModalities,
  };
  if (form.originalName !== null) payload.originalName = form.originalName;
  const threshold = parsePercentField(form.compactionThresholdPercent, '压缩阈值');
  if (threshold !== undefined) payload.compactionThresholdPercent = threshold;
  const wait = parsePercentField(form.compactionWaitThresholdPercent, '等待阈值');
  if (wait !== undefined) payload.compactionWaitThresholdPercent = wait;
  return payload;
}

// ---------------------------------------------------------------------------
// 首启向导（change `web-management-ui` 3.5 / design D11）
// ---------------------------------------------------------------------------

/**
 * catalog 首项模型（**不硬编码任何模型名**：模型名只能来自这次探测的目录）。
 *
 * 目录为空、或条目里没有非空字符串 `id` ⇒ null（向导据此拒绝进入下一步，
 * 而不是拿一个写死的模型名兜底）。
 */
export function pickDefaultModel(entries: { id?: unknown }[]): string | null {
  for (const entry of entries) {
    const id = entry?.id;
    if (typeof id === 'string' && id.length > 0) return id;
  }
  return null;
}

/** 向导 Start 的 provider payload：把 probeFetch 的目录一起写盘（不在 Start 时再探测）。 */
export function wizardProviderPayload(options: {
  name: string;
  baseUrl: string;
  apiKey: string;
  models: unknown[];
}): { providers: Record<string, { base_url: string; api_key: string; models: unknown[] }> } {
  return {
    providers: {
      [options.name.trim()]: {
        base_url: options.baseUrl.trim(),
        api_key: options.apiKey.trim(),
        models: options.models,
      },
    },
  };
}

/** 向导 Start 建 general 的 `template.save` 参数（工具清单来自核心 `defaultTools`）。 */
export function wizardTemplatePayload(options: {
  providerName: string;
  model: string;
  includeImage: boolean;
  defaultTools: string[];
}): Record<string, unknown> {
  return {
    name: 'general',
    provider: options.providerName,
    model: options.model,
    thinkingEffort: '',
    systemPrompt: '',
    tools: [...options.defaultTools],
    // 留空 = 窗口取网关目录值（与 Flutter 首启同一个口径）。
    maxContextTokens: '',
    inputModalities: options.includeImage ? ['text', 'image'] : ['text'],
  };
}
