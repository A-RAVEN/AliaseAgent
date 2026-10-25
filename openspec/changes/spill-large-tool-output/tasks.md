## 1. 先定红

- [ ] 1.1 `test/unit/spill_envelope_test.dart`：先写用例断言「超限时结果信封含 `total_bytes` / `omitted_bytes` / `head` / `tail` / `ref`，且 `omitted_bytes + 内联字节数 == total_bytes`」。判据：此时实现不存在，用例必须红；红的原因是缺少字段而不是语法错误。
- [ ] 1.2 `test/integration/read_spill_roundtrip_test.dart`：先写用例断言「对一份 200000 字节的 spill 引用取 `(offset: 50000, limit: 1000)`，返回内容与文件对应区间逐字节相同」。判据：此时 `read_spill` 不存在，用例必须红。
- [ ] 1.3 `sidecar/test/command_output_test.cpp`：先写 `[spill]` 用例断言「输出 200000 字节、头部第 3 行是 `error C2065`、尾部最后一行是 `Build FAILED.` ⇒ 两者都在给模型的那份里」。判据：跑 `sidecar_tests.exe "[spill]"` 必须红。

## 2. C++：落盘 + 切分 + 导出

- [ ] 2.1 新增 spill 写入：路径 `~/.aliasagent/spill/<会话 id>/<调用序号>.txt`，**原子写**（先 `*.tmp` 再 rename，失败清临时文件）。判据：`sidecar/test/spill_write_test.cpp` 断言写完的文件内容与输入逐字节相同；把 rename 换成直接写目标文件后，注入中途失败的那条用例必须红。
- [ ] 2.2 新增 UTF-8 安全切分：按码点边界取头 N 个字符与尾 N 个字符。判据：同文件断言切出的头尾各自是合法 UTF-8（可用 `MultiByteToWideChar` 严格模式验证），且中文输入不会被切成半个字。
- [ ] 2.3 `run_command` 改用新信封：完整输出先落盘，再按 `spill.inline_chars` 决定内联或头尾 + 引用；**删掉"只截尾部 + 临时文件"的旧逻辑**。判据：1.3 的用例转绿；另断言输出的信封里没有任何指向系统临时目录的路径。
- [ ] 2.4 导出 `read_spill(const char* request_json)`：成功 `{"ok":true,"text":…,"bytes_read":N,"total_bytes":M}`；失败三种（引用不存在 / 越界 / 目录不可读）可区分。判据：`sidecar/test/spill_write_test.cpp` 里三条负例各自断言错误文本不同。

## 3. Dart：工具与配置

- [ ] 3.1 `lib/services/sidecar_bridge.dart` 加 `readSpill(String requestJson)`；`lib/main.dart` 的 `_toolDefs` 加 `read_spill` 工具定义（`input_schema` 要 `ref`、可选 `offset`/`limit`）。判据：`test/integration/read_spill_roundtrip_test.dart` 转绿。
- [ ] 3.2 删掉 Dart 侧对 `run_command` 结果的二次截断（`maxLen = 2000` 那处）。判据：`test/unit/spill_envelope_test.dart` 里一条断言"超过 2000 字节但未超内联上限的输出原样到达模型"，删之前红、删之后绿。
- [ ] 3.3 配置项 `spill.inline_chars`（默认 1000）：读配置、缺省回落 1000。判据：`test/unit/spill_config_test.dart` 断言读到配置值、缺省用 1000；并断言 `Docs/user-guide/configuration.md` 里 grep 得到该键。

## 4. 写盘失败可见

- [ ] 4.1 输出不超过内联上限时写盘失败 ⇒ 直接内联全文，不报错。判据：`sidecar/test/spill_write_test.cpp` 注入不可写目录，断言 `ok:true` 且全文在内联里。
- [ ] 4.2 输出超过内联上限时写盘失败 ⇒ `ok:false` 且含写盘失败原因。判据：同文件注入不可写目录，断言 `ok:false` 且 `error` 里含目录与失败原因，且不返回任何内容片段。

## 5. 清理与保留

- [ ] 5.1 删除会话时连带删除 `~/.aliasagent/spill/<会话 id>/`。判据：`test/unit/spill_cleanup_test.dart` 断言删会话后该目录不存在、别的水话目录仍在。
- [ ] 5.2 文档写明"spill 随会话删除、不设时间上限"（不发明保留天数）。判据：`Docs/user-guide/tools-command.md` 里 grep 得到"随会话删除"。

## 6. 文档与收尾

- [ ] 6.1 `Docs/user-guide/tools-command.md` 补一节：长输出怎么交付、头尾各留多少、怎么用 `read_spill` 读回、写盘失败会看到什么。判据：`test/unit/user_docs_test.dart` 的「界面文案：」机制覆盖到新增的界面文案；文档里的 `read_spill` 示例参数名与工具定义一致（grep 得到）。
- [ ] 6.2 `Docs/user-guide/configuration.md` 补 `spill.inline_chars`（默认 1000、可配范围）。判据：配置键表里 grep 得到该键，且与 `lib` 里读取的键名完全一致。
- [ ] 6.3 `flutter analyze` 改动文件不新增问题。判据：与改动前数字相同，且本单位文件命中 0 条。
- [ ] 6.4 全量 `flutter test` 全绿。判据：`All tests passed!`，通过数不低于改动前。
- [ ] 6.5 C++ 两层验证：`cmake --build sidecar/build/windows --config Debug` + `sidecar_tests.exe`。判据：构建 exit 0；`[spill]` 相关的 tag 全绿；已知的联网 `Rate guard` 用例失败不算本变更引入（基线 1 条，见 `openspec/changes/archive/2026-10-25-add-image-input/tasks.md` 第 17 组）。
- [ ] 6.6 真机验收：手动或 live 用例跑一条会失败的真实构建命令，确认头部的第一条 error 出现在结果里，并用 `read_spill` 把中间段读回一次。判据：把两条输出（头部的 error、读回的中间段）贴进本条记录。
