## ADDED Requirements

### Requirement: 首启默认包含子 Agent 工具且既有模板选择不被覆盖

当前基础工具清单 SHALL 包含 `spawn_subagent`，新首启配置 SHALL 使用该当前清单；旧版两项首启默认清单仍 SHALL 按既有可见迁移规则升级到当前清单。其它既有模板 SHALL NOT 因本 change 被自动添加 `spawn_subagent`，包括工具清单恰好等于上一版完整基础工具默认形状的模板。

上一版十项默认形状与“用户从当前清单主动移除 `spawn_subagent`”在磁盘上相同，系统 SHALL NOT 仅凭该形状推断用户希望自动升级。用户 SHALL 能在模板编辑器中显式添加或移除该工具；保存并再次加载后 SHALL 保持用户选择，已运行实例继续遵循创建时快照。任何迁移 SHALL NOT 静默删除未知工具、修改 provider 或模型字段，也 SHALL NOT 在提示或日志中暴露 provider 密钥。

#### Scenario: 既有十项模板不自动添加

- **WHEN** 读取到工具清单恰好等于上一版完整基础工具默认形状的既有模板
- **THEN** 加载后清单保持不含 `spawn_subagent`，使用该模板的 Agent 请求也不含其定义，其它配置段不变

#### Scenario: 用户删除后再次加载仍保持删除

- **WHEN** 用户从包含当前基础工具的模板中显式移除 `spawn_subagent`，保存并重新加载配置
- **THEN** 清单仍不含该工具，不因它与上一版默认形状相同而被自动加回

#### Scenario: 用户显式添加后新实例生效

- **WHEN** 用户在模板编辑器中添加 `spawn_subagent` 并保存，随后创建新的 Agent
- **THEN** 完整配置写回后包含该工具，新实例的模型请求包含其定义，已运行实例不热更新

#### Scenario: 旧两项首启清单仍迁移

- **WHEN** 读取到仅含 `read_file` 与 `list_dir` 的旧首启默认清单
- **THEN** 既有可见迁移升级到包含 `spawn_subagent` 的当前基础清单，未知工具和自定义清单仍按原规则处理
