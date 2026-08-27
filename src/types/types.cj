package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== 常量 =====================

public const ProtocolVersionV1: Int64 = 1

// ---- JSON-RPC 标准错误 ----
public const PARSE_ERROR: Int64 = -32700
public const INVALID_REQUEST: Int64 = -32600
public const METHOD_NOT_FOUND: Int64 = -32601
public const INVALID_PARAMS: Int64 = -32602
public const INTERNAL_ERROR: Int64 = -32603
// ---- ACP 保留区间 ----
public const REQUEST_CANCELLED: Int64 = -32800
public const AUTH_REQUIRED: Int64 = -32000
public const RESOURCE_NOT_FOUND: Int64 = -32002

// ===================== 基础类型 =====================

// _meta 字段统一用 Option<JsonValue> 表示；extensibility 允许附加任意元数据，
// 实现必须不做假设，仅透传。
public type Meta = Option<JsonValue>
public type SessionId = String
public type MessageId = String
public type ToolCallId = String

// Implementation：agentInfo / clientInfo 共用
public class Implementation <: JsonSerializable & JsonDeserializable<Implementation> {
    public var name: String = ""
    public var title: ?String = None
    public var version: String = ""
    public init() {}
    public init(name: String, version: String) {
        this.name = name
        this.version = version
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        w.writeName("version").writeValue(this.version)
        w.endObject()
    }
    public static func fromJson(r: JsonReader): Implementation {
        let res = Implementation()
        fromJsonObject(r,
            ("name", {=> res.name = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<Option<String>>()}),
            ("version", {=> res.version = r.readValue<String>()})
        )
        res
    }
}

// ===================== 辅助工具 =====================

// 从 JsonReader 读取一个可选值（字段存在但为 null 时读为 None）
public func readOptionalString(r: JsonReader): ?String {
    r.readValue<Option<String>>()
}

// 通用：把 JsonValue 序列化后的字节重新构造一个 JsonReader，
// 用于 union 类型按判别字段分发的二次解析。
public func reparse<T>(v: JsonValue): T where T <: JsonDeserializable<T> {
    let buf = ByteBuffer(v.toBytes())
    let nr = JsonReader(buf)
    T.fromJson(nr)
}

// 把 JsonSerializable 转成 JsonValue（用于 rawInput/rawOutput/_meta 等动态字段）
public func toJsonValue(v: JsonSerializable): JsonValue {
    JsonValue.fromObject(v)
}

// ===================== fromJsonObject =====================
// 与 mcp-cj 相同的对象解析辅助：按字段名分派读取回调，未知字段跳过。
public func fromJsonObject(r: JsonReader, list: Array<(String, () -> Unit)>) {
    let refs = HashMap<String, () -> Unit>(list)
    while (let Some(v) <- r.peek()) {
        match (v) {
            case BeginObject =>
                r.startObject()
                while (r.peek() != EndObject) {
                    let n = r.readName()
                    if (refs.contains(n)) { refs[n]() }
                    else { r.skip() }
                }
                r.endObject()
                break
            case _ => throw Exception()
        }
    }
}

// ===================== 可选值读取辅助 =====================
// 从 ?JsonValue 中读取可选值，供 fromJson 的分支解析使用。

public func optString(v: ?JsonValue): ?String {
    match (v) {
        case Some(jv) => jv.asString()
        case None => None
    }
}
public func optBool(v: ?JsonValue): ?Bool {
    match (v) {
        case Some(jv) => jv.asBool()
        case None => None
    }
}
public func optInt64(v: ?JsonValue): ?Int64 {
    match (v) {
        case Some(jv) => match (jv.asNumber()) {
            case Some(n) => Some(Int64(n))
            case None => None
        }
        case None => None
    }
}
public func optUInt64(v: ?JsonValue): ?UInt64 {
    match (v) {
        case Some(jv) => match (jv.asNumber()) {
            case Some(n) => Some(UInt64(n))
            case None => None
        }
        case None => None
    }
}
public func optFloat64(v: ?JsonValue): ?Float64 {
    match (v) {
        case Some(jv) => jv.asNumber()
        case None => None
    }
}
