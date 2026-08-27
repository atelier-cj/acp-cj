package acp.examples.pi_bridge

import acp.*
import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.{Result}
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
 *
 * 用法：
 *   pi_bridge [--echo] ["<后端agent命令>"]
 *
 *   --echo         不回连后端，直接回显（用于无 LLM 的协议冒烟测试）
 *   默认后端        "opencode acp"（需 XDG_DATA_HOME 指向可写目录）
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
    var backend = "opencode acp"
    for (a in args) {
        if (a == "--echo") { echoFlag = true }
        else if (!a.startsWith("-")) { backend = a }
    }
    let echoMode = echoFlag
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

    // ---- 会话映射：外部 sessionId <-> 后端 sessionId ----
    let sidMap = HashMap<String, String>()
    let mapLock = Mutex()
    let cwdOf = HashMap<String, String>()

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
    agent.capabilities.sessionCapabilities.list = Some(EmptyCapability())
    agent.capabilities.sessionCapabilities.delete = Some(EmptyCapability())

    agent.setOnNewSession({ cwd =>
        synchronized(mapLock) { cwdOf[cwd] = cwd }
    })

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

    logErr("[pi_bridge] 就绪，等待 ACP Client 连接...")
    agent.serve()
}
