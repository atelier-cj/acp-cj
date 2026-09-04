# acp-cj ACP v1 支持矩阵

> 逐项对照 [ACP 官方规范 v1](https://agentclientprotocol.com/protocol/v1/overview)（2026-09-05 抓取）整理的**功能支持清单**，
> 用于跟踪实现进度、明确还差什么。方法与类型全集取自官方最新 release 的
> [schema.json](https://github.com/agentclientprotocol/agent-client-protocol/releases/latest/download/schema.json)，
> 与本地 `docs/schema/schema.json` **完全一致**（md5 `4c526b8b…`，2026-09-05 校验）。

## 图例

| 标记 | 含义 |
|------|------|
| ✅ | 已实现（含单元/端到端验证） |
| 🟡 | 部分实现 / 简化实现（见备注） |
| ❌ | 未实现 |
| ➖ | 规范未定稿 / 范围外（跟踪中） |

> 状态为 **2026-09-05** 快照（master@`03c877e`，39 单测全绿 + 真实 e2e 通过）。后续实现每动一次，请同步更新本文件。

---

## 1. 协议基线

| 项 | 状态 | 备注 |
|----|------|------|
| 协议版本 v1（`protocolVersion: 1`） | ✅ | `ProtocolVersionV1`，握手时按客户端请求回自身版本（简化协商） |
| JSON-RPC 2.0 over stdio、`\n` 帧、无内嵌换行 | ✅ | 复用 `ystyle::jsonrpc` 的 `NewlineFraming`；stdout 只输出 ACP 消息、日志走 stderr 由框架约定保证 |
| 传输抽象可插拔（自定义传输） | ✅ | `Transport` 接口：`StdioTransport` / `SubprocessTransport` / 测试用 `DuplexTransport` |
| Streamable HTTP 传输 | ➖ | 官方仍为 draft（in progress），规范定稿后评估（jsonrpc 传输层已可扩展） |
| 双工通信（两端互发请求/通知） | ✅ | `AcpAgent`=JsonRpcServer、`AcpClient`=JsonRpcClient，均有主动请求对端与注册对端 handler 能力 |

---

## 2. 方法支持矩阵（依据官方 schema `x-method` 全集）

### 2.1 Client → Agent（Agent 接口，共 12 个）

| 方法 | 状态 | Agent 侧实现（AcpAgent） | 备注 |
|------|------|--------------------------|------|
| `initialize` | ✅ | 内置 | 版本协商 + `agentInfo`/`agentCapabilities`/`authMethods` 返回；🟡 未保留客户端能力供业务查询（见 §7-A4） |
| `authenticate` | 🟡 | 内置 + `setOnAuthenticated` | 🟡 仅布尔门控置位，不校验 `methodId` 是否属于 `authMethods`、不拦截 terminal 型 methodId（规范：terminal 型不得走 `authenticate`） |
| `logout` | ✅ | 内置 + `setOnLoggedOut` | 需广告 `agentCapabilities.auth.logout = {}` |
| `session/new` | ✅ | 内置 + `setOnNewSession(sessionId, cwd)` | 🟡 响应固定只有 `sessionId`，无法携带初始 `modes`/`configOptions`（见 §7-A5）；cwd 只校验非空未校验「绝对路径」 |
| `session/load` | ✅ | `setOnLoadSession`（异步重放 → complete/fail）+ `SessionStore` 持久化 | 重放 `session/update` 历史后再响应，与规范一致；需广告 `loadSession: true` |
| `session/list` | ✅ | `setOnListSessions` | 需广告 `sessionCapabilities.list`；分页 cursor 由回调返回 |
| `session/delete` | ✅ | `setOnDeleteSession` | 未找到会话回 `-32002`；需广告 `sessionCapabilities.delete` |
| `session/resume` | ✅ | `setOnResumeSession` | 需广告 `sessionCapabilities.resume` |
| `session/close` | ✅ | 内置 + `setOnClose` | 从会话表移除并置取消标志；需广告 `sessionCapabilities.close` |
| `session/set_mode` | ✅ | `setOnSetMode` | 模式合法性由回调裁决（false → `-32602`） |
| `session/set_config_option` | ✅ | `setOnSetConfigOption` | `value` 联合类型已覆盖：`value_id`（默认，字符串）与 `type:"boolean"` + bool 两种变体序列化 |
| `session/prompt` | ✅ | `setPromptHandler`（异步 `registerAsyncErr` + 会话级 Mutex 串行） | 回合中可 `ctx.emit(SessionUpdate)`、`ctx.isCancelled()`；结束统一归一 stopReason（取消 → `cancelled`） |

### 2.2 Agent → Client（Client 接口，共 9 个）

| 方法 | 状态 | Agent 侧封装 | Client 侧处理 | 备注 |
|------|------|--------------|---------------|------|
| `session/request_permission` | ✅ | `AcpAgent.requestPermission` | 通用 `on("session/request_permission", h)` | 🟡 Client 侧无类型化 handler（需自行解析 params） |
| `terminal/create` | ✅ | `createTerminal` | `on("terminal/create", h)` | 同上 |
| `terminal/output` | ✅ | `terminalOutput` | `on("terminal/output", h)` | 同上 |
| `terminal/wait_for_exit` | ✅ | `terminalWaitForExit` | `on("terminal/wait_for_exit", h)` | 同上 |
| `terminal/release` | ✅ | `terminalRelease` | `on("terminal/release", h)` | 同上 |
| `terminal/kill` | ✅ | `terminalKill` | `on("terminal/kill", h)` | 同上 |
| `fs/read_text_file` | ✅ | `readTextFile` | `on("fs/read_text_file", h)` | `line`/`limit` 参数齐 |
| `fs/write_text_file` | ✅ | `writeTextFile` | `on("fs/write_text_file", h)` | 同上 |
| `elicitation/create` | ❌ | 无 `createElicitation` API | 无类型（仅可 `on()` 裸 JSON 处理） | **最大缺口**：无请求/响应/表单 schema 类型族，见 §7-P0 |

### 2.3 通知（Notifications）

| 通知 | 方向 | 状态 | 备注 |
|------|------|------|------|
| `session/update` | Agent→Client | ✅ | 见 §4 判别全集（10 种全支持） |
| `session/cancel` | Client→Agent | ✅ | 置会话取消标志 → prompt 回 `cancelled` |
| `$/cancel_request` | Client→Agent | ✅ | 按 JSON-RPC 请求 id 取消（`requestId` 映射到会话） |
| `elicitation/complete` | Agent→Client | ❌ | 无类型、无发送 API（elicitation 一并缺失） |
| 扩展通知 `_xxx` | 双向 | 🟡 | Agent 侧可收自定义通知（jsonrpc 层）；Client 侧通知分发只处理 `session/update`，扩展通知无订阅口 |

### 2.4 扩展性（Extensibility 章节）

| 能力 | 状态 | 备注 |
|------|------|------|
| `_meta` 透传 | 🟡 | 收发兼容（未知字段跳过/不序列化），但仅部分类型声明了 `_meta` 字段可编程访问（`InitializeRequest/Response`、`PromptRequest/Response`、`NewSessionResponse` 等），其余请求类型（如 `SetSessionModeRequest`、`DeleteSessionRequest`、`AuthMethod` 相关）未带 |
| 自定义请求（`_foo` 方法） | 🟡 | Client 侧：`AcpClient.on("_foo", h)` ✅；Agent 侧：`AcpAgent` 未暴露扩展方法注册口（内部 `JsonRpcServer` 私有），业务方自定义 `_*` 方法无法注册 |
| 自定义通知 | 🟡 | 同 2.3 扩展通知行 |
| 自定义 capabilities 广告 | ✅ | 各 Capabilities 类均有 `_meta` 透传（Map），可附加自定义键 |

---

## 3. 能力协商矩阵（initialize）

### 3.1 AgentCapabilities（AcpAgent.capabilities，public 可配）

| 字段 | 官方语义 | 类型支持 | 默认 | 备注 |
|------|----------|----------|------|------|
| `loadSession` | 支持 `session/load` | ✅ | false | |
| `promptCapabilities.image` | 支持 Image 内容块进 prompt | ✅ | false | 基线（text/resource_link）恒支持 |
| `promptCapabilities.audio` | 支持 Audio 内容块进 prompt | ✅ | false | |
| `promptCapabilities.embeddedContext` | prompt 中接受嵌入式上下文 | ✅ | false | |
| `mcpCapabilities.http` | 接受 McpServer::Http | ✅ | false | 仅声明；实际 MCP 连接属范围外（§7） |
| `mcpCapabilities.sse` | 接受 McpServer::Sse | ✅ | false | 同上 |
| `sessionCapabilities.list` | `session/list` | ✅ | 缺省(不支持) | `Some(EmptyCapability())` 开启 |
| `sessionCapabilities.delete` | `session/delete` | ✅ | 缺省 | 同上 |
| `sessionCapabilities.resume` | `session/resume` | ✅ | 缺省 | 同上 |
| `sessionCapabilities.close` | `session/close` | ✅ | 缺省 | 同上 |
| `sessionCapabilities.additionalDirectories` | 会话附加工作区根 | ✅ | 缺省 | 新 schema 字段，类型/收发已含 |
| `auth.logout` | 支持 `logout` | ✅ | 缺省 | |

### 3.2 ClientCapabilities（AcpClient.connect 传入 / Agent 接收）

| 字段 | 官方语义 | 类型支持 | 备注 |
|------|----------|----------|------|
| `fs.readTextFile` / `fs.writeTextFile` | Client 提供 fs 反向方法 | ✅ | |
| `terminal` | Client 支持全部 `terminal/*` | ✅ | |
| `auth.terminal` | Client 支持 terminal 认证 | ✅ | |
| `session.configOptions.boolean` | Client 支持布尔配置项 | ✅ | `ClientSessionCapabilities.configOptions` |
| `elicitation.form` / `elicitation.url` | Client 支持表单/URL 引导输入 | 🟡 | 仅 `?JsonValue` 透传，无结构化类型（见 §7-P0） |

---

## 4. 类型与内容支持

### 4.1 session/update 判别（官方 10 种全支持）

| 判别 | 构造 helper | 解析 | 备注 |
|------|------------|------|------|
| `user_message_chunk` | `SessionUpdate.userMessageChunk` | ✅ | + `messageId` |
| `agent_message_chunk` | `SessionUpdate.agentMessage` | ✅ | + `messageId` |
| `agent_thought_chunk` | `SessionUpdate.agentThought` | ✅ | + `messageId` |
| `tool_call` | `SessionUpdate.toolCall` | ✅ | `kind`/`status`/`locations`/`rawInput` |
| `tool_call_update` | `SessionUpdate.toolCallUpdate` | ✅ | 增量字段全可选 |
| `plan` | `SessionUpdate.plan` | ✅ | `PlanEntry{content, priority, status}`（枚举用 String） |
| `available_commands_update` | `SessionUpdate.availableCommandsUpdate` | ✅ | `AvailableCommand{name, description, input.hint}` |
| `current_mode_update` | `SessionUpdate.currentModeUpdate` | ✅ | |
| `config_option_update` | `SessionUpdate.configOptionUpdate` | ✅ | select（含分组）/boolean 两种 option 判别 |
| `session_info_update` | `SessionUpdate.sessionInfoUpdate` | ✅ | 只写有值字段（title/updatedAt，省略=不变） |
| `usage_update` | `SessionUpdate.usageUpdate` | ✅ | `used`/`size` 必填 + 可选 `Cost{amount, currency(ISO4217)}` |

### 4.2 内容块与工具载荷

| 类型 | 支持 | 备注 |
|------|------|------|
| ContentBlock：text / image / audio / resource_link / embedded resource | ✅ | `ContentBlock.ofText/image/ofResource/resourceLink`，parse 判 5 种 |
| EmbeddedResource：text / blob 资源 | ✅ | |
| ToolCallContent：content / diff / terminal（内嵌） | ✅ | `ToolCallContent.type` 判别 + `ContentBlock` 复用 |
| ToolCall / ToolCallUpdate / ToolCallLocation(path,line) | ✅ | locations 用于「follow the agent」 |
| ToolKind / ToolCallStatus / PermissionOptionKind / StopReason | ✅ | 字符串常量/判别收发（`StopReasonEndTurn/…Cancelled` 等常量） |

### 4.3 会话数据模型

| 类型 | 支持 | 备注 |
|------|------|------|
| NewSession/Resume 响应：`modes(SessionModeState)`、`configOptions` | 🟡 | 类型齐（`SessionMode{id,name,desc}`、`SessionConfigOption`…），但 AcpAgent 响应路径无法填充（§7-A5） |
| `SessionInfo{sessionId,cwd,title,updatedAt,additionalDirectories}` | ✅ | session/list 用 |
| McpServer（stdio/http/sse 三形态扁平字段收发） | 🟡 | 类型为扁平近似（command/args/env/type/url/headers），未按判别封闭；实际 MCP 连接=范围外 |
| AuthMethod{id,name,description,type(agent/terminal),args,env} | ✅ | terminal 登录 `AcpClient.terminalLogin` 已实现（env 覆盖、args 追加、退出码判成功） |

---

## 5. 协议章节对照

| 官方章节 | 状态 | 备注 |
|----------|------|------|
| [Overview](https://agentclientprotocol.com/protocol/v1/overview) | ✅ | 基线模型、错误处理、约定均符合 |
| [Initialization](https://agentclientprotocol.com/protocol/v1/initialization) | ✅ | 🟡 版本协商简化（不回协议版本错误，只回自身 v1） |
| [Session Setup](https://agentclientprotocol.com/protocol/v1/session-setup) | ✅ | new/load/resume/close + additionalDirectories 字段收发；MCP 透传=范围外 |
| [Prompt Turn](https://agentclientprotocol.com/protocol/v1/prompt-turn) | ✅ | 流式输出/工具调用/取消语义完整；usage_update helper 齐 |
| [Tool Calls](https://agentclientprotocol.com/protocol/v1/tool-calls) | ✅ | 创建/更新/权限请求/终止语义 + locations |
| [Agent Plan](https://agentclientprotocol.com/protocol/v1/agent-plan) | ✅ | plan/plan_entry 通知收发；整表替换语义由发送方负责 |
| [Slash Commands](https://agentclientprotocol.com/protocol/v1/slash-commands) | ✅ | available_commands_update 收发 + 动态更新；命令解析属业务层 |
| [Session Modes](https://agentclientprotocol.com/protocol/v1/session-modes) | ✅ | set_mode/current_mode_update/初始 availableModes（🟡 初始注入见 §7-A5） |
| [Session Config Options](https://agentclientprotocol.com/protocol/v1/session-config-options) | ✅ | select/boolean 双变体 + config_option_update + set_config_option |
| [Cancellation](https://agentclientprotocol.com/protocol/v1/cancellation) | ✅ | session/cancel + $/cancel_request 双路径，取消后必须回 cancelled 已保证 |
| [Authentication](https://agentclientprotocol.com/protocol/v1/authentication) | ✅ | 协议认证 + terminal 认证 + logout 全链路 e2e 验证（auth_required -32000 门控） |
| [Content](https://agentclientprotocol.com/protocol/v1/content) | ✅ | 5 种内容块 + annotations 透传 |
| [File System](https://agentclientprotocol.com/protocol/v1/file-system) | ✅ | 双向封装齐 |
| [Terminals](https://agentclientprotocol.com/protocol/v1/terminals) | ✅ | 5 方法双向封装齐（含 outputByteLimit、exitStatus） |
| [Elicitation](https://agentclientprotocol.com/protocol/v1/elicitation) | ❌ | 见 §7-P0 |
| [Session List](https://agentclientprotocol.com/protocol/v1/session-list) | ✅ | cursor 分页 + session_info_update 动态元数据 |
| [Session Delete](https://agentclientprotocol.com/protocol/v1/session-delete) | ✅ | -32002 语义 |
| [Extensibility](https://agentclientprotocol.com/protocol/v1/extensibility) | 🟡 | §2.4 |
| [Transports](https://agentclientprotocol.com/protocol/v1/transports) | ✅ | stdio + 自定义传输；Streamable HTTP 官方 draft ➖ |

### 错误码

`-32700/-32600/-32601/-32602/-32603`（标准 JSON-RPC）、`-32800`（cancelled）、`-32000`（auth_required + data.authMethods）、`-32002`（resource not found）—— 常量与返回路径齐全 ✅

---

## 6. 已实现但官方 v1 之外的工程能力

| 能力 | 说明 |
|------|------|
| `SessionStore` 会话映射持久化 | pi_bridge 用，session/load 跨进程重启恢复（对标 pi-acp session-map.json） |
| 真实 Agent 桥接 | `pi_bridge`：AcpAgent ↔ opencode（标准 ACP server），testclient→bridge→opencode→LLM 全链路 e2e |
| 认证门控 e2e | `--auth-required` 开关验证 authenticate/logout 全链路 |
| 测试 | 39 单测（types 23 / agent 14 / client 2）+ `scripts/test-e2e-bridge.sh` |

---

## 7. 还差哪些（差距清单 / Roadmap）

### P0 —— Elicitation（官方章节完整缺失，模块级缺口）

1. **类型族**：`elicitation/create` 请求/响应、`ElicitationSchema` 全家（string/number/integer/boolean/multi_select 属性 schema、enum、默认值、form/url 模式、`ElicitationContentValue`、accept/decline/cancel action、`CompleteElicitationNotification`、`ElicitationId`…）。
2. **Agent 侧**：`AcpAgent.createElicitation(...)` 反向请求封装 + `elicitation/complete` 通知发送；表单/URL 两种 mode。
3. **Client 侧**：`ClientCapabilities.elicitation.form/url` 结构化（当前 `?JsonValue` 透传）；`AcpClient.onElicitationCreate` 类型化 handler（现有 `on()` 裸 JSON 可先顶着）。
4. 单测：schema 往返 + 双端流程（仿 terminal/fs 的既有测试模式）。
   > 依赖：须等 `mcp-cj`/jsonvalue 侧无阻碍；UI 表单渲染仍属业务层（非库职责）。

### P1 —— 框架级能力缺口（影响「agent 规范符合性」）

- **A4. clientCapabilities 不透出**：规范要求 Agent 调用 `fs/*`、`terminal/*`、`elicitation/create` 前**必须**检查 Client 能力声明，但 `AcpAgent` 未保存 initialize 收到的 `ClientCapabilities`，`PromptContext` 也无法查询。→ 建议：`AcpAgent.clientCapabilities`（握手后填充）+ `PromptContext.clientCapabilities`/查询方法 + 测试。
- **A2. authenticate 校验弱**：不校验 `methodId ∈ authMethods`、不拒绝 terminal 型 methodId、`authenticate` 前 session 门控只靠布尔。→ 建议：methodId 白名单校验 + 错误码 `-32602`；terminal 方法收到 `authenticate` 请求应拒绝。
- **E1. Agent 侧扩展方法注册口缺失**：`_foo` 自定义请求无法在 AcpAgent 注册（仅 client 侧 `on()`）。→ 建议：暴露 `AcpAgent.onExtension(method, handler)`（含 `_` 前缀约定检查可选）。

### P2 —— 完整性/易用性打磨

- **A5. 会话初始状态不可返回**：`NewSessionResponse`/`LoadSessionResponse` 的 `modes`（availableModes）、`configOptions` 无法经钩子注入；`setOnNewSession` 也不带 `mcpServers`/`additionalDirectories`。→ 建议：钩子签名升级或新增会话配置对象回调。
- **C2. Client 侧反向方法类型化 handler 缺失**：request_permission/terminal/fs 需手写 `on()` + JsonValue 解析。→ 建议：仿 mcp-cj 提供 `setOnRequestPermission` 等类型化注册。
- **N1. Client 侧扩展通知无订阅口**：`handleNotification` 只分发 `session/update`。→ 建议：公开 `setOnNotification(method, cb)`。
- **M1. `_meta` 字段覆盖不全**：统一给所有请求/响应类型补 `_meta` 可编程访问。
- **A1. cwd 只查非空**：按规范要求绝对路径校验（可加 `Path.isAbsolute` 检查）。
- **A3. 版本协商增强**：收到不支持版本时按官方建议协商（当前直接回自身 v1，宽松可接受）。

### ➖ 跟踪项（非缺口，随官方演进）

- Streamable HTTP 传输（官方 draft in progress）。
- **ACP v2**（[draft 公告](https://agentclientprotocol.com/announcements/acp-v2-draft)）：迁移成本评估（v2 章节已上线：prompt-lifecycle、去掉 session-modes 等），v1 稳定后规划。
- **MCP 透传**（`session/new.mcpServers` 建立真实 MCP 连接）：acp-cj 定位为协议框架，连接层建议由业务方用 `mcp-cj` 实现，acp-cj 只保证字段收发与类型。
- schema 版本漂移：以 `docs/schema/schema.json` md5 与官方 release latest 比对为准（本文件头已记录）。

---

## 8. 验证基线（如何跑）

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm test -j 16 --no-progress          # 39 单测
./scripts/test-e2e-bridge.sh           # 真实 e2e（需 opencode + LLM key）
```

- 本地 schema vs 官方：`md5sum docs/schema/schema.json` 对照 [release latest schema.json](https://github.com/agentclientprotocol/agent-client-protocol/releases/latest/download/schema.json)
- 参考实现：pi-acp（Rust）、官方 SDK（typescript/rust/java/kotlin/python 已 1.0）
