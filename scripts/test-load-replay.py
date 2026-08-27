#!/usr/bin/env python3
"""acp-cj P0 e2e：session/load 历史重放（接真实 opencode，复用已落盘的 sessions.json）"""
import subprocess, json, time, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ)
env["XDG_DATA_HOME"] = os.path.join(ROOT, ".opencode-data")
env["XDG_STATE_HOME"] = os.path.join(ROOT, ".e2e", "state")
env["XDG_CACHE_HOME"] = os.path.join(ROOT, ".e2e", "cache")
STORE = os.path.join(ROOT, ".e2e", "sessions.json")
BRIDGE = os.path.join(ROOT, "target/release/bin/acp.examples.pi_bridge")

def out(s):
    print(s, flush=True)

# 读取已有映射
try:
    with open(STORE) as f:
        mapping = json.load(f)
    sid = list(mapping.keys())[0]
    out(f"==> 从 store 恢复: {sid} -> {mapping[sid]['backendSessionId']}")
except Exception as e:
    out(f"FAIL: 无 sessions.json（先跑连接1）: {e}"); sys.exit(1)

p = subprocess.Popen([BRIDGE, "--store", STORE], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
def send(cmd):
    p.stdin.write(json.dumps(cmd) + "\n"); p.stdin.flush()
def read_until(pred, timeout=60):
    start = time.time()
    while time.time() - start < timeout:
        line = p.stdout.readline()
        if not line: return None
        try: m = json.loads(line)
        except: continue
        if pred(m): return m
    return None

send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"loadtest","version":"1"}}})
r = read_until(lambda m: m.get("id")==0, 30)
out("init: " + ("ok" if r else "TIMEOUT"))
if not r: p.kill(); sys.exit(1)

send({"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":sid,"cwd":"/tmp","mcpServers":[]}})
replayed = []
done = False
start = time.time()
while time.time() - start < 60 and not done:
    m = read_until(lambda x: True, 60)
    if not m: break
    if m.get("method") == "session/update":
        u = m["params"]["update"]
        if u.get("sessionUpdate") in ("user_message_chunk","agent_message_chunk","agent_thought_chunk"):
            c = u.get("content", {})
            if c.get("type") == "text": replayed.append(c.get("text",""))
    if m.get("id") == 1:
        out("load 响应: " + json.dumps(m.get("result") or m.get("error"))[:120])
        done = True
out(f"重放消息数: {len(replayed)}")
for r in replayed[:6]:
    out("  - " + r[:80])
p.stdin.close()
try: p.wait(timeout=5)
except: p.kill()
out("RESULT: " + ("PASS" if len(replayed) > 0 else "WARN"))
