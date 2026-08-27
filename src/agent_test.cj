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

// ===================== 可选方法测试 =====================

@Test
public func agent_set_mode_and_config_option() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    // set_mode 钩子：接受 "code" 和 "ask"
    agent.setOnSetMode({ sid, modeId =>
        modeId == "code" || modeId == "ask"
    })
    // set_config_option 钩子：只接受 "model"
    agent.setOnSetConfigOption({ sid, req =>
        if (req.configId == "model") {
            let opt = SessionConfigOption("model", "Model")
            opt.`type` = "select"
            opt.currentValue = req.value
            Some(ArrayList<SessionConfigOption>([opt]))
        } else {
            None
        }
    })
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    let sessionId = match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }

    // set_mode 成功
    match (client.setMode(sessionId, "code")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("setMode failed: ${e}")
    }
    // set_mode 失败（未知 mode）
    match (client.setMode(sessionId, "bogus")) {
        case Result.Ok(_) => @Fail("expected setMode error")
        case Result.Err(_) => ()
    }
    // set_config_option 成功
    match (client.setConfigOption(sessionId, "model", "model-2")) {
        case Result.Ok(resp) => @Expect(resp.configOptions.size, 1)
        case Result.Err(e) => @Fail("setConfigOption failed: ${e}")
    }
    // set_config_option 失败（未知 configId）
    match (client.setConfigOption(sessionId, "bogus", "x")) {
        case Result.Ok(_) => @Fail("expected setConfigOption error")
        case Result.Err(_) => ()
    }
    client.close()
    agent.close()
}

@Test
public func agent_load_and_delete_session() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setOnLoadSession({ req =>
        if (req.sessionId == "sess_existing") {
            let resp = LoadSessionResponse()
            Some(resp)
        } else {
            None
        }
    })
    agent.setOnDeleteSession({ sid => sid == "sess_existing" })
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // load 成功
    match (client.loadSession("sess_existing", "/tmp")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("loadSession failed: ${e}")
    }
    // load 失败
    match (client.loadSession("sess_missing", "/tmp")) {
        case Result.Ok(_) => @Fail("expected loadSession error")
        case Result.Err(_) => ()
    }
    // delete 成功
    match (client.deleteSession("sess_existing")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("deleteSession failed: ${e}")
    }
    // delete 失败
    match (client.deleteSession("sess_missing")) {
        case Result.Ok(_) => @Fail("expected deleteSession error")
        case Result.Err(_) => ()
    }
    // close 成功（有该会话）
    let sessionId = match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    match (client.closeSession(sessionId)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("closeSession failed: ${e}")
    }
    client.close()
    agent.close()
}

@Test
public func agent_usage_update_notification() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx =>
        let cost = Cost()
        cost.amount = 0.05
        cost.currency = "USD"
        ctx.emit(SessionUpdate.usageUpdate(53000, 200000, cost: Some(cost)))
        PromptResponse(StopReasonEndTurn)
    })
    agent.start()
    let client = AcpClient(pair.a())
    let usage = ArrayList<String>()
    client.setOnSessionUpdate({ sid, update =>
        if (update.sessionUpdate == SessionUpdateUsage) {
            usage.add("${update.used ?? 0}/${update.size ?? 0}")
        }
    })
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    let sessionId = match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    match (client.promptText(sessionId, "hi")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("prompt failed: ${e}")
    }
    var tries: Int64 = 0
    while (usage.size == 0 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(usage.size, 1)
    @Expect(usage[0], "53000/200000")
    client.close()
    agent.close()
}

// ===================== session/resume 与 $/cancel_request =====================

@Test
public func agent_resume_session() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setOnResumeSession({ req =>
        if (req.sessionId == "sess_keep") {
            Some(ResumeSessionResponse())
        } else {
            None
        }
    })
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // resume 成功
    match (client.resumeSession("sess_keep", "/tmp")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("resumeSession failed: ${e}")
    }
    // resume 失败（未知会话）
    match (client.resumeSession("sess_missing", "/tmp")) {
        case Result.Ok(_) => @Fail("expected resumeSession error")
        case Result.Err(_) => ()
    }
    client.close()
    agent.close()
}

@Test
public func agent_cancel_request_by_id() {
    let pair = PipePair()
    // 慢速 prompt handler：轮询取消标志
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx =>
        while (!ctx.isCancelled()) {
            sleep(10 * Duration.millisecond)
        }
        PromptResponse(StopReasonCancelled)
    })
    agent.start()

    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())  // id=1
    let sessionId = match (client.newSession("/tmp/proj")) {                       // id=2
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }

    // 发起 prompt（自动 id=3），阻塞在 spawn 线程
    let respBox = ArrayList<Result<PromptResponse>>()
    spawn {
        respBox.add(client.promptText(sessionId, "long task", timeout: 30 * Duration.second))
    }
    sleep(200 * Duration.millisecond)
    // $/cancel_request 按 id=3 取消（jsonrpc 自动 id：initialize=1, newSession=2, prompt=3）
    client.cancelRequest(JsonValue.Number(3.0))

    var tries: Int64 = 0
    while (respBox.size == 0 && tries < 200) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(respBox.size, 1)
    match (respBox[0]) {
        case Result.Ok(resp) => @Expect(resp.stopReason, StopReasonCancelled)
        case Result.Err(e) => @Fail("prompt should not error on cancel: ${e}")
    }
    client.close()
    agent.close()
}
