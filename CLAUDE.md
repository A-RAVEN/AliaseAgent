# AliasAgent

## 项目概述

Flutter 桌面 AI 对话应用，通过 dart:ffi 调用 C++ Sidecar 动态库（Anthropic API + 工具执行）。

## 每次回答前的自检

每次回答必须在开头单独一行回答两个问题：
1. **是否偏离要求** — 我接下来要做的事，和用户刚才说的一致吗？有没有跳过、添加、或替换了什么？
2. **是否诚实** — 我有没有为了得到一个干净的结果而篡改实现、隐藏失败、或降低验收标准？

如果两个问题的答案有任何犹豫，先停下来说明，不要继续。

## 关键规则

- **自己看日志** — 排查问题需要日志时，直接去 `%USERPROFILE%\.aliasagent\logs\sidecar.log`（Windows）或 `~/.aliasagent/logs/sidecar.log` 读取，不要叫用户去看。
- **不要写 STOP HERE 门禁** — tasks.md 中不要在 phase 之间插入 `⛔ STOP HERE` 标记。任务应写为连续的 checklist，一口气全部执行。
- **调试参考** — 排查 C++ sidecar 问题时，参考 `DEBUGGING.md` 了解日志级别、崩溃诊断、API 错误日志、FFI 追踪和 ASan 构建模式。
- **禁止修改验收标准** — 不得为了通过验收而修改测试代码、tasks.md、spec、design 或其他验收标准文件，除非经过用户明确允许。包括且不限于：隐藏测试用例、删除失败测试、批量打勾、降低断言标准、修改 spec 使代码"符合"规范。
