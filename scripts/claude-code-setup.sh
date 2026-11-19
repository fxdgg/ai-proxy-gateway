#!/usr/bin/env bash
# 为 CLI 类工具(Claude Code / Codex 等)配置代理。这类工具不走系统代理，
# 而是读环境变量 HTTP_PROXY / HTTPS_PROXY。
#
# 双实例端口：AI 实例 7890 / 通用实例 7891。CLI 流量以 AI 站点为主，
# 默认指向 AI 实例(7890)。
#
# 用法: ./claude-code-setup.sh [网关地址]
#   网关地址默认 http://gateway.corp.example.com:7890 —— 请改成你的网关
set -euo pipefail

PROXY="${1:-http://gateway.corp.example.com:7890}"

echo "== 方式 A：临时(当前 shell 会话) =="
echo "  export HTTP_PROXY=$PROXY"
echo "  export HTTPS_PROXY=$PROXY"
echo "  export NO_PROXY=\"localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<常用内网域名>\""
echo "  export no_proxy=\"\$NO_PROXY\""
echo
echo "== 方式 B：永久(写入 ~/.zshrc 或 ~/.bashrc) =="
echo "  echo 'export HTTP_PROXY=$PROXY'  >> ~/.zshrc"
echo "  echo 'export HTTPS_PROXY=$PROXY' >> ~/.zshrc"
echo "  echo 'export NO_PROXY=\"localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<常用内网域名>\"' >> ~/.zshrc"
echo "  echo 'export no_proxy=\"\$NO_PROXY\"' >> ~/.zshrc"
echo
echo "== 方式 C：仅对 Claude Code 生效(~/.claude/settings.json) =="
cat <<EOF
  {
    "env": {
      "HTTP_PROXY": "$PROXY",
      "HTTPS_PROXY": "$PROXY",
      "NO_PROXY": "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<常用内网域名>",
      "no_proxy": "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<常用内网域名>"
    }
  }
EOF
echo
echo "提示：改完后重开终端 / 重启 Claude Code 生效。"
echo "注意：CLI 环境变量代理是全量代理（无 PAC），走 7890（AI 实例）时内网/国内站点会绕道美国出口；"
echo "  NO_PROXY/no_proxy（大小写双写——Node/Python 等工具只认小写，curl 系认大写）已豁免内网段。"
echo "  ⚠ 10.0.0.0/8 等 CIDR 段仅 curl ≥7.86 / libcurl 系工具识别，Node/Python 系不识别；"
echo "  关键内网主机建议同时列出主机名/IP 字面量（替换 <常用内网域名> 占位符）。"
echo "  国内站点如需直连，请自行把域名追加到 NO_PROXY。"
