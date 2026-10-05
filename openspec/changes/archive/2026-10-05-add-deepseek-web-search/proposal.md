## Why

现在助手要联网搜索，必须在配置里额外填一份**付费搜索服务**的密钥（`search` 段里的 `zhipuai` 或 `kimi`）；没填就等于"模型根本没有搜索工具"。但**你手上那把 DeepSeek 的密钥本身就能搜** —— DeepSeek 的接口内置了服务端搜索能力，用你已经在用的那个地址和密钥就能拿到真实的网页结果。

所以这次要做的是：**把 DeepSeek 自带的搜索接成 `web_search` 的一个后端**。它不需要新的密钥、不需要新账号 —— 你配好模型就能搜。

**已经实测过能通**（2026-10-04，用你现有配置里的那把密钥发的一次真实请求）：`HTTP 200`，5.4 秒，拿回 10 条带网址、标题的网页结果。请求形状与返回结构都是从本机装着的参考实现（DeepSeek Harness 的 `dsh-web-search-deepseek`）里读出来的，与本地文档 `Docs/DeepSeekAPIDoc.md` 的兼容性表格对得上（`server_tool_use` 与 `web_search_tool_result` 标为"支持"）。

## What Changes

- **新增一个搜索后端 `deepseek`**，与现有的 `zhipuai`、`kimi` 并列，走同一套搜索后端接口（同一个函数、同一种返回）。
- **凭据只认两份来源，且绝不把非 DeepSeek 的密钥发出去**：推荐做法是在 `search.deepseek` 段里写明密钥与地址；只有当**地址确实指向 DeepSeek**（含 `api.deepseek.com`）且 `search.deepseek` 段存在时，才允许回落复用会话模型那个 provider 的密钥。地址不是 DeepSeek 时该后端**直接不可用**，不回落、不发任何请求。`search` 段整个是空的、也没有任何搜索密钥时，这个后端默认不出现 —— 想用就写一句 `"deepseek": {}` 表明知道自己在开它。
- **搜索的实现方式**：向 `https://api.deepseek.com/anthropic/v1/messages` 发一次**完整的模型调用**，请求里带一个服务端搜索工具（`web_search_20250305`，最多用 1 次），然后从返回里挑出结构化的搜索结果块，映射成项目现有的搜索结果结构（网址、标题、日期、摘要）。
- **这条路上有一段"模型自己写的回答文字"，我们不取** —— 与参考实现一致（它明文写着这段文字不作为答案受到信任）。理由与实测现场写在设计里。
- **摘要有时候是空的**（DeepSeek 只在有引用时才给原文片段），因此放宽"搜索结果正文不许为空"这条老约定，并在有标题时用标题兜底，不让一条只有链接的结果被丢掉。
- **搜索工具的可用性跟着变**：接上之后，只要按上面那条把 DeepSeek 搜索打开（写明 `search.deepseek`，或在指向 DeepSeek 的模型配置下让它回落），模型就有 `web_search` 工具（以前必须有付费搜索密钥才有）。
- **文档同步**：`Docs/user-guide/tools-web.md` 要说明"搜索现在也可以用 DeepSeek 自己的"，并写清它的代价（一次搜索 = 一次完整模型调用，几秒钟、按 token 计费）与限制（结果条数由服务决定、摘要可能为空）。

## Capabilities

### New Capabilities

- `deepseek-search-provider`: 用 DeepSeek 自带的搜索能力当搜索后端 —— 复用哪把密钥与哪个地址、请求怎么拼、返回怎么映射成搜索结果、摘要为空怎么办、条数怎么截断、失败怎么报。
- `web-search`: 搜索后端这份清单本身 —— 现在有哪些后端、各自的凭据从哪来、`web_search` 工具什么时候对模型可见。
- `deepseek-search-provider-tests`: 上面两件事的可失败验证方式 —— 单测覆盖请求构造与返回映射（含乱码标题、空摘要、没有结果块这些边界），集成测试经真实动态库走一遍"配置进去 → 后端可用 → 搜索结果出来"。

### Modified Capabilities

（无。查过 `openspec/specs/`：目前**没有**任何一份规范写着搜索后端这份清单或 `web_search` 工具何时可见 —— 它此前没被规范覆盖，所以本变更把它作为新能力补上，而不是改一份既有条文。）

## Impact

- **新增**：`sidecar/src/deepseek_search.cpp` / `.h`（搜索后端本体）、`sidecar/test/deepseek_search_test.cpp`（单测）。
- **改动**：`sidecar/src/search_provider.cpp` / `.h`（注册新后端与它的凭据解析）、`sidecar/CMakeLists.txt`（两份源码列表）、`lib/main.dart`（把会话模型的 provider 密钥与地址一起交给搜索初始化）、`Docs/user-guide/tools-web.md`、`README.md`（如果需要新增文档索引条目）。
- **不改**：`web_search` 对模型暴露的参数（`query` / `providers` / `depth` / `max_results`）与它的返回结构；`zhipuai` / `kimi` 两个后端的行为。
- **一条安全边界（这次由你当场指出后才加上的）**：本变更 SHALL NOT 把非 DeepSeek 的密钥发到任何端点。判定与处置写在设计 D2 里，并有专门一条测试守着（拿"指向非 DeepSeek 地址"的会话配置断言该后端不可用且**没有发出请求**）。
- **一处需要如实说明的既有约定改动**：搜索结果的"正文"字段现在允许为空（DeepSeek 有时不给摘要）。这不是放松验收，是把接口写实 —— 旧约定假设每个后端都能给正文，DeepSeek 不保证。
- **风险与代价（明写）**：
  - 一次搜索要烧一次完整模型调用（实测 5.4 秒、约 6931 输入 token + 1112 输出 token），比 zhipu / kimi 那种专用检索端点贵得多；因此本变更**给服务端搜索次数设成 1**，不做"一次请求连搜好几轮"。
  - 结果条数由服务决定（实测一次 10 条），`max_results` 只能由我们事后截断。
  - 返回里每条结果带着约 2200 字符的加密内容，我们不用它、也不保存它。
