package acp.transport

import ystyle::jsonrpc.{Transport, NewlineFraming}
import std.env.{getStdIn, getStdOut}
import std.process.{launch, ProcessRedirect, SubProcess}
import std.io.{OutputStream, InputStream}

// ===================== 帧常量 =====================
// ACP stdio 传输：消息以 LF (\n) 分隔，消息内不得含嵌入换行。
// JSON 序列化会把文本内换行转义为 \n，因此 NewlineFraming 完全适用。
public let AcpFraming = NewlineFraming()

/**
 * StdioTransport：绑定当前进程的标准输入输出。
 * 用于 ACP Agent 侧（被 Client 以子进程方式拉起）。
 */
public class StdioTransport <: Transport {
    private var running: Bool = true

    public init() {}

    public func send(data: Array<Byte>): Unit {
        getStdOut().write(data)
        getStdOut().flush()
    }

    public func receive(): ?Array<Byte> {
        // 注意：仓颉 getStdIn().read(chunk) 在管道模式下会缓冲直到 EOF 才返回，
        // 不适合交互式 ACP。改用 readln（按行读），正好匹配 ACP 的换行帧分隔。
        if (let Some(line) <- getStdIn().readln()) {
            let chars = line.toArray()
            let bytes = Array<Byte>(chars.size + 1, repeat: 0)
            for (i in 0..chars.size) { bytes[i] = chars[i] }
            bytes[chars.size] = 10
            Some(bytes)
        } else {
            None
        }
    }

    public func isClosed(): Bool { !this.running }
    public func close(): Unit { this.running = false }
}

/**
 * SubprocessTransport：spawn 一个外部命令并通过其 stdin/stdout 通信。
 * 用于 ACP Client 侧（拉起 pi-acp / 任意 ACP agent）。
 */
public class SubprocessTransport <: Transport {
    private let process: SubProcess
    private let stdin: OutputStream
    private let stdout: InputStream

    public init(command: String, args!: Array<String> = []) {
        let proc = launch(command, args,
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Inherit)
        this.process = proc
        this.stdin = proc.stdInPipe
        this.stdout = proc.stdOutPipe
    }

    public func send(data: Array<Byte>): Unit {
        this.stdin.write(data)
        this.stdin.flush()
    }

    public func receive(): ?Array<Byte> {
        let chunk = Array<Byte>(8192, repeat: 0)
        let n = this.stdout.read(chunk)
        if (n <= 0) {
            return None
        }
        Some(chunk[0..n])
    }

    public func isClosed(): Bool { false }

    public func close(): Unit {
        try {
            this.process.terminate(force: true)
            this.process.wait()
        } catch (e: Exception) {
            // 忽略关闭异常
        }
    }

    public func wait(timeout!: Duration): ?Int64 {
        this.process.wait(timeout: timeout)
    }
}
