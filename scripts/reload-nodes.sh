#!/usr/bin/env bash
# 热重载 mihomo 节点池（改完 nodes/clash.yaml 后调用，员工无感知）。
# 依赖 external-controller(默认 127.0.0.1:9090)。
set -euo pipefail

API="${1:-http://127.0.0.1:9090}"

echo "触发 mihomo provider 重载..."
# 重新拉取/读取名为 airport 的 proxy-provider
curl -fsS -X PUT "$API/providers/proxies/airport" && echo " -> provider 已重载"
echo "查看节点健康：curl -s $API/providers/proxies/airport | jq"
