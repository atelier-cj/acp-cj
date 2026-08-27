import subprocess, json, time, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(os.environ)
env["XDG_DATA_HOME"] = os.path.join(ROOT, ".opencode-data")
env["XDG_STATE_HOME"] = os.path.join(ROOT, ".e2e", "state")
env["XDG_CACHE_HOME"] = os.path.join(ROOT, ".e2e", "cache")
proc = subprocess.Popen(["opencode", "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
proc.stdin.write(json.dumps({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"probe","version":"1"}}})+"\n")
proc.stdin.flush()
start=time.time()
while time.time()-start<30:
    line=proc.stdout.readline()
    if not line: break
    m=json.loads(line)
    if m.get("id")==0:
        print("authMethods:", json.dumps(m["result"].get("authMethods", []), ensure_ascii=False, indent=2))
        print("clientCapabilities auth 相关: 无（agent 侧）")
        break
proc.kill()
