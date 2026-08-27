"""验证 opencode acp 收到 session/new 的 mcpServers 后是否真的连接 MCP 并调用工具"""
import subprocess, json, time, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(os.environ)
env["XDG_DATA_HOME"] = os.path.join(ROOT, ".opencode-data")
env["XDG_STATE_HOME"] = os.path.join(ROOT, ".e2e", "state")
env["XDG_CACHE_HOME"] = os.path.join(ROOT, ".e2e", "cache")

# 启动最小 MCP server 的 stderr 日志观察（opencode 若连接会有 MCP 相关输出）
proc = subprocess.Popen(["opencode", "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
def send(cmd): proc.stdin.write(json.dumps(cmd)+"\n"); proc.stdin.flush()
def read_until(pred, timeout=60):
    start=time.time()
    while time.time()-start<timeout:
        line=proc.stdout.readline()
        if not line: return None
        try: m=json.loads(line)
        except: continue
        if pred(m): return m
    return None

send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"probe","version":"1"}}})
read_until(lambda m: m.get("id")==0, 30)

# session/new 带 mcpServers（stdio）
mcp = {"name":"mini-mcp","command":sys.executable,"args":[os.path.join(ROOT,".e2e/mini_mcp_server.py")],"env":[]}
send({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[mcp]}})
new = read_until(lambda m: m.get("id")==1, 60)
print("session/new:", json.dumps(new.get("result") or new.get("error"), ensure_ascii=False)[:150])
if not new or "error" in new:
    print("RESULT: opencode 拒绝了带 mcpServers 的 session/new")
    proc.kill(); sys.exit(0)
sid = new["result"]["sessionId"]

# prompt 让 opencode 调用 magic_echo 工具（若它连了 MCP 就会调用）
send({"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":"Please call the magic_echo tool with text hello-mcp and report exactly what it returns. If you have no such tool, say NO_TOOL."}]}})
saw_tool = False; saw_text = ""
done=False; start=time.time()
while time.time()-start<120 and not done:
    m=read_until(lambda x: True, 120)
    if not m: break
    if m.get("method")=="session/update":
        u=m["params"]["update"]
        if u.get("sessionUpdate")=="tool_call": saw_tool=True; print("  工具调用:", u.get("title"))
        if u.get("sessionUpdate") in ("agent_message_chunk","agent_thought_chunk"):
            c=u.get("content",{})
            if c.get("type")=="text": saw_text += c.get("text","")
    if m.get("id")==2: done=True
print("  最终回复:", saw_text[:300])
proc.kill()
print("RESULT:", "PASS（opencode 连接了 MCP 并调用工具）" if saw_tool else "WARN（未见工具调用）")
