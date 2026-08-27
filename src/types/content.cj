package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer

// ===================== ContentBlock =====================
// ACP 的 ContentBlock 与 MCP 同构：text / image / audio / resource / resource_link。
// text 与 resource_link 是 baseline，image/audio/resource 需 promptCapabilities 开启。

public enum ContentBlockType {
    | Text
    | Image
    | Audio
    | Resource
    | ResourceLink
}

public class ContentBlock <: JsonSerializable & JsonDeserializable<ContentBlock> {
    public var `type`: ContentBlockType = ContentBlockType.Text
    // text
    public var text: ?String = None
    // image / audio
    public var data: ?String = None
    public var mimeType: ?String = None
    // image
    public var uri: ?String = None
    // resource
    public var resource: ?EmbeddedResourceResource = None
    // resource_link
    public var name: ?String = None
    public var size: ?Int64 = None
    public var description: ?String = None
    // 通用
    public var annotations: ?JsonValue = None

    public init() {}

    public static func ofText(v: String): ContentBlock {
        let c = ContentBlock()
        c.`type` = ContentBlockType.Text
        c.text = Some(v)
        c
    }
    public static func image(data: String, mimeType: String): ContentBlock {
        let c = ContentBlock()
        c.`type` = ContentBlockType.Image
        c.data = Some(data)
        c.mimeType = Some(mimeType)
        c
    }
    public static func ofResource(res: EmbeddedResourceResource): ContentBlock {
        let c = ContentBlock()
        c.`type` = ContentBlockType.Resource
        c.resource = Some(res)
        c
    }
    public static func resourceLink(uri: String, name: String): ContentBlock {
        let c = ContentBlock()
        c.`type` = ContentBlockType.ResourceLink
        c.uri = Some(uri)
        c.name = Some(name)
        c
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        match (this.`type`) {
            case ContentBlockType.Text =>
                w.writeName("type").writeValue("text")
                if (let Some(v) <- this.text) { w.writeName("text").writeValue(v) }
            case ContentBlockType.Image =>
                w.writeName("type").writeValue("image")
                if (let Some(v) <- this.data) { w.writeName("data").writeValue(v) }
                if (let Some(v) <- this.mimeType) { w.writeName("mimeType").writeValue(v) }
                if (let Some(v) <- this.uri) { w.writeName("uri").writeValue(v) }
            case ContentBlockType.Audio =>
                w.writeName("type").writeValue("audio")
                if (let Some(v) <- this.data) { w.writeName("data").writeValue(v) }
                if (let Some(v) <- this.mimeType) { w.writeName("mimeType").writeValue(v) }
            case ContentBlockType.Resource =>
                w.writeName("type").writeValue("resource")
                if (let Some(v) <- this.resource) { w.writeName("resource").writeValue(v) }
            case ContentBlockType.ResourceLink =>
                w.writeName("type").writeValue("resource_link")
                if (let Some(v) <- this.uri) { w.writeName("uri").writeValue(v) }
                if (let Some(v) <- this.name) { w.writeName("name").writeValue(v) }
                if (let Some(v) <- this.mimeType) { w.writeName("mimeType").writeValue(v) }
                if (let Some(v) <- this.size) { w.writeName("size").writeValue(v) }
                if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        }
        if (let Some(v) <- this.annotations) { w.writeName("annotations"); v.toJson(w) }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ContentBlock {
        let v = JsonValue.fromJson(r)
        let typStr = match (v["type"]) {
            case Some(JsonValue.String(t)) => t
            case _ => throw Exception("Missing 'type' field in ContentBlock")
        }
        let res = ContentBlock()
        let obj = match (v) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("ContentBlock must be an object")
        }
        for ((k, vv) in obj) {
            match (k) {
                case "type" => ()
                case "text" => res.text = vv.asString()
                case "data" => res.data = vv.asString()
                case "mimeType" => res.mimeType = vv.asString()
                case "uri" => res.uri = vv.asString()
                case "name" => res.name = vv.asString()
                case "size" => res.size = optInt64(Some(vv))
                case "description" => res.description = vv.asString()
                case "resource" => res.resource = reparse<EmbeddedResourceResource>(vv)
                case "annotations" => res.annotations = Some(vv)
                case _ => () // 忽略未知字段（extensibility）
            }
        }
        match (typStr) {
            case "text" => res.`type` = ContentBlockType.Text
            case "image" => res.`type` = ContentBlockType.Image
            case "audio" => res.`type` = ContentBlockType.Audio
            case "resource" => res.`type` = ContentBlockType.Resource
            case "resource_link" => res.`type` = ContentBlockType.ResourceLink
            case _ => throw Exception("Unknown content block type: ${typStr}")
        }
        res
    }
}

// resource 变体：text 或 blob
public class EmbeddedResourceResource <: JsonSerializable & JsonDeserializable<EmbeddedResourceResource> {
    public var uri: String = ""
    public var text: ?String = None
    public var blob: ?String = None
    public var mimeType: ?String = None
    public init() {}
    public init(uri: String, text: String, mimeType!: ?String = None) {
        this.uri = uri
        this.text = Some(text)
        this.mimeType = mimeType
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("uri").writeValue(this.uri)
        if (let Some(v) <- this.text) { w.writeName("text").writeValue(v) }
        if (let Some(v) <- this.blob) { w.writeName("blob").writeValue(v) }
        if (let Some(v) <- this.mimeType) { w.writeName("mimeType").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): EmbeddedResourceResource {
        let res = EmbeddedResourceResource()
        fromJsonObject(r,
            ("uri", {=> res.uri = r.readValue<String>()}),
            ("text", {=> res.text = r.readValue<Option<String>>()}),
            ("blob", {=> res.blob = r.readValue<Option<String>>()}),
            ("mimeType", {=> res.mimeType = r.readValue<Option<String>>()})
        )
        res
    }
}

// Annotations（与 MCP 相同，客户端展示提示）
public class Annotations <: JsonSerializable & JsonDeserializable<Annotations> {
    public var audience: ?ArrayList<String> = None
    public var priority: ?Float64 = None
    public var lastModified: ?String = None
    public init() {}
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        if (let Some(v) <- this.audience) {
            w.writeName("audience")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        if (let Some(v) <- this.priority) { w.writeName("priority").writeValue(v) }
        if (let Some(v) <- this.lastModified) { w.writeName("lastModified").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): Annotations {
        let res = Annotations()
        fromJsonObject(r,
            ("audience", {=> res.audience = r.readValue<Option<ArrayList<String>>>()}),
            ("priority", {=> res.priority = r.readValue<Option<Float64>>()}),
            ("lastModified", {=> res.lastModified = r.readValue<Option<String>>()})
        )
        res
    }
}
