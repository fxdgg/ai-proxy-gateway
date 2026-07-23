#!/usr/bin/env bash
# 部署后验证脚本：检查节点池、各代理组 filter 命中情况、代理连通性。
# 依赖 mihomo 的 external-controller(默认 127.0.0.1:9090) 与 jq。
#
# 用法: ./scripts/verify.sh [API地址] [网关host:port]
#   API地址    默认 http://127.0.0.1:9090
#   网关地址   默认 127.0.0.1:10800（用于连通性测试）
set -uo pipefail

API="${1:-http://127.0.0.1:9090}"
GATEWAY="${2:-127.0.0.1:10800}"

command -v jq >/dev/null 2>&1 || { echo "缺少 jq，请先安装：brew install jq / apt install jq"; exit 1; }

hr() { printf '%.0s─' {1..60}; echo; }

# 检查某个代理组筛选出的节点：打印数量+列表，空则告警(通常是 filter 没匹配到)
check_group() {
  local group="$1"
  hr
  echo "▶ 代理组 [$group] 命中节点："
  local nodes
  nodes=$(curl -fsS "$API/proxies/$group" 2>/dev/null | jq -r '.all[]?' 2>/dev/null)
  if [ -z "$nodes" ]; then
    echo "  ⚠ 空！filter 可能没匹配到任何节点(检查节点命名或正则)，或该组不存在。"
    return 1
  fi
  echo "$nodes" | sed 's/^/  - /'
  echo "  合计: $(echo "$nodes" | grep -c .) 个节点"
}

echo "== ai-proxy-gateway 验证 =="
echo "API: $API   网关: $GATEWAY"

# 1) 节点池健康
hr
echo "▶ proxy-providers 健康状态："
for p in airport ai_airport; do
  cnt=$(curl -fsS "$API/providers/proxies/$p" 2>/dev/null | jq '.proxies | length' 2>/dev/null)
  echo "  $p: ${cnt:-N/A} 个节点"
done

# 2) 各代理组 filter 命中（重点确认 AI 组锁定美国后非空）
check_group AI-FIXED
check_group GEN-ROTATE
check_group AI-STICKY

# 3) 代理连通性 + 出口 IP/地区（确认真的走了美国出口）
hr
echo "▶ 经网关访问出口 IP（应为美国）："
ipinfo=$(curl -fsS -x "http://$GATEWAY" --max-time 15 https://ipinfo.io/json 2>/dev/null)
if [ -n "$ipinfo" ]; then
  echo "$ipinfo" | jq -r '"  IP: \(.ip)\n  地区: \(.country) \(.region) \(.city)\n  ISP: \(.org)"' 2>/dev/null || echo "$ipinfo"
else
  echo "  ⚠ 经网关请求失败：检查网关是否在 $GATEWAY 监听、节点是否可用。"
fi

hr
echo "验证结束。若 AI 组为空或出口非美国，请检查 nodes/ai.yaml 节点命名与 config.yaml 的 filter 正则。"
