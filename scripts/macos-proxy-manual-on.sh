#!/usr/bin/env bash
# 开启 macOS「手动全局代理」——把所有 http/https 交给网关(mihomo 再按规则分流)。
# 适用于不认 PAC、只认手动代理的桌面 app。与 PAC 二选一，别同时开。
# CLI 工具(Claude Code/Codex)不走系统代理，请用环境变量 HTTPS_PROXY(见 claude-code-setup.sh)。
#
# 用法: ./macos-proxy-manual-on.sh [host] [port] [网络服务名]
#   默认 host=9.135.113.95 port=10800 服务名=Wi-Fi
#   服务名可用 `networksetup -listallnetworkservices` 查看(有线常为 Ethernet)
set -euo pipefail

HOST="${1:-9.135.113.95}"
PORT="${2:-10800}"
SERVICE="${3:-Wi-Fi}"

echo "为 [$SERVICE] 设置手动代理 $HOST:$PORT (http + https)"
networksetup -setwebproxy       "$SERVICE" "$HOST" "$PORT"
networksetup -setsecurewebproxy "$SERVICE" "$HOST" "$PORT"
networksetup -setwebproxystate       "$SERVICE" on
networksetup -setsecurewebproxystate "$SERVICE" on
echo "已开启。设完请【完全退出并重开】桌面 app(Cmd+Q)才会生效。"
echo "验证(服务器上): ./scripts/logs.sh claude  然后用桌面版发消息看日志。"
