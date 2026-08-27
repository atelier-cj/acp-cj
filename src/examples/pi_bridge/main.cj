package acp.examples.pi_bridge

import acp.*
import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.{Result, JsonRpcError}
import std.env.{getCommandLine, getStdErr}
import std.collection.{HashMap, ArrayList}
import std.sync.*

/**
 * pi_bridge：用 acp-cj 实现的 ACP Agent（服务端）代理。
 *
 * - 作为 ACP 服务端（stdio）面向外部 ACP Client（如 testclient / Zed）；
 * - 作为 ACP 客户端连接一个真实后端 agent（默认 `opencode acp`）；
 * - 把收到的 session/prompt 转发给后端，并把后端的 session/update 流式通知
 *   转发回外部 Client（ACP 代理链）。
 * - 支持 session 持久化 + session/load 历史重放（SessionStore 映射 + 后端重放转发）。
 *
 * 用法：
 *   pi_bridge [--echo] ["<后端agent命令>"] [--store <映射文件>]
 *
 *   --echo         不回连后端，直接回显（用于无 LLM 的协议冒烟测试）
 *   默认后端        "opencode acp"（需 XDG_DATA_HOME 指向可写目录）
 *   --store        会话映射文件路径（默认 .pi-acp-sessions.json）
 */
class ClientBox {
    public var client: ?AcpClient = None
    public init() {}
}

func logErr(msg: String): Unit {
    try {
        getStdErr().write((msg + "\n").toArray())
        getStdErr().flush()
    } catch (e: Exception) {
        // 忽略 stderr 写入异常
    }
}

main() {
    let args = getCommandLine()[1..]
    var echoFlag = false
    var authFlag = false
    var backend = "opencode acp"
    var storePath = ".pi-acp-sessions.json"
    var idx: Int64 = 0
    while (idx < args.size) {
        let a = args[idx]
        if (a == "--echo") { echoFlag = true }
        else if (a == "--auth-required") { authFlag = true }
        else if (a == "--store") {
            idx++
            if (idx < args.size) { storePath = args[idx] }
        } else if (!a.startsWith("-")) { backend = a }
        idx++
    }
    let echoMode = echoFlag
    let authRequiredMode = authFlag
    let backendCmd = backend

    // ---- 后端连接（桥接客户端） ----
    let box = ClientBox()
    if (!echoMode) {
        logErr("[pi_bridge] 后端 agent: ${backendCmd}")
        let parts = backendCmd.split(' ')
        let cmd = parts[0]
        let rest = ArrayList<String>()
        var first = true
        for (p in parts) {
            if (!first) { rest.add(p) }
            first = false
        }
        let client = AcpClient(SubprocessTransport(cmd, args: rest.toArray()))
        match (client.connect(Implementation("acp-cj-pi-bridge", "0.1.0"), ClientCapabilities())) {
            case Result.Ok(initResp) =>
                let info = initResp.agentInfo ?? Implementation("", "")
                logErr("[pi_bridge] 后端握手成功: ${info.name} v${info.version}")
            case Result.Err(e) =>
                logErr("[pi_bridge] 后端握手失败: ${e}")
                return
        }
        box.client = Some(client)
    } else {
        logErr("[pi_bridge] echo 模式（不回连后端）")
    }

    // ---- 会话映射：外部 sessionId <-> 后端 sessionId（持久化） ----
    let store = SessionStore(storePath)
    logErr("[pi_bridge] 会话映射: ${storePath}（已恢复 ${store.list().size} 条）")
    let sidMap = HashMap<String, String>()
    let mapLock = Mutex()
    // 启动时把持久化映射恢复到运行期
    for (r in store.list()) {
        synchronized(mapLock) { sidMap.add(r.sessionId, r.backendSessionId) }
    }

    func backendSessionId(extId: String, cwd: String): ?String {
        synchronized(mapLock) {
            match (sidMap.get(extId)) {
                case Some(id) => Some(id)
                case None =>
                    match (box.client) {
                        case Some(c) =>
                            match (c.newSession(cwd)) {
                                case Result.Ok(resp) =>
                                    sidMap.add(extId, resp.sessionId)
                                    store.upsert(SessionRecord(extId, cwd, resp.sessionId))
                                    Some(resp.sessionId)
                                case Result.Err(e) =>
                                    logErr("[pi_bridge] 后端 session/new 失败: ${e}")
                                    None
                            }
                        case None => Some(extId)
                    }
            }
        }
    }

    // ---- ACP 服务端（stdio，面向外部 Client） ----
    let agent = AcpAgent(StdioTransport(), "acp-cj-pi-bridge", "0.1.0")
    agent.capabilities.loadSession = true
    agent.capabilities.promptCapabilities.image = true
    agent.authRequired = authRequiredMode
    if (authRequiredMode) {
        let m = AuthMethod()
        m.id = "pi_bridge_login"
        m.name = "Authenticate with pi_bridge"
        m.description = Some("demo: authenticate to open session creation")
        agent.authMethods.add(m)
        logErr("[pi_bridge] 认证门控已开启（--auth-required）")
    }
    agent.capabilities.sessionCapabilities.list = Some(EmptyCapability())
    agent.capabilities.sessionCapabilities.delete = Some(EmptyCapability())
    agent.capabilities.sessionCapabilities.resume = Some(EmptyCapability())

    // 桥接通知：后端 session/update -> 外部 Client
    match (box.client) {
        case Some(c) =>
            c.setOnSessionUpdate({ backendSid, update =>
                synchronized(mapLock) {
                    for ((extId, bsid) in sidMap) {
                        if (bsid == backendSid) {
                            agent.sessionUpdate(extId, update)
                        }
                    }
                }
            })
        case None => ()
    }

    agent.setPromptHandler({ ctx =>
        if (echoMode) {
            ctx.emit(SessionUpdate.agentMessage("echo: " + ctx.getText()))
            return PromptResponse(StopReasonEndTurn)
        }
        match (box.client) {
            case Some(c) =>
                match (backendSessionId(ctx.sessionId, ctx.cwd)) {
                    case Some(bsid) =>
                        match (c.prompt(bsid, ctx.prompt)) {
                            case Result.Ok(resp) => PromptResponse(resp.stopReason)
                            case Result.Err(e) =>
                                ctx.emit(SessionUpdate.agentMessage("后端错误: ${e}"))
                                PromptResponse(StopReasonRefusal)
                        }
                    case None => PromptResponse(StopReasonRefusal)
                }
            case None => PromptResponse(StopReasonRefusal)
        }
    })

    // session/load：从 store 恢复映射，转发后端 load（后端重放历史，通知由桥接转发）
    agent.setOnLoadSession({ req, complete, fail =>
        if (echoMode) {
            complete(JsonValue.fromObject(LoadSessionResponse()))
            return
        }
        match (store.get(req.sessionId)) {
            case Some(r) =>
                match (box.client) {
                    case Some(c) =>
                        synchronized(mapLock) { sidMap.add(req.sessionId, r.backendSessionId) }
                        match (c.loadSession(r.backendSessionId, req.cwd)) {
                            case Result.Ok(_) => complete(JsonValue.fromObject(LoadSessionResponse()))
                            case Result.Err(e) =>
                                logErr("[pi_bridge] 后端 session/load 失败: ${e}")
                                fail(JsonRpcError(INTERNAL_ERROR, "后端 load 失败: ${e}"))
                        }
                    case None => fail(JsonRpcError(INTERNAL_ERROR, "no backend"))
                }
            case None => fail(JsonRpcError(INVALID_PARAMS, "Unknown sessionId: ${req.sessionId}"))
        }
    })

    // session/resume：转发后端 resume（后端不重放，直接可继续）
    agent.setOnResumeSession({ req =>
        if (echoMode) {
            return Some(ResumeSessionResponse())
        }
        match (store.get(req.sessionId)) {
            case Some(r) =>
                match (box.client) {
                    case Some(c) =>
                        synchronized(mapLock) { sidMap.add(req.sessionId, r.backendSessionId) }
                        match (c.resumeSession(r.backendSessionId, req.cwd)) {
                            case Result.Ok(resp) => Some(resp)
                            case Result.Err(e) =>
                                logErr("[pi_bridge] 后端 session/resume 失败: ${e}")
                                None
                        }
                    case None => None
                }
            case None => None
        }
    })

    logErr("[pi_bridge] 就绪，等待 ACP Client 连接...")
    agent.serve()
}
