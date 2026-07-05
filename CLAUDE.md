# AliasAgent

## 项目概述

Flutter 桌面 AI 对话应用，通过 dart:ffi 调用 C++ Sidecar 动态库（Anthropic API + 工具执行）。

## 关键规则

- **自己看日志** — 排查问题需要日志时，直接去 `%USERPROFILE%\.aliasagent\logs\sidecar.log`（Windows）或 `~/.aliasagent/logs/sidecar.log` 读取，不要叫用户去看。
- **尊重 STOP HERE 门禁** — tasks.md 中每两个 phase 之间有 `⛔ STOP HERE` 标记，完成一个 phase 后必须停下来，等用户明确说 "execute phase N" 才能继续。
