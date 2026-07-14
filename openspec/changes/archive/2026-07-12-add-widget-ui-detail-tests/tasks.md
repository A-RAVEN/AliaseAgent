## 1. Markdown Render Tests

- [x] 1.1 `test/widget/markdown_render_test.dart`：创建测试文件，测试 fenced code block（带语言标识和无语言标识）渲染为 monospace 字体 + 背景色区别于普通文本
- [x] 1.2 测试 inline code（反引号包围）渲染为 monospace 且与周围文字区分
- [x] 1.3 测试 bold（**text**）渲染为 FontWeight.bold
- [x] 1.4 测试 italic（*text*）渲染为斜体
- [x] 1.5 测试 Markdown link [text](url) 渲染为可点击/彩色文字
- [x] 1.6 测试无序列表（- item）渲染为 bulleted list

## 2. Keyboard Input Tests

- [x] 2.1 `test/widget/keyboard_input_test.dart`：创建测试文件，测试 Enter 提交非空消息 → onSendMessage 回调 + 输入框清空
- [x] 2.2 测试 Enter 在空/纯空白输入时 → 不发送消息
- [x] 2.3 测试 Shift+Enter 插入换行 → 文本变为多行，不发送消息
- [x] 2.4 测试多次 Shift+Enter → 输入包含多个换行符

## 3. Auto-Scroll Tests

- [x] 3.1 `test/widget/auto_scroll_test.dart`：创建测试文件，测试新用户消息添加后滚动到底部
- [x] 3.2 测试 streaming text 更新时滚动保持在底部
- [x] 3.3 测试 streaming 完成后滚动到底部（最终 assistant 消息追加）

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | Markdown 测试可运行 | `flutter test test/widget/markdown_render_test.dart` 全部通过 |
| B | 键盘测试可运行 | `flutter test test/widget/keyboard_input_test.dart` 全部通过 |
| C | 滚动测试可运行 | `flutter test test/widget/auto_scroll_test.dart` 全部通过 |
| D | 无副作用 | 未修改任何 `lib/` 下的生产代码 |
