# acp-cj

仓颉语言实现的 [Agent Client Protocol (ACP)](https://agentclientprotocol.com/protocol/v1/overview) 框架，包含：

- **Agent 侧（服务端）**：`AcpAgent` —— 实现 ACP Agent 接口，可作为子进程被任意 ACP Client（如 Zed、opencode）拉起。
- **Client 侧（客户端）**：`AcpClient` —— 连接任意 ACP Agent，完成握手、会话、提示回合与流式通知。
- **桥接示例**：`pi_bridge` —— 用 `AcpAgent` + `AcpClient` 组合成 ACP 代理，把请求桥接到真实 LLM agent（opencode）。

基于 `ystyle::jsonrpc` + `jsonvalue` 分层架构（与 [mcp-cj](../mcp-cj) 同构），支持 ACP 协议版本 **v1**。

## 架构

```
┌───────────────────────────────────────────────┐
│  examples/（testclient、pi_bridge）            │
├───────────────────────────────────────────────┤
│  acp.agent  AcpAgent（ACP 服务端框架，双工）    │
│  acp.client AcpClient（ACP 客户端框架，双工）   │
├───────────────────────────────────────────────┤
│  acp.transport  StdioTransport / SubprocessTransport（\n 帧）│
├───────────────────────────────────────────────┤
│  acp.types   协议类型（ContentBlock、SessionUpdate…）│
├───────────────────────────────────────────────┤
│  ystyle::jsonrpc 0.7.3（注册表依赖，含 registerAsyncErr）│
│  jsonvalue / sonyflake                        │
└───────────────────────────────────────────────┘
```

## 安装

```toml
[dependencies]
  acp = "0.1.1"   # 中心仓版本；本地开发可用 { path = "../acp-cj" }
```

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build
```

## 快速开始：实现一个 ACP Agent（服务端）

```cangjie
import acp.*
import acp.types.*
import acp.transport.*

main() {
    let agent = AcpAgent(StdioTransport(), "my-agent", "1.0.0")
    agent.setPromptHandler({ ctx =>
        ctx.emit(SessionUpdate.agentMessage("你好！你说了：" + ctx.getText()))
        PromptResponse(StopReasonEndTurn)
    })
    agent.serve()   // 阻塞监听 stdin（ACP Client 通过 stdio 连接）
}
```

## 快速开始：连接一个 ACP Agent（客户端）

```cangjie
import acp.*
import acp.types.*
import acp.transport.*
import std.collection.ArrayList

main() {
    let client = AcpClient(SubprocessTransport("opencode", args: ["acp"]))

    client.setOnSessionUpdate({ sid, update =>
        // 流式输出
        if (update.sessionUpdate == SessionUpdateAgentMessageChunk) {
            match (update.content) {
                case Some(c) => print(c.text ?? "")
                case None => ()
            }
        }
    })

    client.connect(Implementation("my-client", "1.0.0"), ClientCapabilities())
    let newResp = client.newSession("/path/to/project")  // Result<NewSessionResponse>
    let sessionId = newResp.getOrThrow().sessionId
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ofText("你好"))
    let resp = client.prompt(sessionId, blocks)  // Result<PromptResponse>，阻塞到回合结束
    println(resp.getOrThrow().stopReason)
}
```

## API 一览

### AcpAgent（服务端）

| 方法 | 说明 |
|------|------|
| `init(transport, name, version)` | 创建 ACP Agent |
| `setPromptHandler(handler)` | 注册提示回合处理器（核心） |
| `setOnNewSession / setOnCancel / setOnClose` | 会话生命周期钩子 |
| `setOnSetMode / setOnSetConfigOption` | 模式 / 配置项钩子（可选能力） |
| `setOnListSessions / setOnLoadSession / setOnDeleteSession` | 会话管理钩子 |
| `sessionUpdate(sessionId, update)` | 主动推送 session/update 通知 |
| `requestPermission / createTerminal / readTextFile …` | 反向调用 Client 的 terminal/fs/permission 方法 |
| `serve() / start() / close()` | 生命周期 |

### AcpClient（客户端）

| 方法 | 说明 |
|------|------|
| `connect(clientInfo, caps)` | initialize 握手 |
| `newSession / loadSession / resumeSession` | 会话创建 / 加载 / 恢复 |
| `listSessions / deleteSession / closeSession` | 会话管理 |
| `prompt / promptText / cancel` | 提示回合与取消 |
| `setMode / setConfigOption` | 模式 / 配置项 |
| `authenticate / logout` | 认证 |
| `setOnSessionUpdate(cb)` | 流式通知回调 |
| `on(method, handler)` | 处理 Agent 反向请求（request_permission 等） |

### Transport

| 实现 | 说明 |
|------|------|
| `StdioTransport` | 绑定当前进程 stdio（Agent 侧） |
| `SubprocessTransport` | spawn 子进程（Client 侧拉取任意 ACP agent） |

> 传输按 `\n` 帧（ACP stdio 规范），复用 `jsonrpc` 的 `NewlineFraming`。

## 示例

| 示例 | 说明 |
|------|------|
| `testclient` | ACP 客户端 CLI：`testclient "opencode acp" /tmp "hello"` |
| `pi_bridge` | ACP 代理：作为服务端接收请求，桥接到真实 agent（默认 opencode） |

```bash
# 构建
cjpm build -j 16

# 端到端测试：Client ↔ Server（echo）以及完整代理链（接真实 LLM）
./scripts/test-e2e-bridge.sh

# 直接连 opencode 的 ACP 模式
export XDG_DATA_HOME=$PWD/.opencode-data
./target/release/bin/acp.examples.testclient "opencode acp" /tmp "hello"
```

## 协议支持

| 能力 | 状态 |
|------|------|
| `initialize`（版本/能力协商） | ✅ |
| `session/new` | ✅ |
| `session/prompt` + `session/update` 流式通知 | ✅ |
| `session/cancel`（取消语义） | ✅ |
| `session/close` / `session/list` / `session/delete` | ✅（可选能力） |
| `session/load` / `session/resume` | ✅（钩子驱动，可选能力） |
| `session/set_mode` / `session/set_config_option` | ✅（可选能力） |
| `authenticate` / `logout` | ✅ |
| `session/request_permission`（Agent→Client 反向调用） | ✅ |
| `terminal/*` `fs/*`（Agent→Client 反向调用便捷封装） | ✅ |
| `$/cancel_request` | ✅ |
| `elicitation/create` · `elicitation/complete` | ❌ 未实现（仅 `clientCapabilities.elicitation` 透传） |

> 📋 完整对照 ACP v1 规范的逐项支持矩阵、差距清单与 Roadmap 见 [支持矩阵](docs/support.md)。

`session/update` 判别：`user_message_chunk / agent_message_chunk / agent_thought_chunk / tool_call / tool_call_update / plan / available_commands_update / current_mode_update / config_option_update / session_info_update / usage_update` 全部支持。

## 测试

```bash
cjpm test -j 16 --no-progress   # 39 个单元测试（types 往返 / transport / client / agent）
./scripts/test-e2e-bridge.sh    # 真实环境端到端（需要 opencode + LLM key）
```

## 文档

- [设计文档](docs/design.md)
- [支持矩阵（ACP v1 功能对照 / 差距 Roadmap）](docs/support.md)
- [ACP 官方文档](https://agentclientprotocol.com/protocol/v1/overview)
- [官方 schema](docs/schema/schema.json)
- [pi-acp 参考实现](https://github.com/svkozak/pi-acp)

## License

MulanPSL-2.0
