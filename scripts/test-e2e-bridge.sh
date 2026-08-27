#!/usr/bin/env bash
# 端到端测试：acp-cj Client ↔ acp-cj Server（pi_bridge）↔ 真实 opencode agent
# 验证 ACP 代理链：testclient -> pi_bridge -> opencode -> LLM
set -euo pipefail
cd "$(dirname "$0")/.."

export XDG_DATA_HOME="${XDG_DATA_HOME:-$PWD/.opencode-data}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$PWD/.opencode-state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$PWD/.opencode-cache}"

if [ ! -f "$XDG_DATA_HOME/auth.json" ] && [ -f "$HOME/.local/share/opencode/auth.json" ]; then
  mkdir -p "$XDG_DATA_HOME"
  cp "$HOME/.local/share/opencode/auth.json" "$XDG_DATA_HOME/" 2>/dev/null || true
  cp "$HOME/.local/share/opencode/account.json" "$XDG_DATA_HOME/" 2>/dev/null || true
fi

echo "==> 构建"
eval "$(cjvs env zsh 2>/dev/null)"
eval "$(cjvs stdx-env zsh 2>/dev/null)"
cjpm build -j 16

echo "==> 1) echo 模式（无 LLM 冒烟）：acp-cj client <-> acp-cj server"
timeout 60 ./target/release/bin/acp.examples.testclient "./target/release/bin/acp.examples.pi_bridge --echo" /tmp "hello bridge"

echo ""
echo "==> 2) 完整代理链：acp-cj client -> acp-cj server(pi_bridge) -> opencode -> LLM"
timeout 180 ./target/release/bin/acp.examples.testclient "./target/release/bin/acp.examples.pi_bridge" /tmp "${1:-Reply with only the word OK, nothing else}"

echo ""
echo "==> 3) session/load 历史重放（接真实 opencode）"
python3 scripts/test-load-replay.py

echo ""
echo "==> 4) 认证门控 e2e（pi_bridge --auth-required）"
python3 scripts/test-auth-e2e.py
