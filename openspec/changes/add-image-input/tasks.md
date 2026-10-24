## 1. 开工基线（先把"现在是什么状态"记下来）

- [ ] 1.1 跑 `flutter test` 与 `ctest --test-dir sidecar/build/windows -C Debug`，把当前通过数、失败数、跳过数记在本文件末尾「15. 实测读数」里；判据：那一节里有这两组数字，且 `flutter test` 的数字与 `test/` 下用例总数对得上
- [ ] 1.2 跑 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 再只跑 `flutter test test/unit/sidecar_dll_freshness_test.dart`；判据：该用例绿（证明 DLL 同步链路通，后面新增导出才可能被 `flutter test` 用到）

## 2. 第三方单头文件

- [ ] 2.1 把 `stb_image.h`、`stb_image_write.h` vendor 到 `sidecar/third_party/stb/`，并在同目录写一份 `README.md` 记下：来源 URL（`https://raw.githubusercontent.com/nothings/stb/master/…`）、抓取日期、每个文件的 SHA-256；在 `sidecar/CMakeLists.txt` 里把该目录加进 `sidecar` 与 `sidecar_tests` 的 include 路径；判据：`sidecar/third_party/stb/README.md` 里两个 SHA-256 与 `Get-FileHash` 重算的结果一致；且第 3 节用例里 `stbi_info` 能编译并返回正确宽高（单独"构建通过"不算判据）

## 3. 图片格式与尺寸判定（纯逻辑，后面两条路径共用）

- [ ] 3.1 先建夹具：`sidecar/test/fixtures/images/` 下放 `tiny.png`、`tiny.jpg`、`tiny.gif` 三张 4×3 的真图；WebP 用一小段 base64 常量在用例里写成临时文件（仓库不放二进制）；判据：三个文件都在，用 PowerShell 读回各自宽高等于 4 与 3
- [ ] 3.2 新增 `sidecar/src/image_probe.h/.cpp`：`declared_media_type_by_extension()`、`sniff_media_type_by_magic()`、`image_dimensions()`（PNG/JPEG/GIF 走 `stbi_info`，WebP 手写 RIFF `VP8X`/`VP8 `/`VP8L` 三种块头）；判据：新建的 `sidecar/test/image_probe_test.cpp` 里四种格式各一条用例断言宽高为 4×3 且通过
- [ ] 3.3 反例用例：扩展名撒谎（JPEG 命名成 `.png`）、`.txt`、截断的 PNG 头；判据：`sidecar_tests.exe "[image-probe]"` 全绿，且把 `sniff_media_type_by_magic` 改成恒返回 PNG 时"扩展名撒谎"那条变红（改回后再跑一次确认绿）
- [ ] 3.4 接入 CMake：把 `src/image_probe.cpp` 与 `test/image_probe_test.cpp` 分别加进 `sidecar` 的 `SOURCES` 与 `sidecar_tests` 的源列表；判据：重新构建后 `sidecar_tests.exe --list-tests` 里出现 `[image-probe]` 用例，且既有用例一条不变红

## 4. read_image 工具（C++）

- [ ] 4.1 先在 `sidecar/test/tool_execution_test.cpp` 写 `[image]` 用例（实现之前先红）：成功、文件不存在、路径是目录、越界、超字节、超单边、扩展名撒谎七种；判据：此时跑 `sidecar_tests.exe "[image]"` 全红，且失败原因是 `read_image` 未实现
- [ ] 4.2 在 `sidecar/src/tools.cpp` 实现 `read_image(request_json)`：复用 `resolve()` / 工作区限制 / 存在性 / 是不是目录（目录文案沿用既有的 `Path is a directory, not a file: `），再做扩展名 → 魔数 → 尺寸 → 字节上限（33554432）与单边（8192），成功返回 `{"ok":true,"content":"<path>…</path>\n<type>image</type>\n<content>\n<media_type> image, <W>x<H> px, <bytes> bytes\n</content>","image":{…}}`；判据：4.1 的七条全绿
- [ ] 4.3 `sidecar/src/tools.h` 声明、`sidecar/include/sidecar_api.h` 与 `sidecar/src/sidecar_api.cpp` 导出 `read_image`；判据：`dumpbin /exports sidecar/build/windows/Debug/sidecar.dll`（或 `Get-Command` 等价手段）能查到 `read_image`
- [ ] 4.4 构建 + 同步 DLL：`cmake --build sidecar/build/windows --config Debug` 后立刻 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`；判据：仓库根 `sidecar.dll` 的 SHA-256 与 `sidecar/build/windows/Debug/sidecar.dll` 相同

## 5. 剪贴板取图（C++）

- [ ] 5.1 新增 `sidecar/src/clipboard_image.h/.cpp`：把"取剪贴板原始数据"抽成可注入的函数指针；实现 `dib_to_png_bytes()`（自下而上 BGRA + 行 padding → 自上而下 → `stbi_write_png_to_func`）；判据：新建的 `sidecar/test/clipboard_image_test.cpp` 用构造的 4×3 DIB 得到能被 `stbi_info` 读回 4×3 的 PNG 字节（实现之前这一条是红的）
- [ ] 5.2 实现 `read_clipboard_image(request_json)`：`{"dest_dir":…}` → 递归建目录 → 优先 `CF_PNG`（`RegisterClipboardFormatW("PNG")`）直接落盘，否则 `CF_DIBV5`/`CF_DIB` 走 5.1 → 文件名 `paste-<yyyyMMdd-HHmmss-SSS>-<序号>.png` → 返回路径与宽高字节数；判据：注入"有 PNG 数据 / 有 DIB 数据 / 什么都没有 / 目录不存在"四种假剪贴板各返回预期 JSON，空剪贴板时错误文本恰为 `clipboard has no image`
- [ ] 5.3 在 `sidecar/test/clipboard_image_test.cpp` 顶部写明这条测试**不碰真实剪贴板**（注入假数据），真实剪贴板由 13.4 覆盖；判据：该文件里有这句注释，且整套 `ctest` 跑完不改变用户剪贴板内容（跑前跑后各 `Get-Clipboard -Format Image` 一次比对）
- [ ] 5.4 `sidecar/include/sidecar_api.h` 与 `sidecar/src/sidecar_api.cpp` 导出 `read_clipboard_image`，并把它加进 `sidecar_tests` 的编译范围；判据：导出表里能查到该符号
- [ ] 5.5 构建 + 同步 DLL（同 4.4）；判据：仓库根 `sidecar.dll` 与构建产物 SHA-256 相同，且此时跑 `flutter test test/unit/sidecar_bridge_test.dart` 不再报 `Failed to lookup symbol`

## 6. Dart 桥接与配置键

- [ ] 6.1 `lib/services/sidecar_bridge.dart`：加 `readImage(String requestJson)` 与 `readClipboardImage(String requestJson)` 两个绑定（含 `ISidecar` 声明与测试用的 fake 实现）；判据：只跑 `flutter test test/unit/sidecar_bridge_test.dart` 全绿（不要跑全量 —— 此时其它用例还在用旧 fake）
- [ ] 6.2 `lib/models/agent_type_config.dart`：加 `inputModalities`（JSON 键 `input_modalities`，缺省/非法一律 `["text"]`，去重，`toJson` 必写）；判据：在既有 `test/unit/agent_registry_test.dart` 的 `AgentTypeConfig` 分组里新增四条用例（缺省、合法、非法回落并打一行日志、`toJson` 回写），并让 `test/unit/agent_type_config_command_test.dart` 仍绿
- [ ] 6.3 `lib/ui/setup_dialog.dart` 生成的默认配置带上 `input_modalities`；判据：既有 `test/widget/setup_dialog_test.dart` 里断言生成的 JSON 含该键（该文件已存在，12 处引用 `SetupDialog`）

## 7. 数据库与消息模型

- [ ] 7.1 新建 `test/unit/message_attachments_test.dart`（三条：`NULL` / 合法 / 坏 JSON），先写红；再改 `lib/models/message.dart` 加 `attachments`（`List<String>`，只装路径），`fromRow` 解析该列，坏 JSON 按空列表并打一行日志；判据：三条用例绿
- [ ] 7.2 `lib/services/database_service.dart`：`_schemaVersion` 6 → 7，`_onCreate` 的 `CREATE TABLE messages` 带 `attachments TEXT`，`_onUpgrade` 加 `if (oldV <= 6) ALTER TABLE messages ADD COLUMN attachments TEXT`；判据：在既有 `test/integration/schema_migration_test.dart` 里加一组"用 v6 库升级到 v7 后旧消息仍全部存在且 attachments 为空"，该用例绿
- [ ] 7.3 `lib/services/message_repository.dart` 的 `insert` 支持写 `attachments`；判据：`test/integration` 里一条带图消息存取回环用例绿，且直接读库确认该列是 `[{"path":"…"}]` 形状（只有一个键）

## 8. 输入区贴图

- [ ] 8.1 改"空内容不提交"守卫：`lib/ui/input_bar.dart` 的 `_submit` 与 `lib/main.dart` 的 `_submitInput` 都改成"没有文字**且没有待发图**才返回"；判据：`test/widget/chat_area_test.dart` 的 `empty message is not sent` 与 `test/widget/keyboard_input_test.dart` 的空/全空格两条同步改成"无图不提交、有图提交"后全绿；把守卫改回只看文字时，"有图能提交"那条变红
- [ ] 8.2 `lib/ui/input_bar.dart`：加「粘贴图片」按钮 + 待发缩略图条（可移除）；判据：新建 `test/widget/input_bar_paste_test.dart`——点按钮且 fake sidecar 返回一张图后出现缩略图；点移除后缩略图消失
- [ ] 8.3 `Ctrl+V` 接管：有图贴图并 `handled`，无图退回文本插入（替换选区）；判据：`test/widget/input_bar_paste_test.dart` 两条——有图时输入框文本不变且出现缩略图；无图时输入框文本变成剪贴板文本
- [ ] 8.4 空剪贴板提示：按钮读到 `ok:false` 时显示可被 `find.text` 找到的提示；判据：删掉提示分支后对应那一条变红
- [ ] 8.5 发出去之后清空待发缩略图；判据：`test/widget/input_bar_paste_test.dart` 里断言发送后缩略图数量为 0

## 9. 请求拼装

- [ ] 9.1 `lib/main.dart` 的 `_buildApiMessages`：用户消息带附件时产出 `[text?, 说明文本, image…]`，空文本不发；判据：请求体断言用例——只有图片的消息不含空 `text` 块，带文字带图的消息块顺序为 text → 说明 → image
- [ ] 9.2 缺失文件 → `[图片已丢失：<path>]` 文本块，其余照发；判据：把该分支注释掉后对应用例变红
- [ ] 9.3 能力门：`input_modalities` 不含 `image` 时每个图位替换成 `[图片未发送：…]` 文本块，请求里零 `image` 块；判据：默认配置下断言"零 image 块"，配了 `["text","image"]` 后断言"有 image 块"
- [ ] 9.4 工具结果数组化：`_executeTool` 的结果带 `image` 时 `tool_result.content` 变成 `[{text},{image}]`；`_elideOversizedToolResult` 只截断文本部分、图片块原样保留；判据：一条超长文本 + 一张图的工具结果，截断后数组仍是两块且第二块是 image
- [ ] 9.5 `_executeTool` 增加 `read_image` 分发，并在调用前查 `input_modalities`；不含 `image` 时直接返回错误、不调 sidecar；判据：用记录调用次数的 fake sidecar 断言"未声明图片时 `readImage` 调用次数为 0"，已声明时为 1
- [ ] 9.6 工具定义：`_toolDefs` 增加 `read_image`（`input_schema` 只要求 `path`）；判据：`test/integration/startup_tool_readiness_test.dart` 里两处精确计数由 8 改成 9、由 10 改成 11（仍是不放松的等值断言），并新增 `expect(names, contains('read_image'))`

## 10. 预算与压缩

- [ ] 10.1 `lib/services/context_estimator.dart` 与 `lib/models/context_breakdown.dart`：每条消息的估算加 `1024 × 图片张数`；判据：`test/unit/context_estimator_test.dart` 新增"同样消息带一张图比不带图恰多 1024"，`test/integration` 里分项之和等于总数
- [ ] 10.2 请求级图片检查（五条，见 `specs/image-budget/spec.md`）：单张 ≤ 33554432 字节、单边 ≤ 8192、≥15 张时单边 ≤ 4096、base64 负载 ≤ 50331648 字节；超出按"最旧优先"替换成可见省略文本；判据：四条用例——40 MiB 单张、9000×100、两张各 24 MiB（原始 48 MiB 未超 64 MiB 但 base64 超 48 MiB）、15 张含一张 5000×100；每条都断言被省略的是最旧/越界那张，且省略文本里带上限数字
- [ ] 10.3 压缩摘要省略说明：被折叠段含图时摘要末尾追加「本段另有 N 张图片…」；判据：`test/unit` 两条用例（有图/无图）分别断言出现与不出现
- [ ] 10.4 `tool_calls` 里的 `image` 只存 `path`；判据：`test/unit` 断言持久化后的 `image` 对象键集合恰为 `{path}`（不含 `width`/`height`/`media_type`/`bytes`）

## 11. 界面显示

- [ ] 11.1 `lib/ui/message_bubble.dart`：气泡内渲染附件图片，显式 `BoxConstraints(maxWidth: 600, maxHeight: 400)`，文件缺失显示 `[图片已丢失：<path>]`，模型未声明图片时多一行提示；判据：新建 `test/widget/message_bubble_image_test.dart` 四条（显示图与尺寸上界、缺失回落、未声明提示、不抛异常）全绿；把 `errorBuilder` 去掉后"缺失"那条变红
- [ ] 11.2 `lib/models/tool_call_activity.dart`：加结构化 `image` 字段，**只装 `path`**（写进 `toJson`、`fromJson` 可选读）；判据：`test/unit` 持久化回环用例断言 `tool_calls` JSON 的 `image` 只有 `path` 一个键
- [ ] 11.3 `lib/ui/tool_call_card.dart`：`read_image` 卡片标题只显示路径（沿用 `_cardTitle()`）；收起状态显示缩略图 + 一行 `image/png · 800×600 · 12345 字节`；展开状态先显示文字信封再显示大图；图与缩略图都用 `maxWidth: 600 / maxHeight: 400`；判据：新建 `test/widget/tool_call_card_image_test.dart` 五条（收起有图、展开有信封、重载有图、持久化无元数据、尺寸上界）全绿
- [ ] 11.4 请求体不夹带工具活动里的 `image` 字段；判据：`test/unit` 里断言 `tool_use.input` 只有模型给的参数，删掉"只取四键"那段后变红

## 12. 文档（同一 change 内必须同步）

- [ ] 12.1 `Docs/user-guide/chat.md`：写清「粘贴图片」按钮与 `Ctrl+V` 的两条分支、图片在气泡里怎么显示、模型没声明图片输入时的提示、"历史只记路径"这条限制；判据：两句界面文案用「界面文案：」前缀写进该文件的正文（落进既有 `test/unit/user_docs_test.dart` 的 ⑥ 检查范围），且 `粘贴图片` 与 `模型未声明图片输入，本次没有发送图片` 能在 `lib/ui/` 下 grep 到同名字符串
- [ ] 12.2 `Docs/user-guide/tools-file.md`：新增 `read_image` 一节（参数、返回的两块、失败文案、四条上限）；判据：该文件里 `read_image` 出现≥1 次，且 `Not an image` / `Image type mismatch` / `Image too large` / `Image dimension too large` 四条文案能在 `sidecar/src/tools.cpp` grep 到；把任一文案改掉而不同步就红（落进 `test/unit/user_docs_test.dart` 的"工具已注册但文档没提"检查）
- [ ] 12.3 `Docs/user-guide/configuration.md`：配置键表新增 `input_modalities`（默认 `["text"]`、可取值、非法值回落）；判据：该文件的 ```json 围栏块里出现 `input_modalities`，且正文写明回落值 `["text"]`；`test/unit/user_docs_test.dart` 的"代码解析了这些配置键但文档没写成配置键"检查对该键为绿
- [ ] 12.4 `README.md` 功能文档索引里补上 `chat.md` / `tools-file.md` / `configuration.md` 三处链接；判据：`README.md` 里三处链接路径都能 resolve 到真实文件（用 `Test-Path` 逐条核）
- [ ] 12.5 文档与代码一致性总验收：把 12.1–12.4 涉及的五处文案各改一个字（不同步文档）跑 `flutter test test/unit/user_docs_test.dart`；判据：至少一条变红，然后改回并确认变绿

## 13. live 实测（真实模型 + 真实剪贴板）

- [ ] 13.1 新建 `integration_test/live_image_paste_test.dart`：把一张纯色 PNG 放上真实剪贴板、点「粘贴图片」、发送"这张图是什么颜色"，断言回答含该颜色词，并在断言前打印本轮实际工具调用与 `usage.input_tokens`；判据：`flutter test --tags live --run-skipped integration_test/live_image_paste_test.dart -d windows` 通过，且读 `test/live_visual/<name>.png` 能看到发出的图与回答
- [ ] 13.2 `integration_test/live_file_tools_test.dart`（或新文件）加一条 `read_image` live：让模型读一张纯色 PNG 并回答颜色；判据：同上，且工具卡片截图里能看到缩略图
- [ ] 13.3 负例 live：把 `input_modalities` 临时移掉再贴图，断言请求里没有 `image` 块且界面出现提示；判据：该用例在去掉能力门之后变红（跑一次证明后恢复配置）
- [ ] 13.4 真实剪贴板（PowerShell `System.Windows.Forms.Clipboard::SetImage` 放图，再点按钮）覆盖 5.3 声明不做的部分；判据：落盘文件的宽高等于放进去那张图的宽高，且该断言在把 `read_clipboard_image` 改成直接返回 `ok:false` 时变红

## 14. 收尾实测

- [ ] 14.1 五层验证逐层跑并贴读数：`flutter analyze`（改动文件不新增问题）、`scripts\sync_sidecar_dll.ps1` + `flutter test`、`flutter test --tags live`、`cmake --build` + `ctest`、`test/smoke/run_all.sh`（Windows 用 `run.bat`）
- [ ] 14.2 变异验证记账：对第 3、4、5、8、9、10、11 节的每条关键守卫各做一次"故意改坏 → 对应用例变红 → 改回"，结果写进本文件末尾
- [ ] 14.3 把 `input_modalities: ["text","image"]` 写进 `~/.aliasagent/config.json` 的 `agent_types.general`，改前改后各读一次确认其余键未动；判据：文件里该键存在且值正确，并用 13.1 那条 live 跑通

## 15. 实测读数（每条做完立刻写，不拖到轮末）

- [ ] 15.1 `flutter test` 开工基线 / 收尾读数
- [ ] 15.2 `ctest` 开工基线 / 收尾读数
- [ ] 15.3 `flutter analyze` 开工基线 / 收尾读数
- [ ] 15.4 变异验证记录（哪条守卫、改坏后哪条用例红、改回了没有）
