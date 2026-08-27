package acp

import jsonvalue.*
import ystyle::jsonrpc.{JsonRpcClient, Transport, NewlineFraming, RequestId, Notification, Request, Result}
import std.collection.*
import stdx.encoding.json.stream.*
import acp.types.*
import acp.transport.*

// ===================== 回调类型 =====================

public type SessionUpdateCallback = (String /*sessionId*/, SessionUpdate) -> Unit
public type PermissionCallback = (RequestPermissionRequest) -> RequestPermissionResponse
public type AcpRequestHandler = (JsonValue /*params*/) -> ?JsonValue
public type ErrorCallback = (Exception) -> Unit

/**
 * AcpClient：ACP 客户端框架。
 * 负责连接 ACP Agent（通过 Transport），完成 initialize → session/new → session/prompt，
 * 并分发 agent 发来的 session/update 通知与 session/request_permission 等请求。
 */
public class AcpClient {
    private let rpcClient: JsonRpcClient
    private var initialized: Bool = false
    private var sessionUpdateCb: ?SessionUpdateCallback = None
    private var errorCb: ?ErrorCallback = None

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

    // ===================== 回调注册 =====================

    public func setOnSessionUpdate(cb: SessionUpdateCallback): Unit { this.sessionUpdateCb = Some(cb) }

    public func setOnError(cb: ErrorCallback): Unit { this.errorCb = Some(cb) }

    /**
     * 注册 agent 发来的方法处理器（如 session/request_permission、terminal 系列、fs 系列）。
     * handler 返回 ?JsonValue 作为响应 result；返回 None 视为无效请求。
     */
    public func on(method: String, handler: AcpRequestHandler): Unit {
        this.rpcClient.registerRequestHandler(method, { req => this.dispatch(method, req, handler) })
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
                case _ => () // 忽略未识别的 ACP 通知
            }
        } catch (e: Exception) {
            if (let Some(cb) <- this.errorCb) { cb(e) }
        }
    }
}
