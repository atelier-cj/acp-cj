package acp

import jsonvalue.*
import ystyle::jsonrpc.{JsonRpcClient, Transport, NewlineFraming, RequestId, Notification, Request, Result}
import std.collection.*
import std.sync.Mutex
import std.process.{launch, ProcessRedirect, SubProcess}
import stdx.encoding.json.stream.*
import acp.types.*
import acp.transport.*

// ===================== 回调类型 =====================

public type SessionUpdateCallback = (String /*sessionId*/, SessionUpdate) -> Unit
public type PermissionCallback = (RequestPermissionRequest) -> RequestPermissionResponse
public type AcpRequestHandler = (JsonValue /*params*/) -> ?JsonValue
public type ErrorCallback = (Exception) -> Unit
/// 非 session/update 通知的订阅回调（含 _ 前缀扩展通知、elicitation/complete 等）
public type NotificationHandler = (String /*method*/, JsonValue /*params*/) -> Unit
// ---- Agent→Client 反向请求的类型化回调 ----
public type RequestPermissionCallback = (RequestPermissionRequest) -> RequestPermissionResponse
public type ReadTextFileCallback = (ReadTextFileRequest) -> ReadTextFileResponse
public type WriteTextFileCallback = (WriteTextFileRequest) -> EmptyResult
public type CreateTerminalCallback = (CreateTerminalRequest) -> CreateTerminalResponse
public type TerminalOutputCallback = (TerminalIdRequest) -> TerminalOutputResponse
public type TerminalWaitForExitCallback = (TerminalIdRequest) -> WaitForTerminalExitResponse
public type TerminalKillCallback = (TerminalIdRequest) -> EmptyResult
public type TerminalReleaseCallback = (TerminalIdRequest) -> EmptyResult
public type ElicitationCreateCallback = (CreateElicitationRequest) -> CreateElicitationResponse
public type ElicitationCompleteCallback = (ElicitationId /*elicitationId*/) -> Unit

/**
 * AcpClient：ACP 客户端框架。
 * 负责连接 ACP Agent（通过 Transport），完成 initialize → session/new → session/prompt，
 * 并分发 agent 发来的 session/update 通知与 session/request_permission 等请求。
 */
public class AcpClient {
    private let rpcClient: JsonRpcClient
    private var initialized: Bool = false
    private var sessionUpdateCb: ?SessionUpdateCallback = None
    private var elicitationCompleteCb: ?ElicitationCompleteCallback = None
    private var errorCb: ?ErrorCallback = None
    // 扩展通知订阅表：method -> 回调列表
    private let notifLock = Mutex()
    private let notifHandlers = HashMap<String, ArrayList<NotificationHandler>>()

    public init(transport: Transport) {
        this.rpcClient = JsonRpcClient(transport, framing: NewlineFraming())
        // 统一的通知分发：把 ACP 通知标准化后回调给用户
        this.rpcClient.setNotificationCallback({ n => this.handleNotification(n) })
    }

    // ===================== 生命周期 =====================

    public func connect(clientInfo: Implementation, clientCapabilities: ClientCapabilities,
                        timeout!: Duration = 30 * Duration.second): Result<InitializeResponse> {
        this.rpcClient.start()
        let req = InitializeRequest()
        req.protocolVersion = ProtocolVersionV1
        req.clientCapabilities = clientCapabilities
        req.clientInfo = Some(clientInfo)
        let result = this.rpcClient.call<InitializeRequest, InitializeResponse>("initialize", params: req, timeout: timeout)
        match (result) {
            case Result.Ok(resp) =>
                // 版本协商（规范）：Agent 回其最新支持的版本；本客户端仅支持 v1，
                // 若响应版本不是 v1 则不应继续（Client SHOULD close connection）
                if (resp.protocolVersion != ProtocolVersionV1) {
                    this.rpcClient.close()
                    return Result.Err("Unsupported protocol version from agent: ${resp.protocolVersion} (client supports ${ProtocolVersionV1})")
                }
                this.initialized = true
                result
            case Result.Err(e) => result
        }
    }

    public func isConnected(): Bool { this.initialized }

    public func close(): Unit {
        this.initialized = false
        this.rpcClient.close()
    }

    // ===================== 会话 =====================

    public func newSession(cwd: String, mcpServers!: ArrayList<McpServer> = ArrayList<McpServer>(),
                           additionalDirectories!: ?ArrayList<String> = None,
                           timeout!: Duration = 60 * Duration.second): Result<NewSessionResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = NewSessionRequest()
        req.cwd = cwd
        req.mcpServers = mcpServers
        req.additionalDirectories = additionalDirectories
        this.rpcClient.call<NewSessionRequest, NewSessionResponse>("session/new", params: req, timeout: timeout)
    }

    public func loadSession(sessionId: String, cwd: String, mcpServers!: ArrayList<McpServer> = ArrayList<McpServer>(),
                            additionalDirectories!: ?ArrayList<String> = None,
                            timeout!: Duration = 60 * Duration.second): Result<LoadSessionResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = SessionLifecycleRequest()
        req.sessionId = sessionId
        req.cwd = cwd
        req.mcpServers = mcpServers
        req.additionalDirectories = additionalDirectories
        this.rpcClient.call<SessionLifecycleRequest, LoadSessionResponse>("session/load", params: req, timeout: timeout)
    }

    public func resumeSession(sessionId: String, cwd: String, mcpServers!: ArrayList<McpServer> = ArrayList<McpServer>(),
                              additionalDirectories!: ?ArrayList<String> = None,
                              timeout!: Duration = 60 * Duration.second): Result<ResumeSessionResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = SessionLifecycleRequest()
        req.sessionId = sessionId
        req.cwd = cwd
        req.mcpServers = mcpServers
        req.additionalDirectories = additionalDirectories
        this.rpcClient.call<SessionLifecycleRequest, ResumeSessionResponse>("session/resume", params: req, timeout: timeout)
    }

    public func listSessions(cwd!: ?String = None, cursor!: ?String = None,
                             timeout!: Duration = 30 * Duration.second): Result<ListSessionsResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = ListSessionsRequest()
        req.cwd = cwd
        req.cursor = cursor
        this.rpcClient.call<ListSessionsRequest, ListSessionsResponse>("session/list", params: req, timeout: timeout)
    }

    public func deleteSession(sessionId: String, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        this.rpcClient.call<DeleteSessionRequest, EmptyResult>("session/delete", params: DeleteSessionRequest(sessionId), timeout: timeout)
    }

    public func closeSession(sessionId: String, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        this.rpcClient.call<CloseSessionRequest, EmptyResult>("session/close", params: CloseSessionRequest(sessionId), timeout: timeout)
    }

    // ===================== Prompt =====================

    public func prompt(sessionId: String, prompt: ArrayList<ContentBlock>,
                       timeout!: Duration = 10 * Duration.minute): Result<PromptResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = PromptRequest()
        req.sessionId = sessionId
        req.prompt = prompt
        this.rpcClient.call<PromptRequest, PromptResponse>("session/prompt", params: req, timeout: timeout)
    }

    public func promptText(sessionId: String, text: String,
                           timeout!: Duration = 10 * Duration.minute): Result<PromptResponse> {
        let blocks = ArrayList<ContentBlock>()
        blocks.add(ContentBlock.ofText(text))
        this.prompt(sessionId, blocks, timeout: timeout)
    }

    // session/cancel 是通知
    public func cancel(sessionId: String): Unit {
        let notif = CancelNotification()
        notif.sessionId = sessionId
        this.rpcClient.notify<CancelNotification>("session/cancel", params: notif)
    }

    // $/cancel_request 协议级通知：按 JSON-RPC 请求 id 取消对应请求
    public func cancelRequest(requestId: JsonValue): Unit {
        let notif = CancelRequestNotification()
        notif.requestId = requestId
        this.rpcClient.notify<CancelRequestNotification>("$/cancel_request", params: notif)
    }

    // ===================== 模式 / 配置 =====================

    public func setMode(sessionId: String, modeId: String, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = SetSessionModeRequest()
        req.sessionId = sessionId
        req.modeId = modeId
        this.rpcClient.call<SetSessionModeRequest, EmptyResult>("session/set_mode", params: req, timeout: timeout)
    }

    public func setConfigOption(sessionId: String, configId: String, value: String,
                                timeout!: Duration = 30 * Duration.second): Result<SetSessionConfigOptionResponse> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = SetSessionConfigOptionRequest()
        req.sessionId = sessionId
        req.configId = configId
        req.value = Some(value)
        this.rpcClient.call<SetSessionConfigOptionRequest, SetSessionConfigOptionResponse>("session/set_config_option", params: req, timeout: timeout)
    }

    // ===================== 扩展方法 =====================

    /// 调用 Agent 注册的扩展方法（`_` 前缀，配合 AcpAgent.registerExtensionMethod）。
    /// 返回原始 JsonValue 结果；未注册/未处理时得到 -32601 错误。
    public func extensionCall(method: String, params: JsonValue,
                              timeout!: Duration = 30 * Duration.second): Result<JsonValue> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        this.rpcClient.call<JsonValue, JsonValue>(method, params: Some(params), timeout: timeout)
    }

    // ===================== 认证 =====================

    public func authenticate(methodId: String, timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        let req = AuthenticateRequest()
        req.methodId = methodId
        this.rpcClient.call<AuthenticateRequest, EmptyResult>("authenticate", params: req, timeout: timeout)
    }

    public func logout(timeout!: Duration = 30 * Duration.second): Result<EmptyResult> {
        if (!this.initialized) { return Result.Err("Client not initialized") }
        this.rpcClient.call<EmptyResult, EmptyResult>("logout", params: EmptyResult(), timeout: timeout)
    }

    /**
     * Terminal Auth（协议认证的 terminal 类型）：
     * 用配置的 agent 程序 + authMethod.args/env 启动一个交互终端（继承当前 stdio），
     * 等待进程退出；退出码 0 表示登录成功。调用方应随后重连并重新 initialize。
     *
     * @param agentCommand agent 可执行程序（与 ACP 连接用的同一命令）
     * @param method       initialize 返回的 authMethod（type == "terminal"）
     * @return 进程退出码（0=成功；None=超时）
     */
    public func terminalLogin(agentCommand: String, method: AuthMethod, env!: ?HashMap<String, String> = None,
                              timeout!: Duration = 10 * Duration.minute): Result<Int64> {
        let args = (method.args ?? ArrayList<String>()).toArray()
        var proc: SubProcess = try {
            match (env) {
                case Some(e) => launch(agentCommand, args, environment: e, stdIn: ProcessRedirect.Inherit, stdOut: ProcessRedirect.Inherit, stdErr: ProcessRedirect.Inherit)
                case None => launch(agentCommand, args, stdIn: ProcessRedirect.Inherit, stdOut: ProcessRedirect.Inherit, stdErr: ProcessRedirect.Inherit)
            }
        } catch (e: Exception) {
            return Result.Err("terminal auth launch failed: ${e.message}")
        }
        let code = try {
            proc.wait(timeout: Some(timeout))
        } catch (e: Exception) {
            return Result.Err("terminal auth timeout")
        }
        Result.Ok(code)
    }

    // ===================== 回调注册 =====================

    public func setOnSessionUpdate(cb: SessionUpdateCallback): Unit { this.sessionUpdateCb = Some(cb) }

    /// 订阅 Agent 的 elicitation/complete 通知（URL 模式外部交互完成）
    public func setOnElicitationComplete(cb: ElicitationCompleteCallback): Unit {
        this.elicitationCompleteCb = Some(cb)
    }

    public func setOnError(cb: ErrorCallback): Unit { this.errorCb = Some(cb) }

    /**
     * 注册 agent 发来的方法处理器（如 session/request_permission、terminal 系列、fs 系列）。
     * handler 返回 ?JsonValue 作为响应 result；返回 None 视为无效请求。
     */
    public func on(method: String, handler: AcpRequestHandler): Unit {
        this.rpcClient.registerRequestHandler(method, { req => this.dispatch(method, req, handler) })
    }

    // ===================== 反向请求类型化注册（C2） =====================

    /// 注册 session/request_permission 类型化处理（参数/响应自动解析）
    public func setOnRequestPermission(cb: RequestPermissionCallback): Unit {
        this.registerTyped("session/request_permission", cb)
    }
    public func setOnReadTextFile(cb: ReadTextFileCallback): Unit {
        this.registerTyped("fs/read_text_file", cb)
    }
    public func setOnWriteTextFile(cb: WriteTextFileCallback): Unit {
        this.registerTyped("fs/write_text_file", cb)
    }
    public func setOnCreateTerminal(cb: CreateTerminalCallback): Unit {
        this.registerTyped("terminal/create", cb)
    }
    public func setOnTerminalOutput(cb: TerminalOutputCallback): Unit {
        this.registerTyped("terminal/output", cb)
    }
    public func setOnTerminalWaitForExit(cb: TerminalWaitForExitCallback): Unit {
        this.registerTyped("terminal/wait_for_exit", cb)
    }
    public func setOnTerminalKill(cb: TerminalKillCallback): Unit {
        this.registerTyped("terminal/kill", cb)
    }
    public func setOnTerminalRelease(cb: TerminalReleaseCallback): Unit {
        this.registerTyped("terminal/release", cb)
    }
    /// 注册 elicitation/create 类型化处理（表单值由回调构造 CreateElicitationResponse）
    public func setOnElicitationCreate(cb: ElicitationCreateCallback): Unit {
        this.registerTyped("elicitation/create", cb)
    }

    /// 通用实现：解析 params 为 RQ → 调用回调 → 序列化 RS 为响应 result
    private func registerTyped<RQ, RS>(method: String, cb: (RQ) -> RS)
        where RQ <: JsonDeserializable<RQ>, RS <: JsonSerializable {
        this.on(method, { params =>
            try {
                let req: RQ = JsonValue.toObject<RQ>(params)
                Some(JsonValue.fromObject(cb(req)))
            } catch (e: Exception) {
                throw Exception("Invalid ${method} params: ${e.message}")
            }
        })
    }

    /**
     * 订阅 Agent 发来的非 session/update 通知（_ 前缀扩展通知、elicitation/complete 等）。
     * 可对同一 method 多次订阅（叠加生效）。
     */
    public func onNotification(method: String, cb: NotificationHandler): Unit {
        synchronized(this.notifLock) {
            match (this.notifHandlers.get(method)) {
                case Some(list) => list.add(cb)
                case None =>
                    let list = ArrayList<NotificationHandler>()
                    list.add(cb)
                    this.notifHandlers[method] = list
            }
        }
    }

    // ===================== 内部 =====================

    private func dispatch(method: String, req: Request, handler: AcpRequestHandler): ?JsonValue {
        match (req.params) {
            case Some(p) => handler(p)
            case None => handler(JsonValue.Null)
        }
    }

    private func handleNotification(n: Notification): Unit {
        try {
            match (n.method) {
                case "session/update" =>
                    let notif = match (n.params) {
                        case Some(p) => JsonValue.toObject<SessionNotification>(p)
                        case None => SessionNotification()
                    }
                    if (let Some(cb) <- this.sessionUpdateCb) {
                        cb(notif.sessionId, notif.update)
                    }
                case "elicitation/complete" =>
                    let notif = match (n.params) {
                        case Some(p) => JsonValue.toObject<CompleteElicitationNotification>(p)
                        case None => CompleteElicitationNotification()
                    }
                    if (let Some(cb) <- this.elicitationCompleteCb) {
                        cb(notif.elicitationId)
                    }
                    this.dispatchOtherNotification(n.method, n.params)
                case other =>
                    this.dispatchOtherNotification(other, n.params)
            }
        } catch (e: Exception) {
            if (let Some(cb) <- this.errorCb) { cb(e) }
        }
    }

    /// 把非 session/update 通知转交 onNotification 订阅者
    private func dispatchOtherNotification(method: String, params: ?JsonValue): Unit {
        let cbs = synchronized(this.notifLock) {
            match (this.notifHandlers.get(method)) {
                case Some(list) => ArrayList<NotificationHandler>(list)
                case None => ArrayList<NotificationHandler>()
            }
        }
        let p = params ?? JsonValue.Null
        for (cb in cbs) {
            try {
                cb(method, p)
            } catch (e: Exception) {
                if (let Some(errCb) <- this.errorCb) { errCb(e) }
            }
        }
    }
}
