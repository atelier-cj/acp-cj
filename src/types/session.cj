package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== SessionInfo =====================

public class SessionInfo <: JsonSerializable & JsonDeserializable<SessionInfo> {
    public var sessionId: String = ""
    public var cwd: String = ""
    public var title: ?String = None
    public var updatedAt: ?String = None
    public var additionalDirectories: ?ArrayList<String> = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("cwd").writeValue(this.cwd)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        if (let Some(v) <- this.updatedAt) { w.writeName("updatedAt").writeValue(v) }
        if (let Some(v) <- this.additionalDirectories) {
            w.writeName("additionalDirectories")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionInfo {
        let res = SessionInfo()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("cwd", {=> res.cwd = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<Option<String>>()}),
            ("updatedAt", {=> res.updatedAt = r.readValue<Option<String>>()}),
            ("additionalDirectories", {=> res.additionalDirectories = r.readValue<Option<ArrayList<String>>>()})
        )
        res
    }
}

// ===================== SessionMode =====================

public class SessionMode <: JsonSerializable & JsonDeserializable<SessionMode> {
    public var id: String = ""
    public var name: String = ""
    public var description: ?String = None
    public init() {}
    public init(id: String, name: String, description!: ?String = None) {
        this.id = id
        this.name = name
        this.description = description
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionMode {
        let res = SessionMode()
        fromJsonObject(r,
            ("id", {=> res.id = r.readValue<String>()}),
            ("name", {=> res.name = r.readValue<String>()}),
            ("description", {=> res.description = r.readValue<Option<String>>()})
        )
        res
    }
}

public class SessionModeState <: JsonSerializable & JsonDeserializable<SessionModeState> {
    public var currentModeId: String = ""
    public var availableModes = ArrayList<SessionMode>()
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("currentModeId").writeValue(this.currentModeId)
        w.writeName("availableModes")
        w.startArray()
        for (item in this.availableModes) { item.toJson(w) }
        w.endArray()
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionModeState {
        let res = SessionModeState()
        fromJsonObject(r,
            ("currentModeId", {=> res.currentModeId = r.readValue<String>()}),
            ("availableModes", {=> res.availableModes = r.readValue<ArrayList<SessionMode>>()})
        )
        res
    }
}

// ===================== SessionConfigOption =====================

public class SessionConfigSelectOption <: JsonSerializable & JsonDeserializable<SessionConfigSelectOption> {
    public var value: String = ""
    public var name: String = ""
    public var description: ?String = None
    public init() {}
    public init(value: String, name: String) {
        this.value = value
        this.name = name
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("value").writeValue(this.value)
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionConfigSelectOption {
        let res = SessionConfigSelectOption()
        fromJsonObject(r,
            ("value", {=> res.value = r.readValue<String>()}),
            ("name", {=> res.name = r.readValue<String>()}),
            ("description", {=> res.description = r.readValue<Option<String>>()})
        )
        res
    }
}

public class SessionConfigSelectGroup <: JsonSerializable & JsonDeserializable<SessionConfigSelectGroup> {
    public var group: String = ""
    public var name: String = ""
    public var options = ArrayList<SessionConfigSelectOption>()
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("group").writeValue(this.group)
        w.writeName("name").writeValue(this.name)
        w.writeName("options")
        w.startArray()
        for (item in this.options) { item.toJson(w) }
        w.endArray()
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionConfigSelectGroup {
        let res = SessionConfigSelectGroup()
        fromJsonObject(r,
            ("group", {=> res.group = r.readValue<String>()}),
            ("name", {=> res.name = r.readValue<String>()}),
            ("options", {=> res.options = r.readValue<ArrayList<SessionConfigSelectOption>>()})
        )
        res
    }
}

// SessionConfigOption：union（select / boolean），用 type 判别
public class SessionConfigOption <: JsonSerializable & JsonDeserializable<SessionConfigOption> {
    public var id: String = ""
    public var name: String = ""
    public var description: ?String = None
    public var category: ?String = None
    public var `type`: String = "select"
    // select 变体
    public var currentValue: ?String = None
    public var options: ?ArrayList<SessionConfigSelectOption> = None
    public var groups: ?ArrayList<SessionConfigSelectGroup> = None
    // boolean 变体
    public var currentBool: ?Bool = None
    public init() {}
    public init(id: String, name: String) {
        this.id = id
        this.name = name
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        if (let Some(v) <- this.category) { w.writeName("category").writeValue(v) }
        w.writeName("type").writeValue(this.`type`)
        match (this.`type`) {
            case "select" =>
                if (let Some(v) <- this.currentValue) { w.writeName("currentValue").writeValue(v) }
                if (let Some(v) <- this.options) {
                    w.writeName("options")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
                if (let Some(v) <- this.groups) {
                    w.writeName("options")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
            case "boolean" =>
                if (let Some(v) <- this.currentBool) { w.writeName("currentValue").writeValue(v) }
            case _ => ()
        }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionConfigOption {
        let v = JsonValue.fromJson(r)
        let res = SessionConfigOption()
        res.id = optString(v["id"]) ?? ""
        res.name = optString(v["name"]) ?? ""
        res.description = optString(v["description"])
        res.category = optString(v["category"])
        res.`type` = optString(v["type"]) ?? "select"
        match (res.`type`) {
            case "select" =>
                res.currentValue = optString(v["currentValue"])
                match (v["options"]) {
                    case Some(JsonValue.Array(items)) =>
                        if (items.size > 0) {
                            // 区分 ungrouped 与 grouped：grouped 的项含 "group" 字段
                            let firstIsGroup = match (items[0]["group"]) {
                                case Some(_) => true
                                case None => false
                            }
                            if (firstIsGroup) {
                                let g = ArrayList<SessionConfigSelectGroup>()
                                for (item in items) { g.add(reparse<SessionConfigSelectGroup>(item)) }
                                res.groups = Some(g)
                            } else {
                                let o = ArrayList<SessionConfigSelectOption>()
                                for (item in items) { o.add(reparse<SessionConfigSelectOption>(item)) }
                                res.options = Some(o)
                            }
                        }
                    case _ => ()
                }
            case "boolean" =>
                res.currentBool = optBool(v["currentValue"])
            case _ => ()
        }
        res
    }
}
