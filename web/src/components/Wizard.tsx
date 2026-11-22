// 首启向导（change `web-management-ui` 任务 3.5 / design D11）。
//
// 流程（与 Flutter setup_dialog 的口径一致，但改在 web 上做）：
//   ① 填 provider 三要素 → ② `provider.probeFetch`（**只探测不写盘**）
//   → ③ 选 catalog **首项**模型（不硬编码任何模型名）→ ④ 建 general（模态可选 image）
//   → ⑤ Start：`config.save`（带探测到的目录）+ `template.save` + 组合根同步（核心做）。
//
// 探测失败或中途放弃都不写盘（probeFetch 不落盘）——不会留半份配置。
import { useEffect, useState } from 'react';

import {
  pickDefaultModel,
  wizardProviderPayload,
  wizardTemplatePayload,
} from '../manage/logic';
import type { CoreClient } from '../protocol';

interface CatalogEntry {
  id?: string;
  display_name?: string;
  context_window?: number | null;
}

export interface WizardProps {
  client: CoreClient;
  onDone: () => void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function Wizard({ client, onDone }: WizardProps) {
  const [providerName, setProviderName] = useState('magpie');
  const [baseUrl, setBaseUrl] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [step, setStep] = useState<'provider' | 'model'>('provider');
  const [entries, setEntries] = useState<CatalogEntry[]>([]);
  const [selectedModel, setSelectedModel] = useState('');
  const [includeImage, setIncludeImage] = useState(false);
  const [defaultTools, setDefaultTools] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    client
      .request<{ defaultTools: string[] }>('template.list')
      .then((result) => setDefaultTools(result.defaultTools ?? []))
      .catch(() => setDefaultTools([]));
  }, [client]);

  const probe = async () => {
    setError(null);
    setBusy(true);
    try {
      const result = await client.request<{
        ok: boolean;
        entries: CatalogEntry[];
        error: string | null;
        errorFilePath?: string | null;
      }>('provider.probeFetch', {
        providerName: providerName.trim(),
        baseUrl: baseUrl.trim(),
        apiKey: apiKey.trim(),
      });
      if (!result.ok) {
        setError(
          `探测失败：${result.error ?? '(未知原因)'}` +
            (result.errorFilePath ? `（完整响应见 ${result.errorFilePath}）` : ''),
        );
        return;
      }
      if (result.entries.length === 0) {
        setError('探测成功但目录为空：这个网关没有返回任何模型，无法确定模型名与上下文窗口。');
        return;
      }
      // 首项即默认值 —— **不硬编码**任何模型名（design D11）。
      const first = pickDefaultModel(result.entries);
      if (first === null) {
        setError('目录条目缺少模型 id：无法确定模型名，向导不会写出配置。');
        return;
      }
      setEntries(result.entries);
      setSelectedModel(first);
      setStep('model');
    } catch (probeError: unknown) {
      setError(`探测失败：${errorText(probeError)}`);
    } finally {
      setBusy(false);
    }
  };

  const start = async () => {
    setError(null);
    if (!selectedModel) {
      setError('还没有选中模型：先探测目录并选择首项。');
      return;
    }
    setBusy(true);
    try {
      const providerPayload = wizardProviderPayload({
        name: providerName,
        baseUrl,
        apiKey,
        models: entries,
      });
      await client.request('config.save', providerPayload);
      await client.request(
        'template.save',
        wizardTemplatePayload({
          providerName: providerName.trim(),
          model: selectedModel,
          includeImage,
          defaultTools,
        }),
      );
      onDone();
    } catch (startError: unknown) {
      setError(`首启配置写入失败：${errorText(startError)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section
      data-testid="wizard"
      className="mx-auto mt-16 w-full max-w-xl rounded-panel border border-line bg-surface p-6 text-fg shadow-e2"
      aria-label="首启向导"
    >
      <h2 className="text-xl font-semibold">首次启动：配置一个 Provider</h2>
      <p className="mt-1 text-xs text-muted">
        配置文件不存在时核心以空配置启动；填完这一页就能在 web 里直接开始聊天。
      </p>

      {error && (
        <p
          data-testid="wizard-error"
          className="mt-3 rounded-card border border-danger/40 bg-danger/10 px-3 py-2 text-sm text-danger"
        >
          {error}
        </p>
      )}

      {step === 'provider' ? (
        <div className="mt-4 space-y-2">
          <label className="block text-xs text-muted">
            Provider 名
            <input
              data-testid="wizard-provider-name"
              value={providerName}
              onChange={(event) => setProviderName(event.target.value)}
              className="mt-1 h-9 w-full rounded-card border border-line bg-bg px-2 text-sm text-fg"
            />
          </label>
          <label className="block text-xs text-muted">
            网关地址
            <input
              data-testid="wizard-base-url"
              value={baseUrl}
              onChange={(event) => setBaseUrl(event.target.value)}
              placeholder="http://127.0.0.1:3425"
              className="mt-1 h-9 w-full rounded-card border border-line bg-bg px-2 text-sm text-fg"
            />
          </label>
          <label className="block text-xs text-muted">
            API Key
            <input
              data-testid="wizard-api-key"
              type="password"
              value={apiKey}
              onChange={(event) => setApiKey(event.target.value)}
              className="mt-1 h-9 w-full rounded-card border border-line bg-bg px-2 text-sm text-fg"
            />
          </label>
          <div className="flex justify-end">
            <button
              type="button"
              data-testid="wizard-next"
              disabled={busy}
              onClick={() => void probe()}
              className="rounded-card bg-accent px-4 py-2 text-sm font-semibold text-bg disabled:opacity-40"
            >
              下一步（探测模型目录）
            </button>
          </div>
        </div>
      ) : (
        <div className="mt-4 space-y-3">
          <p className="text-xs text-muted">
            探测到 {entries.length} 个模型；默认选目录首项（可改）。
          </p>
          <label className="block text-xs text-muted">
            模型
            <select
              data-testid="wizard-model-select"
              value={selectedModel}
              onChange={(event) => setSelectedModel(event.target.value)}
              className="mt-1 h-9 w-full rounded-card border border-line bg-bg px-2 text-sm text-fg"
            >
              {entries.map((entry) => (
                <option key={entry.id} value={entry.id}>
                  {entry.display_name ?? entry.id}
                </option>
              ))}
            </select>
          </label>
          <label className="flex items-center gap-2 text-sm text-fg">
            <input
              type="checkbox"
              data-testid="wizard-include-image"
              checked={includeImage}
              onChange={(event) => setIncludeImage(event.target.checked)}
            />
            这个模型能看图（勾上会写入 input_modalities: text+image）
          </label>
          <p className="text-xs text-muted">
            general 模板会用这条模型与核心给的默认工具清单；点 Start 才写盘（探测本身不写盘）。
          </p>
          <div className="flex justify-between">
            <button
              type="button"
              data-testid="wizard-back"
              onClick={() => setStep('provider')}
              className="rounded-card border border-line px-3 py-2 text-sm text-muted hover:text-fg"
            >
              上一步
            </button>
            <button
              type="button"
              data-testid="wizard-start"
              disabled={busy}
              onClick={() => void start()}
              className="rounded-card bg-accent px-4 py-2 text-sm font-semibold text-bg disabled:opacity-40"
            >
              Start
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
