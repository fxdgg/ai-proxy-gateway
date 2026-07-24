#!/usr/bin/env bash
# 关闭 macOS「手动全局代理」(http + https)。
# 用法: ./macos-proxy-manual-off.sh [网络服务名]   默认 Wi-Fi
set -euo pipefail

SERVICE="${1:-Wi-Fi}"
echo "关闭 [$SERVICE] 的手动代理(http + https)"
networksetup -setwebproxystate       "$SERVICE" off
networksetup -setsecurewebproxystate "$SERVICE" off
echo "已关闭。"
