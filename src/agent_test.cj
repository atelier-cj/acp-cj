package acp

import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.{Result, JsonRpcError}
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

// ===================== 1.1 clientCapabilities 保存与透出 =====================

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
    // Agent 侧保存了客户端声明的能力
    match (agent.clientCapabilities) {
        case Some(c) =>
            @Expect(c.fs.readTextFile, true)
            @Expect(c.fs.writeTextFile, true)
            @Expect(c.terminal, true)
            @Expect(c.auth.terminal, true)
        case None => @Fail("clientCapabilities not preserved")
    }
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
        observed.add("hasCaps=${!ctx.clientCaps().isNone()}")
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
    @Expect(observed.contains("hasCaps=true"), true)
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
