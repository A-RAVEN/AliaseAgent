// Provider 管理页（change `web-management-ui` 任务 3.3 / design D8）。
//
// 复用 provider-model-discovery 规范的四项守卫：
//   ① 删除被模板引用 ⇒ 拒绝并显示引用名单（核心返回的错误正文里带名单）；
//   ② 改名在同一保存动作里级联改写引用模板（payload 带 rename_from）；
//   ③ 密钥不明文：列表只显示 hasApiKey，编辑框是 password 且不回填原值，留空 = 沿用；
//   ④ 保存成功后自动探测一次（与 Flutter Providers 页同一行为）。
import { useCallback, useEffect, useState } from 'react';

import {
  providerDeletePayload,
  providerSavePayload,
  type ProviderSummary,
} from '../manage/logic';
import type { CoreClient } from '../protocol';

interface ProviderView extends ProviderSummary {
  name: string;
  models: { id?: string; display_name?: string }[];
  discoveredAt: string | null;
}

interface ProviderDraftState {
  originalName: string | null;
  name: string;
  baseUrl: string;
  apiKey: string;
}

export interface ProvidersPageProps {
  client: CoreClient;
  onClose: () => void;
  onChanged: () => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function ProvidersPage({ client, onClose, onChanged }: ProvidersPageProps) {
  const [providers, setProviders] = useState<ProviderView[]>([]);
  const [draft, setDraft] = useState<ProviderDraftState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notices, setNotices] = useState<Record<string, string>>({});
  const [deleteErrors, setDeleteErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const result = await client.request<{
      providers: Record<
        string,
        {
          baseUrl: string;
          hasApiKey: boolean;
          models: { id?: string; display_name?: string }[];
          discoveredAt: string | null;
        }
      >;
    }>('config.get');
    setProviders(
      Object.entries(result.providers).map(([name, value]) => ({
        name,
        baseUrl: value.baseUrl,
        hasApiKey: value.hasApiKey,
        models: value.models ?? [],
        discoveredAt: value.discoveredAt,
      })),
    );
  }, [client]);

  useEffect(() => {
    load().catch((loadError: unknown) => setError(errorText(loadError)));
  }, [load]);

  const summaryOf = (): Record<string, ProviderSummary> => {
    const summary: Record<string, ProviderSummary> = {};
    for (const provider of providers) {
      summary[provider.name] = { baseUrl: provider.baseUrl, hasApiKey: provider.hasApiKey };
    }
    return summary;
  };

  const probe = async (name: string) => {
    try {
      const report = await client.request<{
        ok: boolean;
        entries: { id?: string }[];
        added: number;
        updated: number;
        removed: number;
        dropped: number;
        discoveredAt: string | null;
        error: string | null;
        errorFilePath?: string | null;
        preview?: string | null;
      }>('provider.probe', { providerName: name });
      const text = report.ok
        ? `探测成功：新增 ${report.added}，更新 ${report.updated}，移除 ${report.removed}，` +
          `丢弃 ${report.dropped}；目录 ${report.entries.length} 条，` +
          `discovered_at=${report.discoveredAt ?? '(缺失)'}`
        : `探测失败：${report.error ?? '(未知原因)'}` +
          (report.errorFilePath ? `（完整响应见 ${report.errorFilePath}）` : '');
      setNotices((previous) => ({ ...previous, [name]: text }));
      await load();
      onChanged();
    } catch (probeError: unknown) {
      setNotices((previous) => ({ ...previous, [name]: `探测失败：${errorText(probeError)}` }));
    }
  };

  const save = async () => {
    if (!draft) return;
    setError(null);
    setBusy(true);
    try {
      const table = providerSavePayload({
        existing: summaryOf(),
        draft: {
          originalName: draft.originalName,
          name: draft.name,
          baseUrl: draft.baseUrl,
          apiKey: draft.apiKey,
        },
      });
      await client.request('config.save', { providers: table });
      setDraft(null);
      await load();
      onChanged();
      // ④ 保存成功后自动探测一次（新增 / 改名 / 改地址 / 改密钥都算一次保存动作）。
      await probe(draft.name.trim());
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
      await client.request('config.save', {
        providers: providerDeletePayload(summaryOf(), name),
      });
      await load();
      onChanged();
    } catch (deleteError: unknown) {
      setDeleteErrors((previous) => ({ ...previous, [name]: errorText(deleteError) }));
    }
  };

  return (
    <section
      data-testid="providers-page"
      className="flex h-full flex-col bg-bg text-fg"
      aria-label="Provider 管理"
    >
      <header className="flex items-center justify-between border-b border-line px-4 py-3">
        <div>
          <h2 className="text-xl font-semibold">Providers</h2>
          <p className="text-xs text-muted">
            密钥不回显：编辑时密钥框留空 = 沿用原密钥；保存成功后会自动探测一次。
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="provider-add"
            onClick={() => {
              setError(null);
              setDraft({ originalName: null, name: '', baseUrl: '', apiKey: '' });
            }}
            className="rounded-card bg-accent px-3 py-1 text-sm font-semibold text-bg"
          >
            添加 Provider
          </button>
          <button
            type="button"
            data-testid="providers-close"
            onClick={onClose}
            className="rounded-card border border-line px-3 py-1 text-sm text-muted hover:text-fg"
          >
            关闭
          </button>
        </div>
      </header>

      {error && (
        <p
          data-testid="providers-error"
          className="border-b border-danger/40 bg-danger/10 px-4 py-2 text-sm text-danger"
        >
          {error}
        </p>
      )}

      {draft && (
        <div className="border-b border-line px-4 py-3">
          <div className="grid grid-cols-2 gap-2">
            <label className="text-xs text-muted">
              Provider 名
              <input
                data-testid="provider-form-name"
                value={draft.name}
                onChange={(event) => setDraft({ ...draft, name: event.target.value })}
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              />
            </label>
            <label className="text-xs text-muted">
              网关地址
              <input
                data-testid="provider-form-base-url"
                value={draft.baseUrl}
                onChange={(event) => setDraft({ ...draft, baseUrl: event.target.value })}
                placeholder="http://127.0.0.1:3425"
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              />
            </label>
            <label className="col-span-2 text-xs text-muted">
              API Key（留空 = 沿用原密钥；新增必须填）
              <input
                data-testid="provider-form-api-key"
                type="password"
                value={draft.apiKey}
                onChange={(event) => setDraft({ ...draft, apiKey: event.target.value })}
                placeholder={draft.originalName ? '(留空沿用原密钥)' : ''}
                className="mt-1 h-8 w-full rounded-card border border-line bg-surface px-2 text-sm text-fg"
              />
            </label>
          </div>
          <div className="mt-2 flex justify-end gap-2">
            <button
              type="button"
              data-testid="provider-form-cancel"
              onClick={() => setDraft(null)}
              className="rounded-card border border-line px-3 py-1 text-sm text-muted hover:text-fg"
            >
              取消
            </button>
            <button
              type="button"
              data-testid="provider-form-save"
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
        {providers.length === 0 ? (
          <p className="text-sm text-muted">还没有任何 Provider：点「添加 Provider」开始。</p>
        ) : (
          <ul className="space-y-2">
            {providers.map((provider) => (
              <li
                key={provider.name}
                data-testid="provider-row"
                data-name={provider.name}
                className="rounded-card border border-line bg-surface px-3 py-2"
              >
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold text-fg">{provider.name}</p>
                    <p className="truncate text-xs text-muted">
                      {provider.baseUrl} · 密钥 {provider.hasApiKey ? '已配置（不回显）' : '未配置'} ·
                      目录 {provider.models.length} 条
                      {provider.discoveredAt ? ` · 探测于 ${provider.discoveredAt}` : ''}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-2">
                    <button
                      type="button"
                      data-testid="provider-probe"
                      onClick={() => void probe(provider.name)}
                      className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
                    >
                      探测
                    </button>
                    <button
                      type="button"
                      data-testid="provider-edit"
                      onClick={() => {
                        setError(null);
                        setDraft({
                          originalName: provider.name,
                          name: provider.name,
                          baseUrl: provider.baseUrl,
                          apiKey: '',
                        });
                      }}
                      className="rounded-card border border-line px-2 py-1 text-xs text-muted hover:text-fg"
                    >
                      编辑
                    </button>
                    <button
                      type="button"
                      data-testid="provider-delete"
                      onClick={() => void remove(provider.name)}
                      className="rounded-card border border-danger/40 px-2 py-1 text-xs text-danger"
                    >
                      删除
                    </button>
                  </div>
                </div>
                {notices[provider.name] && (
                  <p
                    data-testid="provider-report"
                    className="mt-1 rounded-card bg-surface-2 px-2 py-1 text-xs text-muted"
                  >
                    {notices[provider.name]}
                  </p>
                )}
                {deleteErrors[provider.name] && (
                  <p
                    data-testid="provider-delete-error"
                    className="mt-1 text-xs text-danger"
                  >
                    {deleteErrors[provider.name]}
                  </p>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
