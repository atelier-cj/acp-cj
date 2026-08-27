import subprocess, json, time, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(os.environ)
env["XDG_DATA_HOME"] = os.path.join(ROOT, ".opencode-data")
env["XDG_STATE_HOME"] = os.path.join(ROOT, ".e2e", "state")
env["XDG_CACHE_HOME"] = os.path.join(ROOT, ".e2e", "cache")
env["OPENCODE_SERVER_USERNAME"] = "acp-user"
env["OPENCODE_SERVER_PASSWORD"] = "acp-pass-123"

proc = subprocess.Popen(["opencode", "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
def send(cmd):
    proc.stdin.write(json.dumps(cmd)+"\n"); proc.stdin.flush()
def read_until(pred, timeout=30):
    start=time.time()
    while time.time()-start<timeout:
        line=proc.stdout.readline()
        if not line: return None
        try: m=json.loads(line)
        except: continue
        if pred(m): return m
    return None

send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"probe","version":"1"}}})
init = read_until(lambda m: m.get("id")==0, 30)
print("init authMethods:", json.dumps((init or {}).get("result",{}).get("authMethods",[]), ensure_ascii=False)[:300])

send({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}})
new = read_until(lambda m: m.get("id")==1, 30)
print("session/new:", json.dumps(new.get("result") or new.get("error"), ensure_ascii=False)[:300])
proc.kill()
