## 1. C++ 工具实现

- [ ] 1.1 Enhance `read_file_impl` in `tools.cpp`: add line number prefix (cat -n format), `offset`/`limit` parameters with boundary handling, 2000-line default cap with truncation notice
- [ ] 1.2 Implement `write_file_impl(path, content)` in `tools.cpp`: resolve path within workspace, create parent dirs, write content, return `bytes_written` + `created` flag
- [ ] 1.3 Implement file metadata detection: scan first 50 lines for dominant indent style (tabs/spaces/width) and line ending (CRLF/LF)
- [ ] 1.4 Implement `edit_file_impl(path, old_text, new_text, replace_all)` in `tools.cpp`: empty old_text guard → three-tier matching (exact → normalized → diagnostic)；normalized multi-match returns line numbers
- [ ] 1.5 Implement whitespace normalization: CRLF→LF, detected indent→spaces, strip trailing whitespace; map normalized match position back to original text
- [ ] 1.6 Implement diagnostic error: sliding window Levenshtein distance to find closest match, generate difference list
- [ ] 1.7 Non-text / large file protection: reject edit_file if NUL in first 512 bytes or >1MB

## 2. FFI 导出

- [ ] 2.1 Add `write_file` and `edit_file` to `sidecar_api.h` extern "C" declarations
- [ ] 2.2 Add FFI wrapper functions in `sidecar_api.cpp`

## 3. Dart 集成

- [ ] 3.1 Add `writeFile(String json)` and `editFile(String json)` to `ISidecar` abstract interface；implement in `SidecarBridge` (sync FFI, no isolate needed)；implement in `FakeSidecar` (test double)
- [ ] 3.2 Update `read_file` tool definition in `main.dart`: add offset/limit parameters to input_schema
- [ ] 3.3 Add `write_file` and `edit_file` tool definitions in `main.dart` (unconditional)
- [ ] 3.4 Add `_executeTool` cases for write_file and edit_file; update read_file case to pass offset/limit via JSON

## 4. 测试

- [ ] 4.1 C++ unit tests: write_file create/overwrite/created-flag/path-restriction; edit_file exact/normalized/diagnostic/multiple-match-with-linenums/empty-oldtext-rejected/binary-reject/large-file-reject; read_file offset/limit edge cases (offset<=0, offset>lines, offset+limit>lines)
- [ ] 4.2 Update existing tests for read_file format change: line numbers in content break exact content assertions
- [ ] 4.3 Dart FFI tests: write_file + edit_file via real DLL
- [ ] 4.4 Full test suite: `flutter test` + sidecar_tests 全部通过

## 5. 验证

- [ ] 5.1 Live test: AI 在对话中使用 edit_file 修改一个文件，验证编辑正确
