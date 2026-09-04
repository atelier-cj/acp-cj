package acp.types

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}

// ===================== Elicitation（引导式结构化输入） =====================
// 依据官方 schema（docs/schema/schema.json $defs elicitation 系）与
// https://agentclientprotocol.com/protocol/v1/elicitation
// 采用与 ContentBlock/SessionUpdate 一致的半结构化判别风格：
// 已知模式强类型收放，未知模式（_ 前缀 / 未来 ACP 变体）保留原始载荷。

// ---- 判别常量 ----

public const ElicitationModeForm: String = "form"
public const ElicitationModeUrl: String = "url"
public const ElicitationActionAccept: String = "accept"
public const ElicitationActionDecline: String = "decline"
public const ElicitationActionCancel: String = "cancel"
public const ElicitationSchemaTypeObject: String = "object"

// 属性 schema type 判别
public const PropTypeString: String = "string"
public const PropTypeNumber: String = "number"
public const PropTypeInteger: String = "integer"
public const PropTypeBoolean: String = "boolean"
public const PropTypeArray: String = "array"

// string 属性 format 判别（StringFormat）
public const StringFormatEmail: String = "email"
public const StringFormatUri: String = "uri"
public const StringFormatDate: String = "date"
public const StringFormatDateTime: String = "date-time"

// multi-select items 判别
public const MultiSelectItemsString: String = "string"
public const MultiSelectItemsTitled: String = "titled"

/// ElicitationId：URL 模式引导的唯一标识（字符串，opaque）
public type ElicitationId = String

/// 标题枚举选项（单选 oneOf / 多选 titled items 共用）
public class EnumOption <: JsonSerializable & JsonDeserializable<EnumOption> {
    // 注意：`const` 为仓颉关键字，字段名用反引号转义，访问时写 opt.`const`
    public var `const`: String = ""
    public var title: String = ""
    public var description: ?String = None
    public var _meta: ?JsonValue = None
    public init() {}
    public init(value: String, title: String, description!: ?String = None) {
        this.`const` = value
        this.title = title
        this.description = description
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("const").writeValue(this.`const`)
        w.writeName("title").writeValue(this.title)
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): EnumOption {
        let res = EnumOption()
        fromJsonObject(r,
            ("const", {=> res.`const` = r.readValue<String>()}),
            ("title", {=> res.title = r.readValue<String>()}),
            ("description", {=> res.description = r.readValue<Option<String>>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}

/**
 * ElicitationPropertySchema：表单字段的属性 schema（判别字段 `type`）。
 * 各变体共用本类，字段按变体语义使用（与官方 schema 属性一一对应）：
 *  - string ：title/description/minLength/maxLength/pattern/format/strDefault/enumValues(单选)/titledOptions(单选)/_meta
 *  - number ：title/description/numMinimum/numMaximum/numDefault/_meta
 *  - integer：title/description/intMinimum/intMaximum/intDefault/_meta
 *  - boolean：title/description/boolDefault/_meta
 *  - array  ：title/description/minItems/maxItems/itemsType(strEnum | titledItems)/arrDefault/_meta
 *  - 其他（_ 前缀或未来变体）：raw 原样保留
 */
public class ElicitationPropertySchema <: JsonSerializable & JsonDeserializable<ElicitationPropertySchema> {
    public var `type`: String = ""
    // 通用
    public var title: ?String = None
    public var description: ?String = None
    public var _meta: ?JsonValue = None
    // string
    public var minLength: ?Int64 = None
    public var maxLength: ?Int64 = None
    public var pattern: ?String = None
    public var format: ?String = None
    public var strDefault: ?String = None
    public var enumValues: ?ArrayList<String> = None      // 单选（untitled）
    public var titledOptions: ?ArrayList<EnumOption> = None // 单选（titled, oneOf）
    // number
    public var numMinimum: ?Float64 = None
    public var numMaximum: ?Float64 = None
    public var numDefault: ?Float64 = None
    // integer
    public var intMinimum: ?Int64 = None
    public var intMaximum: ?Int64 = None
    public var intDefault: ?Int64 = None
    // boolean
    public var boolDefault: ?Bool = None
    // array（multi-select）
    public var minItems: ?Int64 = None
    public var maxItems: ?Int64 = None
    public var itemsType: String = MultiSelectItemsString  // string | titled
    public var strEnum: ?ArrayList<String> = None          // items 为 string 时的允许值
    public var titledItems: ?ArrayList<EnumOption> = None  // items 为 titled
    public var arrDefault: ?ArrayList<String> = None
    // 未识别类型（other）：原样保留整个属性对象
    public var raw: ?JsonValue = None

    public init() {}

    // ---- 静态构造 ----

    public static func string(): ElicitationPropertySchema {
        let p = ElicitationPropertySchema()
        p.`type` = PropTypeString
        p
    }
    public static func number(): ElicitationPropertySchema {
        let p = ElicitationPropertySchema()
        p.`type` = PropTypeNumber
        p
    }
    public static func integer(): ElicitationPropertySchema {
        let p = ElicitationPropertySchema()
        p.`type` = PropTypeInteger
        p
    }
    public static func boolean(): ElicitationPropertySchema {
        let p = ElicitationPropertySchema()
        p.`type` = PropTypeBoolean
        p
    }
    public static func array(): ElicitationPropertySchema {
        let p = ElicitationPropertySchema()
        p.`type` = PropTypeArray
        p
    }
    /// 单选（untitled enum）：type=string + enumValues
    public static func singleSelect(values: ArrayList<String>, title!: ?String = None): ElicitationPropertySchema {
        let p = ElicitationPropertySchema.string()
        p.title = title
        p.enumValues = Some(values)
        p
    }
    /// 单选（titled enum）：type=string + titledOptions(oneOf)
    public static func titledSelect(options: ArrayList<EnumOption>, title!: ?String = None): ElicitationPropertySchema {
        let p = ElicitationPropertySchema.string()
        p.title = title
        p.titledOptions = Some(options)
        p
    }
    /// 多选（untitled）：type=array + strEnum
    public static func multiSelect(values: ArrayList<String>, title!: ?String = None): ElicitationPropertySchema {
        let p = ElicitationPropertySchema.array()
        p.title = title
        p.itemsType = MultiSelectItemsString
        p.strEnum = Some(values)
        p
    }
    /// 多选（titled）：type=array + titledItems
    public static func titledMultiSelect(options: ArrayList<EnumOption>, title!: ?String = None): ElicitationPropertySchema {
        let p = ElicitationPropertySchema.array()
        p.title = title
        p.itemsType = MultiSelectItemsTitled
        p.titledItems = Some(options)
        p
    }

    private func writeOptionalMeta(w: JsonWriter): Unit {
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
    }

    public func toJson(w: JsonWriter): Unit {
        if (let Some(v) <- this.raw) {
            // 未识别类型：原样输出（保持载荷无损）
            v.toJson(w)
            return
        }
        w.startObject()
        w.writeName("type").writeValue(this.`type`)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        match (this.`type`) {
            case "string" =>
                if (let Some(v) <- this.minLength) { w.writeName("minLength").writeValue(v) }
                if (let Some(v) <- this.maxLength) { w.writeName("maxLength").writeValue(v) }
                if (let Some(v) <- this.pattern) { w.writeName("pattern").writeValue(v) }
                if (let Some(v) <- this.format) { w.writeName("format").writeValue(v) }
                if (let Some(v) <- this.strDefault) { w.writeName("default").writeValue(v) }
                if (let Some(v) <- this.enumValues) {
                    w.writeName("enum")
                    w.startArray()
                    for (item in v) { w.writeValue(item) }
                    w.endArray()
                }
                if (let Some(v) <- this.titledOptions) {
                    w.writeName("oneOf")
                    w.startArray()
                    for (item in v) { item.toJson(w) }
                    w.endArray()
                }
            case "number" =>
                if (let Some(v) <- this.numMinimum) { w.writeName("minimum").writeValue(v) }
                if (let Some(v) <- this.numMaximum) { w.writeName("maximum").writeValue(v) }
                if (let Some(v) <- this.numDefault) { w.writeName("default").writeValue(v) }
            case "integer" =>
                if (let Some(v) <- this.intMinimum) { w.writeName("minimum").writeValue(v) }
                if (let Some(v) <- this.intMaximum) { w.writeName("maximum").writeValue(v) }
                if (let Some(v) <- this.intDefault) { w.writeName("default").writeValue(v) }
            case "boolean" =>
                if (let Some(v) <- this.boolDefault) { w.writeName("default").writeValue(v) }
            case "array" =>
                if (let Some(v) <- this.minItems) { w.writeName("minItems").writeValue(v) }
                if (let Some(v) <- this.maxItems) { w.writeName("maxItems").writeValue(v) }
                w.writeName("items")
                w.startObject()
                if (this.itemsType == MultiSelectItemsTitled) {
                    w.writeName("anyOf")
                    w.startArray()
                    for (item in this.titledItems ?? ArrayList<EnumOption>()) { item.toJson(w) }
                    w.endArray()
                } else {
                    w.writeName("type").writeValue(MultiSelectItemsString)
                    w.writeName("enum")
                    w.startArray()
                    for (item in this.strEnum ?? ArrayList<String>()) { w.writeValue(item) }
                    w.endArray()
                }
                w.endObject()
                if (let Some(v) <- this.arrDefault) {
                    w.writeName("default")
                    w.startArray()
                    for (item in v) { w.writeValue(item) }
                    w.endArray()
                }
            case _ => () // 未知 type（raw 已处理；此处仅写 type）
        }
        this.writeOptionalMeta(w)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ElicitationPropertySchema {
        let v = JsonValue.fromJson(r)
        let res = ElicitationPropertySchema()
        let obj = match (v) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("ElicitationPropertySchema must be an object")
        }
        let typ = optString(v["type"]) ?? ""
        res.`type` = typ
        // 未识别类型：保留原始对象（_ 前缀或未来变体）
        let known = typ == PropTypeString || typ == PropTypeNumber || typ == PropTypeInteger ||
            typ == PropTypeBoolean || typ == PropTypeArray
        if (!known) {
            res.raw = Some(v)
            return res
        }
        for ((k, vv) in obj) {
            match (k) {
                case "type" => ()
                case "title" => res.title = vv.asString()
                case "description" => res.description = vv.asString()
                case "_meta" => res._meta = Some(vv)
                case "minLength" => res.minLength = optInt64(Some(vv))
                case "maxLength" => res.maxLength = optInt64(Some(vv))
                case "pattern" => res.pattern = vv.asString()
                case "format" => res.format = vv.asString()
                case "enum" =>
                    match (vv) {
                        case JsonValue.Array(items) =>
                            let list = ArrayList<String>()
                            for (i in items) { list.add(i.asString() ?? "") }
                            res.enumValues = Some(list)
                        case _ => ()
                    }
                case "oneOf" =>
                    match (vv) {
                        case JsonValue.Array(items) =>
                            let list = ArrayList<EnumOption>()
                            for (i in items) { list.add(reparse<EnumOption>(i)) }
                            res.titledOptions = Some(list)
                        case _ => ()
                    }
                case "minimum" =>
                    if (typ == PropTypeInteger) { res.intMinimum = optInt64(Some(vv)) }
                    else { res.numMinimum = optFloat64(Some(vv)) }
                case "maximum" =>
                    if (typ == PropTypeInteger) { res.intMaximum = optInt64(Some(vv)) }
                    else { res.numMaximum = optFloat64(Some(vv)) }
                case "default" =>
                    if (typ == PropTypeString) { res.strDefault = vv.asString() }
                    else if (typ == PropTypeNumber) { res.numDefault = optFloat64(Some(vv)) }
                    else if (typ == PropTypeInteger) { res.intDefault = optInt64(Some(vv)) }
                    else if (typ == PropTypeBoolean) { res.boolDefault = vv.asBool() }
                    else {
                        match (vv) {
                            case JsonValue.Array(items) =>
                                let list = ArrayList<String>()
                                for (i in items) {
                                    match (i) {
                                        case JsonValue.String(s) => list.add(s)
                                        case _ => ()
                                    }
                                }
                                res.arrDefault = Some(list)
                            case _ => ()
                        }
                    }
                case "minItems" => res.minItems = optInt64(Some(vv))
                case "maxItems" => res.maxItems = optInt64(Some(vv))
                case "items" =>
                    if (vv["anyOf"].isSome()) {
                        res.itemsType = MultiSelectItemsTitled
                        match (vv["anyOf"]) {
                            case Some(JsonValue.Array(items)) =>
                                let list = ArrayList<EnumOption>()
                                for (i in items) { list.add(reparse<EnumOption>(i)) }
                                res.titledItems = Some(list)
                            case _ => ()
                        }
                    } else {
                        res.itemsType = MultiSelectItemsString
                        match (vv["enum"]) {
                            case Some(JsonValue.Array(items)) =>
                                let list = ArrayList<String>()
                                for (i in items) { list.add(i.asString() ?? "") }
                                res.strEnum = Some(list)
                            case _ => ()
                        }
                    }
                case _ => () // 忽略未知字段
            }
        }
        res
    }
}

/**
 * ElicitationSchema：表单请求的 JSON Schema（type 恒为 "object"，
 * properties 值为 ElicitationPropertySchema）。
 */
public class ElicitationSchema <: JsonSerializable & JsonDeserializable<ElicitationSchema> {
    public var `type`: String = ElicitationSchemaTypeObject
    public var title: ?String = None
    public var description: ?String = None
    public var required: ?ArrayList<String> = None
    public var properties = HashMap<String, ElicitationPropertySchema>()
    public var _meta: ?JsonValue = None

    public init() {}

    /// 便捷构造：from property list（无序）
    public static func of(props: Array<(String, ElicitationPropertySchema)>, required!: ?ArrayList<String> = None): ElicitationSchema {
        let s = ElicitationSchema()
        for ((name, p) in props) { s.properties[name] = p }
        s.required = required
        s
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue(this.`type`)
        if (let Some(v) <- this.title) { w.writeName("title").writeValue(v) }
        if (let Some(v) <- this.description) { w.writeName("description").writeValue(v) }
        w.writeName("properties")
        w.startObject()
        for ((k, p) in this.properties) {
            w.writeName(k)
            p.toJson(w)
        }
        w.endObject()
        if (let Some(v) <- this.required) {
            w.writeName("required")
            w.startArray()
            for (item in v) { w.writeValue(item) }
            w.endArray()
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ElicitationSchema {
        let v = JsonValue.fromJson(r)
        let res = ElicitationSchema()
        let obj = match (v) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("ElicitationSchema must be an object")
        }
        for ((k, vv) in obj) {
            match (k) {
                case "type" => res.`type` = vv.asString() ?? ""
                case "title" => res.title = vv.asString()
                case "description" => res.description = vv.asString()
                case "properties" =>
                    match (vv) {
                        case JsonValue.Map(m) =>
                            for ((name, pv) in m) {
                                res.properties[name] = reparse<ElicitationPropertySchema>(pv)
                            }
                        case _ => ()
                    }
                case "required" =>
                    match (vv) {
                        case JsonValue.Array(items) =>
                            let list = ArrayList<String>()
                            for (i in items) { list.add(i.asString() ?? "") }
                            res.required = Some(list)
                        case _ => ()
                    }
                case "_meta" => res._meta = Some(vv)
                case _ => () // 忽略未知字段
            }
        }
        res
    }
}

/**
 * CreateElicitationRequest：Agent → Client 的 elicitation/create 请求参数。
 * wire 上是扁平字段：
 *  - message（必填）
 *  - mode："form" | "url" | 其他（_ 前缀等）
 *  - scope：sessionId（±toolCallId）或 requestId（JSON-RPC 请求 id）
 *  - form 载荷：requestedSchema
 *  - url 载荷：elicitationId + url
 * 未知 mode/字段经 raw 保留，转发无损。
 */
public class CreateElicitationRequest <: JsonSerializable & JsonDeserializable<CreateElicitationRequest> {
    public var message: String = ""
    public var mode: String = ElicitationModeForm
    // scope（session 或 request 二选一）
    public var sessionId: ?String = None
    public var toolCallId: ?String = None
    public var requestId: ?JsonValue = None
    // form
    public var requestedSchema: ?ElicitationSchema = None
    // url
    public var elicitationId: ?ElicitationId = None
    public var url: ?String = None
    public var _meta: ?JsonValue = None
    // 未知 mode 或未知字段：原始参数保留
    public var raw: ?JsonValue = None

    public init() {}

    public static func form(sessionId: String, message: String,
                            requestedSchema: ElicitationSchema,
                            toolCallId!: ?String = None): CreateElicitationRequest {
        let req = CreateElicitationRequest()
        req.message = message
        req.mode = ElicitationModeForm
        req.sessionId = Some(sessionId)
        req.toolCallId = toolCallId
        req.requestedSchema = Some(requestedSchema)
        req
    }

    public static func formForRequest(requestId: JsonValue, message: String,
                                      requestedSchema: ElicitationSchema): CreateElicitationRequest {
        let req = CreateElicitationRequest()
        req.message = message
        req.mode = ElicitationModeForm
        req.requestId = Some(requestId)
        req.requestedSchema = Some(requestedSchema)
        req
    }

    public static func urlMode(sessionId: String, message: String, url: String,
                           elicitationId!: ?ElicitationId = None,
                           toolCallId!: ?String = None): CreateElicitationRequest {
        let req = CreateElicitationRequest()
        req.message = message
        req.mode = ElicitationModeUrl
        req.sessionId = Some(sessionId)
        req.toolCallId = toolCallId
        req.url = Some(url)
        req.elicitationId = elicitationId
        req
    }

    public static func urlForRequest(requestId: JsonValue, message: String, url: String,
                                     elicitationId!: ?ElicitationId = None): CreateElicitationRequest {
        let req = CreateElicitationRequest()
        req.message = message
        req.mode = ElicitationModeUrl
        req.requestId = Some(requestId)
        req.url = Some(url)
        req.elicitationId = elicitationId
        req
    }

    public func toJson(w: JsonWriter): Unit {
        if (let Some(v) <- this.raw) {
            v.toJson(w)
            return
        }
        w.startObject()
        w.writeName("message").writeValue(this.message)
        w.writeName("mode").writeValue(this.mode)
        if (let Some(v) <- this.sessionId) { w.writeName("sessionId").writeValue(v) }
        if (let Some(v) <- this.toolCallId) { w.writeName("toolCallId").writeValue(v) }
        if (let Some(v) <- this.requestId) { w.writeName("requestId"); v.toJson(w) }
        match (this.mode) {
            case "form" =>
                if (let Some(v) <- this.requestedSchema) { w.writeName("requestedSchema"); v.toJson(w) }
            case "url" =>
                if (let Some(v) <- this.elicitationId) { w.writeName("elicitationId").writeValue(v) }
                if (let Some(v) <- this.url) { w.writeName("url").writeValue(v) }
            case _ => () // 其他 mode：仅 mode 本身可表达
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): CreateElicitationRequest {
        let v = JsonValue.fromJson(r)
        let res = CreateElicitationRequest()
        let obj = match (v) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("CreateElicitationRequest must be an object")
        }
        res.message = optString(v["message"]) ?? ""
        res.mode = optString(v["mode"]) ?? ElicitationModeForm
        let knownMode = res.mode == ElicitationModeForm || res.mode == ElicitationModeUrl
        if (!knownMode) {
            // 未知 mode：保留原始载荷
            res.raw = Some(v)
            return res
        }
        for ((k, vv) in obj) {
            match (k) {
                case "message" => ()
                case "mode" => ()
                case "sessionId" => res.sessionId = vv.asString()
                case "toolCallId" => res.toolCallId = vv.asString()
                case "requestId" => res.requestId = Some(vv)
                case "requestedSchema" => res.requestedSchema = Some(reparse<ElicitationSchema>(vv))
                case "elicitationId" => res.elicitationId = vv.asString()
                case "url" => res.url = vv.asString()
                case "_meta" => res._meta = Some(vv)
                case _ => () // 忽略未知字段
            }
        }
        res
    }
}

/**
 * CreateElicitationResponse：Client → Agent 的 elicitation/create 响应。
 * action 判别：accept（可带 content）/ decline / cancel / 其他（_ 前缀等，raw 保留）。
 */
public class CreateElicitationResponse <: JsonSerializable & JsonDeserializable<CreateElicitationResponse> {
    public var action: String = ElicitationActionAccept
    /// accept 时用户提供的内容（对象，匹配请求的 requestedSchema）
    public var content: ?JsonValue = None
    public var _meta: ?JsonValue = None
    /// 未知 action 时保留原始载荷
    public var raw: ?JsonValue = None

    public init() {}

    public static func accepted(content!: ?JsonValue = None): CreateElicitationResponse {
        let resp = CreateElicitationResponse()
        resp.action = ElicitationActionAccept
        resp.content = content
        resp
    }
    public static func declined(): CreateElicitationResponse {
        let resp = CreateElicitationResponse()
        resp.action = ElicitationActionDecline
        resp
    }
    public static func cancelled(): CreateElicitationResponse {
        let resp = CreateElicitationResponse()
        resp.action = ElicitationActionCancel
        resp
    }
    public static func other(action: String, rawParams: JsonValue): CreateElicitationResponse {
        let resp = CreateElicitationResponse()
        resp.action = action
        resp.raw = Some(rawParams)
        resp
    }

    public func toJson(w: JsonWriter): Unit {
        if (let Some(v) <- this.raw) {
            v.toJson(w)
            return
        }
        w.startObject()
        w.writeName("action").writeValue(this.action)
        if (this.action == ElicitationActionAccept) {
            if (let Some(v) <- this.content) {
                w.writeName("content")
                v.toJson(w)
            }
        }
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): CreateElicitationResponse {
        let v = JsonValue.fromJson(r)
        let res = CreateElicitationResponse()
        let obj = match (v) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("CreateElicitationResponse must be an object")
        }
        res.action = optString(v["action"]) ?? ElicitationActionAccept
        let known = res.action == ElicitationActionAccept || res.action == ElicitationActionDecline ||
            res.action == ElicitationActionCancel
        if (!known) {
            res.raw = Some(v)
            return res
        }
        for ((k, vv) in obj) {
            match (k) {
                case "action" => ()
                case "content" => res.content = Some(vv)
                case "_meta" => res._meta = Some(vv)
                case _ => () // 忽略未知字段
            }
        }
        res
    }
}

/**
 * CompleteElicitationNotification：URL 模式引导的外部交互完成后，
 * Agent → Client 发送的通知（elicitationId 必填，只发给原连接）。
 */
public class CompleteElicitationNotification <: JsonSerializable & JsonDeserializable<CompleteElicitationNotification> {
    public var elicitationId: ElicitationId = ""
    public var _meta: ?JsonValue = None
    public init() {}
    public init(elicitationId: String) {
        this.elicitationId = elicitationId
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("elicitationId").writeValue(this.elicitationId)
        if (let Some(v) <- this._meta) { w.writeName("_meta").writeValue(v) }
        w.endObject()
    }
    public static func fromJson(r: JsonReader): CompleteElicitationNotification {
        let res = CompleteElicitationNotification()
        fromJsonObject(r,
            ("elicitationId", {=> res.elicitationId = r.readValue<String>()}),
            ("_meta", {=> res._meta = r.readValue<Option<JsonValue>>()})
        )
        res
    }
}
