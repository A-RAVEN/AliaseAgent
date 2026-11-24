## ADDED Requirements

### Requirement: 单聊消息气泡与头像

web 聊天屏的单聊主区 SHALL 用与群聊同一套聊天式左右气泡与头像组件渲染消息，MUST NOT 再用「全宽/靠边卡片 + You/Assistant 大写标签」的形态：

- 用户消息 SHALL 靠右、绿气泡，用户头像位于该行**最右端**；
- 助手消息（含流式消息）SHALL 靠左，agent 头像在最左、气泡在右；单聊 SHALL NOT 再画发言者名字（只有一个 agent，名字是噪音）；
- 「正在生成…」指示行 MUST NOT 配头像（它不是一条消息，而是一个状态指示）；
- 气泡 SHALL 是消息行**内部**的元素（行容器保留既有标识、整行含头像），靠哪边、多宽 SHALL 由内层气泡体现并可按内层气泡度量；
- 气泡宽度上限、圆角与内外间距 SHALL 取自既有设计令牌/既有类名，MUST NOT 新写裸色值与任意间距。

头像来源 SHALL 按此顺序：①该会话所属模板的 `avatar_path`（上传覆盖，能取到图片字节时才用）；②否则用该**会话 id** 生成的身份图案（纯前端 SVG、5×5 横向对称网格 + 一档派生色、确定性：同一会话永远同一图案，会话改名 MUST NOT 改变图案）。用户头像 SHALL 取 `profile.avatar_path`，没有则用用户标识生成的身份图案。**头像图片 SHALL 经 `attachment.read` 换成 data URL 后渲染**，MUST NOT 把附件目录的绝对路径、`file://` 地址或由路径拼出的 URL 直接塞进 `<img src>`（静态服务拒绝 web 根外文件，浏览器拿不到）。头像图片取不到字节（文件被删或移走）时 SHALL 回落身份图案并在 DOM 上标出来源（`data-avatar-source`），MUST NOT 弹错误横幅、MUST NOT 让消息渲染失败。

气泡内的既有内容 SHALL 保持：附件缩略图、以及「图片未发送」「图片已丢失」两类可见提示行 MUST NOT 因改气泡而消失或改文案；live 事件与历史加载对同一条消息 SHALL 渲染成同一种形态（气泡 + 头像 + 正文），MUST NOT 出现一边是气泡、另一边还是旧卡片的分叉。

#### Scenario: 用户消息靠右带头像

- **WHEN** 单聊里用户发一条文本消息
- **THEN** 该消息是绿气泡、整体贴在消息区右侧，用户头像在这一行的最右端；MUST NOT 出现「You」这类大写角色标签

#### Scenario: 助手消息靠左带头像

- **WHEN** 助手回复一条文本消息
- **THEN** 该消息贴在消息区左侧，agent 头像在最左、气泡在右；MUST NOT 出现「Assistant」这类大写角色标签，MUST NOT 在气泡上方画发言者名字

#### Scenario: 流式消息与落定消息同一侧

- **WHEN** 助手正在流式输出，随后该轮落定
- **THEN** 流式气泡与落定的助手气泡都在左侧、都带同一个 agent 头像，不出现「流式时在一侧、落定后换到另一侧」

#### Scenario: agent 头像优先用模板上传图

- **WHEN** 当前会话的模板设置了 `avatar_path` 且图片可读
- **THEN** 助手气泡与流式气泡都显示这张图，且 `<img>` 的 `src` 是以 `data:` 开头的 data URL（不是盘符路径）；清除该模板头像后显示由会话 id 生成的身份图案

#### Scenario: 上传头像真的显示出来

- **WHEN** 会话模板设置了头像，且核心的 `attachment.read` 返回该图片的 base64
- **THEN** 头像 `<img>` 实际可解码、可见（尺寸等于头像令牌值），`data-avatar-source="upload"`；MUST NOT 出现空图片框或破图

#### Scenario: 会话改名不换头像

- **WHEN** 用户给一个会话改名（会话 id 不变）
- **THEN** 助手侧的身份图案与改名前一模一样

#### Scenario: 头像图片丢失回落身份图案

- **WHEN** 模板的 `avatar_path` 指向的文件已被删除
- **THEN** 助手气泡显示身份图案，`data-avatar-source="identicon"` 可在 DOM 上读到，消息正文与附件照常渲染且没有错误横幅

#### Scenario: 附件与提示行不变

- **WHEN** 用户消息带图片附件，且模板未声明 image 模态（或附件文件缺失）
- **THEN** 气泡里仍有附件缩略图与「图片未发送」/「图片已丢失」提示行，文案与改气泡前逐字一致

#### Scenario: live 与 history 渲染同一形态

- **WHEN** 同一条用户消息分别经 live 事件与历史分页加载渲染
- **THEN** 两次都是右侧绿气泡 + 右端头像，不出现「live 是气泡、history 是旧卡片」的分叉

#### Scenario: 气泡尺寸与颜色取自令牌

- **WHEN** 审查单聊气泡与头像的样式
- **THEN** 头像尺寸、状态色、气泡底色与圆角都取自集中令牌或既有类名，组件里没有裸十六进制色值与任意间距数字
