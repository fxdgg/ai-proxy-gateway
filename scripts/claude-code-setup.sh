#!/usr/bin/env bash
# 为 CLI 类工具(Claude Code / Codex 等)配置代理。这类工具不走系统代理，
# 而是读环境变量 HTTP_PROXY / HTTPS_PROXY。
#
# 用法: ./claude-code-setup.sh [网关地址]
#   网关地址默认 http://gateway.corp.example.com:10800 —— 请改成你的网关
set -euo pipefail

PROXY="${1:-http://gateway.corp.example.com:10800}"

echo "== 方式 A：临时(当前 shell 会话) =="
echo "  export HTTP_PROXY=$PROXY"
echo "  export HTTPS_PROXY=$PROXY"
echo
echo "== 方式 B：永久(写入 ~/.zshrc 或 ~/.bashrc) =="
echo "  echo 'export HTTP_PROXY=$PROXY'  >> ~/.zshrc"
echo "  echo 'export HTTPS_PROXY=$PROXY' >> ~/.zshrc"
echo
echo "== 方式 C：仅对 Claude Code 生效(~/.claude/settings.json) =="
cat <<EOF
  {
    "env": {
      "HTTP_PROXY": "$PROXY",
      "HTTPS_PROXY": "$PROXY"
    }
  }
EOF
echo
echo "提示：改完后重开终端 / 重启 Claude Code 生效。"
