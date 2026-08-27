package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== 常量（判别字符串） =====================

public const StopReasonEndTurn: String = "end_turn"
public const StopReasonMaxTokens: String = "max_tokens"
public const StopReasonMaxTurnRequests: String = "max_turn_requests"
public const StopReasonRefusal: String = "refusal"
public const StopReasonCancelled: String = "cancelled"

// ===================== 空结果 =====================

public class EmptyResult <: JsonSerializable & JsonDeserializable<EmptyResult> {
    public func toJson(w: JsonWriter): Unit { w.startObject(); w.endObject() }
    public static func fromJson(r: JsonReader): EmptyResult {
        fromJsonObject(r, [])
        EmptyResult()
    }
}

// ===================== Initialize =====================

public class InitializeRequest <: JsonSerializable & JsonDeserializable<InitializeRequest> {
    public var protocolVersion: Int64 = 1
    public var clientCapabilities = ClientCapabilities()
    public var clientInfo: ?Implementation = None
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("protocolVersion").writeValue(this.protocolVersion)
        w.writeName("clientCapabilities").writeValue(this.clientCapabilities)
        if (let Some(v) <- this.clientInfo) { w.writeName("clientInfo").writeValue(v) }
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): InitializeRequest {
        let res = InitializeRequest()
        fromJsonObject(r,
            ("protocolVersion", {=> res.protocolVersion = r.readValue<Int64>()}),
            ("clientCapabilities", {=> res.clientCapabilities = r.readValue<ClientCapabilities>()}),
            ("clientInfo", {=> res.clientInfo = r.readValue<Option<Implementation>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class AuthMethod <: JsonSerializable & JsonDeserializable<AuthMethod> {
    public var id: String = ""
    public var name: String = ""
    public var description: ?String = None
    public var `type`: ?String = None       // "agent"(默认) / "terminal"
    public var args: ?ArrayList<String> = None
    public var env: ?HashMap<String, String> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        if (let Some(v) <- this.`type`) { w.writeName("type").writeValue(v) }
        if (let Some(v) <- this.args) {
            w.writeName("args")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        if (let Some(v) <- this.env) {
            w.writeName("env")
            w.startObject()
            for ((k, val) in v) { w.writeName(k).writeValue(val) }
            w.endObject()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AuthMethod {
        let res = AuthMethod()
        fromJsonObject(r,
            ("id", {=> res.id = r.readValue<String>()}),
            ("name", {=> res.name = r.readValue<String>()}),
            ("description", {=> res.description = r.readValue<Option<String>>()}),
            ("type", {=> res.`type` = r.readValue<Option<String>>()}),
            ("args", {=> res.args = r.readValue<Option<ArrayList<String>>>()}),
            ("env", {=> res.env = r.readValue<Option<HashMap<String, String>>>()})
        )
        res
    }
}

public class InitializeResponse <: JsonSerializable & JsonDeserializable<InitializeResponse> {
    public var protocolVersion: Int64 = 1
    public var agentCapabilities = AgentCapabilities()
    public var agentInfo: ?Implementation = None
    public var authMethods = ArrayList<AuthMethod>()
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("protocolVersion").writeValue(this.protocolVersion)
        w.writeName("agentCapabilities").writeValue(this.agentCapabilities)
        if (let Some(v) <- this.agentInfo) { w.writeName("agentInfo").writeValue(v) }
        if (this.authMethods.size > 0) {
            w.writeName("authMethods")
            w.startArray()
            for (item in this.authMethods) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): InitializeResponse {
        let res = InitializeResponse()
        fromJsonObject(r,
            ("protocolVersion", {=> res.protocolVersion = r.readValue<Int64>()}),
            ("agentCapabilities", {=> res.agentCapabilities = r.readValue<AgentCapabilities>()}),
            ("agentInfo", {=> res.agentInfo = r.readValue<Option<Implementation>>()}),
            ("authMethods", {=> res.authMethods = r.readValue<ArrayList<AuthMethod>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class AuthenticateRequest <: JsonSerializable & JsonDeserializable<AuthenticateRequest> {
    public var methodId: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("methodId").writeValue(this.methodId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AuthenticateRequest {
        let res = AuthenticateRequest()
        fromJsonObject(r,
            ("methodId", {=> res.methodId = r.readValue<String>()})
        )
        res
    }
}

// ===================== Session =====================

public class McpServer <: JsonSerializable & JsonDeserializable<McpServer> {
    public var name: String = ""
    // stdio
    public var command: ?String = None
    public var args: ?ArrayList<String> = None
    public var env: ?ArrayList<EnvVariable> = None
    // http / sse
    public var `type`: ?String = None
    public var url: ?String = None
    public var headers: ?ArrayList<HttpHeader> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.command) { w.writeName("command").writeValue(v) }
        if (let Some(v) <- this.`type`) { w.writeName("type").writeValue(v) }
        if (let Some(v) <- this.url) { w.writeName("url").writeValue(v) }
        if (let Some(v) <- this.args) {
            w.writeName("args")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        if (let Some(v) <- this.env) {
            w.writeName("env")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this.headers) {
            w.writeName("headers")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): McpServer {
        let res = McpServer()
        fromJsonObject(r,
            ("name", {=> res.name = r.readValue<String>()}),
            ("command", {=> res.command = r.readValue<Option<String>>()}),
            ("type", {=> res.`type` = r.readValue<Option<String>>()}),
            ("url", {=> res.url = r.readValue<Option<String>>()}),
            ("args", {=> res.args = r.readValue<Option<ArrayList<String>>>()}),
            ("env", {=> res.env = r.readValue<Option<ArrayList<EnvVariable>>>()}),
            ("headers", {=> res.headers = r.readValue<Option<ArrayList<HttpHeader>>>()})
        )
        res
    }
}

public class EnvVariable <: JsonSerializable & JsonDeserializable<EnvVariable> {
    public var name: String = ""
    public var value: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("value").writeValue(this.value)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): EnvVariable {
        let res = EnvVariable()
        fromJsonObject(r,
            ("name", {=> res.name = r.readValue<String>()}),
            ("value", {=> res.value = r.readValue<String>()})
        )
        res
    }
}

public class HttpHeader <: JsonSerializable & JsonDeserializable<HttpHeader> {
    public var name: String = ""
    public var value: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("value").writeValue(this.value)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): HttpHeader {
        let res = HttpHeader()
        fromJsonObject(r,
            ("name", {=> res.name = r.readValue<String>()}),
            ("value", {=> res.value = r.readValue<String>()})
        )
        res
    }
}

public class NewSessionRequest <: JsonSerializable & JsonDeserializable<NewSessionRequest> {
    public var cwd: String = ""
    public var mcpServers = ArrayList<McpServer>()
    public var additionalDirectories: ?ArrayList<String> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("cwd").writeValue(this.cwd)
        w.writeName("mcpServers")
        w.startArray()
        for (item in this.mcpServers) { item.toJson(w) }
        w.endArray()
        if (let Some(v) <- this.additionalDirectories) {
            w.writeName("additionalDirectories")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): NewSessionRequest {
        let res = NewSessionRequest()
        fromJsonObject(r,
            ("cwd", {=> res.cwd = r.readValue<String>()}),
            ("mcpServers", {=> res.mcpServers = r.readValue<ArrayList<McpServer>>()}),
            ("additionalDirectories", {=> res.additionalDirectories = r.readValue<Option<ArrayList<String>>>()})
        )
        res
    }
}

public class NewSessionResponse <: JsonSerializable & JsonDeserializable<NewSessionResponse> {
    public var sessionId: String = ""
    public var modes: ?SessionModeState = None
    public var configOptions: ?ArrayList<SessionConfigOption> = None
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        if (let Some(v) <- this.modes) { w.writeName("modes").writeValue(v) }
        if (let Some(v) <- this.configOptions) {
            w.writeName("configOptions")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): NewSessionResponse {
        let res = NewSessionResponse()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("modes", {=> res.modes = r.readValue<Option<SessionModeState>>()}),
            ("configOptions", {=> res.configOptions = r.readValue<Option<ArrayList<SessionConfigOption>>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

// 生命周期请求共用字段（load/resume）
public class SessionLifecycleRequest <: JsonSerializable & JsonDeserializable<SessionLifecycleRequest> {
    public var sessionId: String = ""
    public var cwd: String = ""
    public var mcpServers = ArrayList<McpServer>()
    public var additionalDirectories: ?ArrayList<String> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("cwd").writeValue(this.cwd)
        w.writeName("mcpServers")
        w.startArray()
        for (item in this.mcpServers) { item.toJson(w) }
        w.endArray()
        if (let Some(v) <- this.additionalDirectories) {
            w.writeName("additionalDirectories")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionLifecycleRequest {
        let res = SessionLifecycleRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("cwd", {=> res.cwd = r.readValue<String>()}),
            ("mcpServers", {=> res.mcpServers = r.readValue<ArrayList<McpServer>>()}),
            ("additionalDirectories", {=> res.additionalDirectories = r.readValue<Option<ArrayList<String>>>()})
        )
        res
    }
}

public type LoadSessionRequest = SessionLifecycleRequest
public type ResumeSessionRequest = SessionLifecycleRequest

public class LoadSessionResponse <: JsonSerializable & JsonDeserializable<LoadSessionResponse> {
    public var modes: ?SessionModeState = None
    public var configOptions: ?ArrayList<SessionConfigOption> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.modes) { w.writeName("modes").writeValue(v) }
        if (let Some(v) <- this.configOptions) {
            w.writeName("configOptions")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): LoadSessionResponse {
        let res = LoadSessionResponse()
        fromJsonObject(r,
            ("modes", {=> res.modes = r.readValue<Option<SessionModeState>>()}),
            ("configOptions", {=> res.configOptions = r.readValue<Option<ArrayList<SessionConfigOption>>>()})
        )
        res
    }
}
public type ResumeSessionResponse = LoadSessionResponse

public class ListSessionsRequest <: JsonSerializable & JsonDeserializable<ListSessionsRequest> {
    public var cursor: ?String = None
    public var cwd: ?String = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.cursor) { w.writeName("cursor").writeValue(v) }
        if (let Some(v) <- this.cwd) { w.writeName("cwd").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ListSessionsRequest {
        let res = ListSessionsRequest()
        fromJsonObject(r,
            ("cursor", {=> res.cursor = r.readValue<Option<String>>()}),
            ("cwd", {=> res.cwd = r.readValue<Option<String>>()})
        )
        res
    }
}

public class ListSessionsResponse <: JsonSerializable & JsonDeserializable<ListSessionsResponse> {
    public var sessions = ArrayList<SessionInfo>()
    public var nextCursor: ?String = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessions")
        w.startArray()
        for (item in this.sessions) { item.toJson(w) }
        w.endArray()
        if (let Some(v) <- this.nextCursor) { w.writeName("nextCursor").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ListSessionsResponse {
        let res = ListSessionsResponse()
        fromJsonObject(r,
            ("sessions", {=> res.sessions = r.readValue<ArrayList<SessionInfo>>()}),
            ("nextCursor", {=> res.nextCursor = r.readValue<Option<String>>()})
        )
        res
    }
}

public class DeleteSessionRequest <: JsonSerializable & JsonDeserializable<DeleteSessionRequest> {
    public var sessionId: String = ""
    public init() {}
    public init(sessionId: String) { this.sessionId = sessionId }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): DeleteSessionRequest {
        let res = DeleteSessionRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()})
        )
        res
    }
}

public class CloseSessionRequest <: JsonSerializable & JsonDeserializable<CloseSessionRequest> {
    public var sessionId: String = ""
    public init() {}
    public init(sessionId: String) { this.sessionId = sessionId }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CloseSessionRequest {
        let res = CloseSessionRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()})
        )
        res
    }
}

// ===================== Prompt =====================

public class PromptRequest <: JsonSerializable & JsonDeserializable<PromptRequest> {
    public var sessionId: String = ""
    public var prompt = ArrayList<ContentBlock>()
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("prompt")
        w.startArray()
        for (item in this.prompt) { item.toJson(w) }
        w.endArray()
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): PromptRequest {
        let res = PromptRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("prompt", {=> res.prompt = r.readValue<ArrayList<ContentBlock>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class PromptResponse <: JsonSerializable & JsonDeserializable<PromptResponse> {
    public var stopReason: String = StopReasonEndTurn
    public var _meta: ?JsonValue = None
    public init() {}
    public init(stopReason: String) { this.stopReason = stopReason }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("stopReason").writeValue(this.stopReason)
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): PromptResponse {
        let res = PromptResponse()
        fromJsonObject(r,
            ("stopReason", {=> res.stopReason = r.readValue<String>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class CancelNotification <: JsonSerializable & JsonDeserializable<CancelNotification> {
    public var sessionId: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CancelNotification {
        let res = CancelNotification()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()})
        )
        res
    }
}

// ===================== Session 模式 / 配置 =====================

public class SetSessionModeRequest <: JsonSerializable & JsonDeserializable<SetSessionModeRequest> {
    public var sessionId: String = ""
    public var modeId: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("modeId").writeValue(this.modeId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SetSessionModeRequest {
        let res = SetSessionModeRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("modeId", {=> res.modeId = r.readValue<String>()})
        )
        res
    }
}

public class SetSessionConfigOptionRequest <: JsonSerializable & JsonDeserializable<SetSessionConfigOptionRequest> {
    public var sessionId: String = ""
    public var configId: String = ""
    // value 变体：value_id（默认）或 boolean
    public var value: ?String = None
    public var boolValue: ?Bool = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("configId").writeValue(this.configId)
        if (let Some(v) <- this.boolValue) {
            w.writeName("type").writeValue("boolean")
            w.writeName("value").writeValue(v)
        } else if (let Some(v) <- this.value) {
            w.writeName("value").writeValue(v)
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SetSessionConfigOptionRequest {
        let v = JsonValue.fromJson(r)
        let res = SetSessionConfigOptionRequest()
        res.sessionId = optString(v["sessionId"]) ?? ""
        res.configId = optString(v["configId"]) ?? ""
        let typ = optString(v["type"])
        if (typ == Some("boolean")) {
            res.boolValue = optBool(v["value"])
        } else {
            res.value = optString(v["value"])
        }
        res
    }
}

public class SetSessionConfigOptionResponse <: JsonSerializable & JsonDeserializable<SetSessionConfigOptionResponse> {
    public var configOptions = ArrayList<SessionConfigOption>()
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("configOptions")
        w.startArray()
        for (item in this.configOptions) { item.toJson(w) }
        w.endArray()
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SetSessionConfigOptionResponse {
        let res = SetSessionConfigOptionResponse()
        fromJsonObject(r,
            ("configOptions", {=> res.configOptions = r.readValue<ArrayList<SessionConfigOption>>()})
        )
        res
    }
}

// ===================== 权限 =====================

public class PermissionOption <: JsonSerializable & JsonDeserializable<PermissionOption> {
    public var optionId: String = ""
    public var name: String = ""
    public var kind: String = ""     // allow_once/allow_always/reject_once/reject_always
    public init() {}
    public init(optionId: String, name: String, kind: String) {
        this.optionId = optionId
        this.name = name
        this.kind = kind
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("optionId").writeValue(this.optionId)
        w.writeName("name").writeValue(this.name)
        w.writeName("kind").writeValue(this.kind)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): PermissionOption {
        let res = PermissionOption()
        fromJsonObject(r,
            ("optionId", {=> res.optionId = r.readValue<String>()}),
            ("name", {=> res.name = r.readValue<String>()}),
            ("kind", {=> res.kind = r.readValue<String>()})
        )
        res
    }
}

public class RequestPermissionRequest <: JsonSerializable & JsonDeserializable<RequestPermissionRequest> {
    public var sessionId: String = ""
    public var toolCall = ToolCallUpdate()
    public var options = ArrayList<PermissionOption>()
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("toolCall").writeValue(this.toolCall)
        w.writeName("options")
        w.startArray()
        for (item in this.options) { item.toJson(w) }
        w.endArray()
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): RequestPermissionRequest {
        let res = RequestPermissionRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("toolCall", {=> res.toolCall = r.readValue<ToolCallUpdate>()}),
            ("options", {=> res.options = r.readValue<ArrayList<PermissionOption>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

// outcome 变体：cancelled / selected
public class RequestPermissionResponse <: JsonSerializable & JsonDeserializable<RequestPermissionResponse> {
    public var outcome = RequestPermissionOutcome()
    public init() {}
    public init(outcome: RequestPermissionOutcome) { this.outcome = outcome }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("outcome").writeValue(this.outcome)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): RequestPermissionResponse {
        let res = RequestPermissionResponse()
        fromJsonObject(r,
            ("outcome", {=> res.outcome = r.readValue<RequestPermissionOutcome>()})
        )
        res
    }
}

public class RequestPermissionOutcome <: JsonSerializable & JsonDeserializable<RequestPermissionOutcome> {
    public var outcome: String = ""     // "cancelled" | "selected"
    public var optionId: ?String = None
    public init() {}
    public static func cancelled(): RequestPermissionOutcome {
        let r = RequestPermissionOutcome()
        r.outcome = "cancelled"
        r
    }
    public static func selected(optionId: String): RequestPermissionOutcome {
        let r = RequestPermissionOutcome()
        r.outcome = "selected"
        r.optionId = Some(optionId)
        r
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("outcome").writeValue(this.outcome)
        if (let Some(v) <- this.optionId) { w.writeName("optionId").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): RequestPermissionOutcome {
        let res = RequestPermissionOutcome()
        fromJsonObject(r,
            ("outcome", {=> res.outcome = r.readValue<String>()}),
            ("optionId", {=> res.optionId = r.readValue<Option<String>>()})
        )
        res
    }
}

// ===================== 文件系统 =====================

public class ReadTextFileRequest <: JsonSerializable & JsonDeserializable<ReadTextFileRequest> {
    public var sessionId: String = ""
    public var path: String = ""
    public var line: ?Int64 = None
    public var limit: ?Int64 = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("path").writeValue(this.path)
        if (let Some(v) <- this.line) { w.writeName("line").writeValue(v) }
        if (let Some(v) <- this.limit) { w.writeName("limit").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ReadTextFileRequest {
        let res = ReadTextFileRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("path", {=> res.path = r.readValue<String>()}),
            ("line", {=> res.line = r.readValue<Option<Int64>>()}),
            ("limit", {=> res.limit = r.readValue<Option<Int64>>()})
        )
        res
    }
}

public class ReadTextFileResponse <: JsonSerializable & JsonDeserializable<ReadTextFileResponse> {
    public var content: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("content").writeValue(this.content)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ReadTextFileResponse {
        let res = ReadTextFileResponse()
        fromJsonObject(r,
            ("content", {=> res.content = r.readValue<String>()})
        )
        res
    }
}

public class WriteTextFileRequest <: JsonSerializable & JsonDeserializable<WriteTextFileRequest> {
    public var sessionId: String = ""
    public var path: String = ""
    public var content: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("path").writeValue(this.path)
        w.writeName("content").writeValue(this.content)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): WriteTextFileRequest {
        let res = WriteTextFileRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("path", {=> res.path = r.readValue<String>()}),
            ("content", {=> res.content = r.readValue<String>()})
        )
        res
    }
}

// ===================== 终端 =====================

public class CreateTerminalRequest <: JsonSerializable & JsonDeserializable<CreateTerminalRequest> {
    public var sessionId: String = ""
    public var command: String = ""
    public var args: ?ArrayList<String> = None
    public var env: ?ArrayList<EnvVariable> = None
    public var cwd: ?String = None
    public var outputByteLimit: ?Int64 = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("command").writeValue(this.command)
        if (let Some(v) <- this.args) {
            w.writeName("args")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        if (let Some(v) <- this.env) {
            w.writeName("env")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this.cwd) { w.writeName("cwd").writeValue(v) }
        if (let Some(v) <- this.outputByteLimit) { w.writeName("outputByteLimit").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CreateTerminalRequest {
        let res = CreateTerminalRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("command", {=> res.command = r.readValue<String>()}),
            ("args", {=> res.args = r.readValue<Option<ArrayList<String>>>()}),
            ("env", {=> res.env = r.readValue<Option<ArrayList<EnvVariable>>>()}),
            ("cwd", {=> res.cwd = r.readValue<Option<String>>()}),
            ("outputByteLimit", {=> res.outputByteLimit = r.readValue<Option<Int64>>()})
        )
        res
    }
}

public class CreateTerminalResponse <: JsonSerializable & JsonDeserializable<CreateTerminalResponse> {
    public var terminalId: String = ""
    public init() {}
    public init(terminalId: String) { this.terminalId = terminalId }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("terminalId").writeValue(this.terminalId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CreateTerminalResponse {
        let res = CreateTerminalResponse()
        fromJsonObject(r,
            ("terminalId", {=> res.terminalId = r.readValue<String>()})
        )
        res
    }
}

public class TerminalIdRequest <: JsonSerializable & JsonDeserializable<TerminalIdRequest> {
    public var sessionId: String = ""
    public var terminalId: String = ""
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("terminalId").writeValue(this.terminalId)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): TerminalIdRequest {
        let res = TerminalIdRequest()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("terminalId", {=> res.terminalId = r.readValue<String>()})
        )
        res
    }
}

public type KillTerminalRequest = TerminalIdRequest
public type ReleaseTerminalRequest = TerminalIdRequest
public type WaitForTerminalExitRequest = TerminalIdRequest
public type TerminalOutputRequest = TerminalIdRequest

public class TerminalExitStatus <: JsonSerializable & JsonDeserializable<TerminalExitStatus> {
    public var exitCode: ?Int64 = None
    public var signal: ?String = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.exitCode) { w.writeName("exitCode").writeValue(v) }
        if (let Some(v) <- this.signal) { w.writeName("signal").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): TerminalExitStatus {
        let res = TerminalExitStatus()
        fromJsonObject(r,
            ("exitCode", {=> res.exitCode = r.readValue<Option<Int64>>()}),
            ("signal", {=> res.signal = r.readValue<Option<String>>()})
        )
        res
    }
}

public class TerminalOutputResponse <: JsonSerializable & JsonDeserializable<TerminalOutputResponse> {
    public var output: String = ""
    public var truncated: Bool = false
    public var exitStatus: ?TerminalExitStatus = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("output").writeValue(this.output)
        w.writeName("truncated").writeValue(this.truncated)
        if (let Some(v) <- this.exitStatus) { w.writeName("exitStatus").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): TerminalOutputResponse {
        let res = TerminalOutputResponse()
        fromJsonObject(r,
            ("output", {=> res.output = r.readValue<String>()}),
            ("truncated", {=> res.truncated = r.readValue<Bool>()}),
            ("exitStatus", {=> res.exitStatus = r.readValue<Option<TerminalExitStatus>>()})
        )
        res
    }
}

public class WaitForTerminalExitResponse <: JsonSerializable & JsonDeserializable<WaitForTerminalExitResponse> {
    public var exitCode: ?Int64 = None
    public var signal: ?String = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.exitCode) { w.writeName("exitCode").writeValue(v) }
        if (let Some(v) <- this.signal) { w.writeName("signal").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): WaitForTerminalExitResponse {
        let res = WaitForTerminalExitResponse()
        fromJsonObject(r,
            ("exitCode", {=> res.exitCode = r.readValue<Option<Int64>>()}),
            ("signal", {=> res.signal = r.readValue<Option<String>>()})
        )
        res
    }
}

// ===================== 取消请求（$/cancel_request） =====================

public class CancelRequestNotification <: JsonSerializable & JsonDeserializable<CancelRequestNotification> {
    public var requestId: JsonValue = JsonValue.Number(0.0)
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("requestId"); this.requestId.toJson(w)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CancelRequestNotification {
        let res = CancelRequestNotification()
        fromJsonObject(r,
            ("requestId", {=> res.requestId = r.readValue<JsonValue>()})
        )
        res
    }
}
