package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== ToolKind / ToolCallStatus 常量 =====================

public const ToolKindRead: String = "read"
public const ToolKindEdit: String = "edit"
public const ToolKindDelete: String = "delete"
public const ToolKindMove: String = "move"
public const ToolKindSearch: String = "search"
public const ToolKindExecute: String = "execute"
public const ToolKindThink: String = "think"
public const ToolKindFetch: String = "fetch"
public const ToolKindSwitchMode: String = "switch_mode"
public const ToolKindOther: String = "other"

public const ToolStatusPending: String = "pending"
public const ToolStatusInProgress: String = "in_progress"
public const ToolStatusCompleted: String = "completed"
public const ToolStatusFailed: String = "failed"

// ===================== ToolCallLocation =====================

public class ToolCallLocation <: JsonSerializable & JsonDeserializable<ToolCallLocation> {
    public var path: String = ""
    public var line: ?Int64 = None
    public init() {}
    public init(path: String) { this.path = path }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("path").writeValue(this.path)
        if (let Some(v) <- this.line) { w.writeName("line").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ToolCallLocation {
        let res = ToolCallLocation()
        fromJsonObject(r,
            ("path", {=> res.path = r.readValue<String>()}),
            ("line", {=> res.line = r.readValue<Option<Int64>>()})
        )
        res
    }
}

// ===================== ToolCallContent（union: content / diff / terminal） =====================

public class ToolCallContent <: JsonSerializable & JsonDeserializable<ToolCallContent> {
    public var `type`: String = "content"     // content / diff / terminal
    // content 变体
    public var content: ?ContentBlock = None
    // diff 变体
    public var path: ?String = None
    public var oldText: ?String = None
    public var newText: ?String = None
    // terminal 变体
    public var terminalId: ?String = None
    public init() {}
    public static func ofContent(c: ContentBlock): ToolCallContent {
        let r = ToolCallContent()
        r.`type` = "content"
        r.content = Some(c)
        r
    }
    public static func diff(path: String, newText: String, oldText!: ?String = None): ToolCallContent {
        let r = ToolCallContent()
        r.`type` = "diff"
        r.path = Some(path)
        r.newText = Some(newText)
        r.oldText = oldText
        r
    }
    public static func terminal(terminalId: String): ToolCallContent {
        let r = ToolCallContent()
        r.`type` = "terminal"
        r.terminalId = Some(terminalId)
        r
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue(this.`type`)
        match (this.`type`) {
            case "content" =>
                if (let Some(v) <- this.content) { w.writeName("content").writeValue(v) }
            case "diff" =>
                if (let Some(v) <- this.path) { w.writeName("path").writeValue(v) }
                if (let Some(v) <- this.oldText) { w.writeName("oldText").writeValue(v) }
                if (let Some(v) <- this.newText) { w.writeName("newText").writeValue(v) }
            case "terminal" =>
                if (let Some(v) <- this.terminalId) { w.writeName("terminalId").writeValue(v) }
            case _ => ()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ToolCallContent {
        let v = JsonValue.fromJson(r)
        let typ = match (v["type"]) {
            case Some(JsonValue.String(t)) => t
            case _ => throw Exception("Missing 'type' field in ToolCallContent")
        }
        let res = ToolCallContent()
        res.`type` = typ
        match (typ) {
            case "content" =>
                res.content = match (v["content"]) {
                    case Some(c) => Some(reparse<ContentBlock>(c))
                    case None => None
                }
            case "diff" =>
                res.path = optString(v["path"])
                res.oldText = optString(v["oldText"])
                res.newText = optString(v["newText"])
            case "terminal" =>
                res.terminalId = optString(v["terminalId"])
            case _ => ()
        }
        res
    }
}

// ===================== ToolCall / ToolCallUpdate =====================

public class ToolCall <: JsonSerializable & JsonDeserializable<ToolCall> {
    public var toolCallId: String = ""
    public var title: String = ""
    public var kind: ?String = None
    public var status: ?String = None
    public var content: ?ArrayList<ToolCallContent> = None
    public var locations: ?ArrayList<ToolCallLocation> = None
    public var rawInput: ?JsonValue = None
    public var rawOutput: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("title").writeValue(this.title)
        if (let Some(v) <- this.kind) { w.writeName("kind").writeValue(v) }
        if (let Some(v) <- this.status) { w.writeName("status").writeValue(v) }
        if (let Some(v) <- this.content) {
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
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ToolCall {
        let res = ToolCall()
        fromJsonObject(r,
            ("toolCallId", {=> res.toolCallId = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<String>()}),
            ("kind", {=> res.kind = r.readValue<Option<String>>()}),
            ("status", {=> res.status = r.readValue<Option<String>>()}),
            ("content", {=> res.content = r.readValue<Option<ArrayList<ToolCallContent>>>()}),
            ("locations", {=> res.locations = r.readValue<Option<ArrayList<ToolCallLocation>>>()}),
            ("rawInput", {=> res.rawInput = r.readValue<Option<JsonValue>>()}),
            ("rawOutput", {=> res.rawOutput = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

public class ToolCallUpdate <: JsonSerializable & JsonDeserializable<ToolCallUpdate> {
    public var toolCallId: String = ""
    public var title: ?String = None
    public var kind: ?String = None
    public var status: ?String = None
    public var content: ?ArrayList<ToolCallContent> = None
    public var locations: ?ArrayList<ToolCallLocation> = None
    public var rawInput: ?JsonValue = None
    public var rawOutput: ?JsonValue = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("toolCallId").writeValue(this.toolCallId)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        if (let Some(v) <- this.kind) { w.writeName("kind").writeValue(v) }
        if (let Some(v) <- this.status) { w.writeName("status").writeValue(v) }
        if (let Some(v) <- this.content) {
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
        w.endObject()
    }
    public static func fromJson(r: JsonReader): ToolCallUpdate {
        let res = ToolCallUpdate()
        fromJsonObject(r,
            ("toolCallId", {=> res.toolCallId = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<Option<String>>()}),
            ("kind", {=> res.kind = r.readValue<Option<String>>()}),
            ("status", {=> res.status = r.readValue<Option<String>>()}),
            ("content", {=> res.content = r.readValue<Option<ArrayList<ToolCallContent>>>()}),
            ("locations", {=> res.locations = r.readValue<Option<ArrayList<ToolCallLocation>>>()}),
            ("rawInput", {=> res.rawInput = r.readValue<Option<JsonValue>>()}),
            ("rawOutput", {=> res.rawOutput = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}
