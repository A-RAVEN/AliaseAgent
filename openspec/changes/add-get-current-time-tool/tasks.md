## 1. Dart Implementation

- [x] 1.1 Add `get_current_time` to `_toolDefs` in `lib/main.dart`: name, description, empty input_schema
- [x] 1.2 Add `case 'get_current_time'` to `_executeTool` in `lib/main.dart`: build JSON with `datetime`, `date`, `time`, `timezone` fields, AND set `content` to the full datetime string so AI receives usable output
- [x] 1.3 No FFI, no C++ changes needed

## 2. Verification

- [x] 2.1 Build and launch app: `run.bat`
- [ ] 2.2 Ask AI "今天是什么日期" — verify it returns correct date without "未来" disclaimer
