## MODIFIED Requirements

### Requirement: Search tools registration

The `glob_file` and `grep_file` tools SHALL be registered independently of search-provider configuration. They SHALL appear for an Agent when that Agent's resolved configuration includes them, alongside the other file tools allowed by that configuration; they SHALL NOT be sent to an Agent whose resolved configuration excludes them. Their descriptions SHALL state the sandbox scope (workspace-relative paths), the glob syntax, and the result limits.

#### Scenario: 两个工具与搜索配置无关但受模板约束
- **WHEN** 界面把工具清单交给模型（无论搜索后端配没配），且 Agent 的实例生效配置包含 `glob_file` 与 `grep_file`
- **THEN** 清单里 SHALL 同时含 `glob_file` 与 `grep_file`；把搜索配置整个去掉 SHALL NOT 让它们消失

#### Scenario: 模板未允许的工具不出现
- **WHEN** 一个 Agent 的实例生效配置不包含 `glob_file` 或 `grep_file`
- **THEN** 未包含的工具 SHALL NOT 出现在该 Agent 的请求工具定义里，不影响其它允许这些工具的 Agent
