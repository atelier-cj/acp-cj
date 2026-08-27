package acp.examples.testclient

import acp.*
import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.Result
import std.env.getCommandLine
import std.collection.ArrayList

/**
 * testclient：连接一个真实的 ACP Agent（如 `opencode acp` 或 pi-acp），
 * 完成 initialize → session/new → session/prompt 全流程，并打印流式输出。
 *
 * 用法：
 *   testclient "<agent命令>" ["<cwd>"] ["<prompt文本>"]
 *
 * 示例：
 *   # opencode 的 ACP 模式（需要时可先 export XDG_DATA_HOME 到可写目录）
 *   testclient "opencode acp" "/tmp" "hello"
 *
 *   # pi-acp 适配器
 *   testclient "node /path/to/pi-acp/dist/index.js" "/tmp" "hello"
 */
func splitCommand(cmd: String): (String, Array<String>) {
    let parts = cmd.split(' ')
    var first: String = ""
    let rest = ArrayList<String>()
    var idx: Int64 = 0
    for (p in parts) {
        if (idx == 0) {
            first = p
        } else {
            rest.add(p)
        }
        idx++
    }
    (first, rest.toArray())
}

func extractText(update: SessionUpdate): ?String {
    if (update.sessionUpdate == SessionUpdateAgentMessageChunk ||
        update.sessionUpdate == SessionUpdateAgentThoughtChunk) {
        match (update.content) {
            case Some(c) => c.text
            case None => None
        }
    } else {
        None
    }
}

main() {
    let args = getCommandLine()
    if (args.size < 2) {
        println("用法: testclient \"<agent命令>\" [\"<cwd>\"] [\"<prompt文本>\"]")
        return
    }
    let (command, cmdArgs) = splitCommand(args[1])
    let cwd = if (args.size > 2) { args[2] } else { "." }
    let promptText = if (args.size > 3) { args[3] } else { "Hello, reply with a short greeting." }

    println("[testclient] 启动 agent: ${command} ${cmdArgs}")
    let transport = SubprocessTransport(command, args: cmdArgs)
    let client = AcpClient(transport)

    // 流式输出回调
    client.setOnSessionUpdate({ sid, update =>
        match (extractText(update)) {
            case Some(t) => print(t)
            case None => ()
        }
        if (update.sessionUpdate == SessionUpdateToolCall) {
            let title = update.title ?? "tool"
            println("\n[tool_call] ${title}")
        }
        if (update.sessionUpdate == SessionUpdateAvailableCommands) {
            println("\n[commands] ${update.availableCommands?.size ?? 0} 个可用命令")
        }
    })

    // 初始化
    let caps = ClientCapabilities()
    match (client.connect(Implementation("acp-cj-testclient", "0.1.0"), caps, timeout: 30 * Duration.second)) {
        case Result.Ok(initResp) =>
            let info = initResp.agentInfo ?? Implementation("", "")
            println("[init] agent=${info.name} v${info.version} protocol=${initResp.protocolVersion}")
        case Result.Err(e) =>
            println("[init] 失败: ${e}")
            return
    }

    // 创建会话
    let sessionId = match (client.newSession(cwd, timeout: 120 * Duration.second)) {
        case Result.Ok(newResp) =>
            println("[session] id=${newResp.sessionId}")
            newResp.sessionId
        case Result.Err(e) =>
            println("[session] 失败: ${e}")
            return
    }

    // 发送 prompt 并等待回合结束
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ofText(promptText))
    println("[prompt] ${promptText}")
    match (client.prompt(sessionId, blocks, timeout: 10 * Duration.minute)) {
        case Result.Ok(resp) => println("\n[done] stopReason=${resp.stopReason}")
        case Result.Err(e) => println("\n[prompt] 失败: ${e}")
    }

    client.close()
    println("[testclient] 结束")
}
