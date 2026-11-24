// 模板编辑页（change `web-management-ui` 任务 3.4 / design D9）。
//
// 字段：provider / model / tools / systemPrompt / thinkingEffort（执行层合法集合，
// 由核心 `template.list` 给出）/ maxContextTokens / **input_modalities 模态勾选** /
// 压缩阈值。模板名创建后不可改。
//
// 生效时机（design D9 的两类）由核心 `effectiveNote` 原样显示 —— web 不复制文案。
// 保存走 `template.save`（核心复用 AgentTemplateController.validate/save，未开放
// 字段原样保留），失败原因直接显示核心给的那句（含字段名）。
import { useCallback, useEffect, useRef, useState } from 'react';

import { uploadAvatarFile } from '../avatars/upload';
import { templateSavePayload, type TemplateFormState } from '../manage/logic';
import { avatarSizes } from '../tokens';
import type {
  CatalogEntry,
  ConfigGetResult,
  CoreClient,
  TemplateListResult,
  TemplateSummary,
} from '../protocol';
import { Avatar } from './Avatar';

export interface TemplatesPageProps {
  client: CoreClient;
  onClose: () => void;
  onChanged: () => void;
  /**
   * 头像路径 → data URL 的**共用缓存**（change `chat-bubbles-avatars` D2：四个调用点
   * 共用 App 层那一份去重缓存，本组件不自己发 `attachment.read`）。
   */
  avatarDataUrls?: Record<string, string | null>;
  /** 请求 App 层补取若干头像路径的字节（上传完后预览要用）。 */
  onResolveAvatar?: (paths: string[]) => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function formFromTemplate(template: TemplateSummary): TemplateFormState {
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

export function TemplatesPage({
  client,
  onClose,
  onChanged,
  avatarDataUrls,
  onResolveAvatar,
}: TemplatesPageProps) {
  const [templates, setTemplates] = useState<TemplateSummary[]>([]);
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
  // 头像三态草稿：undefined = 没碰（保存时不带该字段）、null = 清除、字符串 = 设为该路径。
  const [avatarDraft, setAvatarDraft] = useState<string | null | undefined>(undefined);
  const avatarFileRef = useRef<HTMLInputElement | null>(null);

  const load = useCallback(async () => {
    const [list, config] = await Promise.all([
      client.request<TemplateListResult>('template.list'),
      client.request<ConfigGetResult>('config.get'),
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

  // 列表里各模板的头像字节交给 App 层共用缓存去取（组件不自己发 attachment.read）。
  useEffect(() => {
    const paths = templates
      .map((template) => template.avatar_path)
      .filter((path): path is string => typeof path === 'string' && path.length > 0);
    if (paths.length > 0) onResolveAvatar?.(paths);
  }, [templates, onResolveAvatar]);

  /** 某模板已保存的头像路径（列表里的 `avatar_path`）。 */
  const savedAvatarPath = (templateName: string | null | undefined): string | null => {
    if (!templateName) return null;
    const row = templates.find((template) => template.name === templateName);
    return typeof row?.avatar_path === 'string' && row.avatar_path.length > 0
      ? row.avatar_path
      : null;
  };

  /** 预览用路径：草稿优先（undefined = 没碰，看已保存值）。 */
  const previewPath =
    avatarDraft === undefined ? savedAvatarPath(form?.originalName) : avatarDraft;
  const previewDataUrl = previewPath !== null ? avatarDataUrls?.[previewPath] ?? null : null;

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
      // 头像三态（design D3）：没碰 ⇒ 不带（= 不改）；清除 ⇒ 空串；设置 ⇒ 该路径。
      if (avatarDraft !== undefined) payload.avatarPath = avatarDraft ?? '';
      await client.request('template.save', payload);
      setForm(null);
      setAvatarDraft(undefined);
      await load();
      onChanged();
    } catch (saveError: unknown) {
      setError(errorText(saveError));
    } finally {
      setBusy(false);
    }
  };

  /** 选图：读文件 → `attachment.upload`（核心做上限与魔数校验）→ 先存草稿，保存时才提交。 */
  const onPickAvatar = async (file: File | undefined) => {
    if (!file || !form) return;
    setError(null);
    setBusy(true);
    try {
      const uploaded = await uploadAvatarFile(client, file);
      setAvatarDraft(uploaded.path);
      onResolveAvatar?.([uploaded.path]);
    } catch (uploadError: unknown) {
      setError(`头像上传失败：${errorText(uploadError)}`);
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
              setAvatarDraft(undefined);
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
            <div className="col-span-2 text-xs text-muted">
              头像（上传图优先，否则按模板名生成身份图案）
              <div className="mt-1 flex items-center gap-2">
                <div data-testid="template-avatar-preview" className="shrink-0">
                  <Avatar
                    dataUrl={previewDataUrl}
                    source={previewDataUrl !== null ? 'upload' : 'identicon'}
                    seed={form.originalName ?? form.name}
                    size={avatarSizes.member}
                    label="模板头像"
                  />
                </div>
                <button
                  type="button"
                  data-testid="template-avatar-pick"
                  disabled={busy}
                  onClick={() => avatarFileRef.current?.click()}
                  className="min-h-6 rounded-card border border-line px-2 py-1 text-muted hover:text-fg disabled:opacity-40"
                >
                  选择图片
                </button>
                <button
                  type="button"
                  data-testid="template-avatar-clear"
                  disabled={busy}
                  onClick={() => setAvatarDraft(null)}
                  className="min-h-6 rounded-card border border-line px-2 py-1 text-muted hover:text-fg disabled:opacity-40"
                >
                  清除头像
                </button>
                <input
                  ref={avatarFileRef}
                  type="file"
                  accept="image/*"
                  data-testid="template-avatar-upload"
                  className="hidden"
                  onChange={(event) => {
                    const file = event.target.files?.[0];
                    event.target.value = '';
                    void onPickAvatar(file);
                  }}
                />
              </div>
            </div>
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
              onClick={() => {
                setForm(null);
                setAvatarDraft(undefined);
              }}
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
                <div className="flex min-w-0 items-center gap-2">
                  <Avatar
                    dataUrl={
                      typeof template.avatar_path === 'string'
                        ? avatarDataUrls?.[template.avatar_path] ?? null
                        : null
                    }
                    source={
                      typeof template.avatar_path === 'string' &&
                      (avatarDataUrls?.[template.avatar_path] ?? null) !== null
                        ? 'upload'
                        : 'identicon'
                    }
                    seed={template.name}
                    size={avatarSizes.bubble}
                    label={`${template.name} 的头像`}
                  />
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
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  <button
                    type="button"
                    data-testid="template-edit"
                    onClick={() => {
                      setError(null);
                      setAvatarDraft(undefined);
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
