# 配置

## 这是什么

AliasAgent 的全部设置都放在一个 JSON 文件里：

```
~/.aliasagent/config.json
```

Windows 上 `~` 是你的用户主目录（`%USERPROFILE%`，例如 `C:\Users\你的名字`），所以完整路径通常是：

```
C:\Users\你的名字\.aliasagent\config.json
```

这个文件分三块：**供应商**（连哪个模型服务、用什么 key）、**agent 类型**（用哪个模型、带哪些工具、上下文多大）、**搜索服务**（联网搜索用哪家）。

Agent 类型（模板）现在有图形界面：会话侧栏的 `Agents` 菜单可以列出、添加和修改模板，改完会写回这个文件的 `agent_types` 段。怎么用见 [Agent 模板](agent-templates.md)。

供应商也有图形界面：会话侧栏的 `Providers` 入口可以新增、编辑、改名、删除 Provider，并点"探测"拉取网关的模型目录（写回以下两个键）。怎么用见 [Provider 与模型目录](provider-models.md)。

## 在哪用

- **第一次启动**：应用发现没有配置文件，会弹出一个两步向导：第一步问 Provider 名字、网关地址与密钥，第二步问上下文窗口。
- **改 Agent 模板**：用侧栏的 `Agents` 菜单（不用重启；保存后**之后创建或恢复**的实例才用新配置）。
- **改 Provider（增删改、探测模型目录）**：用侧栏的 `Providers` 入口（保存后立即写回文件；之后创建或恢复的实例使用新 Provider 配置）。
- **改搜索、spill 或没有界面入口的模板字段**：直接用文本编辑器改上面那个文件，然后**重启应用**（这些段只在启动时读一次）。

## 怎么操作

### 第一次启动的对话框（两步向导）

| 界面上看到的 | 填什么 |
|---|---|
| 第 1 步：`Provider 名称`（默认 `magpie`，可改） | 这份配置里这个供应商的名字；模板用这个名字引用它 |
| 第 1 步：`网关地址`（默认 `http://127.0.0.1:3425`，可改） | 模型服务的地址；填 `http://127.0.0.1:3425/v1` 这类带尾部 `/v1` 的地址也能存（会自动归一化） |
| 第 1 步：`API Key`（遮蔽输入，默认预填 `magpie`，可改） | 你的模型服务 key；magpie 网关的密钥约定就叫 magpie |
| 第 1 步的 `下一步` | 检查名字/地址/密钥后进入第 2 步；校验失败停在第一步并保留输入 |
| 第 2 步：`Max Context Tokens`（提示 `e.g. 200000`，下面一行小字 `Compaction threshold (one-time setting)`） | 模型能装下多少 token；它决定"什么时候开始压缩"（见 [上下文压缩](context-compaction.md)） |
| 第 2 步的 `Start` 按钮 | 两步都合法后保存并进入界面 |

整条向导在两步都成功之前不能关闭（点对话框外面也不会关）。补问（已有配置但 `general` 缺窗口）会跳过第 1 步的默认值猜测，把名字与地址预填成 `general` 实际在用的 Provider；密钥不回显，需要重新输入。

按 `Start` 之后，应用会写出这样一份配置（供应商名默认是 `magpie`，可以改；默认地址是 `http://127.0.0.1:3425`、默认密钥预填 `magpie`；模型写死为 `claude-sonnet-4-6`，工具给当前**十一项基础工具**；没探测过目录，所以没有 `models` / `discovered_at` 两个键）：

```json
{
  "version": 1,
  "providers": {
    "magpie": {
      "api_key": "magpie",
      "base_url": "http://127.0.0.1:3425"
    }
  },
  "agent_types": {
    "general": {
      "provider": "magpie",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["read_file", "write_file", "edit_file", "list_dir", "get_current_time", "glob_file", "grep_file", "read_image", "run_command", "read_spill", "spawn_subagent"],
      "max_context_tokens": 200000
    }
  }
}
```

> 如果你以前用旧版首启生成过 `["read_file", "list_dir"]` 这两项默认清单，启动时会看到一行**迁移提示**：它会被升级成上面这十一项基础工具。你自己收窄或扩展过的清单不会被改动。
>
> 上一版的十项完整默认清单（也就是少了 `spawn_subagent` 的那份）**不会**自动升级：它和"你主动删掉了 `spawn_subagent`"在文件里完全一样，应用无法区分。要让某个模板用上子 Agent，请在 `Agents` 菜单里显式勾选（见 [子 Agent](agent-subagents.md)）。

### 手写一份完整配置

下面是**所有**能填的键。没写的键用括号里的默认值。

```json
{
  "version": 1,
  "providers": {
    "magpie": {
      "api_key": "你的 key",
      "base_url": "http://127.0.0.1:3425",
      "models": [],
      "discovered_at": "2026-11-04T02:00:00.000Z"
    }
  },
  "agent_types": {
    "general": {
      "provider": "magpie",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["read_file", "write_file", "edit_file", "list_dir", "glob_file", "grep_file", "get_current_time"],
      "thinking_effort": "medium",
      "max_context_tokens": 200000,
      "compaction_threshold_percent": 25,
      "compaction_wait_threshold_percent": 75,
      "standing_requirements": ["不要删我的文件"],
      "input_modalities": ["text", "image"]
    }
  },
  "search": {
    "deepseek": {
      "api_key": "不写就用 providers 里那把（前提：地址指向 DeepSeek）",
      "base_url": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-flash"
    },
    "zhipuai": {
      "api_key": "搜索服务的 key",
      "search_engine": "search_std"
    },
    "kimi": {
      "api_key": "搜索服务的 key",
      "model": "kimi-k2-turbo-preview"
    },
    "searxng": {
      "base_url": "http://localhost:8888"
    }
  },
  "tool": {
    "parallel_max": 0
  }
}
```

| 键 | 在哪一层 | 含义 | 不写会怎样 |
|---|---|---|---|
| `version` | 顶层 | 配置格式版本，目前是 `1` | 按 `1` 处理 |
| `providers` | 顶层 | 供应商表，键名随便起（上面用了 `magpie`） | 没有可用供应商，发消息会报错 |
| `api_key` | 每个供应商 | 模型服务的 key | 必填，缺了会报数据结构错误 |
| `base_url` | 每个供应商 | 服务地址 | 空字符串 |
| `models` | 每个供应商 | 模型目录快照：上一次"探测"从网关 `GET /v1/models` 取回的条目数组；没探测过就不写这个键（按空目录读） | 空目录（`Providers` 页显示"未探测"） |
| `discovered_at` | 每个供应商 | 上一次探测成功的时刻（UTC ISO 8601）；没探测过就不写这个键 | 从未探测 |
| `agent_types` | 顶层 | agent 模板表；每个会话按自己保存的模板名选一个（历史会话没有记录时用 `general`）。每个会话用的模板名保存在数据库 `sessions.agent_type` 列里 | 会话引用的模板不存在时，创建 Agent 失败并显示模板名，不会悄悄改用 `general` |
| `provider` | 每个 agent | 用哪个供应商（对应 `providers` 里的键名） | 必填；引用了未定义的 provider 会拒绝创建实例 |
| `model` | 每个 agent | 模型名 | 必填 |
| `system_prompt` | 每个 agent | 系统提示词 | 空字符串 |
| `tools` | 每个 agent | 允许模型调用的工具名清单；只能写工具目录里存在的名字 | 空清单（模型没有工具可用）；写了不存在的工具会拒绝创建实例并列出名字 |
| `thinking_effort` | 每个 agent | 思考强度：low、medium、high、xhigh、max 之一；其它值按"关闭"处理 | 关闭（不传） |
| `max_context_tokens` | 每个 agent | 模型能吃下多少 token；**必须是正整数** | 缺失、为零或负数时拒绝创建 Agent 并显示模板名（不会再按 0 继续发送全文）；`general` 缺这个值时会弹一次欢迎对话框问你要 |
| `compaction_threshold_percent` | 每个 agent | 压缩阈值百分比，1 到 100 的整数 | 用 25 |
| `compaction_wait_threshold_percent` | 每个 agent | **等待**阈值百分比，1 到 100 的整数：这一轮要发出去的内容占模型总上下文超过这个比例时，才等压缩做完再发（见 [上下文压缩](context-compaction.md)） | 用 75 |
| `standing_requirements` | 每个 agent | 你写死的目标，压缩时不许丢掉 | 空清单 |
| `input_modalities` | 每个 agent | 这个模型能吃哪些输入：一个数组，取值只能是 text 和 image。**不写 image，贴进来的图片就不会发给模型**，界面上会提示"模型未声明图片输入，本次没有发送图片" | `["text"]`（只有文字） |
| `spill` | 顶层 | 工具输出的落盘与预览配置（整块都可以不写） | 用下表里的缺省值 |
| `preview_chars` | `spill` 下（完整键名 `spill.preview_chars`） | 工具输出太长时，结果里**头尾各留多少字符**（其余写进 spill 文件、靠 `read_spill` 按字节读回）。判"要不要省略"的阈值是它的 2 倍：头 1000 + 尾 1000 = 2000，超过 2000 字符才省略 | 1000 |
| `tool` | 顶层 | 只读工具并行执行的配置（整块都可以不写） | 用下表里的缺省值 |
| `parallel_max` | `tool` 下（完整键名 `tool.parallel_max`） | 同一轮里**最多同时启动几个只读工具**：`0` = 不设上限（模型发几个就同时跑几个）；正整数 = 按这个数把一段只读调用分批，批与批之间按顺序执行，交付顺序不变。它在**启动时读一次**，改完要重启应用；正整数值会随配置保存写回 `tool` 块 | 0（不设上限） |
| `search` | 顶层 | 搜索服务配置（整块都可以不写） | 不注册任何搜索服务，也就没有 `web_search` 工具 |
| `zhipuai` / `kimi` / `searxng` | 每个搜索服务 | 三家搜索服务的名字，对应各自的键 | 该服务不启用 |
| `deepseek` | `search` 下 | DeepSeek 自己的搜索：**不用另外买搜索 key**，复用你在 `providers` 里已经填的那把（前提是那个地址指向 `api.deepseek.com`） | 该服务不启用（写一个空的 `{}` 就算启用） |
| `search_engine` | `zhipuai` | 用哪个搜索引擎档位 | 由服务端默认决定 |
| `api_key` / `base_url` / `model` | `deepseek` 下 | 单独给搜索指定密钥、地址、模型（都可选） | 用 `providers` 里那把密钥与地址；模型用 `deepseek-v4-flash` |
| `base_url`（`searxng` 下） | `searxng` | 自建搜索服务地址 | `http://localhost:8888` |

> 关于搜索：**`web_search` 工具只有在至少配了一家搜索服务时才会出现**。目前这一版里 `searxng` 在启动时被直接标记为不可用，所以实际能生效的是 `deepseek`、`zhipuai` 和 `kimi` 三家（前一家不用另外买 key，后两家要付费 key）。详见 [联网工具](tools-web.md)。

> 关于"把会话改到已有模板"：用当前会话工具栏（`对话视图` / `真实上下文` 同一行）右侧的模板下拉框，见 [Agent 模板](agent-templates.md)。切换会替换该会话运行中的 Agent 实例，并把数据库 `sessions.agent_type` 更新成新模板名；重启应用后仍按这个值重建实例。改 `agent_types` 里的模板定义本身不会改任何会话的引用。

> 关于 `deepseek` 的一条安全规矩：**只有地址确实指向 DeepSeek（含 `api.deepseek.com`）时才会复用 `providers` 里那把密钥**；地址指向别处时这个后端直接不可用、一个请求都不发（那把密钥可能是别家的，不能发到别的地址上）。

## 出错时会看到什么

| 现象 | 什么时候出现 | 怎么办 |
|---|---|---|
| 对话框里红字 `Please enter an API key` | 两步向导的第 1 步里 `API Key` 空着就点 `下一步` | 填 key |
| 对话框里红字 `请填写 Provider 名称` / `Provider "<名字>" 已存在` | 第 1 步的名字空着，或与配置里已有的 Provider 重名 | 换一个没被占用的名字 |
| 对话框里红字 `网关地址必须是以 http:// 或 https:// 开头的绝对地址` | 第 1 步的网关地址不是绝对 http(s) 地址（例如漏了 `https://`，或写了 `ftp://`） | 补成完整地址，例如 `http://127.0.0.1:3425` |
| 对话框里红字 `Please enter a valid max context token count (a positive integer)` | `Max Context Tokens` 空着、不是整数、或不是正数 | 填一个正整数，例如 `200000` |
| 整屏 `Configuration Error`，下面一行 `Invalid JSON in <路径>: ...` | 配置文件不是合法 JSON（少逗号、多逗号、引号没配对） | 按提示的路径打开文件修好，重启应用 |
| 整屏 `Configuration Error`，下面一行 `Unexpected data structure in <路径>: ...` | JSON 合法但结构不对（例如某个供应商少了 `api_key`，或 `agent_types` 里少了 `general`） | 按上面的完整示例补全 |
| 又弹一次欢迎对话框 | 配置文件不存在，或者 `general` 里没有可用的 `max_context_tokens` | 按对话框填；也可以直接改文件补上这个键 |
| 界面顶部红条 `Agent 模板 "<名字>" 的 max_context_tokens 无效（...）：必须是正整数。拒绝创建实例...` | 某个模板的窗口缺失、为零或负数 | 用 `Agents` 菜单改这个模板的上下文窗口，或直接改文件；修好前这个模板不能创建实例 |
| 界面顶部红条 `Agent 模板 "<名字>" 不存在：拒绝创建实例，也不会退回 general` | 会话保存的模板名在 `agent_types` 里找不到 | 用 `Agents` 菜单添加一个同名模板，或用当前会话工具栏的模板下拉把它换到一个已存在的模板（切换后数据库 `sessions.agent_type` 会更新；本版没有改名入口） |
| 界面顶部红条 `未知工具：<名字>（模板 "<名字>"）：不在 ToolCatalog 中。不会静默丢弃...` | 模板的 `tools` 里写了工具目录中不存在的名字 | 用 `Agents` 菜单改工具集合；不会静默删掉这个名字继续跑 |
| 日志里多一行 `compaction_threshold_percent=... is absent or not an integer in 1..100 — using the default 25% ...` | 这个键写了小数、`0`、负数、大于 `100`、或者写成了字符串 | 改成 1 到 100 的整数；不改也能用（按 25% 走） |
| 日志里多一行 `compaction_wait_threshold_percent=... is absent or not an integer in 1..100 — using the default 75% ...` | `compaction_wait_threshold_percent` 写了小数、`0`、负数、大于 `100`、或者写成了字符串 | 改成 1 到 100 的整数；不改也能用（按 75% 走） |

日志在 `%USERPROFILE%\.aliasagent\logs\sidecar.log`。

## 限制

- **搜索、spill 改完要重启应用**：配置只在启动时读一次，运行中改这些段不生效（Provider 例外：用 `Providers` 页改完立即写回，之后创建或恢复的实例就用新值）。
- **Agent 模板用 `Agents` 菜单改，不用重启**：保存只影响**之后创建或恢复**的实例；已经运行的会话继续使用创建时的配置。要让当前会话立刻用上新模板，用工具栏的模板下拉显式切换（它会替换运行实例并更新数据库 `sessions.agent_type`）；只在会话列表里重新选中它不会重建实例。
- **模板没有删除入口、也不能改名**：模板名是会话的持久化引用键，创建后只读；本版只支持添加与修改。
- **Provider 用 `Providers` 页改，不重启生效**：新增 / 编辑 / 改名 / 删除与"探测"都在侧栏的 `Providers` 入口里；密钥框是遮蔽输入，列表不显示明文。也可以继续手改文件里的 `api_key`、`base_url`，那种方式仍需重启。
- **`spawn_subagent` 不会自动加到既有模板**：新首启配置包含它；旧十项清单与"用户主动删除"形状相同，迁移不会替你加回，需要时在 `Agents` 菜单里显式勾选（见 [子 Agent](agent-subagents.md)）。
