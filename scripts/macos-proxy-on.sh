#!/usr/bin/env bash
# 开启 macOS 系统级自动代理（PAC）。开启后 Chrome、Claude 桌面版、Cursor 等
# 遵循系统代理的 app 全部生效。CLI 工具(Claude Code/Codex)请另见 claude-code-setup.sh。
#
# 用法: ./macos-proxy-on.sh [PAC_URL] [网络服务名]
#   PAC_URL 默认 http://gateway.corp.example.com:19000/proxy.pac —— 请改成你的网关
#   网络服务名 默认 Wi-Fi（有线用 "Ethernet"，可用 `networksetup -listallnetworkservices` 查看）
set -euo pipefail

PAC_URL="${1:-http://gateway.corp.example.com:19000/proxy.pac}"
SERVICE="${2:-Wi-Fi}"

echo "为网络服务 [$SERVICE] 设置自动代理: $PAC_URL"
networksetup -setautoproxyurl "$SERVICE" "$PAC_URL"
networksetup -setautoproxystate "$SERVICE" on
echo "已开启。验证: networksetup -getautoproxyurl \"$SERVICE\""
