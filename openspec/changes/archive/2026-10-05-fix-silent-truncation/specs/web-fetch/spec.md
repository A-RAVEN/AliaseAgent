# web-fetch Specification

## MODIFIED Requirements

### Requirement: Curl fallback size protection
The curl fallback path SHALL use `CURLOPT_MAXFILESIZE` (10MB) to reject responses whose Content-Length exceeds the limit before transfer begins. The previous 100KB incremental write callback cap SHALL be removed. For chunked responses without Content-Length, the 15-second timeout SHALL serve as the transfer volume bound.

**越界必须可见且可恢复**（并入 `truncation-visibility` 的总规则）：当响应因为体积被拒（Content-Length 超过上限）时，`web_fetch` 返回的错误说明 SHALL 写明：①这是因为体积上限而不是网络故障；②上限是多少、以及服务端声明的体积是多少（读不到就说明读不到）；③被拒的响应体**没有**被读取。错误说明里 SHALL 含本次实际请求的网址。

**现状与改动点**（写进规范是为了让判据有对照）：`CURLOPT_MAXFILESIZE` 已在用（10MB），但它被拒时 libcurl 返回的错误码**没有专门分支**，落到末尾那句 `Fetch failed: <libcurl 的英文错误文本>`，说明里既没有上限数字、也没有网址。本要求把这一支补成上面那种说明 —— 原有的三个场景文字保持原样，新增的判断落在下面那条新场景里。

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

#### Scenario: 通用截断的再取入口带网址

- **WHEN** `web_fetch` 的结果正文超过通用截断阈值，被替换成"头 + 尾 + 标记"
- **THEN** 标记里 SHALL 含本次抓取的网址（`refetch via web_fetch "<网址>"` 这样的可执行形态）；`web_fetch` 的输入参数没有 `path`，因此 SHALL NOT 依赖 `path` 来拼这个入口
