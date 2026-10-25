## ADDED Requirements

### Requirement: read_spill via FFI

动态库 SHALL 导出 `read_spill(const char* request_json)`，`request_json` 形如 `{"ref":"<spill 引用>","offset":0,"limit":4096}`，返回以 NUL 结尾的 JSON 字符串。

- 成功：`{"ok":true,"text":"<该区间原文>","bytes_read":N,"total_bytes":M}`；
- 失败：`{"ok":false,"error":"<原因>"}`，与其它工具失败形状一致。

失败的三种情形 SHALL 可区分：引用不存在、偏移/长度越界、spill 根目录不可读。

#### Scenario: 符号解析并返回区间
- **WHEN** Dart 用一份合法引用与合法区间调用导出的 `read_spill`
- **THEN** 返回的 JSON SHALL 满足 `ok == true`，且 `text` 与 spill 文件对应区间逐字节相同

#### Scenario: 越界报错
- **WHEN** `offset + limit` 超过该引用的总字节数
- **THEN** 返回 SHALL 是 `ok:false`，`error` 里 SHALL 说明是越界，而不是静默返回能读到的部分
