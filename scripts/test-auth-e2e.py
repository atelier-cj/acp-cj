#!/usr/bin/env python3
"""P1 e2e：pi_bridge 开启认证门控后，client 走 auth_required -> authenticate -> 成功"""
import subprocess, json, time, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
BRIDGE = os.path.join(ROOT, "target/release/bin/acp.examples.pi_bridge")

def out(s): print(s, flush=True)

p = subprocess.Popen([BRIDGE, "--echo", "--auth-required"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
def send(cmd): p.stdin.write(json.dumps(cmd)+"\n"); p.stdin.flush()
def read_until(pred, timeout=30):
    start=time.time()
    while time.time()-start<timeout:
        line=p.stdout.readline()
        if not line: return None
        try: m=json.loads(line)
        except: continue
        if pred(m): return m
    return None

# initialize：应带 authMethods
send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"authtest","version":"1"}}})
init = read_until(lambda m: m.get("id")==0, 30)
authMethods = (init or {}).get("result",{}).get("authMethods",[])
out("init authMethods: " + json.dumps(authMethods, ensure_ascii=False)[:200])

# session/new：应 auth_required
send({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}})
new = read_until(lambda m: m.get("id")==1, 30)
err = new.get("error") or {}
out("session/new (未认证): code=" + str(err.get("code")) + " message=" + str(err.get("message"))[:60])
out("  data.authMethods: " + json.dumps(err.get("data",{}).get("authMethods"), ensure_ascii=False)[:150])

# authenticate
send({"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"pi_bridge_login"}})
auth = read_until(lambda m: m.get("id")==2, 30)
out("authenticate: " + ("ok" if "result" in (auth or {}) else json.dumps(auth.get("error"),ensure_ascii=False)[:100]))

# session/new 再次：应成功
send({"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}})
new2 = read_until(lambda m: m.get("id")==3, 30)
out("session/new (已认证): " + json.dumps(new2.get("result") or new2.get("error"), ensure_ascii=False)[:120])

# prompt 验证全链路
send({"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":new2["result"]["sessionId"],"prompt":[{"type":"text","text":"hi"}]}})
done=False; start=time.time()
while time.time()-start<30 and not done:
    m=read_until(lambda x: True, 30)
    if not m: break
    if m.get("method")=="session/update":
        u=m["params"]["update"]
        if u.get("sessionUpdate")=="agent_message_chunk":
            c=u.get("content",{})
            if c.get("type")=="text": out("  prompt 回复: " + c.get("text","")[:60])
    if m.get("id")==4:
        out("prompt 完成: stopReason=" + (m.get("result",{}).get("stopReason","?")))
        done=True

# logout 后再 session/new 应回到 auth_required
send({"jsonrpc":"2.0","id":5,"method":"logout","params":{}})
read_until(lambda m: m.get("id")==5, 30)
send({"jsonrpc":"2.0","id":6,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}})
new3 = read_until(lambda m: m.get("id")==6, 30)
err3 = new3.get("error") or {}
out("session/new (logout 后): code=" + str(err3.get("code")))
p.stdin.close()
try: p.wait(timeout=5)
except: p.kill()
out("RESULT: PASS" if err3.get("code")==-32000 else "RESULT: FAIL")
