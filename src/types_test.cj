package acp

import acp.types.*
import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.ByteBuffer

// 序列化往返辅助：toJson -> 字节 -> fromJson
public func roundTrip<T>(v: T): T where T <: JsonSerializable & JsonDeserializable<T> {
    let jv = JsonValue.fromObject(v)
    let bytes = jv.toBytes()
    let buf = ByteBuffer(bytes)
    let r = JsonReader(buf)
    T.fromJson(r)
}


public func contentTypeName(t: ContentBlockType): String {
    match (t) {
        case ContentBlockType.Text => "text"
        case ContentBlockType.Image => "image"
        case ContentBlockType.Audio => "audio"
        case ContentBlockType.Resource => "resource"
        case ContentBlockType.ResourceLink => "resource_link"
    }
}

public func expectTypeEqual(actual: ContentBlockType, expected: ContentBlockType): Unit {
    @Expect(contentTypeName(actual), contentTypeName(expected))
}

// ===================== ContentBlock =====================

@Test
public func content_text_roundtrip() {
    let c = ContentBlock.ofText("hello world")
    let back = roundTrip<ContentBlock>(c)
    expectTypeEqual(back.`type`, ContentBlockType.Text)
    @Expect(back.text == Some("hello world"), true)
}

@Test
public func content_image_roundtrip() {
    let c = ContentBlock.image("aGVsbG8=", "image/png")
    let back = roundTrip<ContentBlock>(c)
    expectTypeEqual(back.`type`, ContentBlockType.Image)
    @Expect(back.data == Some("aGVsbG8="), true)
    @Expect(back.mimeType == Some("image/png"), true)
}

@Test
public func content_resource_roundtrip() {
    let c = ContentBlock.ofResource(EmbeddedResourceResource("file:///tmp/a.txt", "content", mimeType: Some("text/plain")))
    let back = roundTrip<ContentBlock>(c)
    expectTypeEqual(back.`type`, ContentBlockType.Resource)
    let res = match (back.resource) {
        case Some(r) => r
        case None => @Fail("resource is None")
    }
    @Expect(res.uri, "file:///tmp/a.txt")
    @Expect(res.text, Some("content"))
}

@Test
public func content_resource_link_roundtrip() {
    let c = ContentBlock.resourceLink("file:///tmp/b.pdf", "b.pdf")
    let back = roundTrip<ContentBlock>(c)
    expectTypeEqual(back.`type`, ContentBlockType.ResourceLink)
    @Expect(back.uri == Some("file:///tmp/b.pdf"), true)
    @Expect(back.name == Some("b.pdf"), true)
}

// ===================== SessionUpdate =====================

@Test
public func update_agent_message_roundtrip() {
    let u = SessionUpdate.agentMessage("Hello")
    let back = roundTrip<SessionUpdate>(u)
    @Expect(back.sessionUpdate == SessionUpdateAgentMessageChunk, true)
    match (back.content) {
        case Some(c) => @Expect(c.text, Some("Hello"))
        case None => @Fail("content is None")
    }
}

@Test
public func update_tool_call_roundtrip() {
    let u = SessionUpdate.toolCall("call_1", "Reading file", kind: Some(ToolKindRead), status: Some(ToolStatusPending))
    let back = roundTrip<SessionUpdate>(u)
    @Expect(back.sessionUpdate == SessionUpdateToolCall, true)
    @Expect(back.toolCallId == Some("call_1"), true)
    @Expect(back.title == Some("Reading file"), true)
    @Expect(back.kind == Some(ToolKindRead), true)
    @Expect(back.status == Some(ToolStatusPending), true)
}

@Test
public func update_tool_call_with_content_roundtrip() {
    let u = SessionUpdate.toolCallUpdate("call_1", status: Some(ToolStatusCompleted))
    u.toolContent = Some(ArrayList<ToolCallContent>([ToolCallContent.ofContent(ContentBlock.ofText("done"))]))
    let back = roundTrip<SessionUpdate>(u)
    @Expect(back.sessionUpdate == SessionUpdateToolCallUpdate, true)
    @Expect(back.toolCallId == Some("call_1"), true)
    match (back.toolContent) {
        case Some(list) => @Expect(list.size, 1)
        case None => @Fail("toolContent is None")
    }
}

@Test
public func update_plan_roundtrip() {
    let entries = ArrayList<PlanEntry>([PlanEntry("step 1", "high", "pending"), PlanEntry("step 2", "medium", "in_progress")])
    let u = SessionUpdate.plan(entries)
    let back = roundTrip<SessionUpdate>(u)
    @Expect(back.sessionUpdate == SessionUpdatePlan, true)
    match (back.entries) {
        case Some(list) => @Expect(list.size, 2)
        case None => @Fail("entries is None")
    }
}

@Test
public func update_usage_roundtrip() {
    let cost = Cost()
    cost.amount = 0.045
    cost.currency = "USD"
    let u = SessionUpdate.usageUpdate(53000, 200000, cost: Some(cost))
    let back = roundTrip<SessionUpdate>(u)
    @Expect(back.sessionUpdate == SessionUpdateUsage, true)
    @Expect(back.used == Some(53000), true)
    @Expect(back.size == Some(200000), true)
}

// ===================== 请求/响应 =====================

@Test
public func initialize_request_roundtrip() {
    let req = InitializeRequest()
    req.protocolVersion = 1
    req.clientInfo = Some(Implementation("my-client", "1.0.0"))
    let back = roundTrip<InitializeRequest>(req)
    @Expect(back.protocolVersion, 1)
    match (back.clientInfo) {
        case Some(info) => @Expect(info.name, "my-client")
        case None => @Fail("clientInfo is None")
    }
}

@Test
public func initialize_response_roundtrip() {
    let resp = InitializeResponse()
    resp.protocolVersion = 1
    resp.agentInfo = Some(Implementation("pi-acp", "0.0.33"))
    resp.agentCapabilities.loadSession = true
    resp.agentCapabilities.promptCapabilities.image = true
    resp.authMethods.add(AuthMethod())
    resp.authMethods[0].id = "terminal-login"
    resp.authMethods[0].name = "Log in from the terminal"
    resp.authMethods[0].`type` = Some("terminal")

    let back = roundTrip<InitializeResponse>(resp)
    @Expect(back.protocolVersion, 1)
    @Expect(back.agentCapabilities.loadSession, true)
    @Expect(back.agentCapabilities.promptCapabilities.image, true)
    @Expect(back.authMethods.size, 1)
    @Expect(back.authMethods[0].id, "terminal-login")
    @Expect(back.authMethods[0].`type` == Some("terminal"), true)
}

@Test
public func new_session_response_roundtrip() {
    let resp = NewSessionResponse()
    resp.sessionId = "sess_abc"
    let back = roundTrip<NewSessionResponse>(resp)
    @Expect(back.sessionId, "sess_abc")
}

@Test
public func prompt_request_roundtrip() {
    let req = PromptRequest()
    req.sessionId = "sess_abc"
    req.prompt.add(ContentBlock.ofText("hi"))
    let back = roundTrip<PromptRequest>(req)
    @Expect(back.sessionId, "sess_abc")
    @Expect(back.prompt.size, 1)
}

@Test
public func prompt_response_roundtrip() {
    let resp = PromptResponse(StopReasonEndTurn)
    let back = roundTrip<PromptResponse>(resp)
    @Expect(back.stopReason, StopReasonEndTurn)
}

// ===================== 权限 =====================

@Test
public func permission_request_roundtrip() {
    let req = RequestPermissionRequest()
    req.sessionId = "sess_abc"
    req.toolCall.toolCallId = "call_1"
    req.toolCall.title = Some("Run command")
    req.toolCall.kind = Some(ToolKindExecute)
    req.toolCall.status = Some(ToolStatusPending)
    req.options.add(PermissionOption("allow-once", "Allow once", "allow_once"))
    req.options.add(PermissionOption("reject-once", "Reject", "reject_once"))

    let back = roundTrip<RequestPermissionRequest>(req)
    @Expect(back.sessionId, "sess_abc")
    @Expect(back.toolCall.toolCallId, "call_1")
    @Expect(back.options.size, 2)
    @Expect(back.options[0].kind, "allow_once")
}

@Test
public func permission_outcome_selected_roundtrip() {
    let o = RequestPermissionOutcome.selected("allow-once")
    let back = roundTrip<RequestPermissionOutcome>(o)
    @Expect(back.outcome, "selected")
    @Expect(back.optionId == Some("allow-once"), true)
}

// ===================== Capabilities =====================

@Test
public func agent_capabilities_roundtrip() {
    let caps = AgentCapabilities()
    caps.loadSession = true
    caps.sessionCapabilities.list = Some(EmptyCapability())
    caps.sessionCapabilities.delete = Some(EmptyCapability())
    let back = roundTrip<AgentCapabilities>(caps)
    @Expect(back.loadSession, true)
    @Expect(back.sessionCapabilities.list.isSome(), true)
    @Expect(back.sessionCapabilities.delete.isSome(), true)
}

// ===================== ToolCall 结构 =====================

@Test
public func tool_call_content_diff_roundtrip() {
    let d = ToolCallContent.diff("/tmp/a.txt", "new", oldText: Some("old"))
    let back = roundTrip<ToolCallContent>(d)
    @Expect(back.`type`, "diff")
    @Expect(back.path == Some("/tmp/a.txt"), true)
    @Expect(back.oldText == Some("old"), true)
    @Expect(back.newText == Some("new"), true)
}

@Test
public func tool_call_location_roundtrip() {
    let loc = ToolCallLocation("/tmp/a.cj")
    loc.line = Some(42)
    let back = roundTrip<ToolCallLocation>(loc)
    @Expect(back.path, "/tmp/a.cj")
    @Expect(back.line == Some(42), true)
}

// ===================== 会话配置 =====================

@Test
public func session_config_option_select_roundtrip() {
    let opt = SessionConfigOption("model", "Model")
    opt.`type` = "select"
    opt.category = Some("model")
    opt.currentValue = Some("model-1")
    opt.options = Some(ArrayList<SessionConfigSelectOption>([SessionConfigSelectOption("model-1", "Model 1")]))
    let back = roundTrip<SessionConfigOption>(opt)
    @Expect(back.id, "model")
    @Expect(back.currentValue == Some("model-1"), true)
    @Expect(back.category == Some("model"), true)
    match (back.options) {
        case Some(list) => @Expect(list.size, 1)
        case None => @Fail("options is None")
    }
}

@Test
public func session_mode_state_roundtrip() {
    let s = SessionModeState()
    s.currentModeId = "code"
    s.availableModes.add(SessionMode("code", "Code", description: Some("full access")))
    let back = roundTrip<SessionModeState>(s)
    @Expect(back.currentModeId, "code")
    @Expect(back.availableModes.size, 1)
    @Expect(back.availableModes[0].description, Some("full access"))
}

// ===================== 终端 / 文件系统 =====================

@Test
public func terminal_create_request_roundtrip() {
    let req = CreateTerminalRequest()
    req.sessionId = "sess_abc"
    req.command = "ls"
    req.args = Some(ArrayList<String>(["-la"]))
    let back = roundTrip<CreateTerminalRequest>(req)
    @Expect(back.sessionId, "sess_abc")
    @Expect(back.command, "ls")
    match (back.args) {
        case Some(list) => @Expect(list[0], "-la")
        case None => @Fail("args is None")
    }
}

@Test
public func session_notification_roundtrip() {
    let n = SessionNotification()
    n.sessionId = "sess_abc"
    n.update = SessionUpdate.agentMessage("streamed")
    let back = roundTrip<SessionNotification>(n)
    @Expect(back.sessionId, "sess_abc")
    @Expect(back.update.sessionUpdate, SessionUpdateAgentMessageChunk)
}

// ===================== 1.6 _meta 收发 =====================

@Test
public func types_meta_roundtrip_on_requests() {
    // NewSessionRequest 带 _meta 往返
    let req = NewSessionRequest()
    req.cwd = "/tmp/proj"
    let meta = HashMap<String, JsonValue>()
    meta["traceId"] = JsonValue.String("abc-123")
    req._meta = Some(JsonValue.Map(meta))
    let rt = roundTrip(req)
    match (rt._meta) {
        case Some(m) =>
            match (m["traceId"]) {
                case Some(JsonValue.String(s)) => @Expect(s, "abc-123")
                case _ => @Fail("_meta.traceId missing after roundtrip")
            }
        case None => @Fail("_meta lost after roundtrip")
    }
    // 无 _meta 时不序列化该字段
    let req2 = SetSessionModeRequest()
    req2.sessionId = "s"
    req2.modeId = "code"
    let raw = JsonValue.fromObject(req2).stringify()
    @Expect(raw.contains("_meta"), false)

    // AuthenticateRequest / SessionLifecycleRequest / CancelNotification 收 _meta
    let auth = AuthenticateRequest()
    auth.methodId = "m"
    auth._meta = Some(JsonValue.Map(HashMap<String, JsonValue>()))
    let authRt = roundTrip(auth)
    @Expect(authRt._meta.isSome(), true)

    let lc = SessionLifecycleRequest()
    lc.sessionId = "s1"
    lc.cwd = "/tmp"
    lc._meta = Some(JsonValue.String("x"))
    let lcRt = roundTrip(lc)
    @Expect(lcRt._meta.isSome(), true)

    let cn = CancelNotification()
    cn.sessionId = "s2"
    cn._meta = Some(JsonValue.Boolean(true))
    let cnRt = roundTrip(cn)
    @Expect(cnRt._meta.isSome(), true)
}

// ===================== 阶段2 Elicitation 类型层 =====================

func buildStrategySchema(): ElicitationSchema {
    let strategy = ElicitationPropertySchema.singleSelect(
        ArrayList<String>(["conservative", "balanced", "aggressive"]),
        title: Some("策略"))
    strategy.description = Some("重构策略")
    let detail = ElicitationPropertySchema.string()
    detail.minLength = Some(3)
    detail.maxLength = Some(100)
    detail.format = Some(StringFormatDate)
    detail.strDefault = Some("2026-01-01")
    let count = ElicitationPropertySchema.integer()
    count.intMinimum = Some(1)
    count.intMaximum = Some(10)
    count.intDefault = Some(3)
    let ratio = ElicitationPropertySchema.number()
    ratio.numDefault = Some(0.5)
    let verbose = ElicitationPropertySchema.boolean()
    verbose.boolDefault = Some(true)
    let tags = ElicitationPropertySchema.multiSelect(ArrayList<String>(["a", "b"]))
    tags.arrDefault = Some(ArrayList<String>(["a"]))
    let titled = EnumOption("fast", "快速", description: Some("速度优先"))
    let titledOpt = ElicitationPropertySchema.titledSelect(ArrayList<EnumOption>([titled]), title: Some("模式"))
    let msel = ElicitationPropertySchema.titledMultiSelect(ArrayList<EnumOption>([EnumOption("x", "X")]))
    ElicitationSchema.of([
        ("strategy", strategy),
        ("detail", detail),
        ("count", count),
        ("ratio", ratio),
        ("verbose", verbose),
        ("tags", tags),
        ("titledOpt", titledOpt),
        ("msel", msel),
    ], required: Some(ArrayList<String>(["strategy"])))
}

@Test
public func types_elicitation_schema_roundtrip() {
    let schema = buildStrategySchema()
    let rt = roundTrip(schema)
    @Expect(rt.`type`, "object")
    @Expect(rt.properties.size, 8)
    // 单选 enum
    match (rt.properties.get("strategy")) {
        case Some(p) =>
            @Expect(p.`type`, "string")
            match (p.enumValues) {
                case Some(list) =>
                    @Expect(list.size, 3)
                    @Expect(list[0], "conservative")
                case None => @Fail("enumValues lost")
            }
            @Expect(p.title, Some("策略"))
            @Expect(p.description, Some("重构策略"))
        case None => @Fail("strategy property lost")
    }
    // string 约束 + format + default
    match (rt.properties.get("detail")) {
        case Some(p) =>
            @Expect(p.minLength, Some(3))
            @Expect(p.maxLength, Some(100))
            @Expect(p.format, Some("date"))
            @Expect(p.strDefault, Some("2026-01-01"))
        case None => @Fail("detail lost")
    }
    // integer
    match (rt.properties.get("count")) {
        case Some(p) =>
            @Expect(p.intMinimum, Some(1))
            @Expect(p.intMaximum, Some(10))
            @Expect(p.intDefault, Some(3))
        case None => @Fail("count lost")
    }
    // number
    match (rt.properties.get("ratio")) {
        case Some(p) =>
            match (p.numDefault) {
                case Some(v) => @Expect(v > 0.49 && v < 0.51, true)
                case None => @Fail("numDefault lost")
            }
        case None => @Fail("ratio lost")
    }
    // boolean
    match (rt.properties.get("verbose")) {
        case Some(p) => @Expect(p.boolDefault, Some(true))
        case None => @Fail("verbose lost")
    }
    // multi-select（untitled）
    match (rt.properties.get("tags")) {
        case Some(p) =>
            @Expect(p.`type`, "array")
            match (p.strEnum) {
                case Some(list) => @Expect(list.size, 2)
                case None => @Fail("strEnum lost")
            }
            match (p.arrDefault) {
                case Some(list) => @Expect(list[0], "a")
                case None => @Fail("arrDefault lost")
            }
        case None => @Fail("tags lost")
    }
    // titled select oneOf
    match (rt.properties.get("titledOpt")) {
        case Some(p) =>
            match (p.titledOptions) {
                case Some(list) =>
                    @Expect(list.size, 1)
                    @Expect(list[0].`const`, "fast")
                    @Expect(list[0].title, "快速")
                case None => @Fail("titledOptions lost")
            }
        case None => @Fail("titledOpt lost")
    }
    // titled multi-select items(anyOf)
    match (rt.properties.get("msel")) {
        case Some(p) =>
            @Expect(p.itemsType, "titled")
            match (p.titledItems) {
                case Some(list) =>
                    @Expect(list.size, 1)
                    @Expect(list[0].`const`, "x")
                case None => @Fail("titledItems lost")
            }
        case None => @Fail("msel lost")
    }
    match (rt.required) {
        case Some(list) =>
            @Expect(list.size, 1)
            @Expect(list[0], "strategy")
        case None => @Fail("required lost")
    }
}

@Test
public func types_elicitation_request_response_roundtrip() {
    // form（session 域）
    let f = CreateElicitationRequest.form("sess_1", "如何重构？", buildStrategySchema())
    f.toolCallId = Some("call_9")
    f._meta = Some(JsonValue.String("m"))
    let frt = roundTrip(f)
    @Expect(frt.mode, "form")
    @Expect(frt.sessionId, Some("sess_1"))
    @Expect(frt.toolCallId, Some("call_9"))
    @Expect(frt.requestedSchema.isSome(), true)
    match (frt.requestedSchema) {
        case Some(s) => @Expect(s.properties.size, 8)
        case None => @Fail("requestedSchema lost")
    }

    // form（request 域）
    let fr = CreateElicitationRequest.formForRequest(JsonValue.Number(42.0), "输入", buildStrategySchema())
    let frrt = roundTrip(fr)
    @Expect(frrt.mode, "form")
    match (frrt.requestId) {
        case Some(JsonValue.Number(n)) => @Expect(Int64(n), 42)
        case _ => @Fail("requestId lost")
    }
    @Expect(frrt.sessionId.isNone(), true)

    // url（session 域）
    let u = CreateElicitationRequest.urlMode("sess_1", "授权", "https://example.com/oauth",
        elicitationId: Some("oauth-001"))
    let urt = roundTrip(u)
    @Expect(urt.mode, "url")
    @Expect(urt.url, Some("https://example.com/oauth"))
    @Expect(urt.elicitationId, Some("oauth-001"))

    // 响应三态
    let content = HashMap<String, JsonValue>()
    content["strategy"] = JsonValue.String("balanced")
    let acc = CreateElicitationResponse.accepted(content: Some(JsonValue.Map(content)))
    let ar = roundTrip(acc)
    @Expect(ar.action, "accept")
    match (ar.content) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("strategy")) {
                case Some(JsonValue.String(s)) => @Expect(s, "balanced")
                case _ => @Fail("content lost")
            }
        case _ => @Fail("accept content lost")
    }
    @Expect(roundTrip(CreateElicitationResponse.declined()).action, "decline")
    @Expect(roundTrip(CreateElicitationResponse.cancelled()).action, "cancel")

    // complete 通知
    let cn = CompleteElicitationNotification("oauth-001")
    let cr = roundTrip(cn)
    @Expect(cr.elicitationId, "oauth-001")
}

@Test
public func types_elicitation_unknown_preserved() {
    // 未知属性类型：raw 原样保留
    let rawProp = "{\"type\":\"_custom\",\"payload\":{\"k\":\"v\"}}"
    let pv = JsonValue.parse(rawProp)
    let propVar = reparse<ElicitationPropertySchema>(pv)
    @Expect(propVar.`type`, "_custom")
    @Expect(propVar.raw.isSome(), true)
    let back = JsonValue.fromObject(propVar).stringify()
    @Expect(back.contains("_custom"), true)
    @Expect(back.contains("payload"), true)

    // 未知 mode：请求原样保留
    let rawReq = "{\"message\":\"hi\",\"mode\":\"_weird\",\"x\":1}"
    let req = reparse<CreateElicitationRequest>(JsonValue.parse(rawReq))
    @Expect(req.mode, "_weird")
    @Expect(req.raw.isSome(), true)
    @Expect(JsonValue.fromObject(req).stringify().contains("_weird"), true)

    // 未知 action：响应原样保留
    let rawResp = "{\"action\":\"_future\",\"n\":2}"
    let resp = reparse<CreateElicitationResponse>(JsonValue.parse(rawResp))
    @Expect(resp.action, "_future")
    @Expect(resp.raw.isSome(), true)
}

@Test
public func types_elicitation_capabilities_roundtrip() {
    // 默认：不广告
    let caps = ClientCapabilities()
    @Expect(caps.elicitation.isNone(), true)
    let raw = JsonValue.fromObject(caps).stringify()
    @Expect(raw.contains("elicitation"), false)
    // form+url 广告
    let caps2 = ClientCapabilities()
    let elic = ElicitationCapabilities()
    elic.form = Some(EmptyCapability())
    elic.url = Some(EmptyCapability())
    caps2.elicitation = Some(elic)
    let rt = roundTrip(caps2)
    match (rt.elicitation) {
        case Some(e) =>
            @Expect(e.form.isSome(), true)
            @Expect(e.url.isSome(), true)
        case None => @Fail("elicitation capability lost")
    }
    // 仅 form
    let caps3 = ClientCapabilities()
    let e3 = ElicitationCapabilities()
    e3.form = Some(EmptyCapability())
    caps3.elicitation = Some(e3)
    let rt3 = roundTrip(caps3)
    match (rt3.elicitation) {
        case Some(e) =>
            @Expect(e.form.isSome(), true)
            @Expect(e.url.isNone(), true)
        case None => @Fail("elicitation capability lost")
    }
}



// ===================== 4.3 McpServer 三形态判别封闭 =====================

@Test
public func types_mcpserver_stdio_roundtrip() {
    let server = McpServer.stdio("fs-server", "/usr/bin/mcp-fs",
        args: ArrayList<String>(["--root", "/tmp"]))
    let ev = EnvVariable()
    ev.name = "LOG"
    ev.value = "1"
    server.env = Some(ArrayList<EnvVariable>([ev]))
    // stdio 形态：wire 无 type 字段
    let raw = JsonValue.fromObject(server).stringify()
    @Expect(raw.contains("\"command\""), true)
    @Expect(raw.contains("\"args\""), true)
    @Expect(raw.contains("\"env\""), true)
    @Expect(raw.contains("\"type\""), false)
    let rt = roundTrip(server)
    @Expect(rt.name, "fs-server")
    @Expect(rt.command, Some("/usr/bin/mcp-fs"))
    match (rt.args) {
        case Some(list) =>
            @Expect(list.size, 2)
            @Expect(list[0], "--root")
        case None => @Fail("args lost")
    }
    match (rt.env) {
        case Some(list) =>
            @Expect(list.size, 1)
            @Expect(list[0].name, "LOG")
        case None => @Fail("env lost")
    }
    @Expect(rt.transport(), "stdio")
}

@Test
public func types_mcpserver_http_sse_roundtrip() {
    // http 形态
    let h = HttpHeader()
    h.name = "Authorization"
    h.value = "Bearer x"
    let server = McpServer.http("remote-tools", "https://example.com/mcp",
        headers: ArrayList<HttpHeader>([h]))
    let raw = JsonValue.fromObject(server).stringify()
    @Expect(raw.contains("\"type\":\"http\""), true)
    @Expect(raw.contains("\"url\""), true)
    @Expect(raw.contains("\"command\""), false)
    @Expect(raw.contains("\"headers\""), true)
    let rt = roundTrip(server)
    @Expect(rt.transport(), "http")
    @Expect(rt.url, Some("https://example.com/mcp"))
    match (rt.headers) {
        case Some(list) =>
            @Expect(list.size, 1)
            @Expect(list[0].name, "Authorization")
        case None => @Fail("headers lost")
    }
    @Expect(rt.command.isNone(), true)

    // sse 形态
    let sse = McpServer.sse("events", "https://example.com/sse")
    @Expect(JsonValue.fromObject(sse).stringify().contains("\"type\":\"sse\""), true)
    @Expect(roundTrip(sse).transport(), "sse")
}

@Test
public func types_mcpserver_shape_filtering() {
    // 判别封闭：http 形态下 command 字段不参与序列化（避免非法混合载荷）
    let server = McpServer.http("s", "https://example.com")
    server.command = Some("should-not-appear")
    let raw = JsonValue.fromObject(server).stringify()
    @Expect(raw.contains("should-not-appear"), false)
    @Expect(raw.contains("\"url\""), true)

    // stdio 形态下 url/headers 不序列化
    let std = McpServer.stdio("s", "cmd")
    std.url = Some("https://example.com")
    let raw2 = JsonValue.fromObject(std).stringify()
    @Expect(raw2.contains("\"url\""), false)
    @Expect(raw2.contains("\"command\""), true)

    // 未知 type（未来变体）：宽容保留所有字段
    let other = McpServer()
    other.name = "future"
    other.`type` = Some("_custom")
    other.url = Some("https://example.com")
    other.command = Some("c")
    let raw3 = JsonValue.fromObject(other).stringify()
    @Expect(raw3.contains("_custom"), true)
    @Expect(raw3.contains("\"command\""), true)
    let rt = roundTrip(other)
    @Expect(rt.transport(), "_custom")
}
