package acp

import jsonvalue.*
import ystyle::jsonrpc.{JsonRpcServer, Transport, NewlineFraming, HandlerContext, HandlerResult, Result, JsonRpcError, RequestId}
import std.collection.*
import std.sync.*
import stdx.encoding.json.stream.*
import sonyflake.*
import std.random.Random
import acp.types.*
import acp.transport.*

// ===================== 回调类型 =====================

public type NewSessionCallback = (String /*cwd*/) -> Unit
public type CancelCallback = (String /*sessionId*/) -> Unit
public type CloseCallback = (String /*sessionId*/) -> Unit
public type ListSessionsCallback = (ListSessionsRequest) -> ListSessionsResponse
public type SetModeCallback = (String /*sessionId*/, String /*modeId*/) -> Bool
public type SetConfigOptionCallback = (String /*sessionId*/, SetSessionConfigOptionRequest) -> ?ArrayList<SessionConfigOption>
public type LoadSessionCallback = (SessionLifecycleRequest) -> ?LoadSessionResponse
public type DeleteSessionCallback = (String /*sessionId*/) -> Bool
public type ResumeSessionCallback = (SessionLifecycleRequest) -> ?ResumeSessionResponse
public type CancelRequestCallback = (String /*requestId 字符串化*/) -> Unit

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

    public init(sessionId: String, cwd: String, prompt: ArrayList<ContentBlock>,
                emitFn: (SessionUpdate) -> Unit, cancelFlag: AtomicBool) {
        this.sessionId = sessionId
        this.cwd = cwd
        this.prompt = prompt
        this.emitFn = emitFn
        this.cancelFlag = cancelFlag
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
}

public type PromptHandler = (PromptContext) -> PromptResponse

// ===================== 会话状态 =====================

public class SessionState {
    public let sessionId: String
    public let cwd: String
    public let mcpServers: ArrayList<McpServer>
    public let cancelFlag = AtomicBool(false)
    // 同一会话同一时刻只允许一个进行中的回合
    public let promptLock = Mutex()

    public init(sessionId: String, cwd: String, mcpServers: ArrayList<McpServer>) {
        this.sessionId = sessionId
        this.cwd = cwd
        this.mcpServers = mcpServers
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

    // 业务钩子
    private var promptHandler: ?PromptHandler = None
    private var onNewSessionCb: ?NewSessionCallback = None
    private var onCancelCb: ?CancelCallback = None
    private var onCloseCb: ?CloseCallback = None
    private var listSessionsCb: ?ListSessionsCallback = None
    private var setModeCb: ?SetModeCallback = None
    private var setConfigOptionCb: ?SetConfigOptionCallback = None
    private var loadSessionCb: ?LoadSessionCallback = None
    private var deleteSessionCb: ?DeleteSessionCallback = None
    private var resumeSessionCb: ?ResumeSessionCallback = None
    private var cancelRequestCb: ?CancelRequestCallback = None

    // server 主动 request client 的串行锁（jsonrpc 0.7.2 server.request 单挂起）
    private let clientRequestLock = Mutex()
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
    public func setOnCancel(cb: CancelCallback): Unit { this.onCancelCb = Some(cb) }
    public func setOnClose(cb: CloseCallback): Unit { this.onCloseCb = Some(cb) }
    public func setOnListSessions(cb: ListSessionsCallback): Unit { this.listSessionsCb = Some(cb) }
    public func setOnSetMode(cb: SetModeCallback): Unit { this.setModeCb = Some(cb) }
    public func setOnSetConfigOption(cb: SetConfigOptionCallback): Unit { this.setConfigOptionCb = Some(cb) }
    public func setOnLoadSession(cb: LoadSessionCallback): Unit { this.loadSessionCb = Some(cb) }
    public func setOnDeleteSession(cb: DeleteSessionCallback): Unit { this.deleteSessionCb = Some(cb) }
    public func setOnResumeSession(cb: ResumeSessionCallback): Unit { this.resumeSessionCb = Some(cb) }
    public func setOnCancelRequest(cb: CancelRequestCallback): Unit { this.cancelRequestCb = Some(cb) }

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
        this.rpcServer.register("session/load", { ctx => this.handleLoadSession(ctx) })
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
        let sessionId = "sess_" + this.sonyflake.NextID().toString()
        let state = SessionState(sessionId, params.cwd, params.mcpServers)
        synchronized(this.sessionLock) {
            this.sessions.add(sessionId, state)
        }
        if (let Some(cb) <- this.onNewSessionCb) { cb(params.cwd) }
        let resp = NewSessionResponse()
        resp.sessionId = sessionId
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
            let pc = PromptContext(s.sessionId, s.cwd, params.prompt, { u => this.sessionUpdate(s.sessionId, u) }, s.cancelFlag)
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

    private func handleLoadSession(ctx: HandlerContext): HandlerResult {
        let params = ctx.getParams<SessionLifecycleRequest>()
        match (this.loadSessionCb) {
            case Some(cb) =>
                match (cb(params ?? SessionLifecycleRequest())) {
                    case Some(resp) => HandlerResult.ok(JsonValue.fromObject(resp))
                    case None => HandlerResult.err(INVALID_PARAMS, "Unknown sessionId")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/load not supported")
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
                    HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
                } else {
                    HandlerResult.err(RESOURCE_NOT_FOUND, "Unknown sessionId: ${sessionId}")
                }
            case None => HandlerResult.err(METHOD_NOT_FOUND, "session/delete not supported")
        }
    }

    private func handleAuthenticate(ctx: HandlerContext): HandlerResult {
        // 默认无协议驱动认证；子类可重写
        HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
    }

    private func handleLogout(ctx: HandlerContext): HandlerResult {
        // 默认无状态；子类可重写
        HandlerResult.ok(JsonValue.fromObject(EmptyResult()))
    }

    // ===================== 主动推送（Agent → Client 通知） =====================

    public func sessionUpdate(sessionId: String, update: SessionUpdate): Unit {
        let notif = SessionNotification()
        notif.sessionId = sessionId
        notif.update = update
        this.rpcServer.notify<SessionNotification>("session/update", params: notif)
    }

    // ===================== 反向调用（Agent → Client 请求） =====================

    public func requestPermission(sessionId: String, toolCall: ToolCallUpdate,
                                  options: ArrayList<PermissionOption>,
                                  timeout!: Duration = 30 * Duration.second): Result<RequestPermissionResponse> {
        let req = RequestPermissionRequest()
        req.sessionId = sessionId
        req.toolCall = toolCall
        req.options = options
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<RequestPermissionRequest, RequestPermissionResponse>(
                "session/request_permission", params: req, timeout: timeout)
        }
    }

    public func createTerminal(req: CreateTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<CreateTerminalResponse> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<CreateTerminalRequest, CreateTerminalResponse>("terminal/create", params: req, timeout: timeout)
        }
    }

    public func terminalOutput(req: TerminalOutputRequest, timeout!: Duration = 30 * Duration.second): Result<TerminalOutputResponse> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<TerminalIdRequest, TerminalOutputResponse>("terminal/output", params: req, timeout: timeout)
        }
    }

    public func terminalWaitForExit(req: WaitForTerminalExitRequest, timeout!: Duration = 10 * Duration.minute): Result<WaitForTerminalExitResponse> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<TerminalIdRequest, WaitForTerminalExitResponse>("terminal/wait_for_exit", params: req, timeout: timeout)
        }
    }

    public func terminalKill(req: KillTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<TerminalIdRequest, EmptyResult>("terminal/kill", params: req, timeout: timeout)
        }
    }

    public func terminalRelease(req: ReleaseTerminalRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<TerminalIdRequest, EmptyResult>("terminal/release", params: req, timeout: timeout)
        }
    }

    public func readTextFile(req: ReadTextFileRequest, timeout!: Duration = 30 * Duration.second): Result<ReadTextFileResponse> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<ReadTextFileRequest, ReadTextFileResponse>("fs/read_text_file", params: req, timeout: timeout)
        }
    }

    public func writeTextFile(req: WriteTextFileRequest, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        synchronized(this.clientRequestLock) {
            this.rpcServer.request<WriteTextFileRequest, EmptyResult>("fs/write_text_file", params: req, timeout: timeout)
        }
    }
}
