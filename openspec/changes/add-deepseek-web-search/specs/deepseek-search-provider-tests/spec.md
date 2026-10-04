# deepseek-search-provider-tests Specification

## Purpose

把 `deepseek-search-provider` 与 `web-search` 两份规范里的要求落到**在行为坏掉时会红**的检查上，并说清每条检查跑在哪一层：请求构造与返回映射这种纯逻辑放 C++ 单测（不联网，用假的响应文本），"配置进去 → 后端可用 → 搜索结果出来"这条链路放 Dart 集成测试（经真实动态库）。一条检查可以覆盖多件事（允许共用），但用例里 SHALL 写明它覆盖哪几件。

**真实联网的那一次不放进自动测试**：这个后端每次搜索都要花一次模型调用的钱与时间，自动化跑它会让常规回归变贵且依赖网络。因此规范里的场景用**离线可复现**的方式验（构造响应文本喂给解析），另有一条**手动、按需跑**的验收写在任务清单里。

## ADDED Requirements

### Requirement: 请求构造与返回映射由 C++ 单测覆盖

`sidecar/test` 下的 C++ 单测 SHALL 覆盖：请求体的固定形状（查询前缀、服务端搜索工具的 `type` 与 `max_uses`、版本头、没有流式开关）；结果块的映射（网址、标题、日期、按网址去重）；引用片段按网址对应成正文；没有引用时用标题兜底；标题含非法字节不崩；`page_age` 为空不丢结果；`max_results` 按顺序截断；没有结果块时明确报错（而不是返回模型写的文字、也不是返回 0 条）；失败说明里带实际使用的地址。

这些用例 SHALL 在对应行为被改坏时失败（例如把 `max_uses` 改成不限、把没有结果块当成成功、把 `text` 块的回答当成正文、去掉去重）。

#### Scenario: 请求形状的断言能失败

- **WHEN** 运行请求构造单测
- **THEN** 它 SHALL 断言查询出现在固定前缀之后、`tools[0].type` 为 `web_search_20250305`、`max_uses` 为 1；把 `max_uses` 改掉会让它失败

#### Scenario: 没有结果块当失败的断言能失败

- **WHEN** 运行"响应里只有 text 与 thinking"的单测
- **THEN** 它 SHALL 断言返回是失败且说明里含"没有触发服务端搜索"；改成"返回 0 条算成功"或"把 text 当正文"都会让它失败

#### Scenario: 去重的断言能失败

- **WHEN** 运行两个结果块含同一网址的单测
- **THEN** 它 SHALL 断言该网址只出现一次；去掉去重会让它失败

#### Scenario: 摘要回落的断言能失败

- **WHEN** 分别运行"有引用片段"与"没有引用"两条单测
- **THEN** 前者 SHALL 断言正文等于 `cited_text`，后者 SHALL 断言正文用标题兜底且非空；把两者对调、或让正文为空，都会失败

#### Scenario: 坏字节不崩的断言能失败

- **WHEN** 运行标题含非法字节的单测
- **THEN** 它 SHALL 断言解析成功、坏字节被替换字符取代；让解析抛异常会让它失败

### Requirement: 跨语言链路由 Dart 集成测试覆盖

`test/integration` 下 SHALL 有一条经**真实动态库**的集成测试，覆盖：把带 DeepSeek 凭据的搜索配置交给初始化之后，可用后端清单里出现 `deepseek`；把凭据拿掉之后它不出现。这条用例 SHALL 在断言前打印实际的清单内容。它 SHALL NOT 真的发起联网搜索（联网那一次按任务清单手动跑）。

#### Scenario: 有凭据时后端出现

- **WHEN** 用例把 `{"deepseek":{"api_key":"..."}}` 交给搜索初始化，然后读可用后端清单
- **THEN** 清单 SHALL 含 `deepseek`；把它从配置里去掉会让这条失败

#### Scenario: 清单内容在断言前被打印

- **WHEN** 运行该用例
- **THEN** 输出里 SHALL 有本次实际的可用后端清单（让人看得出它到底认出了哪些后端）

### Requirement: 文档与本规范的一致性

`Docs/user-guide/tools-web.md` SHALL 说明：搜索现在也可以走 DeepSeek 自己的搜索（不需要额外密钥）、它的代价（一次搜索等于一次完整模型调用，几秒钟、按 token 计费）、以及它的限制（结果条数由服务决定、摘要可能为空）。文档里出现的工具名与配置键 SHALL 能在产品代码里核到（现有的文档一致性检查会管这件事）。

#### Scenario: 文档写了 DeepSeek 这条路

- **WHEN** 检查 `Docs/user-guide/tools-web.md`
- **THEN** 它 SHALL 提到 `deepseek` 这个后端与"不需要额外密钥"；把它们删掉会让任务清单里那条文档验收失败

#### Scenario: 文档里的键名能在代码里核到

- **WHEN** 文档里写出 `search.deepseek.api_key` 这类键
- **THEN** 现有的文档一致性检查 SHALL 能在配置解析路径里找到它们
