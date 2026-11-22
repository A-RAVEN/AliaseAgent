// 模板编辑页（change `web-management-ui` 任务 3.4 / design D9）。
//
// 字段：provider / model / tools / systemPrompt / thinkingEffort（执行层合法集合，
// 由核心 `template.list` 给出）/ maxContextTokens / **input_modalities 模态勾选** /
// 压缩阈值。模板名创建后不可改。
//
// 生效时机（design D9 的两类）由核心 `effectiveNote` 原样显示 —— web 不复制文案。
// 保存走 `template.save`（核心复用 AgentTemplateController.validate/save，未开放
// 字段原样保留），失败原因直接显示核心给的那句（含字段名）。
import { useCallback, useEffect, useState } from 'react';

import { templateSavePayload, type TemplateFormState } from '../manage/logic';
import type { CoreClient } from '../protocol';

interface TemplateRow {
  name: string;
  provider?: string;
  model?: string;
  thinking_effort?: string | null;
  system_prompt?: string;
  tools?: string[];
  max_context_tokens?: number | null;
  input_modalities?: string[];
  compaction_threshold_percent?: number;
  compaction_wait_threshold_percent?: number;
}

interface CatalogEntry {
  id?: string;
  display_name?: string;
  context_window?: number | null;
  modalities?: { input?: string[] };
}

export interface TemplatesPageProps {
  client: CoreClient;
  onClose: () => void;
  onChanged: () => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function formFromTemplate(template: TemplateRow): TemplateFormState {
  return {
    originalName: template.name,
    name: template.name,
    provider: template.provider ?? '',
    model: template.model ?? '',
    thinkingEffort: template.thinking_effort ?? '',
    systemPrompt: template.system_prompt ?? '',
    tools: [...(template.tools ?? [])],
    maxContextTokens:
      template.max_context_tokens === null || template.max_context_tokens === undefined
        ? ''
        : String(template.max_context_tokens),
    inputModalities: [
      ...(template.input_modalities ?? ['text']),
    ],
    compactionThresholdPercent:
      template.compaction_threshold_percent === undefined
        ? ''
        : String(template.compaction_threshold_percent),
    compactionWaitThresholdPercent:
      template.compaction_wait_threshold_percent === undefined
        ? ''
        : String(template.compaction_wait_threshold_percent),
  };
}

const EMPTY_FORM: TemplateFormState = {
  originalName: null,
  name: '',
  provider: '',
  model: '',
  thinkingEffort: '',
  systemPrompt: '',
  tools: [],
  maxContextTokens: '',
  inputModalities: ['text'],
  compactionThresholdPercent: '',
  compactionWaitThresholdPercent: '',
};

export function TemplatesPage({ client, onClose, onChanged }: TemplatesPageProps) {
  const [templates, setTemplates] = useState<TemplateRow[]>([]);
  const [tools, setTools] = useState<string[]>([]);
  const [providers, setProviders] = useState<string[]>([]);
  const [defaultTools, setDefaultTools] = useState<string[]>([]);
  const [thinkingEfforts, setThinkingEfforts] = useState<string[]>([]);
  const [allowedModalities, setAllowedModalities] = useState<string[]>(['text', 'image']);
  const [effectiveNote, setEffectiveNote] = useState('');
  const [catalogs, setCatalogs] = useState<Record<string, CatalogEntry[]>>({});
  const [form, setForm] = useState<TemplateFormState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [deleteErrors, setDeleteErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const [list, config] = await Promise.all([
      client.request<{
        templates: TemplateRow[];
        tools: string[];
        providers: string[];
        defaultTools: string[];
        thinkingEfforts: string[];
        allowedModalities: string[];
        effectiveNote: string;
      }>('template.list'),
      client.request<{
        providers: Record<string, { models: CatalogEntry[] }>;
      }>('config.get'),
    ]);
    setTemplates(list.templates);
    setTools(list.tools);
    setProviders(list.providers);
    setDefaultTools(list.defaultTools ?? []);
    setThinkingEfforts(list.thinkingEfforts ?? []);
    if ((list.allowedModalities ?? []).length > 0) {
      setAllowedModalities(list.allowedModalities);
    }
    setEffectiveNote(list.effectiveNote ?? '');
    const catalogMap: Record<string, CatalogEntry[]> = {};
    for (const [name, provider] of Object.entries(config.providers)) {
      catalogMap[name] = provider.models ?? [];
    }
    setCatalogs(catalogMap);
  }, [client]);

  useEffect(() => {
    load().catch((loadError: unknown) => setError(errorText(loadError)));
  }, [load]);

  /** 目录里的模型条目（当前 form 的 provider）。 */
  const catalog = form ? (catalogs[form.provider] ?? []) : [];

  const onPickCatalogModel = (modelId: string) => {
    if (!form) return;
    const entry = catalog.find((item) => item.id === modelId);
    const next: TemplateFormState = { ...form, model: modelId };
    if (entry) {
      // 与 Flutter 编辑器同一口径的**动作时**回填（目录后续刷新不改已保存模板）。
      if (typeof entry.context_window === 'number' && entry.context_window > 0) {
        next.maxContextTokens = String(entry.context_window);
      }
      const input = (entry.modalities?.input ?? []).filter((value) =>
        allowedModalities.includes(value),
      );
      if (input.length > 0) next.inputModalities = input;
    }
    setForm(next);
  };

  const toggle = (list: string[], value: string): string[] =>
    list.includes(value) ? list.filter((item) => item !== value) : [...list, value];

  const save = async () => {
    if (!form) return;
    setError(null);
    setBusy(true);
    try {
      const payload = templateSavePayload(form);
      await client.request('template.save', payload);
      setForm(null);
      await load();
      onChanged();
    } catch (saveError: unknown) {
      setError(errorText(saveError));
    } finally {
      setBusy(false);
    }
  };

  const remove = async (name: string) => {
    setError(null);
    setDeleteErrors((previous) => {
      const next = { ...previous };
      delete next[name];
      return next;
    });
    try {
      await client.request('template.delete', { templateName: name });
      await load();
      onChanged();
    } catch (deleteError: unknown) {
      setDeleteErrors((previous) => ({ ...previous, [name]: errorText(deleteError) }));
    }
  };

  return (
    <section
      data-testid="templates-page"
      className="flex h-full flex-col bg-bg text-fg"
      aria-label="Agent 模板管理"
    >
      <header className="flex items-center justify-between border-b border-line px-4 py-3">
        <div>
          <h2 className="text-xl font-semibold">Agent 模板</h2>
          <p data-testid="template-effective-note" className="text-xs text-muted">
            {effectiveNote}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="template-add"
            onClick={() => {
              setError(null);
              setForm({
                ...EMPTY_FORM,
                provider: providers[0] ?? '',
                // 新模板默认勾上核心给的默认工具清单（与 Flutter 首启同一份数据）。
                tools: [...defaultTools],
              });
            }}
            className="rounded-card bg-accent px-3 py-1 text-sm font-semibold text-bg"
          >
            添加模板
          </button>
          <button
            type="button"
            data-testid="templates-close"
            onClick={onClose}
            className="rounded-card border border-line px-3 py-1 text-sm text-muted hover:text-fg"
          >
            关闭
          </button>
        </div>
      </header>

      {error && (
        <p
          data-testid="templates-error"
          className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
        >
          {error}
        </p>
      )}

      {form && (
        <div className="max-h-64 overflow-y-auto border-b border-line px-4 py-3">
          <div className="grid grid-cols-2 gap-2">
            <label className="text-xs text-muted">
              模板名（创建后不可改）
              <input
                data-testid="template-form-name"
                readOnly={form.originalName !== null}
                data-readonly={form.originalName !== null ? 'true' : 'false'}
                value={form.name}
                onChange={(event) => setForm({ ...form, name: event.target.value })}
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg read-only:opacity-60"
              />
            </label>
            <label className="text-xs text-muted">
              provider
              <select
                data-testid="template-form-provider"
                value={form.provider}
                onChange={(event) =>
                  setForm({ ...form, provider: event.target.value, model: '' })
                }
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              >
                {providers.map((name) => (
                  <option key={name} value={name}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-xs text-muted">
              模型（可从目录选，也可手输）
              <input
                data-testid="template-form-model"
                list="template-model-options"
                value={form.model}
                onChange={(event) => setForm({ ...form, model: event.target.value })}
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              />
              <datalist id="template-model-options">
                {catalog.map((entry) => (
                  <option key={entry.id} value={entry.id}>
                    {entry.display_name ?? entry.id}
                  </option>
                ))}
              </datalist>
            </label>
            <label className="text-xs text-muted">
              从目录选模型（回填窗口与模态）
              <select
                data-testid="template-form-catalog-model"
                value=""
                onChange={(event) => onPickCatalogModel(event.target.value)}
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              >
                <option value="">（目录 {catalog.length} 条）</option>
                {catalog.map((entry) => (
                  <option key={entry.id} value={entry.id}>
                    {entry.display_name ?? entry.id}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-xs text-muted">
              推理强度
              <select
                data-testid="template-form-thinking"
                value={form.thinkingEffort}
                onChange={(event) =>
                  setForm({ ...form, thinkingEffort: event.target.value })
                }
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              >
                <option value="">关闭</option>
                {thinkingEfforts.map((effort) => (
                  <option key={effort} value={effort}>
                    {effort}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-xs text-muted">
              上下文窗口覆盖（留空 = 用目录窗口）
              <input
                data-testid="template-form-max-context"
                value={form.maxContextTokens}
                onChange={(event) =>
                  setForm({ ...form, maxContextTokens: event.target.value })
                }
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              />
            </label>
            <label className="col-span-2 text-xs text-muted">
              系统提示词
              <textarea
                data-testid="template-form-system-prompt"
                value={form.systemPrompt}
                onChange={(event) =>
                  setForm({ ...form, systemPrompt: event.target.value })
                }
                rows={2}
                className="mt-1 w-full rounded-card border border-line bg-surface px-2 py-1 text-sm text-fg"
              />
            </label>
            <div className="text-xs text-muted">
              输入模态
              <div data-testid="template-form-modalities" className="mt-1 flex gap-3">
                {allowedModalities.map((modality) => (
                  <label key={modality} className="flex items-center gap-1 text-sm text-fg">
                    <input
                      type="checkbox"
                      data-testid={`template-modality-${modality}`}
                      checked={form.inputModalities.includes(modality)}
                      onChange={() =>
                        setForm({
                          ...form,
                          inputModalities: toggle(form.inputModalities, modality),
                        })
                      }
                    />
                    {modality}
                  </label>
                ))}
              </div>
            </div>
            <div className="text-xs text-muted">
              压缩阈值 / 等待阈值（1..100，留空 = 沿用既有值）
              <div className="mt-1 flex gap-2">
                <input
                  data-testid="template-form-compaction"
                  value={form.compactionThresholdPercent}
                  onChange={(event) =>
                    setForm({ ...form, compactionThresholdPercent: event.target.value })
                  }
                  className="h-8 w-20 rounded-card border border-line bg-surface px-2 text-sm text-fg"
                />
                <input
                  data-testid="template-form-compaction-wait"
                  value={form.compactionWaitThresholdPercent}
                  onChange={(event) =>
                    setForm({
                      ...form,
                      compactionWaitThresholdPercent: event.target.value,
                    })
                  }
                  className="h-8 w-20 rounded-card border border-line bg-surface px-2 text-sm text-fg"
                />
              </div>
            </div>
            <div className="col-span-2 text-xs text-muted">
              工具
              <div data-testid="template-form-tools" className="mt-1 flex flex-wrap gap-2">
                {tools.map((tool) => (
                  <label key={tool} className="flex items-center gap-1 text-xs text-fg">
                    <input
                      type="checkbox"
                      data-testid={`template-tool-${tool}`}
                      checked={form.tools.includes(tool)}
                      onChange={() =>
                        setForm({ ...form, tools: toggle(form.tools, tool) })
                      }
                    />
                    {tool}
                  </label>
                ))}
              </div>
            </div>
          </div>
          <div className="mt-2 flex justify-end gap-2">
            <button
              type="button"
              data-testid="template-form-cancel"
              onClick={() => setForm(null)}
              className="rounded-card border border-line px-3 py-1 text-sm text-muted hover:text-fg"
            >
              取消
            </button>
            <button
              type="button"
              data-testid="template-form-save"
              disabled={busy}
              onClick={() => void save()}
              className="rounded-card bg-accent px-3 py-1 text-sm font-semibold text-bg disabled:opacity-40"
            >
              保存
            </button>
          </div>
        </div>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto px-4 py-3">
        <ul className="space-y-2">
          {templates.map((template) => (
            <li
              key={template.name}
              data-testid="template-row"
              data-name={template.name}
              className="rounded-card border border-line bg-surface px-3 py-2"
            >
              <div className="flex items-center justify-between gap-2">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-fg">
                    {template.name}
                    {template.name === 'general' && (
                      <span className="ml-2 text-xs text-muted">（默认，不可删）</span>
                    )}
                  </p>
                  <p className="truncate text-xs text-muted">
                    {template.provider} · {template.model} · 推理{' '}
                    {template.thinking_effort || '关闭'} · 模态{' '}
                    {(template.input_modalities ?? ['text']).join('+')}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  <button
                    type="button"
                    data-testid="template-edit"
                    onClick={() => {
                      setError(null);
                      setForm(formFromTemplate(template));
                    }}
                    className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
                  >
                    编辑
                  </button>
                  <button
                    type="button"
                    data-testid="template-delete"
                    onClick={() => void remove(template.name)}
                    className="rounded-card border border-danger/40 px-2 py-1 text-xs text-danger"
                  >
                    删除
                  </button>
                </div>
              </div>
              {deleteErrors[template.name] && (
                <p data-testid="template-delete-error" className="mt-1 text-xs text-danger">
                  {deleteErrors[template.name]}
                </p>
              )}
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
