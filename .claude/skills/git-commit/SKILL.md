---
name: git-commit
description: 自动分析当前修改，生成规范的中文 commit message 并提交。当用户说"提交"、"commit"、"git提交"时使用。
license: MIT
metadata:
  author: happy
  version: "1.0"
---

自动提交 Git 修改。检查当前变更，生成描述性的中文 commit message，并执行提交。

**Input**: 无需参数。自动检测当前工作区的所有修改。

**Steps**

1. **检查状态**

   并行执行以下命令了解当前仓库状态：
   ```bash
   git status
   git diff --stat
   git diff --cached --stat
   git log --oneline -5
   ```

2. **分析变更范围**

   如果暂存区为空但有未暂存修改，将所有修改的文件 `git add` 加入暂存区。

   分析 `git diff --stat` 和 `git diff --cached --stat` 的输出，判断本次修改的：
   - **范围**：哪些模块/目录被修改
   - **性质**：新增功能、bug 修复、重构、文档、配置等
   - **影响面**：几个文件、涉及哪些子系统

   注意：不提交包含敏感信息的文件（`.env`、`credentials.json` 等）。

3. **生成 Commit Message**

   根据分析结果生成中文 commit message，遵循以下格式：

   ```
   <类型>: <简短描述>

   - <具体改动点 1>
   - <具体改动点 2>
   - <具体改动点 3>

   Co-Authored-By: Claude <noreply@anthropic.com>
   Co-Authored-By: Happy <yesreply@happy.engineering>
   ```

   **类型**选项：
   - `feat` - 新功能
   - `fix` - bug 修复
   - `refactor` - 重构（不改变功能）
   - `docs` - 文档
   - `chore` - 构建/工具/依赖
   - `style` - 代码格式
   - `test` - 测试

   描述部分控制在 50 字符以内。具体改动点每条一行，说明做了什么、为什么，而非罗列文件名。

4. **展示生成的 commit message 给用户确认**

   将生成的 commit message 展示给用户，询问是否确认提交。

5. **执行提交**

   ```bash
   git commit -m "$(cat <<'EOF'
   <commit message>
   EOF
   )"
   ```

6. **验证并报告**

   ```bash
   git status
   git log --oneline -1
   ```

   向用户报告：提交 hash、分支名、简要摘要。

**示例 Commit Message**

```
feat: Phase 4 FFI Bridge — Dart 侧函数签名与回调 marshaling

- 新增 SidecarBridge 类：封装动态库加载、FFI 函数绑定
- 定义 NativeCallable.listener 回调机制，保证跨线程安全
- 新增 Checkpoint 4 验收测试，A/B/C/D 全部通过
- 对齐 Dart typedef 与 C 头文件 send_message/set_workspace 签名

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
```

**Guardrails**
- 先分析后提交，不要盲目 git add -A
- 检查是否有敏感文件（.env 等），如有则警告用户
- commit message 必须用中文，便于团队阅读
- 展示 message 让用户确认后再执行
- 不要使用 --no-verify 跳过 hooks
- 不要 amend 已有提交，始终创建新提交