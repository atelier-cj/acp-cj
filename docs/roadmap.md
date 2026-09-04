# acp-cj ACP v1 补全 · 实施规划（Roadmap）

> 目标：按 [支持矩阵](support.md) §7 差距清单，把 acp-cj 补全到 ACP v1 规范完整覆盖。
> 开发在独立 worktree `acp-cj-dev/`（分支 `feat/acp-v1-complete`）中进行，不干扰主工作树。
> 进度状态同步维护两份文档：本规划（任务状态）+ support.md（能力状态）。

## 开发约定（每阶段通用）

- **TDD**：先写仓颉单元测试 → 跑红/编译 → 实现 → 全绿 → 独立提交（commit 一次只含一个子项）。
- 测试命令：`cjpm test -j 16 --no-progress`（39 个存量单测须保持全绿，只增不减）。
- schema 唯一事实源：`docs/schema/schema.json`（与官方 release latest md5 一致）。
- 提交信息风格沿用仓库历史（`feat:` / `fix:` / `test:` / `docs:`）。
- 全部完成并回归后：`git merge --no-ff` 回 master，删分支；**不推送远程**（用户确认）。
- 涉及协议类型行为变化（如 `ClientCapabilities.elicitation` 由 JsonValue 变结构化）属 **0.2.0** 语义（minor），发版与否另行决定。

## 阶段总览

| 阶段 | 内容 | 对应差距 |
|------|------|----------|
| 1 | 框架小项（不依赖 elicitation 的 P1/P2 快赢） | A4/A2/E1/N1/C2/M1/A1/A3 |
| 2 | Elicitation 模块（最大缺口，P0） | §7-P0 全部 |
| 3 | 收尾：回归、文档同步、合并 | — |

---

## 阶段 1：框架小项

### 1.1 clientCapabilities 保存与透出（A4）

- [ ] `AcpAgent.handleInitialize` 保存握手收到的 `ClientCapabilities`（新增 `public var clientCapabilities: ?ClientCapabilities`，握手后填充）
- [ ] `PromptContext` 携带同一引用，提供查询方法（如 `hasFs() / hasTerminal() / hasElicitation(mode)` 或直接 `clientCapabilities()`），供 prompt 处理器做规范要求的「调用 fs/terminal/elicitation 前 MUST 检查能力」
- [ ] 测试：握手后 AcpAgent 可查询；prompt 处理器内可查询（FakeAgent/MemoryPipe 双端用例）
- [ ] 提交

### 1.2 authenticate 参数校验（A2）

- [ ] `handleAuthenticate`：校验 `methodId` 必须存在于 `authMethods` 且该方法 `type` 不是 `"terminal"`（规范：terminal 型不得走协议 authenticate）；不合法回 `-32602`，合法才置位认证
- [ ] 测试：未广告 methodId → -32602；terminal 型 methodId → -32602；合法 → 成功
- [ ] 提交

### 1.3 Agent 侧扩展方法注册口（E1）

- [ ] `AcpAgent.registerExtensionMethod(method: String, handler)`：注册 `_` 前缀自定义请求（约定检查 `_` 开头，非 `_` 开头直接拒绝/警告由实现定）
- [ ] 测试：注册 `_foo` 后 client 侧可调用并收到结果；未注册返回 `-32601`
- [ ] 提交

### 1.4 Client 侧扩展通知订阅口（N1）

- [ ] `AcpClient.setOnNotification(method: String, cb)`：目前 `handleNotification` 只分发 `session/update`，其他（含 `_` 扩展通知、后续 elicitation/complete）转交订阅者
- [ ] 测试：Agent 侧发自定义通知 → Client 收到
- [ ] 提交

### 1.5 Client 侧反向方法类型化 handler（C2）

- [ ] 新增类型化注册 API（与现有通用 `on(method, handler)` 并存）：
  `setOnRequestPermission(cb: (RequestPermissionRequest) -> RequestPermissionResponse)`
  `setOnReadTextFile` / `setOnWriteTextFile` / `setOnCreateTerminal` / `setOnTerminalOutput` / `setOnTerminalWaitForExit` / `setOnTerminalKill` / `setOnTerminalRelease`
- [ ] 测试：Agent 经 MemoryPipe 反向调用各类方法 → Client 类型化回调触发、响应正确序列化
- [ ] 提交

### 1.6 细节打磨（M1/A1/A3 合并提交）

- [ ] **M1 `_meta` 补齐**：给主要请求/响应类型补 `_meta: Option<JsonValue>` 收发（InitializeRequest/Response 已有；重点：NewSessionRequest、PromptRequest、RequestPermissionRequest、terminal/fs 请求等）
- [ ] **A1 cwd 绝对路径校验**：`session/new` 按规范校验绝对路径（查 std lib 有无现成判断，无则按平台惯例 `'/'` 或盘符前缀检查）
- [ ] **A3 版本协商**：客户端请求的 protocolVersion 不支持时行为按规范核对（当前直接回自身版本；如规范要求可接受则补测试固化该语义，避免误改）
- [ ] 测试 + 提交

**阶段 1 出口条件**：单测全绿；support.md §7 的 P1/P2 项对应勾除（A4/A2/E1/N1/C2/M1/A1/A3 完成）。

---

## 阶段 2：Elicitation 模块（P0）

依据：[官方文档 Elicitation](https://agentclientprotocol.com/protocol/v1/elicitation) + 本地 `docs/schema/schema.json` `$defs`（elicitation 系 16 个 def，见附录 A）。

### 2.1 类型层 `src/types/elicitation.cj`（新文件）

- [ ] `ElicitationSchemaType`（判别常量 `"object"`）
- [ ] `ElicitationSchema`（type/title/properties/required/description/_meta）
- [ ] 属性 schema 族：`StringPropertySchema`（含 enum 单选与 `StringFormat`）、`NumberPropertySchema`、`IntegerPropertySchema`、`BooleanPropertySchema`、`MultiSelectPropertySchema`（items：string / titled）、`EnumOption`、`ElicitationPropertySchema` 判别联合（string/number/integer/boolean/array/other `_` 前缀兜底）
- [ ] 作用域：`ElicitationSessionScope{sessionId, toolCallId?}` / `ElicitationRequestScope{requestId}`（requestId 复用 jsonrpc 的 Int/String 形式）
- [ ] 模式：`ElicitationFormMode{requestedSchema}` / `ElicitationUrlMode{elicitationId, url}` + scope 联合
- [ ] `CreateElicitationRequest`（sessionScope/requestScope + formMode/urlMode 判别 + message 必填 + _meta）
- [ ] 响应：`CreateElicitationResponse` 判别（`accept{content?}` / `decline` / `cancel` / other `_` 前缀兜底），`ElicitationAcceptAction`、`ElicitationContentValue`（string/integer/number/boolean/string-array）
- [ ] `CompleteElicitationNotification{elicitationId, _meta}`、`ElicitationId` 类型别名
- [ ] 测试：全部类型 JSON 往返矩阵 + 未知/容错路径
- [ ] 提交

### 2.2 ClientCapabilities.elicitation 结构化（breaking → 0.2.0）

- [ ] `ElicitationCapabilities{form?, url?}` / `ElicitationFormCapabilities{}` / `ElicitationUrlCapabilities{}`（EmptyCapability 语义复用）
- [ ] `ClientCapabilities.elicitation: ?JsonValue` 换成结构化类型，序列化保持「省略/null = 不支持、`{}` 空对象 = 支持该模式」语义
- [ ] 测试：能力广告往返（含 form/url 单独与组合）
- [ ] 提交

### 2.3 Agent 侧

- [ ] `AcpAgent.createElicitation(...)` 反向请求（form/url 两种载荷 + 两种 scope 的重载或参数对象）+ `AcpAgent.elicitationComplete(elicitationId)` 通知
- [ ] **前置能力检查**：发起前按 1.1 的 clientCapabilities 校验模式已广告（form/url），未广告返回 `-32602`（规范 MUST NOT）
- [ ] 测试：Agent→Client 双端 create 全流程（accept/decline/cancel 三响应路径）+ complete 通知
- [ ] 提交

### 2.4 Client 侧

- [ ] `AcpClient.setOnElicitationCreate(cb)` 类型化请求处理（返回 accept/decline/cancel 构造 helper：`ElicitationResponse.accepted(content)` 等）
- [ ] `handleNotification` 增加 `elicitation/complete` 分发（依赖 1.4 的订阅口或独立回调）
- [ ] 测试：同上双端用例覆盖 Client 侧回调与响应载荷
- [ ] 提交

### 2.5 双端集成 + 文档同步

- [ ] MemoryPipe 双端集成用例：能力广告（form+url）→ create(form) → accept(content) → create(url) → decline/cancel 路径 → complete 通知
- [ ] support.md：Elicitation 章节/矩阵标记 ✅，§7 P0 勾除；README「协议支持」表格更新
- [ ] 提交

**阶段 2 出口条件**：全量单测绿（存量 39 + 新增），Elicitation 章节覆盖度 100%。

---

## 阶段 3：收尾

- [ ] `cjpm test -j 16 --no-progress` 全量回归；`scripts/test-e2e-bridge.sh`（环境可用时）验证不回归
- [ ] README API 一览表补新 API；support.md 状态与日期刷新、schema md5 复核
- [ ] 格式化/静态检查（按仓库既有习惯，不引入新工具链）
- [ ] `git merge --no-ff feat/acp-v1-complete` 回 master，删除分支，移除 worktree 登记（分支删除前保留 worktree 引用）
- [ ] （可选）发版 0.2.0 另行走中心仓流程

---

## 附录 A：官方 schema elicitation 系 $defs 清单（实现核对源：docs/schema/schema.json）

顶层 16 个 def：`ElicitationSchema` `ElicitationSchemaType` `ElicitationPropertySchema` `StringPropertySchema` `NumberPropertySchema` `IntegerPropertySchema` `BooleanPropertySchema` `MultiSelectPropertySchema` `MultiSelectItems` `StringMultiSelectItems` `TitledMultiSelectItems` `StringFormat` `EnumOption` `ElicitationFormMode` `ElicitationUrlMode` `ElicitationId` `ElicitationSessionScope` `ElicitationRequestScope` `CreateElicitationRequest` `CreateElicitationResponse` `ElicitationContentValue` `ElicitationAcceptAction` `CompleteElicitationNotification` `ElicitationCapabilities` `ElicitationFormCapabilities` `ElicitationUrlCapabilities`。

关键结构速记：

- `CreateElicitationRequest`：message(必填) + _meta；判别体为 form/url 二选一，各带 scope（`sessionId`±`toolCallId`，或 `requestId`）——wire 上是**扁平字段**（无嵌套 scope 对象）
- `ElicitationSchema`：`type:"object"` + title?/description? + properties(map,值=属性 schema) + required?(array) + _meta?
- 属性 schema 判别 `type`: string / number / integer / boolean / array(multi-select) / 其他 `_` 前缀（兜底透传）
- `CreateElicitationResponse.action` 常量：`accept`（可带 content 对象）/ `decline` / `cancel` / `_` 前缀其他
- `CompleteElicitationNotification`：elicitationId 必填（仅 url 模式 agent 可发，且只发给原连接）
- 能力：顶层省略/null=不支持；`form`/`url` 各自 `{}` = 支持（与 ACP 要求「显式声明」一致，区别于 MCP RC 的 form-only 默认）

> 字段级细节（default、format 枚举、multi-select items 判别、each 约束）以 `docs/schema/schema.json` 原文为准，编码时逐条对照，不凭记忆。
