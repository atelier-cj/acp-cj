package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== Capabilities =====================
// 遵循 schema：所有 capability 字段可选，未声明视为不支持。

// 空能力标记（如 sessionCapabilities.list/delete/resume/close、auth.logout 等）：
// 协议中以空对象 `{}` 表示"支持"。
public class EmptyCapability <: JsonSerializable & JsonDeserializable<EmptyCapability> {
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject(); w.endObject()
    }
    public static func fromJson(r: JsonReader): EmptyCapability {
        fromJsonObject(r, [])
        EmptyCapability()
    }
}

// ---- Agent 侧能力 ----

public class PromptCapabilities <: JsonSerializable & JsonDeserializable<PromptCapabilities> {
    public var image: Bool = false
    public var audio: Bool = false
    public var embeddedContext: Bool = false
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("image").writeValue(this.image)
        w.writeName("audio").writeValue(this.audio)
        w.writeName("embeddedContext").writeValue(this.embeddedContext)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): PromptCapabilities {
        let res = PromptCapabilities()
        fromJsonObject(r,
            ("image", {=> res.image = r.readValue<Bool>()}),
            ("audio", {=> res.audio = r.readValue<Bool>()}),
            ("embeddedContext", {=> res.embeddedContext = r.readValue<Bool>()})
        )
        res
    }
}

public class McpCapabilities <: JsonSerializable & JsonDeserializable<McpCapabilities> {
    public var http: Bool = false
    public var sse: Bool = false
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("http").writeValue(this.http)
        w.writeName("sse").writeValue(this.sse)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): McpCapabilities {
        let res = McpCapabilities()
        fromJsonObject(r,
            ("http", {=> res.http = r.readValue<Bool>()}),
            ("sse", {=> res.sse = r.readValue<Bool>()})
        )
        res
    }
}

public class AgentAuthCapabilities <: JsonSerializable & JsonDeserializable<AgentAuthCapabilities> {
    public var logout: ?EmptyCapability = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.logout) { w.writeName("logout").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AgentAuthCapabilities {
        let res = AgentAuthCapabilities()
        fromJsonObject(r,
            ("logout", {=> res.logout = r.readValue<Option<EmptyCapability>>()})
        )
        res
    }
}

public class SessionCapabilities <: JsonSerializable & JsonDeserializable<SessionCapabilities> {
    public var list: ?EmptyCapability = None
    public var delete: ?EmptyCapability = None
    public var resume: ?EmptyCapability = None
    public var close: ?EmptyCapability = None
    public var additionalDirectories: ?EmptyCapability = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.list) { w.writeName("list").writeValue(v) }
        if (let Some(v) <- this.delete) { w.writeName("delete").writeValue(v) }
        if (let Some(v) <- this.resume) { w.writeName("resume").writeValue(v) }
        if (let Some(v) <- this.close) { w.writeName("close").writeValue(v) }
        if (let Some(v) <- this.additionalDirectories) { w.writeName("additionalDirectories").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionCapabilities {
        let res = SessionCapabilities()
        fromJsonObject(r,
            ("list", {=> res.list = r.readValue<Option<EmptyCapability>>()}),
            ("delete", {=> res.delete = r.readValue<Option<EmptyCapability>>()}),
            ("resume", {=> res.resume = r.readValue<Option<EmptyCapability>>()}),
            ("close", {=> res.close = r.readValue<Option<EmptyCapability>>()}),
            ("additionalDirectories", {=> res.additionalDirectories = r.readValue<Option<EmptyCapability>>()})
        )
        res
    }
}

public class AgentCapabilities <: JsonSerializable & JsonDeserializable<AgentCapabilities> {
    public var loadSession: Bool = false
    public var promptCapabilities = PromptCapabilities()
    public var mcpCapabilities = McpCapabilities()
    public var sessionCapabilities = SessionCapabilities()
    public var auth = AgentAuthCapabilities()
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("loadSession").writeValue(this.loadSession)
        w.writeName("promptCapabilities").writeValue(this.promptCapabilities)
        w.writeName("mcpCapabilities").writeValue(this.mcpCapabilities)
        w.writeName("sessionCapabilities").writeValue(this.sessionCapabilities)
        w.writeName("auth").writeValue(this.auth)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AgentCapabilities {
        let res = AgentCapabilities()
        fromJsonObject(r,
            ("loadSession", {=> res.loadSession = r.readValue<Bool>()}),
            ("promptCapabilities", {=> res.promptCapabilities = r.readValue<PromptCapabilities>()}),
            ("mcpCapabilities", {=> res.mcpCapabilities = r.readValue<McpCapabilities>()}),
            ("sessionCapabilities", {=> res.sessionCapabilities = r.readValue<SessionCapabilities>()}),
            ("auth", {=> res.auth = r.readValue<AgentAuthCapabilities>()})
        )
        res
    }
}

// ---- Client 侧能力 ----

public class FileSystemCapabilities <: JsonSerializable & JsonDeserializable<FileSystemCapabilities> {
    public var readTextFile: Bool = false
    public var writeTextFile: Bool = false
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("readTextFile").writeValue(this.readTextFile)
        w.writeName("writeTextFile").writeValue(this.writeTextFile)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): FileSystemCapabilities {
        let res = FileSystemCapabilities()
        fromJsonObject(r,
            ("readTextFile", {=> res.readTextFile = r.readValue<Bool>()}),
            ("writeTextFile", {=> res.writeTextFile = r.readValue<Bool>()})
        )
        res
    }
}

public class AuthCapabilities <: JsonSerializable & JsonDeserializable<AuthCapabilities> {
    public var terminal: Bool = false
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("terminal").writeValue(this.terminal)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AuthCapabilities {
        let res = AuthCapabilities()
        fromJsonObject(r,
            ("terminal", {=> res.terminal = r.readValue<Bool>()})
        )
        res
    }
}

// ClientSessionCapabilities：当前仅 configOptions
public class ClientSessionCapabilities <: JsonSerializable & JsonDeserializable<ClientSessionCapabilities> {
    public var configOptions: ?EmptyCapability = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.configOptions) { w.writeName("configOptions").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ClientSessionCapabilities {
        let res = ClientSessionCapabilities()
        fromJsonObject(r,
            ("configOptions", {=> res.configOptions = r.readValue<Option<EmptyCapability>>()})
        )
        res
    }
}

// Elicitation 能力：省略/null = 不支持；`{}` 空对象 = 支持该模式（form/url 各自显式声明）
public class ElicitationCapabilities <: JsonSerializable & JsonDeserializable<ElicitationCapabilities> {
    public var form: ?EmptyCapability = None
    public var url: ?EmptyCapability = None
    public var _meta: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.form) { w.writeName("form").writeValue(v) }
        if (let Some(v) <- this.url) { w.writeName("url").writeValue(v) }
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ElicitationCapabilities {
        let res = ElicitationCapabilities()
        fromJsonObject(r,
            ("form", {=> res.form = r.readValue<Option<EmptyCapability>>()}),
            ("url", {=> res.url = r.readValue<Option<EmptyCapability>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class ClientCapabilities <: JsonSerializable & JsonDeserializable<ClientCapabilities> {
    public var fs = FileSystemCapabilities()
    public var terminal: Bool = false
    public var auth = AuthCapabilities()
    public var elicitation: ?ElicitationCapabilities = None
    public var session: ?ClientSessionCapabilities = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("fs").writeValue(this.fs)
        w.writeName("terminal").writeValue(this.terminal)
        w.writeName("auth").writeValue(this.auth)
        if (let Some(v) <- this.elicitation) { w.writeName("elicitation").writeValue(v) }
        if (let Some(v) <- this.session) { w.writeName("session").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ClientCapabilities {
        let res = ClientCapabilities()
        fromJsonObject(r,
            ("fs", {=> res.fs = r.readValue<FileSystemCapabilities>()}),
            ("terminal", {=> res.terminal = r.readValue<Bool>()}),
            ("auth", {=> res.auth = r.readValue<AuthCapabilities>()}),
            ("elicitation", {=> res.elicitation = r.readValue<Option<ElicitationCapabilities>>()}),
            ("session", {=> res.session = r.readValue<Option<ClientSessionCapabilities>>()})
        )
        res
    }
}
