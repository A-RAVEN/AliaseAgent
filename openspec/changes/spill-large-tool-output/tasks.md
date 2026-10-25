## 1. 先定红

- [ ] 1.1 `test/unit/spill_envelope_test.dart`：先写用例断言「超限时结果信封含 `total_bytes` / `omitted_bytes` / `head` / `tail` / `ref`，且 `omitted_bytes + 内联字节数 == total_bytes`」，**并额外断言 `total_bytes` 等于测试命令实际输出的字节数**（不只让信封内部自洽）。判据：实现不存在时该用例必须红；把 `total_bytes` 写小 100 后必须仍红。
- [ ] 1.2 `test/integration/read_spill_roundtrip_test.dart`：先写用例断言「对一份 200000 字节的 spill 引用取 `(offset: 50000, limit: 1000)`，返回内容与文件对应区间逐字节相同」。判据：`read_spill` 不存在时该用例必须红。
- [ ] 1.3 `sidecar/test/command_tool_test.cpp`（**已存在于 `sidecar/test/`，文件名就是它**）：在该文件里先写 `[spill]` 用例，断言「输出 200000 字节、**第 1 行**是 `error C2065`、最后一行是 `Build FAILED.` ⇒ 两者都在给模型的那份里」。判据：跑 `sidecar_tests.exe "[spill]"` 必须红。

## 2. C++：落盘 + 切分 + 导出

- [ ] 2.1 新增 spill 写入：路径 `~/.aliasagent/spill/<会话 id>/<调用序号>.txt`，**原子写**（先 `*.tmp` 再 rename，失败清临时文件）。判据：`sidecar/test/spill_write_test.cpp` 断言写完的文件与输入逐字节相同；把 rename 换成直接写目标文件后，注入中途失败的那条用例必须红。
- [ ] 2.2 **把新测试文件接进构建**：在 `sidecar/CMakeLists.txt` 的 `sidecar_tests` 显式源文件清单里加 `test/spill_write_test.cpp`（该清单不用 GLOB，不登记就编不进去）。判据：`sidecar_tests.exe --list-tests` 输出里能 grep 到 `[spill]` 标签的用例名。
- [ ] 2.3 新增 UTF-8 安全切分：按码点边界取头 `preview_chars` 个字符与尾 `preview_chars` 个字符。判据：同文件断言切出的头尾各自是合法 UTF-8（严格模式校验），中文输入不会被切成半个字。
- [ ] 2.4 `run_command` 改用新信封：完整输出先落盘，再按 `preview_chars × 2` 决定"全文内联"还是"头尾 + 引用"；**删掉"只截尾部 + 写系统临时文件"的旧逻辑**。判据：1.3 的用例转绿；另断言信封里没有任何指向系统临时目录的路径。
- [ ] 2.5 导出 `read_spill(const char* request_json)`：成功 `{"ok":true,"text":…,"bytes_read":N,"total_bytes":M}`；失败五种（不在 spill 根内 / 引用不存在 / 越界 / 切点多字节字符中间 / 根目录不可读）各有不同错误文本。判据：`spill_write_test.cpp` 里五条负例各自断言错误文本互不相同。
- [ ] 2.6 **`ref` 必须解析到 spill 根目录之内**：先 `canonical` 再比前缀，越界直接拒。判据：把 `~/.aliasagent/config.json` 当 `ref` 传入，必须 `ok:false` 且错误文本与"引用不存在"不同；把前缀检查注释掉后该用例必须红。

## 3. Dart：工具与配置

- [ ] 3.1 `lib/services/sidecar_bridge.dart` 加 `readSpill(String requestJson)`；`lib/main.dart` 的 `_toolDefs` 加 `read_spill` 工具定义；**并在 `_executeTool` 的 `switch (name)` 里加 `case 'read_spill'`**（不加就落到 `default` 返回 `Unknown tool`）。判据：`test/integration/read_spill_roundtrip_test.dart` 转绿；另加一条用例走**模型路径**（`ChatScreen` 发起一次带 `read_spill` 的 tool_use），断言拿到的不是 `Unknown tool`。
- [ ] 3.2 **确认新信封不会被通用截断掐掉引用段**：`lib/main.dart` 的 `_elideOversizedToolResult` 阈值是 `kToolResultElisionThreshold`（= `searchTextElisionThreshold` = 8000，见 `lib/services/search_text_assembly.dart`），而 `preview_chars` 可配。判据：`test/unit/spill_envelope_test.dart` 加一条「把 `preview_chars` 配到 4000（头尾合计 8000+）时，结果里的 `ref` 字段仍然完整可见」——把 `_elideOversizedToolResult` 对 run_command 的再取入口改坏后该条必须红。
- [ ] 3.3 配置项 `spill.preview_chars`（默认 1000）：读配置、缺省回落 1000，并在 `Docs/user-guide/configuration.md` 的配置键表里出现。判据：`test/unit/spill_config_test.dart` 断言读到配置值、缺省用 1000；并断言文档里 grep 得到该键。

## 4. 写盘失败可见

- [ ] 4.1 输出不超过预览阈值时写盘失败 ⇒ 直接内联全文，不报错。判据：`sidecar/test/spill_write_test.cpp` 注入不可写目录，断言 `ok:true` 且全文在内联里。
- [ ] 4.2 输出超过预览阈值时写盘失败 ⇒ `ok:false` 且含写盘失败原因。判据：同文件注入不可写目录，断言 `ok:false` 且 `error` 里含目录与失败原因，且不返回任何内容片段。

## 5. 清理与保留

- [ ] 5.1 删除会话时连带删除 `~/.aliasagent/spill/<会话 id>/`。判据：`test/unit/spill_cleanup_test.dart` 断言删会话后该目录不存在、别的会话目录仍在。
- [ ] 5.2 文档写明"spill 随会话删除、不设时间上限"（不发明保留天数）。判据：`Docs/user-guide/tools-command.md` 里 grep 得到"随会话删除"。

## 6. 旧规范与旧用例的处置（这一步不做，两份规范会同时成立）

- [ ] 6.1 新增 `specs/command-tool/spec.md` 的 **MODIFIED** delta：把现有「输出有界、只保留尾部、截断可见」那条改成"完整输出先落盘 + 头尾预览 + 引用"，并交代 `command_max_output_chars` / `command_output_full_chars` 两个配置键的去留。判据：`openspec validate spill-large-tool-output` 通过，且该 delta 的 Requirement 标题与主规范逐字一致（MODIFIED 要求标题匹配）。
- [ ] 6.2 改 `sidecar/test/command_tool_test.cpp` 里按旧行为写的三条断言：`HEAD-MARKER` 必须存在（不再"头部丢掉"）、`full_output_paths` 不再出现、未超限时也不写临时文件。判据：改完跑 `sidecar_tests.exe "[command_tool]"` 全绿；改之前必须红（红在"头部丢掉"那条）。
- [ ] 6.3 改 `Docs/user-guide/tools-command.md` 的旧表（四个配置键、`[output truncated; full output: <路径>]` 文案）。判据：该文件里 grep 不到旧文案，且能 grep 到"头尾预览"与"随会话删除"。

## 7. 文档与收尾

- [ ] 7.1 `Docs/user-guide/tools-command.md` 补一节：长输出怎么交付、头尾各留多少、怎么用 `read_spill` 读回、写盘失败会看到什么。判据：`test/unit/user_docs_test.dart` 的「界面文案：」机制覆盖到新增界面文案；文档里的 `read_spill` 参数名与工具定义一致（grep 得到）。
- [ ] 7.2 `Docs/user-guide/configuration.md` 补 `spill.preview_chars`（默认 1000）。判据：配置键表里 grep 得到该键，且与 `lib` 里读取的键名完全一致。
- [ ] 7.3 `flutter analyze` 改动文件不新增问题。判据：与改动前数字相同，且本轮文件命中 0 条。
- [ ] 7.4 全量 `flutter test` 全绿。判据：`All tests passed!`，通过数不低于改动前。
- [ ] 7.5 C++ 两层验证：`cmake --build sidecar/build/windows --config Debug` + `sidecar_tests.exe`。判据：构建 exit 0；`[spill]` 与 `[command_tool]` 两个 tag 全绿；已知的联网 `Rate guard` 用例失败不算本变更引入（基线 1 条，见归档 change `2026-10-25-add-image-input` 的 tasks 第 17 组）。
- [ ] 7.6 真机验收：`integration_test/live_spill_output_test.dart`（**新建，点名路径**）跑一条真实的失败构建命令，断言头部那条 error 出现在结果里，并用 `read_spill` 把中间段读回一次。判据：`flutter test --tags live --run-skipped integration_test/live_spill_output_test.dart -d windows` 通过，并把"头部 error"与"读回的中间段"两段输出贴进本条记录。
