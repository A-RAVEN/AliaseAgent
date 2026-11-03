## ADDED Requirements

### Requirement: 按上下文读取当前工作区

系统 SHALL 提供 `get_workspace(const char* handle)` 只读接口，返回调用时该上下文实际保存的工作区。成功结果 SHALL 为 `{"ok":true,"workspace":"..."}`；空工作区 SHALL 以空字符串如实返回，不得替换为应用主目录或其它上下文的工作区。

未知、已销毁或正在销毁的句柄 SHALL 返回 `ok:false`、`code:"unknown_context"` 和错误文本，不得隐式创建上下文。该接口 SHALL NOT 修改工作区、文件版本表、spill 序号、模型请求或浏览器状态；返回的动态字符串 SHALL 遵守既有调用线程结果缓冲规则。

#### Scenario: 读取各上下文自己的工作区

- **WHEN** 上下文甲与乙分别设置为不同工作区，随后分别调用 `get_workspace`
- **THEN** 两次结果分别等于甲与乙的当前工作区，第二次读取不覆盖第一次的业务值

#### Scenario: 未知句柄不隐式创建

- **WHEN** 对从未创建或已经销毁的句柄调用 `get_workspace`
- **THEN** 返回 `ok:false` 和 `unknown_context`，随后用同名 `create_context` 仍得到全新上下文

#### Scenario: 查询不改变上下文状态

- **WHEN** 一个上下文已有工作区、文件读取记录和 spill 序号，调用 `get_workspace` 后继续执行原有操作
- **THEN** 工作区、文件版本记录和后续 spill 序号与未调用查询时一致
