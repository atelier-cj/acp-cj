# ACP v1 协议要点笔记

> 摘自 `docs/raw/` 的官方文档与 `docs/schema/schema.json`，供实现参考。

## 1. 传输与帧

- JSON-RPC 2.0，消息按 `\n`（LF）分隔，消息内不得含嵌入换行。
- JSON 序列化会把文本内换行转义为 `\n`，因此换行帧可行。
- Agent 作为 Client 的子进程：Agent 读 stdin、写 stdout；日志走 stderr。
- Agent 的 stdout **只允许**输出合法 ACP 消息。

## 2. 双向方法

| 方向 | 方法 | 说明 |
|------|------|------|
| C→A | initialize | 版本协商 + 能力交换 |
| C→A | session/new | 建会话（cwd + mcpServers） |
| C→A | session/prompt | 提示回合（**长时阻塞**） |
| C→A | session/cancel | 通知：取消回合 → prompt 响应 cancelled |
| A→C | session/update | 通知：流式更新（判别见下） |
| A→C | session/request_permission | 请求工具授权 |

其余可选方法见 `docs/design.md`。

## 3. session/update 判别（sessionUpdate 字段）

```
user_message_chunk      content + messageId
agent_message_chunk     content + messageId
agent_thought_chunk     content + messageId
tool_call               toolCallId + title + kind + status + content[] + locations + rawInput
tool_call_update        toolCallId + 增量字段
plan                    entries[]
available_commands_update  availableCommands[]
current_mode_update     currentModeId
config_option_update    configOptions[]
session_info_update     title + updatedAt
usage_update            used + size + cost
```

## 4. 停止原因

```
end_turn | max_tokens | max_turn_requests | refusal | cancelled
```

取消时**必须**返回 `cancelled`（即使底层抛异常也要 catch 后返回该语义）。

## 5. 错误码（ACP 保留区间）

- `-32800` Request Cancelled
- `-32000` Auth Required（session/new 可能返回，数据含 authMethods）
- `-32002` Resource Not Found

标准 JSON-RPC：`-32700 / -32600 / -32601 / -32602 / -32603`。

## 6. 能力协商默认值

- AgentCapabilities 默认：`loadSession:false, promptCapabilities:{image,audio,embeddedContext:false}, mcpCapabilities:{http,sse:false}, sessionCapabilities:{}, auth:{}`
- ClientCapabilities 默认：`fs:{readTextFile,writeTextFile:false}, terminal:false, auth:{terminal:false}`
- 省略的字段一律视为不支持。

## 7. 关键实现决策（acp-cj）

1. **双工**：`AcpAgent` 基于 `JsonRpcServer`，`AcpClient` 基于 `JsonRpcClient`；两端都能"请求对端"与"注册对端方法 handler"。
2. **session/prompt 必须异步**：用 `registerAsyncErr`（jsonrpc 增强），否则 `session/cancel` 无法被接收线程处理。
3. **仓颉 stdin 陷阱**：`getStdIn().read(chunk)` 在管道模式会缓冲到 EOF；必须用 `readln()`（按行，正好匹配 ACP 换行帧）。
4. **`type` 是仓颉关键字**：协议字段 `type` 需写成 `` `type` ``。
5. **match 陷阱**：`case 大写常量 =>` 会被当作绑定模式（总是匹配）；字符串判别需用字面量 `case "tool_call" =>`。
6. **会话串行**：同一会话同一时刻一个进行中的回合（Mutex 保护）。
7. **jsonrpc 0.7.2 的 server.request 单挂起**：Agent→Client 反向调用需串行（`clientRequestLock`）。

## 8. 测试对象结论

- 沙箱环境 `~/.pi`（pi 的数据目录）与 `~/.local/share/opencode` 为只读，pi 无法工作。
- **opencode 1.18+ 的 `opencode acp` 是标准 ACP server**（stdio），且有配置好的模型（deepseek 等），是可靠的真实测试对象。
- 运行时需把 `XDG_DATA_HOME/STATE_HOME/CACHE_HOME` 指向可写目录，并预置 `auth.json`。
- acp-cj 的完整代理链已端到端验证：`testclient → pi_bridge(AcpAgent+AcpClient) → opencode → LLM`。
