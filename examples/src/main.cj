package acp_probe_test

import acp.*
import acp.types.*
import acp.transport.*
import ystyle::jsonrpc.Result
import std.env.{getCommandLine, getStdErr, getVariable, setVariable, getWorkingDirectory}
import std.process.executeWithOutput

/**
 * acp_probe_test：acp-cj 的演示客户端。
 *
 * 像 src/examples/pi_bridge 一样拉起真实后端 agent（默认 `opencode acp`），
 * 走完整 ACP client 链路：握手 → session/new → prompt → 流式打印 agent 回复。
 * 比 pi_bridge 简单：不做 ACP server 代理、不做会话持久化。
 *
 * opencode 未安装时提示安装命令并退出。
 *
 * 用法：
 *   acp_probe_test [--prompt "<文本>"] [--cwd <目录>]
 */
public struct DemoOptions {
    public var prompt: String = "你好，请用一句话介绍你自己"
    public var cwd: String = ""
    public init() {}
}

public func parseOptions(args: Array<String>): DemoOptions {
    var opts = DemoOptions()
    var i: Int64 = 0
    while (i < args.size) {
        let a = args[i]
        if (a == "--prompt") {
            i++
            if (i < args.size) { opts.prompt = args[i] }
        } else if (a == "--cwd") {
            i++
            if (i < args.size) { opts.cwd = args[i] }
        }
        i++
    }
    opts
}

// 检测 opencode 是否可用：执行 `opencode --version`，退出码为 0 即已安装
public func checkOpencode(): Bool {
    try {
        let (code, _, _) = executeWithOutput("opencode", ["--version"])
        code == 0
    } catch (e: Exception) {
        false
    }
}

// XDG 重定向：home 目录只读时 opencode 仍能写入运行时数据（沿用 pi_bridge 的沙箱经验）
public func setupXdg(cwd: String): Unit {
    if (getVariable("XDG_DATA_HOME") == None) { setVariable("XDG_DATA_HOME", cwd + "/.opencode-data") }
    if (getVariable("XDG_CONFIG_HOME") == None) { setVariable("XDG_CONFIG_HOME", cwd + "/.opencode-config") }
    if (getVariable("XDG_CACHE_HOME") == None) { setVariable("XDG_CACHE_HOME", cwd + "/.opencode-cache") }
}

func logMsg(msg: String): Unit {
    let err = getStdErr()
    err.writeln(msg)
    err.flush()
}

func logErr(msg: String): Unit {
    let err = getStdErr()
    err.writeln("[acp_probe_test] ${msg}")
    err.flush()
}

main(): Int64 {
    let opts = parseOptions(getCommandLine()[1..])
    let cwd = if (opts.cwd == "") { getWorkingDirectory().toString() } else { opts.cwd }

    // 1. 检测 opencode，未安装则提示
    if (!checkOpencode()) {
        logErr("未检测到 opencode，请先安装：npm install -g opencode-ai")
        return 1
    }
    logMsg("[acp_probe_test] 检测到 opencode，拉起后端 agent（opencode acp）...")

    // 2. XDG 重定向（未设置时指向工作目录，避免写入只读 home）
    setupXdg(cwd)

    // 3. 握手
    let client = AcpClient(SubprocessTransport("opencode", args: ["acp"]))
    match (client.connect(Implementation("acp-probe-test", "0.1.0"), ClientCapabilities())) {
        case Result.Ok(initResp) =>
            let info = initResp.agentInfo ?? Implementation("unknown", "?")
            logMsg("[acp_probe_test] 后端握手成功: ${info.name} v${info.version}")
        case Result.Err(e) =>
            logErr("后端握手失败: ${e}")
            return 1
    }

    // 4. 流式打印 agent 文本回复
    client.setOnSessionUpdate({ _, update =>
        if (update.sessionUpdate == SessionUpdateAgentMessageChunk) {
            match (update.content) {
                case Some(c) =>
                    match (c.text) {
                        case Some(t) => println(t)
                        case None => ()
                    }
                case None => ()
            }
        }
    })

    // 5. 建会话 + 发 prompt
    match (client.newSession(cwd)) {
        case Result.Ok(resp) =>
            logMsg("[acp_probe_test] 会话已创建: ${resp.sessionId}")
            logMsg("[acp_probe_test] Prompt: ${opts.prompt}")
            match (client.promptText(resp.sessionId, opts.prompt)) {
                case Result.Ok(pres) =>
                    logMsg("[acp_probe_test] 完成，stop_reason = ${pres.stopReason}")
                case Result.Err(e) =>
                    logErr("prompt 失败: ${e}")
                    return 1
            }
        case Result.Err(e) =>
            logErr("session/new 失败: ${e}")
            return 1
    }

    client.close()
    0
}
