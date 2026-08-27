# acp-cj 设计文档

> 仓颉语言实现的 [Agent Client Protocol (ACP)](https://agentclientprotocol.com/protocol/v1/overview) 框架，
> 包含 **Agent 侧（服务端）** 与 **Client 侧（客户端）** 双向能力，以及面向
> [pi coding agent](https://pi.dev/docs/latest/rpc) 的真实桥接适配。

- 状态：设计中
- 协议版本：ACP **v1**（`protocolVersion: 1`）
- 依赖：`ystyle::jsonrpc` 0.7.3 + `jsonvalue`（与 [mcp-cj](../mcp-cj) 同构的分层架构）

---

## 1. 背景与目标

### 1.1 什么是 ACP

ACP 是 Zed 主导的开放协议，标准化**代码编辑器/客户端**与**AI 编码 Agent** 之间的通信：

- Agent（如 pi、claude-code）以**子进程**形式被 Client 拉起；
- 通信走 **JSON-RPC 2.0 over stdio**，消息按 `\n` 换行分隔（NDJSON 风格）；
- Agent 是请求的服务方（被 Client 调用 `initialize`、`session/new`、`session/prompt`…），
  但 Agent 也可以反向调用 Client 的方法（`terminal/*`、`fs/*`、`session/request_permission`）并发送 `session/update` 通知；
- 因此 ACP 是**双工 JSON-RPC**：两侧既可能是请求方，也可能是响应方。

### 1.2 目标

1. 提供一个与 `mcp-cj` 同等质量、同样风格的仓颉 ACP 框架：`acp` 包。
2. **Client 侧**：可作为任意 ACP Agent（真实使用 `pi-acp` 适配器 + `pi --mode rpc`）的客户端，
   完成 `initialize → session/new → session/prompt → 接收流式通知` 的完整交互。
3. **Agent（Server）侧**：实现一个 ACP 兼容的 Agent 服务端框架，并把 `session/prompt` 桥接到
   真实的 pi agent（`pi --mode rpc`），复刻 `pi-acp` 的翻译语义。
4. 遵循项目规范：TDD，新功能必须有仓颉单元测试；测试驱动提交。

### 1.3 非目标（v1 范围外）

- Streamable HTTP / WebSocket 传输（ACP 仍在草案阶段，v1 只要求 stdio）。
- 完整的 Elicitation（结构化表单）的 UI 侧实现：库层定义类型与模式，不做表单渲染。
- MCP over ACP 透传：类型上支持 `mcpServers` 字段的收发，但不实际建立 MCP 子进程连接。

---

## 2. 协议速览（v1）

### 2.1 角色与方法

| 方向 | 方法 | 类型 | 说明 |
|------|------|------|------|
| C→A | `initialize` | request | 版本/能力协商 |
| C→A | `authenticate` | request | 协议驱动认证（可选） |
| C→A | `logout` | request | 登出（可选，需能力） |
| C→A | `session/new` | request | 新建会话 |
| C→A | `session/load` | request | 加载历史会话（需 `loadSession`） |
| C→A | `session/resume` | request | 恢复会话不重放（需 `sessionCapabilities.resume`） |
| C→A | `session/list` | request | 列出会话（需 `sessionCapabilities.list`） |
| C→A | `session/delete` | request | 删除会话（需 `sessionCapabilities.delete`） |
| C→A | `session/close` | request | 关闭活动会话（需 `sessionCapabilities.close`） |
| C→A | `session/prompt` | request | 发起提示回合 |
| C→A | `session/set_mode` | request | 切换模式（可选） |
| C→A | `session/set_config_option` | request | 设置配置项（可选） |
| C→A | `session/cancel` | notification | 取消进行中的回合 |
| C→A | `$/cancel_request` | notification | 通用请求取消 |
| A→C | `session/update` | notification | 流式更新（核心） |
| A→C | `session/request_permission` | request | 请求用户授权工具执行 |
| A→C | `terminal/create` `terminal/output` `terminal/wait_for_exit` `terminal/kill` `terminal/release` | request | 客户端终端（需 `clientCapabilities.terminal`） |
| A→C | `fs/read_text_file` `fs/write_text_file` | request | 客户端文件系统（需 `clientCapabilities.fs.*`） |
| A→C | `elicitation/create` / `elicitation/complete` | request / notification | 结构化采集（需 `clientCapabilities.elicitation`） |

### 2.2 `session/update` 的判别（`sessionUpdate`）

```
user_message_chunk | agent_message_chunk | agent_thought_chunk
| tool_call | tool_call_update | plan | available_commands_update
| current_mode_update | config_option_update | session_info_update | usage_update
```

### 2.3 停止原因（StopReason）

`end_turn | max_tokens | max_turn_requests | refusal | cancelled`

### 2.4 错误码

JSON-RPC 标准错误（-32700/-32600/-32601/-32602/-32603）+ ACP 保留区间：
`-32800`（Request Cancelled）、`-32000`（Auth Required）、`-32002`（Resource Not Found）。

### 2.5 能力协商（Capabilities）

- **AgentCapabilities**：`loadSession`、`promptCapabilities{image,audio,embeddedContext}`、
  `mcpCapabilities{http,sse}`、`sessionCapabilities{list,delete,resume,close,additionalDirectories}`、`auth{logout}`。
- **ClientCapabilities**：`fs{readTextFile,writeTextFile}`、`terminal`、`auth{terminal}`、`elicitation`、`session{configOptions}`。

---

## 3. 架构设计

### 3.1 分层

与 mcp-cj 保持一致的分层，直接复用同一套 JSON-RPC 引擎：

```
┌─────────────────────────────────────────────────────────┐
│  examples/（cli、testclient、pi-bridge-server…）          │
├─────────────────────────────────────────────────────────┤
│  acp.agent   AcpAgent（ACP 服务端框架，双工）             │
│  acp.client  AcpClient（ACP 客户端框架，双工）            │
├─────────────────────────────────────────────────────────┤
│  acp.pi      PiRpcProcess / 事件翻译（桥接真实 pi agent） │
├─────────────────────────────────────────────────────────┤
│  acp.transport  StdioTransport（按 \n 帧）               │
├─────────────────────────────────────────────────────────┤
│  acp.types   协议类型（JsonSerializable / Deserializable）│
├─────────────────────────────────────────────────────────┤
│  ystyle::jsonrpc 0.7.3   ← 复用 mcp-cj 同款 JSON-RPC 引擎 │
│  jsonvalue 1.1.0                                        │
└─────────────────────────────────────────────────────────┘
```

复用点（全部来自 `ystyle::jsonrpc` 0.7.3）：

| 能力 | jsonrpc 提供 | ACP 用途 |
|------|-------------|----------|
| 方法注册 / 分发 | `JsonRpcServer.register/registerAsync` | Agent 侧处理 `session/*` 等 |
| 主动调用对端 | `JsonRpcServer.request<req,res>` | Agent 侧调用 `terminal/*`、`fs/*` |
| 发送通知 | `JsonRpcServer.notify` | Agent 侧发送 `session/update` |
| 客户端调用 + 处理对端请求 | `JsonRpcClient.call` / `registerRequestHandler` | Client 侧调用方法、处理 agent 反向请求与通知 |
| 异步 handler | `registerAsync` | `session/prompt` 长时阻塞不卡接收线程 |
| 帧 | `NewlineFraming` | ACP stdio 换行帧 |

> **关键洞察**：jsonrpc 的 `JsonRpcServer` 与 `JsonRpcClient` 都支持"接收方主动请求对端"，
> 这正是 ACP 双工模型的基础——因此 **AcpAgent 基于 JsonRpcServer，AcpClient 基于 JsonRpcClient**，
> 且两端都暴露"调用对端方法 + 注册对端方法 handler"的能力。

### 3.2 双工抽象

为消除两端重复代码，库层提供统一的**连接句柄**：

```cangjie
public interface AcpPeer {
    // 请求对端方法（双向都可用）
    func request<T, R>(method: String, params!: ?T, timeout!: Duration): Result<R>
    // 发通知
    func notify<T>(method: String, params!: ?T): Unit
    // 注册对端方法的处理器（双向都可用）
    func on(method: String, handler: AcpHandlerFunc): Unit
}
```

`AcpAgent` / `AcpClient` 都组合一个 `AcpPeer`，差异仅在各自注册的内置方法与对外 API。

### 3.3 并发模型

- `session/prompt` 用 `registerAsync` 注册：**异步 handler 在独立线程执行**，
  接收线程保持空闲，从而能同时处理 `$/cancel_request`、其他会话的请求、以及 agent 反向调用 client 方法的响应。
- 单个 Agent 进程内允许多会话并行，但**每个会话同一时刻至多一个进行中的回合**（prompt 串行，后续排队）。
- `session/update` 通知发送需串行化（链式 promise/锁），保证通知顺序。

---

## 4. 模块与文件规划

```
acp-cj/
├── cjpm.toml
├── README.md
├── docs/
│   ├── design.md            ← 本文档
│   ├── schema/schema.json   ← 官方 schema（已收集）
│   └── protocol-notes.md    ← 协议要点笔记
└── src/
    ├── root.cj              # package acp 聚合导出
    ├── types/
    │   ├── types.cj         # 基础：Implementation、RequestId、ErrorCode、SessionId、_meta
    │   ├── content.cj       # ContentBlock（text/image/audio/resource/resource_link）
    │   ├── capabilities.cj  # AgentCapabilities / ClientCapabilities / PromptCapabilities 等
    │   ├── tool.cj          # ToolCall / ToolCallUpdate / ToolKind / ToolCallStatus / ToolCallContent
    │   ├── update.cj        # SessionUpdate（11 种判别变体）与子结构 Plan/UsageUpdate/…
    │   ├── messages.cj      # InitializeRequest/Response、NewSessionRequest/Response、PromptRequest/Response…
    │   ├── mcp.cj           # McpServer / EnvVariable / HttpHeader
    │   ├── session.cj       # SessionInfo / SessionModeState / SessionConfigOption…
    │   ├── auth.cj          # AuthMethod / AuthCapabilities
    │   └── elicitation.cj   # ElicitationSchema / 相关类型（类型定义级）
    ├── transport/stdio.cj   # StdioTransport（双向，\n 帧）
    ├── peer.cj              # AcpPeer 双工抽象 + AcpPeerImpl
    ├── agent.cj             # AcpAgent：ACP 服务端框架
    ├── client.cj            # AcpClient：ACP 客户端框架
    ├── pi/
    │   ├── process.cj       # PiRpcProcess：spawn `pi --mode rpc`，命令/事件
    │   ├── command.cj       # pi RPC 命令与响应模型
    │   └── translate.cj     # pi 事件 ↔ ACP session/update 翻译
    └── examples/
        ├── pi_bridge/       # 真实 Agent：ACP stdio 服务端 + pi 桥接（对标 pi-acp）
        ├── testclient/      # 真实 Client：连接 pi-acp / acp-cj，打印流式输出
        └── echo_agent/      # 无 LLM 的 echo agent，用于纯协议冒烟测试
```

包名：`acp`，依赖 `ystyle::jsonrpc = "0.7.3"`、`jsonvalue = "1.1.0"`、`sonyflake`（ID 生成）。

---

## 5. 核心类型设计（types）

> 遵循 AGENTS.md：**固定结构的类实现 `json.stream` 序列化接口**（`JsonSerializable & JsonDeserializable<T>`），
> 不使用 `jsonvalue` 动态解析。

### 5.1 ContentBlock（与 MCP 同构）

```cangjie
public enum ContentBlockType { Text, Image, Audio, Resource, ResourceLink }
public class ContentBlock <: JsonSerializable & JsonDeserializable<ContentBlock> {
    public var type: ContentBlockType
    // text
    public var text: ?String
    // image/audio
    public var data: ?String          // base64
    public var mimeType: ?String
    public var uri: ?String
    // resource
    public var resource: ?EmbeddedResource
    // resource_link
    public var name: ?String
    public var size: ?Int64
    // 通用
    public var annotations: ?Annotations
}
```

> ACP 的 `ContentBlock` 与 MCP 完全一致，因此可复刻 mcp-cj `src/types/content.cj` 的结构，
> 仅在 `resource_link`（size/name/description/title）与 `resource`（text/blob）上按 ACP schema 补齐。

### 5.2 SessionUpdate（判别联合）

用 `sessionUpdate` 字符串判别；库层提供**半结构化**表示 + 便捷构造函数：

```cangjie
public class SessionUpdate <: JsonSerializable & JsonDeserializable<SessionUpdate> {
    public var sessionUpdate: String               // 判别字段
    public var content: ?ContentBlock              // user/agent/thought chunk
    public var messageId: ?String
    public var toolCallId: ?String
    public var title: ?String
    public var kind: ?String                       // ToolKind 字符串
    public var status: ?String                     // ToolCallStatus 字符串
    public var contentList: ?ArrayList<ToolCallContent>   // tool_call 的 content
    public var locations: ?ArrayList<ToolCallLocation>
    public var rawInput: ?JsonValue
    public var rawOutput: ?JsonValue
    public var entries: ?ArrayList<PlanEntry>      // plan
    public var availableCommands: ?ArrayList<AvailableCommand>
    public var currentModeId: ?String
    public var configOptions: ?ArrayList<SessionConfigOption>
    public var used: ?UInt64
    public var size: ?UInt64
    public var cost: ?Cost
    public var title2: ?String                     // session_info_update.title
    public var updatedAt: ?String
    public var _meta: ?JsonValue
}
```

同时提供类型安全的分发：`update.kind()` 返回一个内部枚举，
使用者可按枚举 `match` 处理，而不是手拼字符串。

### 5.3 请求/响应消息

为每个 ACP 方法定义 `XxxRequest` / `XxxResponse`（均实现序列化接口）：

- `InitializeRequest` / `InitializeResponse`
- `NewSessionRequest` / `NewSessionResponse`（含 `modes`、`configOptions`）
- `LoadSessionRequest/Response`、`ResumeSessionRequest/Response`、`ListSessionsRequest/Response`、
  `DeleteSessionRequest/Response`、`CloseSessionRequest/Response`
- `PromptRequest` / `PromptResponse`（`stopReason`）
- `CancelNotification`、`CancelRequestNotification`
- `SetSessionModeRequest/Response`、`SetSessionConfigOptionRequest/Response`
- `RequestPermissionRequest/Response`（含 `RequestPermissionOutcome`）
- `ReadTextFileRequest/Response`、`WriteTextFileRequest/Response`
- `CreateTerminalRequest/Response`、`TerminalOutputRequest/Response`、`WaitForTerminalExitRequest/Response`、
  `KillTerminalRequest/Response`、`ReleaseTerminalRequest/Response`
- `AuthenticateRequest/Response`、`LogoutRequest/Response`

---

## 6. Client 侧设计（AcpClient）

### 6.1 职责

```cangjie
public class AcpClient {
    // 生命周期
    func connect(clientInfo: Implementation, protocolVersion!: Int64, clientCapabilities!: ClientCapabilities): Result<InitializeResponse>
    func close(): Unit
    // 会话
    func newSession(cwd: String, mcpServers!: ArrayList<McpServer>): Result<NewSessionResponse>
    func loadSession(sessionId: String, cwd: String, ...): Result<LoadSessionResponse>
    func listSessions(...): Result<ListSessionsResponse>
    func deleteSession(...): Result<...>
    func closeSession(...): Result<...>
    func prompt(sessionId: String, prompt: ArrayList<ContentBlock>, timeout!: Duration): Result<PromptResponse>
    func cancel(sessionId: String): Unit          // session/cancel 通知
    // 通知/反向请求
    func setOnSessionUpdate(cb: (String /*sessionId*/, SessionUpdate) -> Unit): Unit
    func setOnRequestPermission(cb: (PermissionRequest) -> PermissionOutcome): Unit
    // 可配置：agent 反向调用 client 方法（terminal/fs）的默认实现
}
```

### 6.2 传输

`StdioTransport` 支持两种构造：

1. **服务当前进程的 stdin/stdout**（当 acp-cj 作为 Agent 时用）；
2. **spawn 外部命令**（当 acp-cj 作为 Client 拉取 pi-acp / 任意 ACP agent 时用）。

```cangjie
public class StdioTransport <: Transport {
    public init() {}                              // 绑定当前进程 stdio
    public init(command: String, args: Array<String>, env!: ?HashMap<String,String>)  // spawn 子进程
}
```

帧使用 `NewlineFraming()`（ACP 规定 `\n` 分隔，消息内不得含换行）。

### 6.3 与真实 pi-acp 对接的握手

```text
AcpClient.connect(...)
  └─ rpc "initialize" {protocolVersion:1, clientInfo, clientCapabilities}
AcpClient.newSession(cwd, [])
  └─ rpc "session/new" {cwd}                    → {sessionId}
AcpClient.prompt(sessionId, [text])
  └─ rpc "session/prompt"                       → {stopReason}
  └─ 同时收到 agent 的 session/update 通知流（在 receiveLoop 回调中分发）
AcpClient.cancel(sessionId)                     // 通知
```

---

## 7. Agent（Server）侧设计（AcpAgent）

### 7.1 职责

```cangjie
public class AcpAgent {
    public func addHandler(method: String, handler: ...)   // 扩展自定义方法（_ 前缀）
    public func sessionUpdate(sessionId: String, update: SessionUpdate): Unit   // 主动推送
    public func requestPermission(sessionId: String, toolCall: ToolCallUpdate, options: ArrayList<PermissionOption>): Result<RequestPermissionOutcome>
    public func terminal(..) / fs(..)                      // 调用 client 侧能力（可选便捷封装）
    public func serve() / start() / close()
    public var capabilities: AgentCapabilities             // 自定义声明
    public var sessionHandlers: 会话生命周期钩子           // onNewSession / onPrompt / onCancel
}
```

内置注册：

| 方法 | 处理 |
|------|------|
| `initialize` | 版本协商 + 返回 agentInfo/capabilities/authMethods |
| `session/new` | 创建会话上下文，调用 `onNewSession` 钩子，返回 `sessionId` |
| `session/load` `session/resume` | 若声明能力则走存储恢复 |
| `session/list` `session/delete` | 若声明能力 |
| `session/close` | 取消活动回合并释放资源 |
| `session/prompt` | **async handler**：调 `onPrompt(sessionId, prompt, emit)`，期间可任意 `emit(SessionUpdate)`，结束时返回 stopReason |
| `session/cancel` | 通知：调 `onCancel`，当前 prompt 返回 `cancelled` stop reason |
| `session/set_mode` / `session/set_config_option` | 若声明能力 |
| `$/cancel_request` | 通用请求取消（尽力而为） |

`onPrompt` 钩子签名（由使用者实现，pi 桥接即在此接入）：

```cangjie
public type PromptHandler = (String sessionId, ArrayList<ContentBlock> prompt,
                             (SessionUpdate) -> Unit emit, // 推送更新
                             () -> Bool isCancelled) => PromptResponse
```

### 7.2 会话状态机

```
created(初始) → active(可 prompt)
active ──session/prompt──▶ turn_running ──完成──▶ active
turn_running ──session/cancel──▶ aborting ──▶ active（prompt 响应 cancelled）
active/任何状态 ──session/close──▶ closed（释放资源）
```

### 7.3 与 pi 的桥接（`acp.pi`）

`AcpAgent` 默认不绑定任何 LLM；`examples/pi_bridge` 通过 `onPrompt` 接入 pi：

```
ACP client ── session/prompt(text) ──▶ pi_bridge
   └─ PiRpcProcess.prompt(text)           # 向 `pi --mode rpc` 发 {type:"prompt"}
   └─ pi 事件（message_update / tool_execution_* / agent_end / agent_settled…）
        └─ translate → ACP session/update（agent_message_chunk / tool_call / tool_call_update…）
pi 流结束后 ──▶ 返回 PromptResponse{stopReason: end_turn}
```

`PiRpcProcess` 封装（参照 pi-acp `src/pi-rpc/process.ts`）：

```cangjie
public class PiRpcProcess {
    public static func spawn(cwd: String, sessionPath!: ?String, piCommand!: ?String): Result<PiRpcProcess>
    public func prompt(message: String, images: ArrayList<PiImage>): Result<Unit>   // 响应=接受确认
    public func abort(): Result<Unit>
    public func getState() / getAvailableModels() / setModel() / setThinkingLevel() ...
    public func onEvent(cb: (JsonValue /*pi event*/) -> Unit): Unit
    public func dispose(): Unit
}
```

翻译层 `translate.cj`（对标 pi-acp `src/acp/translate/*`）核心映射：

| pi 事件 | ACP 通知 |
|--------|----------|
| `message_update` + `assistantMessageEvent.text_delta` | `agent_message_chunk` {text} |
| `message_update` + `thinking_delta` | `agent_thought_chunk` {text} |
| `message_update` + `toolcall_start/delta/end` | `tool_call`（pending，含 rawInput/locations） |
| `tool_execution_start` | `tool_call_update`（in_progress，bash 带 terminal content） |
| `tool_execution_update` | `tool_call_update`（in_progress + 增量输出） |
| `tool_execution_end` | `tool_call_update`（completed/failed + content） |
| `extension_ui_request`（select/confirm…） | `session/request_permission`（client 决定） |
| `agent_end` / `agent_settled` | 回合结束信号，决定 `stopReason` |

---

## 8. 测试策略

### 8.1 单元测试（cjpm test，TDD）

- **types**：每个类型 `toJson` → `fromJson` 往返一致；判别字段解析正确；边界（缺字段/多余字段/null）。
- **transport**：`StdioTransport` 在本地 pipe 上收发 `\n` 帧；内容含多行字符串时不裂帧。
- **peer/agent/client**：用**内存管道对**（in-process）把 `AcpAgent` 与 `AcpClient` 连起来，
  走完整握手 → 会话 → prompt → 通知 → cancel 闭环，不依赖外部进程。
- **pi/translate**：喂入固定 pi 事件 JSON，断言翻译出的 `SessionUpdate` 结构与字段值。

### 8.2 集成测试（真实环境）

**阶段一（Client 测真实 pi agent）**：

```bash
# 启动真实 ACP agent：pi-acp 适配器（内部 spawn `pi --mode rpc`）
node $(npm root -g)/pi-acp/dist/index.js

# acp-cj 的 testclient 连接它
cjpm run acp.examples.testclient -- --agent pi-acp
#   └─ initialize → session/new(cwd) → prompt("Hello") → 打印流式文本 → end_turn
```

需要真实 API key 的场景放行；无 key 时验证握手/会话创建/`auth_required` 错误语义即可。

**阶段二（Server 测）**：用阶段一的 `testclient` 连接 **acp-cj 的 `pi_bridge` server**，
验证 acp-cj server ↔ acp-cj client 全链路；同时用真实 Zed 或 pi-acp 的 client 语义做交叉验证。

### 8.3 协议合规冒烟

`echo_agent`（不接 LLM）：收到 prompt 立即回 `agent_message_chunk` 并返回 `end_turn`，
用于测试 client 与 server 的协议合规性（不消耗 API）。

---

## 9. 分阶段实施

| 阶段 | 内容 | 验收 |
|------|------|------|
| P0 | 项目骨架 + types 全部类型 + 单测 | `cjpm test` 全绿 |
| P1 | StdioTransport + AcpPeer + AcpClient | 单测通过（内存管道） |
| P2 | **Client ↔ 真实 pi-acp + pi** | testclient 打印出真实 LLM 流式回复 |
| P3 | AcpAgent 框架 + echo_agent | 单测通过 + echo 闭环 |
| P4 | pi 桥接（PiRpcProcess + translate） | testclient ↔ pi_bridge 真实对话成功 |
| P5 | 可选能力补齐（load/resume/list/delete/close、modes、config options） | 单测 + 集成 |
| P6 | README / docs 收尾 / 合并 master | 文档完整，提交记录清晰 |

当前进度：P0 资料收集完成，正在设计确认。

---

## 10. 风险与权衡

1. **jsonrpc 库的通知分发**：`JsonRpcClient` 通知回调是 `Notification -> Unit`；
   `session/update` 需从 `Notification` 中解析 `params.sessionId` 与 `params.update`，再转 `SessionUpdate`。
   —— AcpClient 内部做一层适配，把 ACP 通知标准化后回调给用户。
2. **`session/prompt` 的长时间阻塞**：必须用 `registerAsync`，否则 `session/cancel` 无法到达。
   jsonrpc 0.7.2 已支持 `registerAsync`，无风险。
3. **`JsonRpcServer.request` 的并发限制**：0.7.2 的 server 主动 request 是单挂起（`pendingRequest`），
   同一时刻只能有一个 server→client 请求在途。pi 桥接中 `request_permission`/`terminal` 调用需排队串行。
4. **pi 输出中的 ANSI / 前置信息**：`pi --mode rpc` 可能在 NDJSON 前输出人类可读信息，
   需剥离并缓存（对标 pi-acp `preludeLines`）。
5. **多会话单 subprocess 策略**：对标 pi-acp，同一 ACP 连接内保持一个活跃 pi 子进程
   （`closeAllExcept`），避免泄漏。

---

## 11. 参考资料

- ACP 官方：https://agentclientprotocol.com/protocol/v1/overview
- 官方 schema：`docs/schema/schema.json`（GitHub release 最新）
- pi RPC：https://pi.dev/docs/latest/rpc
- pi-acp 参考实现：https://github.com/svkozak/pi-acp（MIT，源码）
- 复用库：`ystyle::jsonrpc` 0.7.3（中心仓，含 `registerAsyncErr` + `HandlerContext.requestId`）、`jsonvalue`、`sonyflake`
