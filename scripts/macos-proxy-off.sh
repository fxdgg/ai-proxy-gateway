#!/usr/bin/env bash
# 关闭 macOS 系统级自动代理。
# 用法: ./macos-proxy-off.sh [网络服务名]   默认 Wi-Fi
# ```bash
# networksetup -listallnetworkservices                                   # 先确认服务名(Wi-Fi/Ethernet…)
# networksetup -setautoproxyurl "Wi-Fi" "http://服务器:19000/proxy.pac"   # 开(整条一行)
# networksetup -setautoproxystate "Wi-Fi" on
# networksetup -getautoproxyurl "Wi-Fi"                                   # 验证:URL + Enabled: Yes
# networksetup -setautoproxystate "Wi-Fi" off                            # 关
# ```
set -euo pipefail

SERVICE="${1:-Wi-Fi}"
echo "关闭网络服务 [$SERVICE] 的自动代理"
networksetup -setautoproxystate "$SERVICE" off
echo "已关闭。"
