# web-fetch 变更（Delta）

## MODIFIED Requirements

### Requirement: Curl fallback size protection
The curl fallback path SHALL use `CURLOPT_MAXFILESIZE` (10MB) to reject responses whose Content-Length exceeds the limit before transfer begins. The previous 100KB incremental write callback cap SHALL be removed. For chunked responses without Content-Length, the 15-second timeout SHALL serve as the transfer volume bound.

**越界必须可见且可恢复**（并入 `truncation-visibility` 的总规则）：当响应因为体积被拒（Content-Length 超过上限）时，`web_fetch` 返回的错误说明 SHALL 写明：①这是因为体积上限而不是网络故障；②上限是多少、以及服务端声明的体积是多少（读不到就说明读不到）；③被拒的响应体**没有**被读取。错误说明里 SHALL 含本次实际请求的网址。

**现状与改动点**（写进规范是为了让判据有对照）：`CURLOPT_MAXFILESIZE` 已在用（10MB）。提案时点该拒绝**没有专门分支**（落到 `Fetch failed: <libcurl 的英文错误文本>`，无上限数字、无网址）；change `fix-silent-truncation` 已补上专门分支（`sidecar/src/web_fetch.cpp` 的 `CURLE_FILESIZE_EXCEEDED` 一支，写出上限与实际请求网址），与本段三条件对齐。本要求在已归档状态上只追加下面两条新场景（spill 交付形态），既有的三个原始场景与"体积被拒"场景文字保持原样。

#### Scenario: Response with large Content-Length rejected

- **WHEN** the curl fallback fetches a URL whose server responds with `Content-Length: 50000000` (50MB)
- **THEN** curl SHALL abort before downloading the body, and `web_fetch` SHALL return an error

#### Scenario: Normal page under limit fetched fully

- **WHEN** the curl fallback fetches a 500KB HTML page
- **THEN** the full response body SHALL be received and processed without truncation

#### Scenario: Chunked response bounded by timeout

- **WHEN** the curl fallback fetches a chunked response (no Content-Length) that streams indefinitely
- **THEN** the 15-second timeout SHALL terminate the transfer

#### Scenario: 体积被拒时的说明要指名上限与网址

- **WHEN** 响应因为 Content-Length 超过 10MB 而被拒
- **THEN** 错误说明 SHALL 含上限（10MB）、服务端声明的体积、以及本次请求的网址；只回 `Fetch failed: <libcurl 英文原文>` SHALL 算不满足本场景

#### Scenario: 正文超预览阈值时交付 spill 引用而不是硬切

- **WHEN** `web_fetch` 抓回的正文长度超过 `preview_chars × 2`（`spill.preview_chars`，默认 1000）
- **THEN** 模型可见正文 SHALL 为"头 `preview_chars` 字符 + 省略说明（含省略字节数、总量、spill 引用与 `read_spill` 读回参数）+ 尾 `preview_chars` 字符"，末尾另带一行 spill 引用；SHALL NOT 出现"只保留前 N 个字符、不交代略去多少与如何取回"的形态（旧 Dart 侧 2000 字符硬切连同其三个点标记废除）

#### Scenario: 通用截断的再取入口带网址

- **WHEN** `web_fetch` 的结果正文超过通用截断阈值，被替换成"头 + 尾 + 标记"
- **THEN** 标记里 SHALL 含本次抓取的网址（`refetch via web_fetch "<网址>"` 这样的可执行形态）；`web_fetch` 的输入参数没有 `path`，因此 SHALL NOT 依赖 `path` 来拼这个入口

## ADDED Requirements

### Requirement: web_fetch 结果交付给模型的形态

`web_fetch` 成功结果交付给模型的正文 SHALL 按以下形态拼装（Dart 侧后处理，替换旧的"前 2000 字符加三个点"）：

1. 第一行标题（页面 `<title>`，为空时用网址）、第二行网址；
2. 正文为 C++ 侧 spill 形状后的内联文本：不超阈值时就是完整正文；超阈值时为头尾预览加省略说明；
3. 落了盘时，**最后一行** SHALL 是 `[spill refs: content=<引用> (<总字节> bytes, <省略字节> omitted) …read_spill(ref, offset, limit)]` 形态的引用行——放最后一行是为了重放阶段的通用省略（保头保尾）掐不到取回入口；
4. 正文为空时 SHALL 给 `(fetched empty page)` 提示（既有行为保留），此时不产生 spill 引用；
5. 交付给界面结果卡片的文本 SHALL 与发给模型的正文为同一份字符串（SHALL NOT 为卡片另行取一份未形状化的全文或另切一份）；卡片结果行按既有 UI 机制显示前 200 字符折叠摘要、完整正文保留在工具调用记录里，该显示机制 SHALL NOT 被本要求禁止，其存在 SHALL 在用户文档披露。

#### Scenario: 短正文完整内联且不出现省略字样
- **WHEN** `web_fetch` 抓回 800 字符的正文（默认配置，阈值 1000×2）
- **THEN** 模型可见正文 SHALL 含全部 800 字符，且 SHALL NOT 含"省略"字样

#### Scenario: 长正文的取回入口在最后一行
- **WHEN** `web_fetch` 抓回 19,806 字符的正文（用例构造值，规模取自提案时点在真机日志观察过的被切样本）
- **THEN** 模型可见正文最后一行 SHALL 是带引用与 `read_spill` 参数的 spill 引用行；模型按该引用调用 `read_spill` SHALL 能读回头尾之外的中间段原文

#### Scenario: 引用行随请求体重放不被掐断
- **WHEN** 会话重放一轮历史 `web_fetch` 调用、其正文再次经过通用省略处理
- **THEN** 交付的 `tool_result` 正文 SHALL 仍含可辨认的 spill 引用信息（`[spill refs:` 标记被保留或被"中间的原文可用 read_spill 读回"的尾注指到）

#### Scenario: 卡片与模型拿同一份字符串
- **WHEN** 渲染一轮长正文 `web_fetch` 的结果卡片
- **THEN** 卡片内容项拿到的文本 SHALL 与发给模型的正文为同一字符串（同为预览加引用行形态）；卡片结果行的 200 字符折叠摘要按第 5 项处理——它显示的是这份字符串的开头，不另取第二份正文
