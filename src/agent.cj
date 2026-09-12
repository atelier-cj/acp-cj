package acp

import jsonvalue.*
import ystyle::jsonrpc.{JsonRpcServer, Transport, NewlineFraming, HandlerContext, HandlerResult, Result, JsonRpcError, RequestId}
import std.collection.*
import std.sync.*
import std.fs.Path
import stdx.encoding.json.stream.*
import sonyflake.*
import std.random.Random
import acp.types.*
import acp.transport.*

// ===================== 回调类型 =====================

/// 会话初始状态：session/new 响应中携带的 modes / configOptions（A5）
public class SessionInitialState {
    public var modes: ?SessionModeState = None
    public var configOptions: ?ArrayList<SessionConfigOption> = None
    public init(modes!: ?SessionModeState = None,
                configOptions!: ?ArrayList<SessionConfigOption> = None) {
        this.modes = modes
        this.configOptions = configOptions
    }
}

public type NewSessionCallback = (String /*sessionId*/, String /*cwd*/) -> Unit
public type CancelCallback = (String /*sessionId*/) -> Unit
public type CloseCallback = (String /*sessionId*/) -> Unit
public type ListSessionsCallback = (ListSessionsRequest) -> ListSessionsResponse
public type SetModeCallback = (String /*sessionId*/, String /*modeId*/) -> Bool
public type SetConfigOptionCallback = (String /*sessionId*/, SetSessionConfigOptionRequest) -> ?ArrayList<SessionConfigOption>
// 异步会话加载：业务层负责重放历史（agent.sessionUpdate），完成后 complete(resp)，
// 失败 fail(err)。重放通知必须全部发出后，才调用 complete 响应 session/load 请求。
public type LoadSessionHandler = (SessionLifecycleRequest, (JsonValue) -> Unit /*complete*/, (JsonRpcError) -> Unit /*fail*/) -> Unit
public type DeleteSessionCallback = (String /*sessionId*/) -> Bool
public type ResumeSessionCallback = (SessionLifecycleRequest) -> ?ResumeSessionResponse
public type CancelRequestCallback = (String /*requestId 字符串化*/) -> Unit

/// 扩展方法处理器：入参为请求 params（原始 JsonValue），返回 Some(result) 作为响应结果；
/// 返回 None 表示未处理（响应 -32601 Method not found）。
public type ExtensionHandler = (JsonValue /*params*/) -> ?JsonValue

/// 会话初始状态处理器：session/new 时按请求内容构造初始 modes/configOptions；
/// 返回 None 表示不带初始状态（响应维持仅 sessionId）。
public type SessionInitialStateHandler = (NewSessionRequest /*params*/) -> ?SessionInitialState

/**
 * PromptContext：一次 prompt 回合的执行上下文。
 * 处理器通过 emit 推送 session/update 通知，通过 isCancelled 检测取消。
 */
public class PromptContext {
    public let sessionId: String
    public let prompt: ArrayList<ContentBlock>
    public let cwd: String
    private let emitFn: (SessionUpdate) -> Unit
    private let cancelFlag: AtomicBool
    // 客户端在 initialize 中声明的能力查询（规范要求调用 fs/terminal/elicitation 前 MUST 检查；
    // 未握手时为空对象 = 全部不支持）
    private let capsQuery: () -> ClientCapabilities

    public init(sessionId: String, cwd: String, prompt: ArrayList<ContentBlock>,
                emitFn: (SessionUpdate) -> Unit, cancelFlag: AtomicBool,
                capsQuery: () -> ClientCapabilities) {
        this.sessionId = sessionId
        this.cwd = cwd
        this.prompt = prompt
        this.emitFn = emitFn
        this.cancelFlag = cancelFlag
        this.capsQuery = capsQuery
    }

    public func emit(update: SessionUpdate): Unit { this.emitFn(update) }
    public func isCancelled(): Bool { this.cancelFlag.load() }
    public func getText(): String {
        var out = ""
        for (b in this.prompt) {
            match (b.text) {
                case Some(t) => out += t
                case None => ()
            }
        }
        out
    }

    /// 客户端在 initialize 中声明的能力（未握手时为空对象 = 全部不支持）
    public func clientCaps(): ClientCapabilities { this.capsQuery() }

    /// 客户端是否支持 fs/read_text_file（规范：不支持则 MUST NOT 调用）
    public func canReadTextFile(): Bool { this.capsQuery().fs.readTextFile }

    /// 客户端是否支持 fs/write_text_file
    public func canWriteTextFile(): Bool { this.capsQuery().fs.writeTextFile }

    /// 客户端是否支持全部 terminal/* 方法
    public func canUseTerminal(): Bool { this.capsQuery().terminal }
}

public type PromptHandler = (PromptContext) -> PromptResponse

// ===================== 会话状态 =====================

public class SessionState {
    public let sessionId: String
    public let cwd: String
    public let mcpServers: ArrayList<McpServer>
    // 客户端声明的附加工作区根（session/new 携带；宿主按需用于信任/作用域扩展）
    public let additionalDirectories: ArrayList<String>
    public let cancelFlag = AtomicBool(false)
    // 同一会话同一时刻只允许一个进行中的回合
    public let promptLock = Mutex()

    public init(sessionId: String, cwd: String, mcpServers: ArrayList<McpServer>,
        additionalDirectories: ArrayList<String>) {
        this.sessionId = sessionId
        this.cwd = cwd
        this.mcpServers = mcpServers
        this.additionalDirectories = additionalDirectories
    }

    public init(sessionId: String, cwd: String, mcpServers: ArrayList<McpServer>) {
        this(sessionId, cwd, mcpServers, ArrayList<String>())
    }
}

/**
 * AcpAgent：ACP Agent（服务端）框架。
 * 基于 JsonRpcServer 实现双工 JSON-RPC：处理 Client 的方法请求，同时可
 * 主动推送 session/update 通知、反向调用 Client 的 terminal/fs/permission 方法。
 */
public class AcpAgent {
    private let rpcServer: JsonRpcServer
    private let sessions = HashMap<String, SessionState>()
    private let sessionLock = Mutex()
    private let sonyflake = Sonyflake(Setting(Random().nextUInt16()))

    // 声明信息
    public var agentInfo: Implementation
    public var capabilities = AgentCapabilities()
    public var authMethods = ArrayList<AuthMethod>()
    public var protocolVersion: Int64 = ProtocolVersionV1
    // 握手时对端（Client）声明的能力：宿主可在 initialize 之后（session/new 等回调中）读取，
    // 例如按 clientCapabilities.session.configOptions 决定是否下发 config options
    public var clientCapabilities = ClientCapabilities()
    // 认证门控：true 表示 session/new 前必须通过 authenticate（或终端登录）
    public var authRequired: Bool = false
    private var authenticated: Bool = false

    // 业务钩子
    private var promptHandler: ?PromptHandler = None
    private var onNewSessionCb: ?NewSessionCallback = None
    private var initialSessionStateCb: ?SessionInitialStateHandler = None
    private var onCancelCb: ?CancelCallback = None
    private var onCloseCb: ?CloseCallback = None
    private var listSessionsCb: ?ListSessionsCallback = None
    private var setModeCb: ?SetModeCallback = None
    private var setConfigOptionCb: ?SetConfigOptionCallback = None
    private var loadSessionCb: ?LoadSessionHandler = None
    private var deleteSessionCb: ?DeleteSessionCallback = None
    private var resumeSessionCb: ?ResumeSessionCallback = None
    private var cancelRequestCb: ?CancelRequestCallback = None
    private var onAuthenticatedCb: ?CancelRequestCallback = None
    private var onLoggedOutCb: ?CancelRequestCallback = None

    // $/cancel_request 支持：JSON-RPC 请求 id -> 进行中的 prompt 所在会话
    private let activePrompts = HashMap<String, String>()

    public init(transport: Transport, name: String, version: String) {
        this.agentInfo = Implementation(name, version)
        this.rpcServer = JsonRpcServer(transport, framing: NewlineFraming())
        this.registerHandlers()
    }

    // ===================== 钩子 =====================

    public func setPromptHandler(handler: PromptHandler): Unit { this.promptHandler = Some(handler) }
    public func setOnNewSession(cb: NewSessionCallback): Unit { this.onNewSessionCb = Some(cb) }

    /// 注册会话初始状态处理器：session/new 响应携带 modes/configOptions（A5）。
    /// load/resume 响应由对应回调自行构造（LoadSessionResponse/ResumeSessionResponse 已可带）。
    public func setInitialSessionState(cb: SessionInitialStateHandler): Unit {
        this.initialSessionStateCb = Some(cb)
    }
    public func setOnCancel(cb: CancelCallback): Unit { this.onCancelCb = Some(cb) }
    public func setOnClose(cb: CloseCallback): Unit { this.onCloseCb = Some(cb) }
    public func setOnListSessions(cb: ListSessionsCallback): Unit { this.listSessionsCb = Some(cb) }
    public func setOnSetMode(cb: SetModeCallback): Unit { this.setModeCb = Some(cb) }
    public func setOnSetConfigOption(cb: SetConfigOptionCallback): Unit { this.setConfigOptionCb = Some(cb) }
    public func setOnLoadSession(cb: LoadSessionHandler): Unit { this.loadSessionCb = Some(cb) }
    public func setOnDeleteSession(cb: DeleteSessionCallback): Unit { this.deleteSessionCb = Some(cb) }
    public func setOnResumeSession(cb: ResumeSessionCallback): Unit { this.resumeSessionCb = Some(cb) }
    public func setOnCancelRequest(cb: CancelRequestCallback): Unit { this.cancelRequestCb = Some(cb) }
    public func setOnAuthenticated(cb: CancelRequestCallback): Unit { this.onAuthenticatedCb = Some(cb) }
    public func setOnLoggedOut(cb: CancelRequestCallback): Unit { this.onLoggedOutCb = Some(cb) }

    /**
     * 注册 ACP 扩展方法（客户端发来的自定义请求）。
     * ACP 约定自定义方法名以 `_` 开头；非 `_` 前缀的方法名直接抛异常拒绝，
     * 避免误覆盖协议方法。
     */
    public func registerExtensionMethod(method: String, handler: ExtensionHandler): Unit {
        if (!method.startsWith("_")) {
            throw Exception("ACP extension methods must start with '_': ${method}")
        }
        this.rpcServer.register(method, { ctx =>
            let params: JsonValue = ctx.getRawParams() ?? JsonValue.Null
            match (handler(params)) {
                case Some(result) => HandlerResult.ok(result)
                case None => HandlerResult.err(METHOD_NOT_FOUND,
                    "Extension method returned no result: ${method}")
            }
        })
    }

    // 是否已认证（未启用门控时恒为 true）
    public func isAuthenticated(): Bool { !this.authRequired || this.authenticated }

    // 会话声明的 MCP server 配置（session/new 携带；宿主可按需建立连接，未知会话返回 None）
    public func sessionMcpServers(sessionId: String): ?ArrayList<McpServer> {
        synchronized(this.sessionLock) {
            match (this.sessions.get(sessionId)) {
                case Some(s) => Some(s.mcpServers)
                case None => None
            }
        }
    }

    // 会话声明的附加工作区根（session/new 携带；未知会话返回 None）
    public func sessionAdditionalDirectories(sessionId: String): ?ArrayList<String> {
        synchronized(this.sessionLock) {
            match (this.sessions.get(sessionId)) {
                case Some(s) => Some(s.additionalDirectories)
                case None => None
            }
        }
    }

    // ===================== 生命周期 =====================

    public func start(): Unit { this.rpcServer.start() }
    public func serve(): Unit { this.rpcServer.serve() }
    public func close(): Unit { this.rpcServer.close() }

    // ===================== 内置方法注册 =====================

    private func registerHandlers() {
        this.rpcServer.register("initialize", { ctx => this.handleInitialize(ctx) })
        this.rpcServer.register("session/new", { ctx => this.handleNewSession(ctx) })
        this.rpcServer.registerAsyncErr("session/prompt", { ctx, complete, fail => this.handlePromptAsync(ctx, complete, fail) })
        this.rpcServer.register("session/cancel", { ctx => this.handleCancel(ctx) })
        this.rpcServer.register("session/close", { ctx => this.handleClose(ctx) })
        this.rpcServer.register("session/list", { ctx => this.handleListSessions(ctx) })
        this.rpcServer.register("session/set_mode", { ctx => this.handleSetMode(ctx) })
        this.rpcServer.register("session/set_config_option", { ctx => this.handleSetConfigOption(ctx) })
        this.rpcServer.registerAsyncErr("session/load", { ctx, complete, fail => this.handleLoadSessionAsync(ctx, complete, fail) })
        this.rpcServer.register("session/resume", { ctx => this.handleResumeSession(ctx) })
        this.rpcServer.register("$/cancel_request", { ctx => this.handleCancelRequest(ctx) })
        this.rpcServer.register("session/delete", { ctx => this.handleDeleteSession(ctx) })
        this.rpcServer.register("authenticate", { ctx => this.handleAuthenticate(ctx) })
        this.rpcServer.register("logout", { ctx => this.handleLogout(ctx) })
    }

    // ===================== 处理方法 =====================

    private func handleInitialize(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<InitializeRequest>()
        let requested = params?.protocolVersion ?? ProtocolVersionV1
        // 记录对端能力（供宿主在后续回调中按能力决策 / 反向调用前能力检查）
        if (let Some(caps) <- params?.clientCapabilities) {
            this.clientCapabilities = caps
        }
        let resp = InitializeResponse()
        resp.protocolVersion = if (requested == this.protocolVersion) { requested } else { this.protocolVersion }
        resp.agentInfo = Some(this.agentInfo)
        resp.agentCapabilities = this.capabilities
        resp.authMethods = this.authMethods
        HandlerResult.ok(JsonValue.fromObject(resp))
    }

    private func handleNewSession(ctx: HandlerContext): HandlerResult {
        let params = match (ctx.getParams<NewSessionRequest>()) {
            case Some(p) => p
            case None => return HandlerResult.err(INVALID_PARAMS, "Invalid session/new params")
        }
        if (params.cwd.isEmpty()) {
            return HandlerResult.err(INVALID_PARAMS, "cwd must be an absolute path")
        }
        // 1.6 A1：规范要求 cwd 为绝对路径
        let absOk = try {
            Path(params.cwd).isAbsolute()
        } catch (e: Exception) {
            false
        }
        if (!absOk) {
            return HandlerResult.err(INVALID_PARAMS, "cwd must be an absolute path: ${params.cwd}")
        }
        if (!this.isAuthenticated()) {
            // auth_required：-32000，data 携带 authMethods
            let data = HashMap<String, JsonValue>()
            data.add("authMethods", JsonValue.from(ArrayList<JsonValue>()))
            let arr = ArrayList<JsonValue>()
            for (m in this.authMethods) { arr.add(JsonValue.fromObject(m)) }
            data["authMethods"] = JsonValue.Array(arr)
            return HandlerResult.err(AUTH_REQUIRED, "Authentication required", data: JsonValue.Map(data))
        }
        let sessionId = "sess_" + this.sonyflake.NextID().toString()
        let dirs = params.additionalDirectories ?? ArrayList<String>()
        let state = SessionState(sessionId, params.cwd, params.mcpServers, dirs)
        synchronized(this.sessionLock) {
            this.sessions.add(sessionId, state)
        }
        if (let Some(cb) <- this.onNewSessionCb) { cb(sessionId, params.cwd) }
        let resp = NewSessionResponse()
        resp.sessionId = sessionId
        // A5：会话初始状态（modes/configOptions）经钩子注入
        if (let Some(cb) <- this.initialSessionStateCb) {
            match (cb(params)) {
                case Some(st) =>
                    resp.modes = st.modes
                    resp.configOptions = st.configOptions
                case None => ()
            }
        }
        HandlerResult.ok(JsonValue.fromObject(resp))
    }

    private func handlePromptAsync(ctx: HandlerContext, complete: (JsonValue) -> Unit, fail: (JsonRpcError) -> Unit): Unit {
        spawn {
            => this.doPrompt(ctx, complete, fail)
        }
    }

    private func doPrompt(ctx: HandlerContext, complete: (JsonValue) -> Unit, fail: (JsonRpcError) -> Unit): Unit {
        let params = match (ctx.getParams<PromptRequest>()) {
            case Some(p) => p
            case None =>
                fail(JsonRpcError(INVALID_PARAMS, "Invalid prompt params"))
                return
        }
        let state = synchronized(this.sessionLock) { this.sessions.get(params.sessionId) }
        if (state.isNone()) {
            fail(JsonRpcError(INVALID_PARAMS, "Unknown sessionId: ${params.sessionId}"))
            return
        }
        let s = state.getOrThrow()
        let handler = match (this.promptHandler) {
            case Some(h) => h
            case None =>
                fail(JsonRpcError(INTERNAL_ERROR, "No prompt handler registered"))
                return
        }
        // 记录请求 id -> 会话，供 $/cancel_request 按请求取消
        let rid: ?RequestId = ctx.requestId
        let reqKey: ?String = match (rid) {
            case Some(r) => Some(this.requestIdKey(r))
            case None => None
        }
        if (let Some(k) <- reqKey) {
            synchronized(this.sessionLock) { this.activePrompts.add(k, s.sessionId) }
        }
        // 串行执行：同一会话一次只处理一个回合
        synchronized(s.promptLock) {
            if (s.cancelFlag.load()) { s.cancelFlag.store(false) }
            let pc = PromptContext(s.sessionId, s.cwd, params.prompt, { u => this.sessionUpdate(s.sessionId, u) },
                s.cancelFlag, { => this.clientCapabilities })
            let resp = handler(pc)
            // 若回合结束时取消标志仍为真，且处理器返回 end_turn，统一转为 cancelled
            let finalResp = if (s.cancelFlag.load() && resp.stopReason == StopReasonEndTurn) {
                PromptResponse(StopReasonCancelled)
            } else {
                resp
            }
            s.cancelFlag.store(false)
            complete(JsonValue.fromObject(finalResp))
        }
        if (let Some(k) <- reqKey) {
            synchronized(this.sessionLock) { this.activePrompts.remove(k) }
        }
    }

    // 把 RequestId 转成 map key 字符串（$/cancel_request 的 requestId 是 JsonValue，统一字符串化）
    private func requestIdKey(rid: RequestId): String {
        match (rid) {
            case RequestId.Int(i) => "i" + i.toString()
            case RequestId.String(s) => "s" + s
        }
    }
    private func requestIdKeyFromJson(v: JsonValue): ?String {
        match (v) {
            case JsonValue.Number(n) => Some("i" + Int64(n).toString())
            case JsonValue.String(s) => Some("s" + s)
            case _ => None
        }
    }

    private func handleCancel(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<CancelNotification>()
        let sessionId = params?.sessionId ?? ""
        if (let Some(s) <- synchronized(this.sessionLock) { this.sessions.get(sessionId) }) {
            s.cancelFlag.store(true)
            if (let Some(cb) <- this.onCancelCb) { cb(sessionId) }
        }
        // session/cancel 是通知，不返回响应
        HandlerResult.ok(JsonValue.Null)
    }

    private func handleClose(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<CloseSessionRequest>()
        let sessionId = params?.sessionId ?? ""
        let removed = synchronized(this.sessionLock) {
            let s = this.sessions.get(sessionId)
            this.sessions.remove(sessionId)
            s
        }
        match (removed) {
            case Some(s) =>
                s.cancelFlag.store(true)
                if (let Some(cb) <- this.onCloseCb) { cb(sessionId) }
                HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
            case None => HandlerResult.err(INVALID_PARAMS, "Unknown sessionId: ${sessionId}")
        }
    }

    private func handleListSessions(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<ListSessionsRequest>()
        match (this.listSessionsCb) {
            case Some(cb) =>
                let resp = cb(params ?? ListSessionsRequest())
                HandlerResult.ok(JsonValue.fromObject(resp))
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/list not supported")
        }
    }

    private func handleSetMode(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<SetSessionModeRequest>()
        let sessionId = params?.sessionId ?? ""
        let modeId = params?.modeId ?? ""
        if (synchronized(this.sessionLock) { this.sessions.get(sessionId) }.isNone()) {
            return HandlerResult.err(INVALID_PARAMS, "Unknown sessionId: ${sessionId}")
        }
        match (this.setModeCb) {
            case Some(cb) =>
                if (cb(sessionId, modeId)) {
                    HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
                } else {
                    HandlerResult.err(INVALID_PARAMS, "Unknown modeId: ${modeId}")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/set_mode not supported")
        }
    }

    private func handleSetConfigOption(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<SetSessionConfigOptionRequest>()
        let sessionId = params?.sessionId ?? ""
        if (synchronized(this.sessionLock) { this.sessions.get(sessionId) }.isNone()) {
            return HandlerResult.err(INVALID_PARAMS, "Unknown sessionId: ${sessionId}")
        }
        match (this.setConfigOptionCb) {
            case Some(cb) =>
                match (cb(sessionId, params ?? SetSessionConfigOptionRequest())) {
                    case Some(options) =>
                        let resp = SetSessionConfigOptionResponse()
                        resp.configOptions = options
                        HandlerResult.ok(JsonValue.fromObject(resp))
                    case None => HandlerResult.err(INVALID_PARAMS, "Unknown configId")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/set_config_option not supported")
        }
    }

    private func handleLoadSessionAsync(ctx: HandlerContext, complete: (JsonValue) -> Unit, fail: (JsonRpcError) -> Unit): Unit {
        spawn {
            => this.doLoadSession(ctx, complete, fail)
        }
    }

    private func doLoadSession(ctx: HandlerContext, complete: (JsonValue) -> Unit, fail: (JsonRpcError) -> Unit): Unit {
        let params = match (ctx.getParams<SessionLifecycleRequest>()) {
            case Some(p) => p
            case None =>
                fail(JsonRpcError(INVALID_PARAMS, "Invalid session/load params"))
                return
        }
        match (this.loadSessionCb) {
            case Some(cb) =>
                cb(params,
                    { result =>
                        // 加载成功后，把会话恢复到会话表（供后续 session/prompt 使用）
                        synchronized(this.sessionLock) {
                            if (!this.sessions.contains(params.sessionId)) {
                                this.sessions.add(params.sessionId, SessionState(params.sessionId, params.cwd, params.mcpServers))
                            }
                        }
                        complete(result)
                    },
                    { err => fail(err) })
            case None => fail(JsonRpcError(METHOD_NOT_FOUND, "session/load not supported"))
        }
    }

    private func handleResumeSession(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<SessionLifecycleRequest>()
        match (this.resumeSessionCb) {
            case Some(cb) =>
                match (cb(params ?? SessionLifecycleRequest())) {
                    case Some(resp) => HandlerResult.ok(JsonValue.fromObject(resp))
                    case None => HandlerResult.err(INVALID_PARAMS, "Unknown sessionId")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/resume not supported")
        }
    }

    private func handleCancelRequest(ctx: HandlerContext): HandlerResult {
        // $/cancel_request 是通知：按 requestId 取消对应的进行中请求（主要是 session/prompt）
        let sessionId: ?String = match (ctx.getParam("requestId")) {
            case Some(v) =>
                let k: ?String = this.requestIdKeyFromJson(v)
                match (k) {
                    case Some(key) =>
                        let found: ?String = synchronized(this.sessionLock) { this.activePrompts.get(key) }
                        found
                    case None => None
                }
            case None => None
        }
        if (let Some(sid) <- sessionId) {
            if (let Some(s) <- synchronized(this.sessionLock) { this.sessions.get(sid) }) {
                s.cancelFlag.store(true)
                if (let Some(cb) <- this.cancelRequestCb) { cb(sid) }
            }
        }
        // 通知不返回响应
        HandlerResult.ok(JsonValue.Null)
    }

    private func handleDeleteSession(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<DeleteSessionRequest>()
        let sessionId = params?.sessionId ?? ""
        match (this.deleteSessionCb) {
            case Some(cb) =>
                if (cb(sessionId)) {
                    // 删除成功后清理内部会话状态：后续 prompt 该 id 返回 -32602
                    synchronized(this.sessionLock) {
                        match (this.sessions.remove(sessionId)) {
                            case Some(s) => s.cancelFlag.store(true)
                            case None => ()
                        }
                    }
                    HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
                } else {
                    HandlerResult.err(RESOURCE_NOT_FOUND, "Unknown sessionId: ${sessionId}")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/delete not supported")
        }
    }

    private func handleAuthenticate(ctx: HandlerContext): HandlerResult {
        // 协议驱动认证：methodId 必须已在 authMethods 广告，
        // 且方法类型不是 terminal（terminal 型由客户端另起交互进程登录，不得走本流程）
        let methodId = ctx.getParams<AuthenticateRequest>()?.methodId ?? ""
        var valid: Bool = false
        for (m in this.authMethods) {
            if (m.id == methodId) {
                let methodType = m.`type` ?? "agent"
                valid = methodType != "terminal"
            }
        }
        if (!valid) {
            return HandlerResult.err(INVALID_PARAMS,
                "Unknown or non-protocol authentication method: ${methodId}")
        }
        this.authenticated = true
        if (let Some(cb) <- this.onAuthenticatedCb) { cb(methodId) }
        HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
    }

    private func handleLogout(ctx: HandlerContext): HandlerResult {
        // 登出：清除认证状态
        this.authenticated = false
        if (let Some(cb) <- this.onLoggedOutCb) { cb("") }
        HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
    }

    // ===================== 主动推送（Agent → Client 通知） =====================

    public func sessionUpdate(sessionId: String, update: SessionUpdate): Unit {
        let notif = SessionNotification()
        notif.sessionId = sessionId
        notif.update = update
        this.rpcServer.notify<SessionNotification>("session/update", params: notif)
    }

    /// 发送 ACP 扩展通知（Agent → Client，方法名按约定以 `_` 开头）
    public func sendExtensionNotification(method: String, params!: ?JsonValue = None): Unit {
        match (params) {
            case Some(p) => this.rpcServer.notify<JsonValue>(method, params: p)
            case None => this.rpcServer.notify(method)
        }
    }

    /**
     * elicitation/create 反向请求：向 Client 请求用户的结构化输入（form / url 模式）。
     * 前置能力检查（规范 MUST NOT）：Client 未在 initialize 广告对应模式时返回
     * -32602 Invalid params 语义错误。
     */
    public func createElicitation(req: CreateElicitationRequest,
                                  timeout!: Duration = 5 * Duration.minute): Result<CreateElicitationResponse> {
        var supported: Bool = false
        match (this.clientCapabilities.elicitation) {
            case Some(e) =>
                if (req.mode == ElicitationModeForm) { supported = e.form.isSome() }
                else if (req.mode == ElicitationModeUrl) { supported = e.url.isSome() }
                else { supported = true }  // 自定义/未来 mode 无法按标准能力判定 → 放行
            case None => ()  // 未声明 elicitation 能力 = 不支持
        }
        if (!supported) {
            return Result.Err("[-32602] Client does not advertise elicitation mode: ${req.mode}")
        }
        this.rpcServer.request<CreateElicitationRequest, CreateElicitationResponse>(
            "elicitation/create", params: req, timeout: timeout)
    }

    /// URL 模式外部交互完成通知（Agent → Client；elicitationId 与原请求一致）
    public func elicitationComplete(elicitationId: ElicitationId): Unit {
        this.rpcServer.notify<CompleteElicitationNotification>("elicitation/complete",
            params: CompleteElicitationNotification(elicitationId))
    }

    // ===================== 反向调用（Agent → Client 请求） =====================
    //
    // 这里**不再**用调用方锁把反向调用串行化。此前 jsonrpc ≤0.7.4 的
    // `JsonRpcServer.request()` 只有一个挂起槽（且 id 恒为 0），并发在飞会丢响应/串台，
    // 所以 acp-cj 用一个 clientRequestLock 把 9 个反向调用全串起来 —— 代价是锁横跨整个
    // 往返：terminal/wait_for_exit 超时可达 10 分钟，期间连一次 fs/read_text_file 都发不出去。
    // jsonrpc 0.7.5 起 `request()` 按 id 配对（每个在飞请求一个等待槽），可以真正并发。

    public func requestPermission(sessionId: String, toolCall: ToolCallUpdate,
                                  options: ArrayList<PermissionOption>,
                                  timeout!: Duration = 30 * Duration.second): Result<RequestPermissionResponse> {
        let req = RequestPermissionRequest()
        req.sessionId = sessionId
        req.toolCall = toolCall
        req.options = options
        this.rpcServer.request<RequestPermissionRequest, RequestPermissionResponse>(
            "session/request_permission", params: req, timeout: timeout)
    }

    public func createTerminal(req: CreateTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<CreateTerminalResponse> {
        this.rpcServer.request<CreateTerminalRequest, CreateTerminalResponse>("terminal/create", params: req, timeout: timeout)
    }

    public func terminalOutput(req: TerminalOutputRequest, timeout!: Duration = 30 * Duration.second): Result<TerminalOutputResponse> {
        this.rpcServer.request<TerminalIdRequest, TerminalOutputResponse>("terminal/output", params: req, timeout: timeout)
    }

    public func terminalWaitForExit(req: WaitForTerminalExitRequest, timeout!: Duration = 10 * Duration.minute): Result<WaitForTerminalExitResponse> {
        this.rpcServer.request<TerminalIdRequest, WaitForTerminalExitResponse>("terminal/wait_for_exit", params: req, timeout: timeout)
    }

    public func terminalKill(req: KillTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        this.rpcServer.request<TerminalIdRequest, EmptyResult>("terminal/kill", params: req, timeout: timeout)
    }

    public func terminalRelease(req: ReleaseTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        this.rpcServer.request<TerminalIdRequest, EmptyResult>("terminal/release", params: req, timeout: timeout)
    }

    public func readTextFile(req: ReadTextFileRequest, timeout!: Duration = 30 * Duration.second): Result<ReadTextFileResponse> {
        this.rpcServer.request<ReadTextFileRequest, ReadTextFileResponse>("fs/read_text_file", params: req, timeout: timeout)
    }

    public func writeTextFile(req: WriteTextFileRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        this.rpcServer.request<WriteTextFileRequest, EmptyResult>("fs/write_text_file", params: req, timeout: timeout)
    }
}
