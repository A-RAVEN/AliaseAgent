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

## 在哪用

- **第一次启动**：应用发现没有配置文件，会弹出欢迎对话框，只问两件事。
- **以后改配置**：直接用文本编辑器改上面那个文件，然后**重启应用**（配置在启动时读一次）。

## 怎么操作

### 第一次启动的对话框

| 界面上看到的 | 填什么 |
|---|---|
| `API Key`（提示 `sk-ant-...`） | 你的模型服务 key |
| `Max Context Tokens`（提示 `e.g. 200000`，下面一行小字 `Compaction threshold (one-time setting)`） | 模型能装下多少 token；它决定"什么时候开始压缩"（见 [上下文压缩](context-compaction.md)） |
| `Start` 按钮 | 保存并进入界面 |

按 `Start` 之后，应用会写出这样一份配置（供应商固定叫 `anthropic`，模型写死为 `claude-sonnet-4-6`，工具给 `read_file` 和 `list_dir`）：

```json
{
  "version": 1,
  "providers": {
    "anthropic": {
      "api_key": "你的 key",
      "base_url": "https://api.anthropic.com"
    }
  },
  "agent_types": {
    "general": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["read_file", "list_dir"],
      "max_context_tokens": 200000
    }
  }
}
```

### 手写一份完整配置

下面是**所有**能填的键。没写的键用括号里的默认值。

```json
{
  "version": 1,
  "providers": {
    "anthropic": {
      "api_key": "你的 key",
      "base_url": "https://api.anthropic.com"
    }
  },
  "agent_types": {
    "general": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["read_file", "write_file", "edit_file", "list_dir", "glob_file", "grep_file", "get_current_time"],
      "thinking_effort": "medium",
      "max_context_tokens": 200000,
      "compaction_threshold_percent": 25,
      "compaction_wait_threshold_percent": 75,
      "standing_requirements": ["不要删我的文件"]
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
  }
}
```

| 键 | 在哪一层 | 含义 | 不写会怎样 |
|---|---|---|---|
| `version` | 顶层 | 配置格式版本，目前是 `1` | 按 `1` 处理 |
| `providers` | 顶层 | 供应商表，键名随便起（上面用了 `anthropic`） | 没有可用供应商，发消息会报错 |
| `api_key` | 每个供应商 | 模型服务的 key | 必填，缺了会报数据结构错误 |
| `base_url` | 每个供应商 | 服务地址 | 空字符串 |
| `agent_types` | 顶层 | agent 表，应用只找名字叫 `general` 的那个 | 没有 `general`，发消息时报 `No agent type configured.` |
| `provider` | 每个 agent | 用哪个供应商（对应 `providers` 里的键名） | 必填 |
| `model` | 每个 agent | 模型名 | 必填 |
| `system_prompt` | 每个 agent | 系统提示词 | 空字符串 |
| `tools` | 每个 agent | 允许模型调用的工具名清单 | 空清单（模型没有工具可用） |
| `thinking_effort` | 每个 agent | 思考强度 | 不传（用服务端默认） |
| `max_context_tokens` | 每个 agent | 模型能吃下多少 token | 不写就再弹一次欢迎对话框问你要 |
| `compaction_threshold_percent` | 每个 agent | 压缩阈值百分比，1 到 100 的整数 | 用 25 |
| `compaction_wait_threshold_percent` | 每个 agent | **等待**阈值百分比，1 到 100 的整数：这一轮要发出去的内容占模型总上下文超过这个比例时，才等压缩做完再发（见 [上下文压缩](context-compaction.md)） | 用 75 |
| `standing_requirements` | 每个 agent | 你写死的目标，压缩时不许丢掉 | 空清单 |
| `search` | 顶层 | 搜索服务配置（整块都可以不写） | 不注册任何搜索服务，也就没有 `web_search` 工具 |
| `zhipuai` / `kimi` / `searxng` | 每个搜索服务 | 三家搜索服务的名字，对应各自的键 | 该服务不启用 |
| `deepseek` | `search` 下 | DeepSeek 自己的搜索：**不用另外买搜索 key**，复用你在 `providers` 里已经填的那把（前提是那个地址指向 `api.deepseek.com`） | 该服务不启用（写一个空的 `{}` 就算启用） |
| `search_engine` | `zhipuai` | 用哪个搜索引擎档位 | 由服务端默认决定 |
| `api_key` / `base_url` / `model` | `deepseek` 下 | 单独给搜索指定密钥、地址、模型（都可选） | 用 `providers` 里那把密钥与地址；模型用 `deepseek-v4-flash` |
| `base_url`（`searxng` 下） | `searxng` | 自建搜索服务地址 | `http://localhost:8888` |

> 关于搜索：**`web_search` 工具只有在至少配了一家搜索服务时才会出现**。目前这一版里 `searxng` 在启动时被直接标记为不可用，所以实际能生效的是 `deepseek`、`zhipuai` 和 `kimi` 三家（前一家不用另外买 key，后两家要付费 key）。详见 [联网工具](tools-web.md)。

> 关于 `deepseek` 的一条安全规矩：**只有地址确实指向 DeepSeek（含 `api.deepseek.com`）时才会复用 `providers` 里那把密钥**；地址指向别处时这个后端直接不可用、一个请求都不发（那把密钥可能是别家的，不能发到别的地址上）。

## 出错时会看到什么

| 现象 | 什么时候出现 | 怎么办 |
|---|---|---|
| 对话框里红字 `Please enter an API key` | 第一次启动时 `API Key` 空着就按 `Start` | 填 key |
| 对话框里红字 `Please enter a valid max context token count (a positive integer)` | `Max Context Tokens` 空着、不是整数、或不是正数 | 填一个正整数，例如 `200000` |
| 整屏 `Configuration Error`，下面一行 `Invalid JSON in <路径>: ...` | 配置文件不是合法 JSON（少逗号、多逗号、引号没配对） | 按提示的路径打开文件修好，重启应用 |
| 整屏 `Configuration Error`，下面一行 `Unexpected data structure in <路径>: ...` | JSON 合法但结构不对（例如某个供应商少了 `api_key`，或 `agent_types` 里少了 `general`） | 按上面的完整示例补全 |
| 又弹一次欢迎对话框 | 配置文件不存在，或者 `general` 里没有可用的 `max_context_tokens` | 按对话框填；也可以直接改文件补上这个键 |
| 日志里多一行 `compaction_threshold_percent=... is absent or not an integer in 1..100 — using the default 25% ...` | 这个键写了小数、`0`、负数、大于 `100`、或者写成了字符串 | 改成 1 到 100 的整数；不改也能用（按 25% 走） |
| 日志里多一行 `compaction_wait_threshold_percent=... is absent or not an integer in 1..100 — using the default 75% ...` | `compaction_wait_threshold_percent` 写了小数、`0`、负数、大于 `100`、或者写成了字符串 | 改成 1 到 100 的整数；不改也能用（按 75% 走） |

日志在 `%USERPROFILE%\.aliasagent\logs\sidecar.log`。

## 限制

- **改完要重启应用**：配置只在启动时读一次，运行中改文件不生效。
- **没有图形化设置界面**：除了第一次启动那个对话框，其余都得手改 JSON。
- **应用只认名字叫 `general` 的 agent**：`agent_types` 里可以放别的名字，但界面上不会用到。
- **首启对话框写死的那份配置里只有两个文件工具**（`read_file`、`list_dir`）；想要别的工具得自己往 `tools` 里加。
