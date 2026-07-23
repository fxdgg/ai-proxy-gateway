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

# 3) 测试终端出口（是否静态住宅 IP）——等价于终端设了 HTTP_PROXY 后 curl ipinfo.io
hr
echo "▶ 测试终端走的是否为静态住宅 IP：curl -x $GATEWAY ipinfo.io"
ipinfo=$(curl -fsS -x "http://$GATEWAY" --max-time 15 https://ipinfo.io/json 2>/dev/null)
if [ -n "$ipinfo" ]; then
  echo "$ipinfo" | jq -r '"  IP: \(.ip)\n  地区: \(.country) \(.region) \(.city)\n  ISP/组织: \(.org)"' 2>/dev/null || echo "$ipinfo"
  echo "  提示：ISP/组织若为住宅运营商(如 Comcast/AT&T/Verizon 等)则为住宅 IP；"
  echo "        若为机房厂商(如 Amazon/Google/DigitalOcean/OVH 等)则是数据中心 IP。"
else
  echo "  ⚠ 经网关请求失败：检查网关是否在 $GATEWAY 监听、节点是否可用。"
fi

# 4) 测试 Claude 出口（是否静态住宅 IP）——claude.ai 的 Cloudflare trace
hr
echo "▶ 测试 Claude 走的是否为静态住宅 IP：curl -x $GATEWAY https://claude.ai/cdn-cgi/trace"
trace=$(curl -fsS -x "http://$GATEWAY" --max-time 15 https://claude.ai/cdn-cgi/trace 2>/dev/null)
if [ -n "$trace" ]; then
  echo "$trace" | grep -E '^(ip|loc|colo|warp)=' | sed 's/^/  /'
  claude_ip=$(echo "$trace" | awk -F= '/^ip=/{print $2}')
  # 对该出口 IP 反查 ISP/地区，判断是否住宅
  if [ -n "$claude_ip" ]; then
    echo "  ↳ 出口 IP $claude_ip 归属："
    curl -fsS --max-time 15 "https://ipinfo.io/$claude_ip/json" 2>/dev/null \
      | jq -r '"     地区: \(.country) \(.region) \(.city)\n     ISP/组织: \(.org)"' 2>/dev/null \
      || echo "     (ipinfo 查询失败)"
  fi
else
  echo "  ⚠ 经网关访问 claude.ai 失败：检查 AI 组节点是否可用、claude.ai 是否被正确代理。"
fi

hr
echo "验证结束。若 AI 组为空或出口非美国，请检查 nodes/ai.yaml 节点命名与 config.yaml 的 filter 正则。"
