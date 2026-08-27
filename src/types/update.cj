package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== SessionUpdate 判别常量 =====================

public const SessionUpdateUserMessageChunk: String = "user_message_chunk"
public const SessionUpdateAgentMessageChunk: String = "agent_message_chunk"
public const SessionUpdateAgentThoughtChunk: String = "agent_thought_chunk"
public const SessionUpdateToolCall: String = "tool_call"
public const SessionUpdateToolCallUpdate: String = "tool_call_update"
public const SessionUpdatePlan: String = "plan"
public const SessionUpdateAvailableCommands: String = "available_commands_update"
public const SessionUpdateCurrentMode: String = "current_mode_update"
public const SessionUpdateConfigOption: String = "config_option_update"
public const SessionUpdateSessionInfo: String = "session_info_update"
public const SessionUpdateUsage: String = "usage_update"

// ===================== 子结构 =====================

public class Cost <: JsonSerializable & JsonDeserializable<Cost> {
    public var amount: Float64 = 0.0
    public var currency: String = "USD"
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("amount").writeValue(this.amount)
        w.writeName("currency").writeValue(this.currency)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): Cost {
        let res = Cost()
        fromJsonObject(r,
            ("amount", {=> res.amount = r.readValue<Float64>()}),
            ("currency", {=> res.currency = r.readValue<String>()})
        )
        res
    }
}

public class PlanEntry <: JsonSerializable & JsonDeserializable<PlanEntry> {
    public var content: String = ""
    public var priority: String = ""   // high/medium/low
    public var status: String = ""     // pending/in_progress/completed
    public init() {}
    public init(content: String, priority: String, status: String) {
        this.content = content
        this.priority = priority
        this.status = status
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("content").writeValue(this.content)
        w.writeName("priority").writeValue(this.priority)
        w.writeName("status").writeValue(this.status)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): PlanEntry {
        let res = PlanEntry()
        fromJsonObject(r,
            ("content", {=> res.content = r.readValue<String>()}),
            ("priority", {=> res.priority = r.readValue<String>()}),
            ("status", {=> res.status = r.readValue<String>()})
        )
        res
    }
}

public class AvailableCommandInput <: JsonSerializable & JsonDeserializable<AvailableCommandInput> {
    public var hint: String = ""
    public init() {}
    public init(hint: String) { this.hint = hint }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("hint").writeValue(this.hint)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AvailableCommandInput {
        let res = AvailableCommandInput()
        fromJsonObject(r,
            ("hint", {=> res.hint = r.readValue<String>()})
        )
        res
    }
}

public class AvailableCommand <: JsonSerializable & JsonDeserializable<AvailableCommand> {
    public var name: String = ""
    public var description: String = ""
    public var input: ?AvailableCommandInput = None
    public init() {}
    public init(name: String, description: String) {
        this.name = name
        this.description = description
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("description").writeValue(this.description)
        if (let Some(v) <- this.input) { w.writeName("input").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): AvailableCommand {
        let res = AvailableCommand()
        fromJsonObject(r,
            ("name", {=> res.name = r.readValue<String>()}),
            ("description", {=> res.description = r.readValue<String>()}),
            ("input", {=> res.input = r.readValue<Option<AvailableCommandInput>>()})
        )
        res
    }
}

// ===================== SessionUpdate =====================
// 判别联合的半结构化表示：sessionUpdate 为判别字段，其余字段按变体可选填充。
// 提供各变体的静态构造与 kind() 分发。

public class SessionUpdate <: JsonSerializable & JsonDeserializable<SessionUpdate> {
    public var sessionUpdate: String = ""
    // chunk 变体（user/agent/thought）
    public var content: ?ContentBlock = None
    public var messageId: ?String = None
    // tool_call / tool_call_update 变体
    public var toolCallId: ?String = None
    public var title: ?String = None
    public var kind: ?String = None
    public var status: ?String = None
    public var toolContent: ?ArrayList<ToolCallContent> = None
    public var locations: ?ArrayList<ToolCallLocation> = None
    public var rawInput: ?JsonValue = None
    public var rawOutput: ?JsonValue = None
    // plan 变体
    public var entries: ?ArrayList<PlanEntry> = None
    // available_commands_update 变体
    public var availableCommands: ?ArrayList<AvailableCommand> = None
    // current_mode_update 变体
    public var currentModeId: ?String = None
    // config_option_update 变体
    public var configOptions: ?ArrayList<SessionConfigOption> = None
    // session_info_update 变体
    public var infoTitle: ?String = None
    public var updatedAt: ?String = None
    // usage_update 变体
    public var used: ?UInt64 = None
    public var size: ?UInt64 = None
    public var cost: ?Cost = None
    public var _meta: ?JsonValue = None

    public init() {}

    // ---- 静态构造 ----

    public static func agentMessage(text: String, messageId!: ?String = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateAgentMessageChunk
        u.content = Some(ContentBlock.ofText(text))
        u.messageId = messageId
        u
    }
    public static func agentThought(text: String, messageId!: ?String = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateAgentThoughtChunk
        u.content = Some(ContentBlock.ofText(text))
        u.messageId = messageId
        u
    }
    public static func userMessageChunk(c: ContentBlock, messageId!: ?String = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateUserMessageChunk
        u.content = Some(c)
        u.messageId = messageId
        u
    }
    public static func toolCall(toolCallId: String, title: String, kind!: ?String = None,
                                status!: ?String = None, rawInput!: ?JsonValue = None,
                                locations!: ?ArrayList<ToolCallLocation> = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateToolCall
        u.toolCallId = Some(toolCallId)
        u.title = Some(title)
        u.kind = kind
        u.status = status
        u.rawInput = rawInput
        u.locations = locations
        u
    }
    public static func toolCallUpdate(toolCallId: String, status!: ?String = None,
                                      title!: ?String = None, kind!: ?String = None,
                                      content!: ?ArrayList<ToolCallContent> = None,
                                      rawInput!: ?JsonValue = None, rawOutput!: ?JsonValue = None,
                                      locations!: ?ArrayList<ToolCallLocation> = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateToolCallUpdate
        u.toolCallId = Some(toolCallId)
        u.status = status
        u.title = title
        u.kind = kind
        u.toolContent = content
        u.rawInput = rawInput
        u.rawOutput = rawOutput
        u.locations = locations
        u
    }
    public static func plan(entries: ArrayList<PlanEntry>): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdatePlan
        u.entries = Some(entries)
        u
    }
    public static func availableCommandsUpdate(commands: ArrayList<AvailableCommand>): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateAvailableCommands
        u.availableCommands = Some(commands)
        u
    }
    public static func currentModeUpdate(modeId: String): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateCurrentMode
        u.currentModeId = Some(modeId)
        u
    }
    public static func configOptionUpdate(options: ArrayList<SessionConfigOption>): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateConfigOption
        u.configOptions = Some(options)
        u
    }
    public static func sessionInfoUpdate(title!: ?String = None, updatedAt!: ?String = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateSessionInfo
        u.infoTitle = title
        u.updatedAt = updatedAt
        u
    }
    public static func usageUpdate(used: UInt64, size: UInt64, cost!: ?Cost = None): SessionUpdate {
        let u = SessionUpdate()
        u.sessionUpdate = SessionUpdateUsage
        u.used = Some(used)
        u.size = Some(size)
        u.cost = cost
        u
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionUpdate").writeValue(this.sessionUpdate)
        match (this.sessionUpdate) {
            case "user_message_chunk" => this.writeChunkFields(w)
            case "agent_message_chunk" => this.writeChunkFields(w)
            case "agent_thought_chunk" => this.writeChunkFields(w)
            case "tool_call" => this.writeToolCallFields(w, true)
            case "tool_call_update" => this.writeToolCallFields(w, false)
            case "plan" =>
                if (let Some(v) <- this.entries) {
                    w.writeName("entries")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
            case "available_commands_update" =>
                if (let Some(v) <- this.availableCommands) {
                    w.writeName("availableCommands")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
            case "current_mode_update" =>
                if (let Some(v) <- this.currentModeId) { w.writeName("currentModeId").writeValue(v) }
            case "config_option_update" =>
                if (let Some(v) <- this.configOptions) {
                    w.writeName("configOptions")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
            case "session_info_update" =>
                if (let Some(v) <- this.infoTitle) { w.writeName("title").writeValue(v) }
                if (let Some(v) <- this.updatedAt) { w.writeName("updatedAt").writeValue(v) }
            case "usage_update" =>
                if (let Some(v) <- this.used) { w.writeName("used").writeValue(v) }
                if (let Some(v) <- this.size) { w.writeName("size").writeValue(v) }
                if (let Some(v) <- this.cost) { w.writeName("cost").writeValue(v) }
            case _ => ()
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta"); v.toJson(w) }
        w.endObject()
    }

    private func writeChunkFields(w: JsonWriter): Unit {
        if (let Some(v) <- this.content) { w.writeName("content").writeValue(v) }
        if (let Some(v) <- this.messageId) { w.writeName("messageId").writeValue(v) }
    }

    private func writeToolCallFields(w: JsonWriter, includeTitle: Bool): Unit {
        if (let Some(v) <- this.toolCallId) { w.writeName("toolCallId").writeValue(v) }
        if (includeTitle) {
            if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        } else {
            if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        }
        if (let Some(v) <- this.kind) { w.writeName("kind").writeValue(v) }
        if (let Some(v) <- this.status) { w.writeName("status").writeValue(v) }
        if (let Some(v) <- this.toolContent) {
            w.writeName("content")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this.locations) {
            w.writeName("locations")
            w.startArray()
            for (item in v) { item.toJson(w) }
            w.endArray()
        }
        if (let Some(v) <- this.rawInput) { w.writeName("rawInput"); v.toJson(w) }
        if (let Some(v) <- this.rawOutput) { w.writeName("rawOutput"); v.toJson(w) }
    }

    public static func fromJson(r: JsonReader): SessionUpdate {
        let v = JsonValue.fromJson(r)
        let res = SessionUpdate()
        let disc = match (v["sessionUpdate"]) {
            case Some(JsonValue.String(t)) => t
            case _ => throw Exception("Missing 'sessionUpdate' discriminator")
        }
        res.sessionUpdate = disc
        res._meta = v["_meta"]
        // 仅 chunk 变体把 content 解析为单个 ContentBlock；
        // tool_call/tool_call_update 的 content 是 ToolCallContent 数组（见 toolContent）
        let isChunk = disc == SessionUpdateUserMessageChunk || disc == SessionUpdateAgentMessageChunk || disc == SessionUpdateAgentThoughtChunk
        res.content = if (isChunk) {
            match (v["content"]) {
                case Some(c) => Some(reparse<ContentBlock>(c))
                case None => None
            }
        } else {
            None
        }
        res.messageId = optString(v["messageId"])
        // 工具字段
        res.toolCallId = optString(v["toolCallId"])
        res.title = optString(v["title"])
        res.kind = optString(v["kind"])
        res.status = optString(v["status"])
        res.locations = match (v["locations"]) {
            case Some(JsonValue.Array(items)) =>
                let list = ArrayList<ToolCallLocation>()
                for (item in items) { list.add(reparse<ToolCallLocation>(item)) }
                Some(list)
            case _ => None
        }
        res.rawInput = v["rawInput"]
        res.rawOutput = v["rawOutput"]
        res.toolContent = match (v["content"]) {
            case Some(JsonValue.Array(items)) =>
                // 仅当判别为 tool_call 变体时按 ToolCallContent 数组解析
                if (disc == SessionUpdateToolCall || disc == SessionUpdateToolCallUpdate) {
                    let list = ArrayList<ToolCallContent>()
                    for (item in items) { list.add(reparse<ToolCallContent>(item)) }
                    Some(list)
                } else {
                    None
                }
            case _ => None
        }
        // plan
        res.entries = match (v["entries"]) {
            case Some(JsonValue.Array(items)) =>
                let list = ArrayList<PlanEntry>()
                for (item in items) { list.add(reparse<PlanEntry>(item)) }
                Some(list)
            case _ => None
        }
        // available_commands_update
        res.availableCommands = match (v["availableCommands"]) {
            case Some(JsonValue.Array(items)) =>
                let list = ArrayList<AvailableCommand>()
                for (item in items) { list.add(reparse<AvailableCommand>(item)) }
                Some(list)
            case _ => None
        }
        res.currentModeId = optString(v["currentModeId"])
        res.configOptions = match (v["configOptions"]) {
            case Some(JsonValue.Array(items)) =>
                let list = ArrayList<SessionConfigOption>()
                for (item in items) { list.add(reparse<SessionConfigOption>(item)) }
                Some(list)
            case _ => None
        }
        res.infoTitle = optString(v["title"])
        res.updatedAt = optString(v["updatedAt"])
        res.used = optUInt64(v["used"])
        res.size = optUInt64(v["size"])
        res.cost = match (v["cost"]) {
            case Some(c) => Some(reparse<Cost>(c))
            case None => None
        }
        res
    }
}

// ===================== SessionNotification（session/update 的 params） =====================

public class SessionNotification <: JsonSerializable & JsonDeserializable<SessionNotification> {
    public var sessionId: String = ""
    public var update = SessionUpdate()
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("update").writeValue(this.update)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionNotification {
        let res = SessionNotification()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("update", {=> res.update = r.readValue<SessionUpdate>()})
        )
        res
    }
}
