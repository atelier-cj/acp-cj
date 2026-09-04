package acp

import acp.types.*
import acp.transport.*
import jsonvalue.*
import ystyle::jsonrpc.*
import std.sync.*
import std.collection.*
import std.io.ByteBuffer
import stdx.encoding.json.stream.*

// ===================== 内存管道（in-process 双工） =====================

public class MemoryPipe {
    private let lock = Mutex()
    private let cond: Condition
    private let data = ArrayList<UInt8>()
    private var closed = false

    public init() {
        this.cond = synchronized(this.lock) { this.lock.condition() }
    }

    public func write(bytes: Array<UInt8>): Unit {
        synchronized(this.lock) {
            for (b in bytes) { this.data.add(b) }
            this.cond.notifyAll()
        }
    }

    public func read(): ?Array<UInt8> {
        synchronized(this.lock) {
            while (this.data.size == 0 && !this.closed) {
                if (!this.cond.wait(timeout: 1 * Duration.second)) { return None }
            }
            if (this.data.size == 0 && this.closed) { return None }
            let out = Array<UInt8>(this.data.size, repeat: 0)
            for (i in 0..this.data.size) { out[i] = this.data[i] }
            this.data.clear()
            Some(out)
        }
    }

    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.cond.notifyAll()
        }
    }
}

public class DuplexTransport <: Transport {
    // 发送与接收使用不同方向的管道，保证双向隔离
    private let out: MemoryPipe
    private let inp: MemoryPipe
    public init(out: MemoryPipe, inp: MemoryPipe) {
        this.out = out
        this.inp = inp
    }
    public func send(data: Array<Byte>): Unit { this.out.write(data) }
    public func receive(): ?Array<Byte> { this.inp.read() }
    public func isClosed(): Bool { false }
    public func close(): Unit { this.out.close() }
}

// A<->B 双向管道对
public class PipePair {
    public let a2b = MemoryPipe()
    public let b2a = MemoryPipe()
    // A 侧 transport：send 到 a2b，从 b2a 接收
    public func a(): Transport { DuplexTransport(a2b, b2a) }
    // B 侧 transport：send 到 b2a，从 a2b 接收
    public func b(): Transport { DuplexTransport(b2a, a2b) }
}

// ===================== 模拟 ACP Agent（JsonRpcServer 实现） =====================

public class FakeAgent {
    public let server: JsonRpcServer
    public var emitted: ArrayList<String> = ArrayList<String>()   // 记录发出的通知文本
    public let emitLock = Mutex()
    public let sessions = ArrayList<String>()
    public let sessionLock = Mutex()

    public init(transport: Transport) {
        this.server = JsonRpcServer(transport, framing: NewlineFraming())
        this.server.register("initialize", { ctx => this.handleInitialize(ctx) })
        this.server.register("session/new", { ctx => this.handleNewSession(ctx) })
        this.server.registerAsync("session/prompt", { ctx, complete => this.handlePrompt(ctx, complete) })
    }

    private func handleInitialize(ctx: HandlerContext): HandlerResult {
        let resp = InitializeResponse()
        resp.protocolVersion = 1
        resp.agentInfo = Some(Implementation("fake-agent", "0.1.0"))
        resp.agentCapabilities.loadSession = true
        HandlerResult.ok(JsonValue.fromObject(resp))
    }

    private func handleNewSession(ctx: HandlerContext): HandlerResult {
        let resp = NewSessionResponse()
        resp.sessionId = "sess_fake_1"
        synchronized(this.sessionLock) { this.sessions.add("sess_fake_1") }
        HandlerResult.ok(JsonValue.fromObject(resp))
    }

    private func handlePrompt(ctx: HandlerContext, complete: (JsonValue) -> Unit): Unit {
        spawn {
            => this.doPrompt(ctx, complete)
        }
    }

    private func doPrompt(ctx: HandlerContext, complete: (JsonValue) -> Unit): Unit {
        // 发送一条 agent_message_chunk 通知
        let notif = SessionNotification()
        notif.sessionId = "sess_fake_1"
        notif.update = SessionUpdate.agentMessage("hello from fake agent")
        this.server.notify<SessionNotification>("session/update", params: notif)
        // 记录（加锁）
        synchronized(this.emitLock) {
            let jv = JsonValue.fromObject(notif)
            this.emitted.add(jv.stringify())
        }
        // 完成回合
        complete(JsonValue.fromObject(PromptResponse(StopReasonEndTurn)))
    }
}

// ===================== 测试 =====================

func connectClient(pair: PipePair): AcpClient {
    AcpClient(pair.a())
}

@Test
public func client_connect_and_new_session() {
    let pair = PipePair()
    let agent = FakeAgent(pair.b())
    agent.server.start()

    let client = AcpClient(pair.a())
    let caps = ClientCapabilities()
    let result = client.connect(Implementation("test-client", "1.0.0"), caps)
    match (result) {
        case Result.Ok(resp) =>
            @Expect(resp.protocolVersion, 1)
            match (resp.agentInfo) {
                case Some(info) => @Expect(info.name, "fake-agent")
                case None => @Fail("agentInfo is None")
            }
        case Result.Err(e) => @Fail("connect failed: ${e}")
    }

    let newResult = client.newSession("/tmp/proj")
    match (newResult) {
        case Result.Ok(resp) => @Expect(resp.sessionId, "sess_fake_1")
        case Result.Err(e) => @Fail("newSession failed: ${e}")
    }
    client.close()
    agent.server.close()
}

@Test
public func client_prompt_streams_notification() {
    let pair = PipePair()
    let agent = FakeAgent(pair.b())
    agent.server.start()

    let client = AcpClient(pair.a())
    let received = ArrayList<String>()
    client.setOnSessionUpdate({ sid, update =>
        if (update.sessionUpdate == SessionUpdateAgentMessageChunk) {
            match (update.content) {
                case Some(c) => received.add(c.text ?? "")
                case None => ()
            }
        }
    })
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())
    client.newSession("/tmp/proj")

    let pResult = client.promptText("sess_fake_1", "hi")
    match (pResult) {
        case Result.Ok(resp) => @Expect(resp.stopReason, StopReasonEndTurn)
        case Result.Err(e) => @Fail("prompt failed: ${e}")
    }
    // 通知应在 receiveLoop 中送达（轻微等待保证线程调度）
    var tries: Int64 = 0
    while (received.size == 0 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(received.size, 1)
    @Expect(received[0], "hello from fake agent")
    client.close()
    agent.server.close()
}

@Test
public func client_receives_extension_notification() {
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "fake-agent", "0.1.0")
    agent.start()

    let client = AcpClient(pair.a())
    let got = ArrayList<String>()
    client.onNotification("_hello", { method, params =>
        got.add(method)
        match (params) {
            case JsonValue.String(s) => got.add("param:" + s)
            case _ => got.add("param:none")
        }
    })
    client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())

    // Agent 发扩展通知（带参数）
    agent.sendExtensionNotification("_hello", params: Some(JsonValue.String("world")))
    // Agent 发未订阅的通知（应被忽略不报错）
    agent.sendExtensionNotification("_ignored")

    var tries: Int64 = 0
    while (got.size == 0 && tries < 100) {
        tries++
        sleep(10 * Duration.millisecond)
    }
    @Expect(got.size, 2)
    @Expect(got[0], "_hello")
    @Expect(got[1], "param:world")
    client.close()
    agent.close()
}

@Test
public func client_connect_rejects_unsupported_protocol_version() {
    // 规范：Client 收到不支持协议版本（Agent 侧声明最新支持为 v2）时应失败并提示，而非照常工作
    let pair = PipePair()
    let agent = AcpAgent(pair.b(), "fake-agent", "0.1.0")
    agent.protocolVersion = 2   // 模拟未来 Agent：只支持 v2
    agent.start()
    let client = AcpClient(pair.a())
    match (client.connect(Implementation("test-client", "1.0.0"), ClientCapabilities())) {
        case Result.Ok(_) => @Fail("client must reject unsupported protocol version")
        case Result.Err(e) =>
            @Expect(e.contains("protocol version"), true)
            @Expect(e.contains("2"), true)
    }
    @Expect(client.isConnected(), false)
    client.close()
    agent.close()
}
