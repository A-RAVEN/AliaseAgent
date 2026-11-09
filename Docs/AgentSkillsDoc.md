# Agent Skills 开放规范（本地事实源）

- **抓取时间**：2026-11-06（Asia/Hong_Kong）
- **来源**：<https://agentskills.io/specification.md>（开放规范全文）；<https://code.claude.com/docs/en/skills.md>（Claude Code 对规范的采用与扩展字段表）
- **维护**：与官方不一致时以官方为准并记录；引用本文件的结论必须能指回下面的原文。
- 本文第一节是**规范条文**（本仓库工件引用外部约束的唯一依据）；第二节是 Claude Code 的扩展事实（说明哪些字段**不是**规范的一部分）；第三节是**本项目推导**，不是规范条文。

## 一、Agent Skills 开放规范（agentskills.io）

### 目录结构

一个技能就是一个目录，最少只含一份 `SKILL.md`：

```
skill-name/
├── SKILL.md          # 必需：元数据 + 操作说明
├── scripts/          # 可选：可执行代码
├── references/       # 可选：按需加载的文档
├── assets/           # 可选：模板、图片、数据文件
└── ...               # 任何其它文件与目录
```

### `SKILL.md` 格式

文件必须是 YAML frontmatter（`---` 包裹）+ Markdown 正文。frontmatter 字段只有六个：

| 字段 | 必需 | 约束（规范原文口径） |
|---|---|---|
| `name` | 是 | 1–64 字符；仅小写字母、数字、连字符；不得以 `-` 开头或结尾；不得含连续 `--`；**必须与父目录名一致** |
| `description` | 是 | 1–1024 字符，非空；说明"做什么 + 何时用" |
| `license` | 否 | 许可证名或随技能附带的许可证文件名，建议简短 |
| `compatibility` | 否 | 若提供则 1–500 字符；声明环境要求（目标产品、系统依赖、网络访问等）；大多数技能不需要 |
| `metadata` | 否 | 字符串键 → 字符串值的映射，存规范之外的自定义属性；建议键名足够独特避免冲突 |
| `allowed-tools` | 否 | 空格分隔的预批准工具字符串；**实验性字段**，各客户端支持度不一 |

最小示例：

```yaml
---
name: skill-name
description: A description of what this skill does and when to use it.
---
```

### 正文与附属文件

- frontmatter 之后的 Markdown 正文**无格式限制**；规范建议主 `SKILL.md` 保持在 500 行以内，详细参考资料拆成单独文件。
- 正文内引用技能内其它文件用**相对技能根的路径**（例：`references/REFERENCE.md`、`scripts/extract.py`）；该段原文为面向技能作者的祈使句 "**Keep file references one level deep from `SKILL.md`.** Avoid deeply nested reference chains."——它约束的是技能写法，规范未定义客户端如何校验；本仓库工件对它按"作者指导句"处理（见 design D6，客户端不做深度校验）。
- 可选目录约定：`scripts/`（代理可执行的代码，语言支持由客户端决定）、`references/`（按需加载的文档，单文件保持聚焦）、`assets/`（模板、图片、数据文件）。

### 渐进加载（规范定义的三层）

1. **元数据**（规范标注约 100 token）：所有技能的 `name` + `description` 在启动时载入目录；
2. **指令**（规范建议 < 5000 token）：技能被激活时才载入 `SKILL.md` 正文；
3. **资源**（按需）：`scripts/`、`references/`、`assets/` 等文件只在真正用到时载入。

> 上节的 "~100 token / <5000 token / 500 行" 是规范给出的**建议值**，不是硬性校验限；硬限只有字段表里的 64 / 1024 / 500。

### 校验

规范提供 `skills-ref` 参考实现做校验（`skills-ref validate ./my-skill`），检查 frontmatter 有效性与命名约定。

## 二、Claude Code 的扩展（划清"什么不是规范"）

- Claude Code 在规范的六个字段**之外**另有一批自有 frontmatter 字段：`when_to_use`、`argument-hint`、`arguments`、`disable-model-invocation`、`user-invocable`、`disallowed-tools`、`model`、`effort`、`context`（=fork，子代理隔离执行）、`agent`、`background`、`hooks`、`paths`、`shell`。这些**不是规范的一部分**。
- 官方文档原文：往 claude.ai/Skills API 打包上传时，**只允许规范六字段**，出现额外字段直接报错拒收（报错样例：`Unexpected key(s) in SKILL.md frontmatter: argument-hint. Allowed properties are: allowed-tools, compatibility, description, license, metadata, name`）。
- Claude Code 把"自定义斜杠命令"合并进了技能：`.claude/commands/deploy.md` 与 `.claude/skills/deploy/SKILL.md` 都生成 `/deploy`，行为一致；即"用户以 `/名字` 显式触发技能"是官方形态之一。
- Claude Code 在目录列表里把 `description`（连同 `when_to_use`）**截断到 1,536 字符**以省上下文——这是 Claude Code 的上下文口径，不是规范要求。
- 加载侧的宽松行为（Claude Code 文档「Frontmatter reference」节原文）：**"All fields are optional. Only `description` is recommended"**、**"Claude Code ignores a field it doesn't recognize without reporting an error"**、**"Claude Code reads the frontmatter only when the opening `---` is the file's first line. Otherwise it treats the whole file, `---` markers included, as skill content"**（YAML 解析失败时技能仍加载、只是不设字段）。本 change 的加载侧口径（未知键忽略、首行恰 `---`）以这三句原文为据，字段**必填**要求则来自第一节规范本身（规范说 `name`/`description` Required，Claude Code 的"全可选"是它自己的放宽）。
- 技能名另有 Claude Code 的额外拒收规则（零宽字符、控制字符、`<` `>` 等），比规范的字符集限制更细，属产品自有防御。

## 三、本项目的适用口径（推导，非规范条文）

立项 `add-skill-mechanism` 时按本仓库已拍板的需求裁剪：

- 技能存放 = `~/.aliasagent/skills/<name>/SKILL.md`（全局安装，目录名换即生效；对应 Claude Code 的 "Personal" 层，本项目不做工作区层）。
- 采用规范的**目录结构、六字段 frontmatter、命名校验（含"与父目录名一致"）**；校验规则逐字段照抄第一节表。
- `load_skill` 工具对应规范的"激活时载入指令 + 按需载入资源"两层：一次调用返回 `SKILL.md` 正文，或以相对路径参数返回同一技能目录内的附属文件——**只允许解析后仍在技能目录内的相对路径**（防目录穿越）。
- 不采用：`allowed-tools` 的预批准语义（本产品零审批全权限，`CLAUDE.md` 立场）、Claude Code 全部扩展字段、`!` 动态命令注入、claude.ai 同步。`allowed-tools` 作为未知字段按规范加载方行为处理：识别到的六字段之外的键**忽略不报错**（宽松读取，与 Claude Code 行为一致，区别于上传路径的严拒）。
