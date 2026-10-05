# model-gateway Specification

## ADDED Requirements

### Requirement: API 报错时要说明原因
模型端点返回 HTTP ≥ 400 时，交给上层（界面与模型）的错误文本 SHALL 含**服务端给出的原因** —— 响应体里的 `error.message`（或正文前若干字节，按原样带去）。SHALL NOT 只有一句 `API returned HTTP <状态码>`；401 那一支 SHALL NOT 把服务端原因整段丢掉换成一句固定话术。

**现状与改动点**（写进规范是为了让判据有对照）：`sidecar/src/model_gateway.cpp` 里 `http_code == 401` 与 `http_code >= 400` 两条分支现在把响应体**只写进 `sidecar.log`**（`LOG_ERR("API error body: " + preview)`），交给 `dispatch_done(...)` 的只有 `"Authentication failed — invalid API key"` / `"API returned HTTP <码>"`。服务端明明回了原因（例如"余额不足"、"模型名不存在"、"上下文超长"），模型与用户却只看得到一个状态码，无法据此判断该怎么办。

#### Scenario: 4xx 的错误文本带上服务端原因

- **WHEN** 端点返回 HTTP 400，正文是 `{"error":{"message":"insufficient balance"}}`
- **THEN** 交给上层的错误文本 SHALL 同时含状态码与 `insufficient balance`；把原因去掉（只留状态码）SHALL 让对应用例失败

#### Scenario: 401 也带上服务端原因

- **WHEN** 端点返回 HTTP 401，正文里带了原因
- **THEN** 错误文本 SHALL 在指明鉴权失败的同时带上那段原因，SHALL NOT 只有一句固定话术

#### Scenario: 读不出原因时不编

- **WHEN** 端点返回 4xx 但正文为空或不含可读原因
- **THEN** 错误文本 SHALL 只报状态码并注明"没有更多信息"，SHALL NOT 编一个原因
