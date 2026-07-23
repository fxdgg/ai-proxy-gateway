#!/usr/bin/env bash
# 关闭 macOS 系统级自动代理。
# 用法: ./macos-proxy-off.sh [网络服务名]   默认 Wi-Fi
set -euo pipefail

SERVICE="${1:-Wi-Fi}"
echo "关闭网络服务 [$SERVICE] 的自动代理"
networksetup -setautoproxystate "$SERVICE" off
echo "已关闭。"
