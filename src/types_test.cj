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
