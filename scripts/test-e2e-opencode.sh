#!/usr/bin/env bash
# 端到端测试：acp-cj Client 连接 opencode 的 ACP 模式（真实 LLM）
# 需要：opencode 已安装且配置了模型（~/.config/opencode 或可写 XDG 数据目录）
set -euo pipefail
cd "$(dirname "$0")/.."

export XDG_DATA_HOME="${XDG_DATA_HOME:-$PWD/.opencode-data}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$PWD/.opencode-state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$PWD/.opencode-cache}"

# 首次运行时把 opencode 的 auth/account 复制到可写数据目录
if [ ! -f "$XDG_DATA_HOME/auth.json" ] && [ -f "$HOME/.local/share/opencode/auth.json" ]; then
  mkdir -p "$XDG_DATA_HOME"
  cp "$HOME/.local/share/opencode/auth.json" "$XDG_DATA_HOME/" 2>/dev/null || true
  cp "$HOME/.local/share/opencode/account.json" "$XDG_DATA_HOME/" 2>/dev/null || true
fi

echo "==> 构建 testclient"
eval "$(cjvs env zsh 2>/dev/null)"
eval "$(cjvs stdx-env zsh 2>/dev/null)"
cjpm build -j 16

echo "==> 连接 opencode acp 并发送真实 prompt"
timeout 180 ./target/release/bin/acp.examples.testclient "opencode acp" /tmp "${1:-Reply with only the word OK, nothing else}"
