package acp

import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.{Result, JsonRpcError, Transport}
import std.collection.*
import std.sync.*
import std.time.DateTime

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
        // ACP-ERROR-003：未知会话一律 -32002（data.sessionId 由下面的裸帧用例断言）
        case Result.Err(e) => @Expect(e.contains("-32002"), true)
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
    agent.setOnLoadSession({ req, complete, fail =>
        if (req.sessionId == "sess_existing") {
            complete(JsonValue.fromObject(LoadSessionResponse()))
        } else {
            fail(JsonRpcError(INVALID_PARAMS, "Unknown sessionId"))
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
    // delete 不存在的会话：静默成功（ACP-DELETE-002 幂等）
    match (client.deleteSession("sess_missing")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("deleting a missing session must succeed silently, got: ${e}")
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

// ===================== SessionStore =====================

@Test
public func session_store_persist_roundtrip() {
    let path = "/tmp/session-store-test.json"
    let store = SessionStore(path)
    store.upsert(SessionRecord("sess_1", "/proj/a", "backend_1", title: Some("proj a")))
    store.upsert(SessionRecord("sess_2", "/proj/b", "backend_2"))

    // 重新加载（模拟重启）应能恢复
    let store2 = SessionStore(path)
    let rec = match (store2.get("sess_1")) {
        case Some(r) => r
        case None => return @Fail("session not restored")
    }
    @Expect(rec.cwd, "/proj/a")
    @Expect(rec.backendSessionId, "backend_1")
    @Expect(rec.title, Some("proj a"))
    @Expect(store2.list().size, 2)

    // 删除后持久化
    store2.delete("sess_1")
    let store3 = SessionStore(path)
    @Expect(store3.get("sess_1").isNone(), true)
    @Expect(store3.get("sess_2").isSome(), true)
}

// ===================== 异步 session/load 重放 =====================

@Test
public func agent_load_replays_history_then_responds() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx =>
        ctx.emit(SessionUpdate.agentMessage("ok"))
        PromptResponse(StopReasonEndTurn)
    })
    agent.setOnLoadSession({ req, complete, fail =>
        // 重放历史：user message + agent reply（必须在 complete 之前全部发出）
        agent.sessionUpdate(req.sessionId, SessionUpdate.userMessageChunk(ContentBlock.ofText("what's up")))
        agent.sessionUpdate(req.sessionId, SessionUpdate.agentMessage("I'm fine"))
        complete(JsonValue.fromObject(LoadSessionResponse()))
    })
    agent.start()
    let client = AcpClient(pair.a())
    let replayed = ArrayList<String>()
    client.setOnSessionUpdate({ sid, update =>
        match (update.content) {
            case Some(c) =>
                match (c.text) {
                    case Some(t) => replayed.add(t)
                    case None => ()
                }
            case None => ()
        }
    })
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // load 成功：重放 2 条通知，然后响应
    match (client.loadSession("sess_old", "/tmp")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("loadSession failed: ${e}")
    }
    var tries: Int64 = 0
    while (replayed.size < 2 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(replayed.size, 2)
    @Expect(replayed[0], "what's up")
    @Expect(replayed[1], "I'm fine")

    // load 后该会话可用于 prompt（恢复的会话已注册）
    match (client.promptText("sess_old", "hi")) {
        case Result.Ok(resp) => @Expect(resp.stopReason, StopReasonEndTurn)
        case Result.Err(e) => @Fail("prompt after load failed: ${e}")
    }
    client.close()
    agent.close()
}

// ===================== P1: 认证 =====================

@Test
public func agent_auth_required_gating() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.authRequired = true
    agent.authMethods.add(AuthMethod())
    agent.authMethods[0].id = "pi_terminal_login"
    agent.authMethods[0].name = "Launch pi in the terminal"
    agent.authMethods[0].`type` = Some("terminal")
    agent.authMethods[0].args = Some(ArrayList<String>(["--terminal-login"]))
    // agent 型（默认）：走协议 authenticate 流程
    agent.authMethods.add(AuthMethod())
    agent.authMethods[1].id = "agent_login"
    agent.authMethods[1].name = "Agent login"
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // 未认证：session/new 应返回 -32000 auth_required
    match (client.newSession("/tmp/proj")) {
        case Result.Ok(_) => @Fail("expected auth_required error")
        case Result.Err(e) => @Expect(e.contains("-32000"), true)
    }

    // terminal 型方法不得走协议 authenticate（规范：Clients MUST NOT pass a terminal method）
    match (client.authenticate("pi_terminal_login")) {
        case Result.Ok(_) => @Fail("terminal method must not be protocol-authenticated")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }

    // 未广告的 methodId 应拒绝
    match (client.authenticate("no_such_method")) {
        case Result.Ok(_) => @Fail("unknown method must be rejected")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }

    // agent 型 authenticate 后：session/new 成功
    match (client.authenticate("agent_login")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("authenticate failed: ${e}")
    }
    match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => @Expect(resp.sessionId.startsWith("sess_"), true)
        case Result.Err(e) => @Fail("newSession after auth failed: ${e}")
    }
    client.close()
    agent.close()
}

@Test
public func agent_logout_clears_auth() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.authRequired = true
    agent.authMethods.add(AuthMethod())
    agent.authMethods[0].id = "m"
    agent.authMethods[0].name = "Agent login"
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // 登录
    match (client.authenticate("m")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("authenticate failed: ${e}")
    }
    // 登出
    match (client.logout()) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("logout failed: ${e}")
    }
    // 登出后再 session/new 应回到 auth_required
    match (client.newSession("/tmp/proj")) {
        case Result.Ok(_) => @Fail("expected auth_required after logout")
        case Result.Err(e) => @Expect(e.contains("-32000"), true)
    }
    client.close()
    agent.close()
}

@Test
public func client_terminal_login_exit_code() {
    let client = AcpClient(StdioTransport())
    let method = AuthMethod()
    method.id = "t"
    method.name = "test"
    method.`type` = Some("terminal")
    method.args = Some(ArrayList<String>(["-c", "exit 3"]))
    // 不初始化也能用（纯进程辅助）
    match (client.terminalLogin("sh", method)) {
        case Result.Ok(code) => @Expect(code, 3)
        case Result.Err(e) => @Fail("terminalLogin failed: ${e}")
    }
    // 成功退出码 0
    let method2 = AuthMethod()
    method2.id = "t2"
    method2.name = "test2"
    method2.`type` = Some("terminal")
    method2.args = Some(ArrayList<String>(["-c", "exit 0"]))
    match (client.terminalLogin("sh", method2)) {
        case Result.Ok(code) => @Expect(code, 0)
        case Result.Err(e) => @Fail("terminalLogin failed: ${e}")
    }
}

// ===================== clientCapabilities（宿主读取 + 1.1 透出） =====================

// initialize 后：AcpAgent 记录对端 clientCapabilities（宿主按能力决策的读取点）
@Test
public func agent_records_client_capabilities() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    let client = AcpClient(pair.a())

    // 声明支持 session.configOptions（select 之外的能力仅在此探测位）
    let caps = ClientCapabilities()
    caps.session = Some(ClientSessionCapabilities())
    let initResult = client.connect(Implementation("test-client", "1.0.0"), caps)
    match (initResult) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // 宿主视角：握手后（session/new 前）应能读到对端声明
    @Expect(agent.clientCapabilities.session.isSome(), true)
}


@Test
public func agent_preserves_client_capabilities() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx =>
        PromptResponse(StopReasonEndTurn)
    })
    agent.start()
    let client = AcpClient(pair.a())

    let caps = ClientCapabilities()
    caps.fs.readTextFile = true
    caps.fs.writeTextFile = true
    caps.terminal = true
    caps.auth.terminal = true
    match (client.connect(Implementation("test-client", "1.0.0"), caps)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // Agent 侧保存了客户端声明的能力（非 Option：未握手时空对象）
    let c = agent.clientCapabilities
    @Expect(c.fs.readTextFile, true)
    @Expect(c.fs.writeTextFile, true)
    @Expect(c.terminal, true)
    @Expect(c.auth.terminal, true)
    client.close()
    agent.close()
}

@Test
public func agent_prompt_context_can_query_client_caps() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    // prompt 处理器内查询客户端能力（规范要求调用 fs/terminal 前检查）
    let observed = ArrayList<String>()
    agent.setPromptHandler({ ctx =>
        observed.add("read=${ctx.canReadTextFile()}")
        observed.add("write=${ctx.canWriteTextFile()}")
        observed.add("terminal=${ctx.canUseTerminal()}")
        PromptResponse(StopReasonEndTurn)
    })
    agent.start()
    let client = AcpClient(pair.a())
    let caps = ClientCapabilities()
    caps.fs.readTextFile = true
    caps.terminal = true
    match (client.connect(Implementation("test-client", "1.0.0"), caps)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) =>
            let sid = resp.sessionId
            let blocks = ArrayList<ContentBlock>()
            blocks.add(ContentBlock.ofText("hi"))
            match (client.prompt(sid, blocks)) {
                case Result.Ok(_) => ()
                case Result.Err(e) => return @Fail("prompt failed: ${e}")
            }
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    @Expect(observed.contains("read=true"), true)
    @Expect(observed.contains("write=false"), true)
    @Expect(observed.contains("terminal=true"), true)
    client.close()
    agent.close()
}

// ===================== 1.3 扩展方法 =====================

@Test
public func agent_extension_method_roundtrip() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    // 注册 _ 前缀扩展方法：回显 params.echo
    agent.registerExtensionMethod("_ping", { params =>
        match (params["echo"]) {
            case Some(JsonValue.String(s)) => Some(JsonValue.String("pong:" + s))
            case _ => Some(JsonValue.String("pong:empty"))
        }
    })
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }

    // 正常调用
    let m = HashMap<String, JsonValue>()
    m["echo"] = JsonValue.String("hello")
    match (client.extensionCall("_ping", JsonValue.Map(m))) {
        case Result.Ok(v) =>
            match (v) {
                case JsonValue.String(s) => @Expect(s, "pong:hello")
                case _ => @Fail("unexpected result: ${v}")
            }
        case Result.Err(e) => @Fail("extensionCall failed: ${e}")
    }

    // 未注册方法 → -32601
    match (client.extensionCall("_nope", JsonValue.Map(HashMap<String, JsonValue>()))) {
        case Result.Ok(_) => @Fail("expected method not found")
        case Result.Err(e) => @Expect(e.contains("-32601"), true)
    }
    client.close()
    agent.close()
}

@Test
public func agent_extension_method_must_start_with_underscore() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    var threw = false
    try {
        agent.registerExtensionMethod("session/new", { params => None })
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)
    agent.close()
}

// ===================== 1.5 Client 侧类型化反向 handler =====================

@Test
public func agent_typed_reverse_handlers_roundtrip() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // Client 侧类型化注册（C2）：全部 8 类反向方法
    client.setOnRequestPermission({ req =>
        RequestPermissionResponse(RequestPermissionOutcome.selected(req.options[0].optionId))
    })
    client.setOnReadTextFile({ req =>
        let r = ReadTextFileResponse()
        r.content = "content of ${req.path}"
        r
    })
    client.setOnWriteTextFile({ req => EmptyResult() })
    client.setOnCreateTerminal({ req =>
        let r = CreateTerminalResponse()
        r.terminalId = "term_" + req.command
        r
    })
    client.setOnTerminalOutput({ req =>
        let r = TerminalOutputResponse()
        r.output = "out of ${req.terminalId}"
        r
    })
    client.setOnTerminalWaitForExit({ req =>
        let r = WaitForTerminalExitResponse()
        r.exitCode = Some(0)
        r
    })
    client.setOnTerminalKill({ req => EmptyResult() })
    client.setOnTerminalRelease({ req => EmptyResult() })

    match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => ()
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    let sid = "sess_typed"

    // request_permission
    let toolCall = ToolCallUpdate()
    toolCall.toolCallId = "call_1"
    toolCall.title = Some("Run")
    toolCall.kind = Some(ToolKindExecute)
    toolCall.status = Some(ToolStatusPending)
    let options = ArrayList<PermissionOption>()
    options.add(PermissionOption("allow-once", "Allow once", "allow_once"))
    match (agent.requestPermission(sid, toolCall, options)) {
        case Result.Ok(resp) =>
            @Expect(resp.outcome.outcome, "selected")
            @Expect(resp.outcome.optionId, Some("allow-once"))
        case Result.Err(e) => return @Fail("requestPermission failed: ${e}")
    }

    // fs
    let rd = ReadTextFileRequest()
    rd.sessionId = sid
    rd.path = "/tmp/a.txt"
    match (agent.readTextFile(rd)) {
        case Result.Ok(resp) => @Expect(resp.content, "content of /tmp/a.txt")
        case Result.Err(e) => return @Fail("readTextFile failed: ${e}")
    }
    let wr = WriteTextFileRequest()
    wr.sessionId = sid
    wr.path = "/tmp/a.txt"
    wr.content = "hi"
    match (agent.writeTextFile(wr)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("writeTextFile failed: ${e}")
    }

    // terminal
    let ct = CreateTerminalRequest()
    ct.sessionId = sid
    ct.command = "ls"
    match (agent.createTerminal(ct)) {
        case Result.Ok(resp) => @Expect(resp.terminalId, "term_ls")
        case Result.Err(e) => return @Fail("createTerminal failed: ${e}")
    }
    let tid1 = TerminalIdRequest()
    tid1.sessionId = sid
    tid1.terminalId = "t1"
    match (agent.terminalOutput(tid1)) {
        case Result.Ok(resp) => @Expect(resp.output, "out of t1")
        case Result.Err(e) => return @Fail("terminalOutput failed: ${e}")
    }
    let tid2 = TerminalIdRequest()
    tid2.sessionId = sid
    tid2.terminalId = "t1"
    match (agent.terminalWaitForExit(tid2)) {
        case Result.Ok(resp) => @Expect(resp.exitCode, Some(0))
        case Result.Err(e) => return @Fail("terminalWaitForExit failed: ${e}")
    }
    let tid3 = TerminalIdRequest()
    tid3.sessionId = sid
    tid3.terminalId = "t1"
    match (agent.terminalKill(tid3)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("terminalKill failed: ${e}")
    }
    let tid4 = TerminalIdRequest()
    tid4.sessionId = sid
    tid4.terminalId = "t1"
    match (agent.terminalRelease(tid4)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("terminalRelease failed: ${e}")
    }
    client.close()
    agent.close()
}

// ===================== 1.55 反向调用并发（jsonrpc 0.7.5：撤掉串行锁） =====================
//
// 此前 jsonrpc ≤0.7.4 的 `JsonRpcServer.request()` 只有一个挂起槽（id 恒为 0），并发在飞会
// 丢响应/串台，acp-cj 只能用一个 clientRequestLock 把 9 个反向调用全串起来 —— 锁横跨整个
// 往返，`terminal/wait_for_exit`（超时 10 分钟）期间连一次 `fs/read_text_file` 都发不出去。
// jsonrpc 0.7.5 起 `request()` 按 id 配对，本用例断言两个反向请求**真正重叠**且各拿各的结果。

// 跨协程收集（lambda 不能捕获可变局部变量）
class ReverseCallBox {
    private let lock = Mutex()
    private let cond: Condition
    private var value: ?String = None

    public init() {
        this.cond = synchronized(this.lock) { this.lock.condition() }
    }

    public func set(v: String): Unit {
        synchronized(this.lock) {
            this.value = Some(v)
            this.cond.notifyAll()
        }
    }

    public func wait(timeoutMs: Int64): String {
        synchronized(this.lock) {
            var waited: Int64 = 0
            while (this.value.isNone() && waited < timeoutMs) {
                this.cond.wait(timeout: 100 * Duration.millisecond)
                waited += 100
            }
            match (this.value) {
                case Some(v) => v
                case None => "<no result>"
            }
        }
    }
}

@Test
public func agent_concurrent_reverse_requests_overlap_and_pair_by_id() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // 每个反向请求固定耗时 400ms，回自己那条 path —— 串行 vs 并发由总耗时区分
    client.setOnReadTextFile({ req =>
        sleep(Duration.millisecond * 400)
        let r = ReadTextFileResponse()
        r.content = "content of ${req.path}"
        r
    })

    let box = ReverseCallBox()
    let first = ReadTextFileRequest()
    first.sessionId = "s1"
    first.path = "/tmp/first.txt"
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    spawn {
        box.set(match (agent.readTextFile(first)) {
            case Result.Ok(r) => r.content
            case Result.Err(e) => "ERR: ${e}"
        })
    }
    sleep(Duration.millisecond * 50)
    let second = ReadTextFileRequest()
    second.sessionId = "s1"
    second.path = "/tmp/second.txt"
    let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let secondContent = match (agent.readTextFile(second)) {
        case Result.Ok(r) => r.content
        case Result.Err(e) => "ERR: ${e}"
    }
    let secondElapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t1

    // ① 各自拿到自己的内容（按 id 配对，不串台）
    @Expect(secondContent, "content of /tmp/second.txt")
    @Expect(box.wait(3000), "content of /tmp/first.txt")
    // ② 真正重叠：第二个请求只等自己那 400ms，而不是「等第一个跑完再等自己那 400ms」（≈800ms）
    @Expect(secondElapsed < 650, true)
    @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - t0 < 1100, true)

    client.close()
    agent.close()
}

// ===================== 1.6 cwd 绝对路径校验 / 版本协商 =====================

@Test
public func agent_rejects_relative_cwd() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setPromptHandler({ ctx => PromptResponse(StopReasonEndTurn) })
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // 相对路径 cwd → -32602
    match (client.newSession("relative/dir")) {
        case Result.Ok(_) => @Fail("relative cwd must be rejected")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }
    client.close()
    agent.close()
}

@Test
public func agent_protocol_version_negotiation() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    // 客户端请求 v1 → agent 回 v1
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(resp) => @Expect(resp.protocolVersion, 1)
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    client.close()
    agent.close()
}

// ===================== 阶段2 Elicitation 双端 =====================

func makeElicitCaps(form: Bool, url: Bool): ClientCapabilities {
    let caps = ClientCapabilities()
    let elic = ElicitationCapabilities()
    if (form) { elic.form = Some(EmptyCapability()) }
    if (url) { elic.url = Some(EmptyCapability()) }
    caps.elicitation = Some(elic)
    caps
}

@Test
public func agent_elicitation_requires_advertised_mode() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    // Client 只广告 form
    match (client.connect(Implementation("test-client", "1.0.0"), makeElicitCaps(true, false))) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // url 未广告 → 拒绝（-32602 语义）
    let u = CreateElicitationRequest.urlMode("sess_1", "授权", "https://example.com")
    match (agent.createElicitation(u)) {
        case Result.Ok(_) => @Fail("url mode must be rejected when not advertised")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }
    // 未握手 clientCapabilities 时也拒绝
    client.close()
    agent.close()
    let pair2 = PipePair()
    let agent2 = AcpAgent(pair2.b(), "test-agent", "0.1.0")
    agent2.start()
    let client2 = AcpClient(pair2.a())
    // 先不 connect 直接 newSession 失败……改用未广告普通 caps（elicitation=None 等价未握手）
    match (client2.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect2 failed: ${e}")
    }
    match (agent2.createElicitation(CreateElicitationRequest.form("s", "x", ElicitationSchema()))) {
        case Result.Ok(_) => @Fail("form mode must be rejected when elicitation not advertised")
        case Result.Err(e) => @Expect(e.contains("-32602"), true)
    }
    client2.close()
    agent2.close()
}

@Test
public func agent_elicitation_form_accept_roundtrip() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), makeElicitCaps(true, true))) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // Client 类型化处理：返回 accept + 内容
    client.setOnElicitationCreate({ req =>
        let content = HashMap<String, JsonValue>()
        content["strategy"] = JsonValue.String("balanced")
        CreateElicitationResponse.accepted(content: Some(JsonValue.Map(content)))
    })
    // Agent 发起 form 请求
    let schema = ElicitationSchema.of([("strategy", ElicitationPropertySchema.singleSelect(
        ArrayList<String>(["conservative", "balanced"])))], required: Some(ArrayList<String>(["strategy"])))
    let req = CreateElicitationRequest.form("sess_1", "如何重构？", schema, toolCallId: Some("call_1"))
    match (agent.createElicitation(req)) {
        case Result.Ok(resp) =>
            @Expect(resp.action, "accept")
            match (resp.content) {
                case Some(JsonValue.Map(m)) =>
                    match (m.get("strategy")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "balanced")
                        case _ => @Fail("content.strategy missing")
                    }
                case _ => @Fail("accept content missing")
            }
        case Result.Err(e) => @Fail("createElicitation failed: ${e}")
    }
    // decline / cancel 路径
    client.setOnElicitationCreate({ req => CreateElicitationResponse.declined() })
    match (agent.createElicitation(req)) {
        case Result.Ok(resp) => @Expect(resp.action, "decline")
        case Result.Err(e) => @Fail("decline roundtrip failed: ${e}")
    }
    client.setOnElicitationCreate({ req => CreateElicitationResponse.cancelled() })
    match (agent.createElicitation(req)) {
        case Result.Ok(resp) => @Expect(resp.action, "cancel")
        case Result.Err(e) => @Fail("cancel roundtrip failed: ${e}")
    }
    client.close()
    agent.close()
}

@Test
public func agent_elicitation_url_and_complete() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), makeElicitCaps(true, true))) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    // url 模式：Client 同意打开（accept 无内容）
    client.setOnElicitationCreate({ req =>
        @Expect(req.mode, "url")
        @Expect(req.url, Some("https://example.com/oauth"))
        @Expect(req.elicitationId, Some("oauth-001"))
        CreateElicitationResponse.accepted()
    })
    let req = CreateElicitationRequest.urlMode("sess_1", "授权", "https://example.com/oauth",
        elicitationId: Some("oauth-001"))
    match (agent.createElicitation(req)) {
        case Result.Ok(resp) => @Expect(resp.action, "accept")
        case Result.Err(e) => @Fail("url elicitation failed: ${e}")
    }
    // 外部交互完成 → elicitation/complete 通知送达 Client
    let done = ArrayList<String>()
    client.setOnElicitationComplete({ id => done.add(id) })
    agent.elicitationComplete("oauth-001")
    var tries: Int64 = 0
    while (done.size == 0 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(done.size, 1)
    @Expect(done[0], "oauth-001")
    client.close()
    agent.close()
}

// ===================== A5 会话初始状态（NewSession 响应带 modes/configOptions） =====================

func makeInitialStateStub(): SessionInitialState {
    let st = SessionInitialState()
    let modes = SessionModeState()
    modes.currentModeId = "code"
    modes.availableModes.add(SessionMode("code", "Code"))
    modes.availableModes.add(SessionMode("ask", "Ask"))
    st.modes = Some(modes)
    let model = SessionConfigOption("model", "Model")
    model.`type` = "select"
    let opt1 = SessionConfigSelectOption()
    opt1.value = "deepseek"
    opt1.name = "DeepSeek"
    let optList = ArrayList<SessionConfigSelectOption>()
    optList.add(opt1)
    model.options = Some(optList)
    model.currentValue = Some("deepseek")
    st.configOptions = Some(ArrayList<SessionConfigOption>([model]))
    st
}

@Test
public func agent_new_session_returns_initial_state() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.setInitialSessionState({ req =>
        @Expect(req.cwd, "/tmp/init-proj")
        makeInitialStateStub()
    })
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    match (client.newSession("/tmp/init-proj")) {
        case Result.Ok(resp) =>
            @Expect(resp.sessionId.startsWith("sess_"), true)
            match (resp.modes) {
                case Some(m) =>
                    @Expect(m.currentModeId, "code")
                    @Expect(m.availableModes.size, 2)
                    @Expect(m.availableModes[0].id, "code")
                case None => @Fail("modes missing in newSession response")
            }
            match (resp.configOptions) {
                case Some(opts) =>
                    @Expect(opts.size, 1)
                    @Expect(opts[0].id, "model")
                    @Expect(opts[0].currentValue, Some("deepseek"))
                case None => @Fail("configOptions missing in newSession response")
            }
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    client.close()
    agent.close()
}

@Test
public func agent_new_session_without_initial_state_handler() {
    // 无初始状态钩子时：响应不带 modes/configOptions（既有行为保持）
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("connect failed: ${e}")
    }
    match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) =>
            @Expect(resp.modes.isNone(), true)
            @Expect(resp.configOptions.isNone(), true)
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    client.close()
    agent.close()
}

// session/delete 成功后内部会话状态清理：后续 prompt 该 id 返回 -32002（未知会话）
@Test
public func agent_delete_clearsInternalSession() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    agent.setOnDeleteSession({ sid => true })
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    let newResult = client.newSession("/tmp/proj")
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    // delete 成功
    match (client.deleteSession(sessionId)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("delete failed: ${e}")
    }
    // 删除后 prompt 同 id → -32002（内部状态已清理，与「从未创建」同义）
    let pResult = client.promptText(sessionId, "hi")
    match (pResult) {
        case Result.Ok(_) => @Fail("expected error for deleted session")
        case Result.Err(e) => @Expect(e.contains("-32002"), true)
    }
    client.close()
    agent.close()
}

// session/new 携带附加工作区 → SessionState 保存且可查询
@Test
public func agent_new_session_with_additional_directories() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    agent.capabilities.sessionCapabilities.additionalDirectories = Some(EmptyCapability())
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    let dirs = ArrayList<String>(["/work/a", "/data/b"])
    let newResult = client.newSession("/tmp/proj", additionalDirectories: Some(dirs))
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    // 宿主查询（session/new 回调之后可用）
    var i: Int64 = 0
    var found: ?ArrayList<String> = None
    while (i < 50 && found.isNone()) {
        i++
        found = agent.sessionAdditionalDirectories(sessionId)
        if (found.isNone()) { sleep(10 * Duration.millisecond) }
    }
    match (found) {
        case Some(list) =>
            @Expect(list.size, 2)
            @Expect(list[0], "/work/a")
            @Expect(list[1], "/data/b")
        case None => @Fail("additionalDirectories not stored")
    }
    // 未知会话
    @Expect(agent.sessionAdditionalDirectories("sess_unknown").isNone(), true)
    client.close()
    agent.close()
}

// session/new 携带 mcpServers → 宿主查询（McpServer 配置原样返回）
@Test
public func agent_new_session_mcp_servers_queryable() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    let servers = ArrayList<McpServer>()
    servers.add(McpServer.stdio("fs", "npx", args: ArrayList<String>(["-y", "@modelcontextprotocol/server-filesystem"])))
    servers.add(McpServer.http("docs", "https://example.com/mcp"))
    let newResult = client.newSession("/tmp/proj", mcpServers: servers)
    let sessionId = match (newResult) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    var i: Int64 = 0
    var found: ?ArrayList<McpServer> = None
    while (i < 50 && found.isNone()) {
        i++
        found = agent.sessionMcpServers(sessionId)
        if (found.isNone()) { sleep(10 * Duration.millisecond) }
    }
    match (found) {
        case Some(list) =>
            @Expect(list.size, 2)
            @Expect(list[0].name, "fs")
            @Expect(list[1].name, "docs")
            @Expect(list[1].url.isSome(), true)
        case None => @Fail("mcpServers not stored")
    }
    @Expect(agent.sessionMcpServers("sess_unknown").isNone(), true)
    client.close()
    agent.close()
}

// ===================== 协议一致性（ACP TCK 判据） =====================
// 这些判据看的是 JSON-RPC 错误对象本身（code / data），而 AcpClient 把错误压成
// "[code] message" 字符串、丢掉 data，所以这里直接用裸帧读写。

// 裸 JSON-RPC 读端：按 ACP 的换行帧切分，只取与请求 id 匹配的响应
class RawPeer {
    private let transport: Transport
    private let buf = ArrayList<UInt8>()
    private var consumed: Int64 = 0
    private var nextId: Int64 = 1

    public init(transport: Transport) { this.transport = transport }

    // 读一条完整帧；超时返回 None
    private func readFrame(): ?JsonValue {
        var idle: Int64 = 0
        while (idle < 200) {
            let arr = this.buf.toArray()
            var idx: Int64 = -1
            for (i in this.consumed..arr.size) {
                if (arr[i] == 10) { idx = i; break }
            }
            if (idx >= 0) {
                let line = String.fromUtf8(arr[this.consumed..idx])
                this.consumed = idx + 1
                if (this.consumed >= this.buf.size) {
                    this.buf.clear()
                    this.consumed = 0
                }
                if (line.trimAscii().isEmpty()) { continue }
                return Some(JsonValue.parse(line))
            }
            match (this.transport.receive()) {
                case Some(chunk) =>
                    for (b in chunk) { this.buf.add(b) }
                case None => idle++
            }
        }
        None
    }

    // ACP 以 LF 分帧：发送时必须补换行，否则对端一直等下一帧
    private func writeLine(line: String): Unit {
        this.transport.send((line + "\n").toArray())
    }

    // 发送请求并返回其响应（跳过通知与本请求之外的响应）
    public func request(method: String, paramsJson: String): JsonValue {
        let id = this.nextId
        this.nextId++
        this.writeLine("{\"jsonrpc\":\"2.0\",\"id\":" + id.toString() +
            ",\"method\":\"" + method + "\",\"params\":" + paramsJson + "}")
        var tries: Int64 = 0
        while (tries < 400) {
            tries++
            match (this.readFrame()) {
                case Some(v) =>
                    match (v["id"]) {
                        case Some(jv) => match (jv.asNumber()) {
                            case Some(n) => if (Int64(n) == id) { return v }
                            case None => ()
                        }
                        case None => ()
                    }
                case None => break
            }
        }
        JsonValue.Null
    }
}

// JSON 字符串字面量（避免在测试里手写转义）
func jstr(s: String): String { "\"" + s + "\"" }

// 响应里的 result 对象（无 result 时返回 Null）
func resultOf(resp: JsonValue): JsonValue { resp["result"] ?? JsonValue.Null }

// 从可选 JsonValue 取字符串（缺省空串）
func strOf(v: ?JsonValue): String {
    match (v) {
        case Some(jv) => jv.asString() ?? ""
        case None => ""
    }
}

// 断言「未知会话」类错误：-32002 且 data.sessionId 为请求的 id（ACP-ERROR-003/004）
func expectUnknownSessionError(resp: JsonValue, sessionId: String) {
    let err = match (resp["error"]) {
        case Some(e) => e
        case None => return @Fail("expected -32002 error, got " + resp.stringify())
    }
    match (err["code"]) {
        case Some(c) => match (c.asNumber()) {
            case Some(n) => @Expect(Int64(n), RESOURCE_NOT_FOUND)
            case None => @Fail("error.code is not a number: " + resp.stringify())
        }
        case None => @Fail("error has no code: " + resp.stringify())
    }
    match (err["data"]) {
        case Some(d) => match (d["sessionId"]) {
            case Some(sid) => @Expect(sid.asString() ?? "", sessionId)
            case None => @Fail("error.data has no sessionId: " + resp.stringify())
        }
        case None => @Fail("error has no data.sessionId: " + resp.stringify())
    }
}

// 断言错误码（非未知会话类判据）
func expectErrorCode(resp: JsonValue, code: Int64) {
    let err = match (resp["error"]) {
        case Some(e) => e
        case None => return @Fail("expected error ${code}, got " + resp.stringify())
    }
    match (err["code"]) {
        case Some(c) => match (c.asNumber()) {
            case Some(n) => @Expect(Int64(n), code)
            case None => @Fail("error.code is not a number: " + resp.stringify())
        }
        case None => @Fail("error has no code: " + resp.stringify())
    }
}

// ACP-CLOSE-003：session/close 幂等——重复关闭、关闭从未创建的会话都返回空结果
@Test
public func agent_close_session_is_idempotent() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.capabilities.sessionCapabilities.close = Some(EmptyCapability())
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    let sessionId = match (client.newSession("/tmp/proj")) {
        case Result.Ok(resp) => resp.sessionId
        case Result.Err(e) => return @Fail("newSession failed: ${e}")
    }
    // 首次关闭
    match (client.closeSession(sessionId)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("first close failed: ${e}")
    }
    // 再次关闭同一会话：仍成功
    match (client.closeSession(sessionId)) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("closing an already-closed session must succeed, got: ${e}")
    }
    // 关闭从未创建的会话：仍成功
    match (client.closeSession("sess_never_created")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("closing a never-created session must succeed, got: ${e}")
    }
    client.close()
    agent.close()
}

// ACP-DELETE-002：session/delete 对不存在/已删除的会话静默成功
@Test
public func agent_delete_session_is_idempotent() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    // 宿主只认得 sess_known：其余一律视为「不存在」
    agent.setOnDeleteSession({ sid => sid == "sess_known" })
    agent.start()
    let client = AcpClient(pair.a())
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    // 从未创建
    match (client.deleteSession("sess_never_created")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("deleting a never-created session must succeed silently, got: ${e}")
    }
    // 已删除（第二次）
    match (client.deleteSession("sess_known")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => return @Fail("first delete failed: ${e}")
    }
    match (client.deleteSession("sess_known")) {
        case Result.Ok(_) => ()
        case Result.Err(e) => @Fail("deleting an already-deleted session must succeed silently, got: ${e}")
    }
    client.close()
    agent.close()
}

// ACP-ERROR-003：session/prompt 指向不存在或已关闭会话 → -32002 + data.sessionId
@Test
public func agent_prompt_unknown_or_closed_session_resource_not_found() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.capabilities.sessionCapabilities.close = Some(EmptyCapability())
    agent.setPromptHandler({ ctx => PromptResponse(StopReasonEndTurn) })
    agent.start()

    let peer = RawPeer(pair.a())
    peer.request("initialize", "{}")
    let promptParams = "{\"sessionId\":" + jstr("sess_never_created") +
        ",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}"
    expectUnknownSessionError(peer.request("session/prompt", promptParams), "sess_never_created")

    // 关闭后的会话与「不存在」等价
    let newResp = peer.request("session/new", "{\"cwd\":\"/tmp/proj\",\"mcpServers\":[]}")
    let sessionId = strOf(resultOf(newResp)["sessionId"])
    if (sessionId.isEmpty()) { return @Fail("session/new failed: " + newResp.stringify()) }
    let closeResp = peer.request("session/close", "{\"sessionId\":" + jstr(sessionId) + "}")
    match (closeResp["error"]) {
        case Some(_) => return @Fail("session/close failed: " + closeResp.stringify())
        case None => ()
    }
    let closedPrompt = "{\"sessionId\":" + jstr(sessionId) +
        ",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}"
    expectUnknownSessionError(peer.request("session/prompt", closedPrompt), sessionId)
    agent.close()
}

// ACP-ERROR-004：set_mode / set_config_option / load / resume 指向不存在会话
// → -32002 + data.sessionId（load 由宿主用 unknownSessionError 构造，验证该 helper 的形状）
@Test
public func agent_session_methods_unknown_session_resource_not_found() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.capabilities.loadSession = true
    agent.capabilities.sessionCapabilities.resume = Some(EmptyCapability())
    agent.setOnSetMode({ _, _ => true })
    agent.setOnSetConfigOption({ _, req => Some(ArrayList<SessionConfigOption>()) })
    agent.setOnLoadSession({ req, complete, fail => fail(unknownSessionError(req.sessionId)) })
    agent.setOnResumeSession({ req => None })
    agent.start()

    let peer = RawPeer(pair.a())
    peer.request("initialize", "{}")
    let sid = "sess_never_created"
    let lifecycle = "{\"sessionId\":" + jstr(sid) + ",\"cwd\":\"/tmp/proj\",\"mcpServers\":[]}"

    expectUnknownSessionError(
        peer.request("session/set_mode", "{\"sessionId\":" + jstr(sid) + ",\"modeId\":\"code\"}"), sid)
    expectUnknownSessionError(
        peer.request("session/set_config_option",
            "{\"sessionId\":" + jstr(sid) + ",\"configId\":\"model\",\"value\":\"m1\"}"), sid)
    expectUnknownSessionError(peer.request("session/load", lifecycle), sid)
    expectUnknownSessionError(peer.request("session/resume", lifecycle), sid)
    agent.close()
}

// ACP-ERROR-005：initialize 之前的其它请求 → -32600，之后 initialize 恢复正常
@Test
public func agent_request_before_initialize_invalid_request() {
    let pair = PipePair()
    let agent = makeEchoAgent(pair)
    let peer = RawPeer(pair.a())

    // 首条消息即 session/new
    expectErrorCode(peer.request("session/new", "{\"cwd\":\"/tmp/proj\",\"mcpServers\":[]}"),
        INVALID_REQUEST)
    // initialize 之后同一请求正常
    let initResp = peer.request("initialize", "{}")
    match (initResp["error"]) {
        case Some(_) => return @Fail("initialize failed: " + initResp.stringify())
        case None => ()
    }
    let newResp = peer.request("session/new", "{\"cwd\":\"/tmp/proj\",\"mcpServers\":[]}")
    @Expect(strOf(resultOf(newResp)["sessionId"]).isEmpty(), false)
    agent.close()
}


// ACP-LIST-003：session/list 收到 agent 从未签发过的 cursor → -32602（不能忽略后照常返回列表）
func listStub(req: ListSessionsRequest): Result<ListSessionsResponse> {
    match (req.cursor) {
        case None =>
            let info = SessionInfo()
            info.sessionId = "sess_1"
            info.cwd = "/tmp/proj"
            let resp = ListSessionsResponse()
            resp.sessions.add(info)
            resp.nextCursor = Some("cur_issued")
            Result.Ok(resp)
        case Some(c) =>
            // 宿主只签发过 cur_issued：其余都是「未签发」，必须回 -32602
            if (c == "cur_issued") {
                Result.Ok(ListSessionsResponse())
            } else {
                Result.Err("Unknown cursor: " + c)
            }
    }
}

@Test
public func agent_list_rejects_unknown_cursor() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "test-agent", "0.1.0")
    agent.capabilities.sessionCapabilities.list = Some(EmptyCapability())
    agent.setOnListSessions(listStub)
    agent.start()
    let peer = RawPeer(pair.a())
    peer.request("initialize", "{}")

    // 不带 cursor：正常返回一页，并带 nextCursor
    let page = peer.request("session/list", "{}")
    @Expect(strOf(resultOf(page)["nextCursor"]), "cur_issued")
    // 自己签发过的 cursor：正常
    let page2 = peer.request("session/list", "{\"cursor\":" + jstr("cur_issued") + "}")
    match (page2["error"]) {
        case Some(_) => @Fail("issued cursor must be accepted: " + page2.stringify())
        case None => ()
    }
    // 从未签发过的 cursor：-32602
    expectErrorCode(peer.request("session/list", "{\"cursor\":" + jstr("_tck-never-issued-cursor") + "}"),
        INVALID_PARAMS)
    agent.close()
}
