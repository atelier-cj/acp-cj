package acp

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.sync.*
import std.fs.{File, Path}
import acp.types.*

/**
 * SessionRecord：会话持久化记录。
 * 保存外部 ACP sessionId 与后端 agent session 的映射，以及会话元数据。
 */
public class SessionRecord <: JsonSerializable & JsonDeserializable<SessionRecord> {
    public var sessionId: String = ""
    public var cwd: String = ""
    public var backendSessionId: String = ""
    public var title: ?String = None
    public var createdAt: String = ""
    public init() {}
    public init(sessionId: String, cwd: String, backendSessionId: String, title!: ?String = None) {
        this.sessionId = sessionId
        this.cwd = cwd
        this.backendSessionId = backendSessionId
        this.title = title
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("cwd").writeValue(this.cwd)
        w.writeName("backendSessionId").writeValue(this.backendSessionId)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        w.writeName("createdAt").writeValue(this.createdAt)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): SessionRecord {
        let res = SessionRecord()
        fromJsonObject(r,
            ("sessionId", {=> res.sessionId = r.readValue<String>()}),
            ("cwd", {=> res.cwd = r.readValue<String>()}),
            ("backendSessionId", {=> res.backendSessionId = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<Option<String>>()}),
            ("createdAt", {=> res.createdAt = r.readValue<String>()})
        )
        res
    }
}

/**
 * SessionStore：会话映射的持久化存储（JSON 文件）。
 * 对标 pi-acp 的 session-map.json：让 session/load 在重启后仍能恢复会话。
 */
public class SessionStore {
    private let filePath: String
    private let records = HashMap<String, SessionRecord>()
    private let lock = Mutex()

    public init(filePath: String) {
        this.filePath = filePath
        this.reload()
    }

    public func upsert(record: SessionRecord): Unit {
        synchronized(this.lock) {
            this.records[record.sessionId] = record
            this.persistLocked()
        }
    }

    public func get(sessionId: String): ?SessionRecord {
        synchronized(this.lock) {
            this.records.get(sessionId)
        }
    }

    public func delete(sessionId: String): Unit {
        synchronized(this.lock) {
            if (this.records.remove(sessionId).isSome()) {
                this.persistLocked()
            }
        }
    }

    public func list(): ArrayList<SessionRecord> {
        synchronized(this.lock) {
            ArrayList<SessionRecord>(this.records.values())
        }
    }

    public func persist(): Unit {
        synchronized(this.lock) {
            this.persistLocked()
        }
    }

    public func reload(): Unit {
        synchronized(this.lock) {
            try {
                let text = String.fromUtf8(File.readFrom(Path(this.filePath)))
                let jv = JsonValue.parse(text)
                match (jv) {
                    case JsonValue.Map(m) =>
                        for ((k, v) in m) {
                            try {
                                this.records.add(k, reparse<SessionRecord>(v))
                            } catch (e: Exception) {
                                // 跳过损坏的记录
                            }
                        }
                    case _ => ()
                }
            } catch (e: Exception) {
                // 文件不存在或解析失败：视为空库
            }
        }
    }

    private func persistLocked(): Unit {
        let m = HashMap<String, JsonValue>()
        for ((k, v) in this.records) {
            m.add(k, JsonValue.fromObject(v))
        }
        let jv = JsonValue.Map(m)
        try {
            File.writeTo(Path(this.filePath), jv.toBytes())
        } catch (e: Exception) {
            // 持久化失败不致命（仅影响跨进程恢复）
        }
    }
}
