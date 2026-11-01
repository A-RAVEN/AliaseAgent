## ADDED Requirements

### Requirement: 每份上下文独立持有执行状态

系统 SHALL 提供 `create_context(const char* name)` 与 `dispose_context(const char* handle)`。句柄 SHALL 是原始、区分大小写的不透明字符串，SHALL NOT 假设它等于会话 id。

`create_context` SHALL 返回 JSON：成功为 `{"ok":true,"handle":"<原名>","created":true|false}`；空名字为 `{"ok":false,"code":"empty_context","error":"..."}`；`no-session` 或 `_it_` 前缀为 `reserved_context`；同名上下文正在销毁时为 `context_disposing`。`dispose_context` SHALL 返回 JSON 且幂等。

工作区根、文件版本表、spill 调用序号、模型网关、浏览器会话 SHALL 每份上下文各持一份。`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` SHALL 保持机器/应用级接口，不要求上下文句柄。

#### Scenario: 创建结果包含句柄与是否新建

- **WHEN** 首次用 `agent-7` 创建上下文，随后再次用同名创建
- **THEN** 两次返回的 `handle` SHALL 都是 `agent-7`，第一次 `created` 为真、第二次为假，第二次 SHALL 保留第一次的状态

#### Scenario: 空名字、保留名与销毁中的同名创建被拒

- **WHEN** 用空字符串、`no-session`、`_it_x` 创建，或在一个同名上下文尚未销毁完成时再次创建
- **THEN** 分别返回 `empty_context` / `reserved_context` / `reserved_context` / `context_disposing`，SHALL NOT 建出新上下文

#### Scenario: 句柄不要求等于会话 id

- **WHEN** 用不与任何会话 id 相同的名字创建上下文并调用工具
- **THEN** 调用 SHALL 成功，名字 SHALL NOT 被当作会话 id 查询

### Requirement: 结果返回按调用线程隔离

凡返回**动态构造字符串**的导出函数（含 create/dispose/cancel）SHALL 使用调用线程自己的结果缓冲；`ping` 等字符串字面量可继续使用静态存储。不同 OS 线程即使使用**同一个上下文**并发调用，也 SHALL NOT 覆盖彼此的返回字符串。返回指针只在同一线程下一次调用前有效，Dart SHALL 在返回后立即复制，不得保存指针备用。

#### Scenario: 同上下文两个线程同时读不同文件

- **WHEN** 两个 OS 线程用同一句柄分别读文件 A 与文件 B
- **THEN** 两边各自复制到的内容 SHALL 分别等于 A 与 B；把线程本地缓冲改回每上下文一份或进程级一份时，该场景 SHALL 能检出覆盖

### Requirement: 未知句柄必须报错，不许隐式创建

除幂等的 `dispose_context` 外，用没有登记过或已销毁的句柄调用上下文接口时，系统 SHALL NOT 隐式创建。返回 JSON 的接口 SHALL 给出 `{"ok":false,"code":"unknown_context","error":"..."}`；`set_workspace` SHALL 返回纯文本 `unknown_context: <handle>` 而不是成功空串；`send_message` SHALL 返回负数并通过 `on_done` 给出 `unknown_context` 错误；`cancel_request` SHALL 返回同样的 JSON 错误。机器级四个接口不适用本条。

#### Scenario: 没建就调用

- **WHEN** 用 `never-created` 这个从未登记过的名字调 `read_file`
- **THEN** 返回 SHALL 是 `ok:false`、`code` SHALL 等于 `unknown_context`，且随后用同一个名字调 `create_context` 得到的 SHALL 是一份全新上下文（结果缓冲里没有上一次调用的残留）

#### Scenario: 销了之后再用同一个句柄

- **WHEN** 建一个上下文、调一次工具、`dispose_context` 掉它，然后用同一个句柄再调一次工具
- **THEN** 返回 SHALL 是 `ok:false` 且 `code` SHALL 等于 `unknown_context`

#### Scenario: send_message 的未知句柄不进入队列

- **WHEN** 用未登记句柄调用 `send_message`
- **THEN** 返回值 SHALL 为负，`on_done` SHALL 收到 `unknown_context`，且 SHALL NOT 发起 HTTP 请求

#### Scenario: set_workspace 的未知句柄不伪装成功

- **WHEN** 用未登记句柄调用 `set_workspace` 并给一个合法目录
- **THEN** 返回 SHALL 是含 `unknown_context` 的非空错误文本，SHALL NOT 返回表示成功的空串，也 SHALL NOT 为它隐式建上下文

### Requirement: 取消失败不得伪造 done

取消请求后，如果 C++ 没有交付真实 done，Dart 桥 SHALL NOT 调用模型的 `onDone`。它 SHALL 让等待的 Future 以错误结束，把该上下文标为 `context_poisoned`，拒绝其后续请求，并保持可能仍被 curl 线程使用的 callable 打开。该状态 SHALL 只能通过销毁（并在底层真正排空成功后）或进程重启清除。

#### Scenario: 取消后长时间没有 done

- **WHEN** 取消请求后经过桥既有的兜底等待仍没有收到 done
- **THEN** 等待方收到错误而不是假的模型完成；该句柄后续调用返回 `context_poisoned`；不得放行新请求去清掉旧回调字符串

### Requirement: 文件版本表按上下文隔离

「读过没有、读的是哪一版」这条守卫（`edit_file` 的 `not_observed` 与 `stale` 两个分支）SHALL 按上下文隔离：一个上下文的读、写、改 SHALL NOT 改变另一个上下文的记录。

#### Scenario: 另一个上下文改过文件不算「我读过」

- **WHEN** 上下文 `甲` 读文件 X（版本 v1），随后上下文 `乙` 把 X 写成 v2，然后 `甲` 对 X 调用 `edit_file`
- **THEN** `甲` 的这次编辑 SHALL 返回 `code:"stale"`（文件读后已变），SHALL NOT 被放行

#### Scenario: 自己的读仍然有效

- **WHEN** 上下文 `甲` 读完文件 X 之后没有别人改过 X，`甲` 再调 `edit_file`
- **THEN** 编辑 SHALL 成功，SHALL NOT 报 `not_observed` 或 `stale`

### Requirement: 每份上下文一份模型网关

模型网关 SHALL 每份上下文一个（各自一份 curl 句柄与取消状态）。`cancel_request` SHALL 带上下文句柄，只取消该上下文自己的请求。

#### Scenario: 两个上下文各自发请求不排队

- **WHEN** 上下文 `甲` 与 `乙` 几乎同时各发一个 `send_message`
- **THEN** 两个请求的执行区间 SHALL 重叠（按各自 `request_id` 的起止时间核对），SHALL NOT 出现「乙在甲结束之后才开始」

#### Scenario: 取消只落到自己那份

- **WHEN** `甲` 与 `乙` 都在跑请求，对 `甲` 调 `cancel_request(甲的句柄, 甲的 request_id)`
- **THEN** SHALL 只有 `甲` 的请求以 `cancelled` 结束，`乙` 的请求 SHALL 照常完成

### Requirement: 销毁上下文要真的释放

`dispose_context` SHALL 先停止接收该上下文的新调用，取消其模型请求并等待模型、工具与浏览器在途调用全部结束，然后才关闭浏览器上下文、删除 spill 目录并释放网关。若上下文处于 `context_poisoned` 且底层无法证明排空完成，`dispose_context` SHALL 返回错误并保留资源，SHALL NOT 假装成功释放。对同一句柄重复销毁 SHALL 等同一次清理完成后幂等返回；同名上下文在清理完成前 SHALL NOT 重建。

#### Scenario: 重复销毁不崩

- **WHEN** 对同一个句柄连续调用两次 `dispose_context`
- **THEN** 两次调用 SHALL 都不崩，第二次 SHALL 不产生额外副作用

#### Scenario: 有在途请求时不提前释放

- **WHEN** 一个上下文仍有模型请求或长命令在执行时调用 `dispose_context`
- **THEN** 新调用 SHALL 立即被拒绝，旧请求 SHALL 被取消或按自身协议结束，资源 SHALL 只在在途计数归零后释放

#### Scenario: 销毁后浏览器标签页关掉

- **WHEN** 一个上下文用浏览器打开了页面，随后对它 `dispose_context`
- **THEN** 属于该上下文的浏览器上下文 SHALL 被关闭，它的页 SHALL 不再存在；别的上下文的页 SHALL 不受影响

#### Scenario: 毒化且无法排空时不假装释放

- **WHEN** 一个上下文已 `context_poisoned`，底层仍无法证明在途调用归零时调用 `dispose_context`
- **THEN** 返回 SHALL 是 `ok:false` 并说明未能排空，资源 SHALL 保留；SHALL NOT 释放网关、删除 callable 或允许同名重建

### Requirement: spill 目录跟着上下文走

每个上下文 SHALL 有自己的 spill 目录，目录名由**上下文名字**无损编码得到：`[a-z0-9_-]` 原样保留，其余字节写成 `%XX`（大写十六进制）。

- 两个不同的**非空**名字 SHALL NOT 落到同一个目录（含只差大小写的两个名字：Windows 文件系统不区分大小写，所以大写字母必须被编码掉）；
- 目录名 SHALL 能唯一还原成原始名字；
- 名字里的 `..`、`.` SHALL NOT 让目录跑到 spill 根目录之外；
- 序号 SHALL 在上下文创建时从本目录已有的 `NNNNNN-*.txt` 最大序号之后继续；没有目录时从 1 开始。进程重启后 SHALL NOT 从 1 重来并覆盖旧文件；
- `dispose_context` SHALL 在在途调用排空后删除该上下文的 spill 目录；
- `read_spill` SHALL 先按平台把引用规范化（POSIX 用 `realpath`，Windows 用 `GetFullPathName`），再只接受本上下文目录内的引用；`<本上下文>/../<别的上下文>/文件` SHALL 被拒绝；
- 空名字、`no-session` 与 `_it_` 前缀 SHALL 被 `create_context` 拒绝；`no-session/` 只作为历史遗留在应用启动时清理。

#### Scenario: 只差大小写的两个名字不共用目录

- **WHEN** 上下文 `Agent-7` 与 `agent-7` 各跑一次 `run_command`
- **THEN** 两份 spill 文件 SHALL 落在两个不同目录里，且两次都读得回来

#### Scenario: 名字里的 `..` 不会跑出根目录

- **WHEN** 上下文名字是 `..`
- **THEN** 它的 spill 目录 SHALL 仍在 spill 根目录之内，`read_spill` 能正常读回它的文件

#### Scenario: 销毁上下文时删掉它的目录

- **WHEN** 一个上下文产生过 3 次工具输出，随后对它 `dispose_context`
- **THEN** 它的 spill 目录 SHALL 不存在了，别的上下文的 spill 目录 SHALL 不受影响

#### Scenario: 同一上下文并发分配序号不撞

- **WHEN** 两个线程用同一句柄同时执行产生 spill 的 `run_command`
- **THEN** 两次调用 SHALL 得到不同序号与不同文件，两份文件内容 SHALL 分别对应各自命令的完整输出

#### Scenario: 不能用另一个上下文的句柄读引用

- **WHEN** 用乙的句柄读取甲目录下的 spill 引用
- **THEN** 返回 SHALL 是 `ok:false`，且 SHALL NOT 返回甲文件的内容

#### Scenario: 路径里加 `..` 也不能跨到别的上下文

- **WHEN** 用乙的句柄读取 `<乙目录>/../<甲目录>/000001-stdout.txt`
- **THEN** 规范化之后 SHALL 被判定在甲目录，返回 `ok:false`，SHALL NOT 用 `fopen` 读到甲文件

#### Scenario: 重启后继续编号，不覆盖旧引用

- **WHEN** 某上下文已经写出 `000001-stdout.txt`，进程重启并对同一名字重建上下文，再执行一次会产生 spill 的命令
- **THEN** 新文件 SHALL 使用更大的序号，`000001-stdout.txt` 的旧内容 SHALL 保持不变，旧引用仍读回旧内容

#### Scenario: 保留名不能作为上下文

- **WHEN** 用 `no-session` 或 `_it_x` 调用 `create_context`
- **THEN** 返回 `reserved_context`，启动清理即使删除这些目录也 SHALL NOT 删掉合法上下文的数据
