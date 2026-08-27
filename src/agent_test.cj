package acp

import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.{Result}
import std.collection.*
import std.sync.*

// ===================== Agent 单元测试 =====================
// 使用内存管道对：AcpClient(pipe.a()) ↔ AcpAgent(pipe.b())

// 构造一个带 echo prompt handler 的 AcpAgent
func makeEchoAgent(pair: PipePair): AcpAgent {
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.capabilities.loadSession = true
    agent.capabilities.sessionCapabilities.list = Some(EmptyCapability())
    agent.setPromptHandler({ ctx =>
        ctx.emit(SessionUpdate.agentMessage("echo: " + ctx.getText()))
        PromptResponse(StopReasonEndTurn)
    })
    agent.start()
    agent
}

@Test
public func agent_connect_new_session_prompt() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    let client = AcpClient(pair.a())

    // 收集通知
    let received = ArrayList<String>()
    client.setOnSessionUpdate({ sid, update =>
        if (update.sessionUpdate == SessionUpdateAgentMessageChunk) {
            match (update.content) {
                case Some(c) => received.add(c.text ?? "")
                case None => ()
            }
        }
    })

    let initResult = client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    match (initResult) {
        case Result.Ok(resp) =>
            @Expect(resp.protocolVersion, 1)
            match (resp.agentInfo) {
                case Some(info) => @Expect(info.name, "test-agent")
                case None => @Fail("agentInfo is None")
            }
            @Expect(resp.agentCapabilities.loadSession, true)
        case Result.Err(e) => @Fail("connect failed: ${e}")
    }

    let newResult = client.newSession("/tmp/proj")
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    @Expect(sessionId.startsWith("sess_"), true)

    let pResult = client.promptText(sessionId, "hi")
    match (pResult) {
        case Result.Ok(resp) => @Expect(resp.stopReason, StopReasonEndTurn)
        case Result.Err(e) => @Fail("prompt failed: ${e}")
    }
    var tries: Int64 = 0
    while (received.size == 0 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(received.size, 1)
    @Expect(received[0], "echo: hi")

    client.close()
    agent.close()
}

@Test
public func agent_prompt_unknown_session_errors() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    let pResult = client.promptText("sess_unknown", "hi")
    match (pResult) {
        case Result.Ok(_) => @Fail("expected error for unknown session")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }
    client.close()
    agent.close()
}

@Test
public func agent_cancel_prompt_returns_cancelled() {
    let pair = PipePair()
    // 慢速 handler：检测到取消后停止
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx =>
        // 模拟长时间工作：轮询取消标志
        while (!ctx.isCancelled()) {
            sleep(10 * Duration.millisecond)
        }
        PromptResponse(StopReasonCancelled)
    })
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    let newResult = client.newSession("/tmp/proj")
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }

    // 在另一个线程发 prompt（会阻塞直到取消）
    let resultBox = ArrayList<Result<PromptResponse>>()
    spawn {
        let r = client.promptText(sessionId, "long task", timeout: 30 * Duration.second)
        resultBox.add(r)
    }
    sleep(200 * Duration.millisecond)
    client.cancel(sessionId)

    var tries: Int64 = 0
    while (resultBox.size == 0 && tries < 200) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(resultBox.size, 1)
    match (resultBox[0]) {
        case Result.Ok(resp) => @Expect(resp.stopReason, StopReasonCancelled)
        case Result.Err(e) => @Fail("prompt should not error on cancel: ${e}")
    }
    client.close()
    agent.close()
}

@Test
public func agent_request_permission_roundtrip() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // client 处理 session/request_permission 请求
    client.on("session/request_permission", { params =>
        let req = JsonValue.toObject<RequestPermissionRequest>(params)
        let resp = RequestPermissionResponse(RequestPermissionOutcome.selected(req.options[0].optionId))
        Some(JsonValue.fromObject(resp))
    })

    let newResult = client.newSession("/tmp/proj")
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }

    // agent 调用 client 的 request_permission
    let toolCall = ToolCallUpdate()
    toolCall.toolCallId = "call_1"
    toolCall.title = Some("Run command")
    toolCall.kind = Some(ToolKindExecute)
    toolCall.status = Some(ToolStatusPending)
    let options = ArrayList<PermissionOption>()
    options.add(PermissionOption("allow-once", "Allow once", "allow_once"))
    options.add(PermissionOption("reject-once", "Reject", "reject_once"))

    let permResult = agent.requestPermission(sessionId, toolCall, options)
    match (permResult) {
        case Result.Ok(resp) =>
            @Expect(resp.outcome.outcome, "selected")
            @Expect(resp.outcome.optionId, Some("allow-once"))
        case Result.Err(e) => @Fail("requestPermission failed: ${e}")
    }
    client.close()
    agent.close()
}
