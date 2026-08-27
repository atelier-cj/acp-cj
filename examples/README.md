# acp_probe_test

acp-cj 的 ACP 演示客户端：像 `src/examples/pi_bridge` 一样拉起真实后端 agent（默认 **opencode**），
走完整 ACP（Agent Client Protocol）client 链路：握手 → session/new → prompt → 流式打印 agent 回复。

比 pi_bridge 简单：不做 ACP server 代理、不做会话持久化，是一个开箱即用的演示二进制。

## 安装

从中心仓安装（安装后命令为 `acp_probe_test`）：

```bash
cjpm install acp_probe_test-0.1.0
```

或源码构建（依赖 acp-cj 主模块，`acp = { path = ".." }`）：

```bash
cd acp-cj/examples
cjpm build -j 16
./target/release/bin/acp_probe_test
```

## 环境要求

- 需要已安装 **opencode** CLI（ACP server）：`npm install -g opencode-ai`
- 未安装时程序会提示安装命令并以退出码 1 结束

## 用法

```bash
acp_probe_test [--prompt "<文本>"] [--cwd <目录>]
```

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--prompt` | 发送给 agent 的提示词 | `你好，请用一句话介绍你自己` |
| `--cwd` | 会话工作目录 | 当前目录 |

## 演示输出

```text
[acp_probe_test] 检测到 opencode，拉起后端 agent（opencode acp）...
[acp_probe_test] 后端握手成功: OpenCode v1.18.11
[acp_probe_test] 会话已创建: ses_fbcd3c701ffeWoB4jGi1NikHBM
[acp_probe_test] Prompt: 你好，请用一句话介绍你自己
我是 opencode，一个交互式命令行编程助手，能帮你搜索、阅读、编写和调试代码。有什么可以帮你的吗？
[acp_probe_test] 完成，stop_reason = end_turn
```

说明：进度日志输出到 stderr，agent 回复文本输出到 stdout。
