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

# 住宅 vs 机房 IP —— 关键词启发式判断（精确判定需付费 API 的 privacy/company 字段）
classify_org() {
  local lc; lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$lc" | grep -Eq 'akamai|linode|amazon|aws|google|azure|digitalocean|vultr|choopa|ovh|hetzner|cloudflare|m247|leaseweb|contabo|oracle|gcore|datacamp|colocross|constant|data ?cent|cloud|hosting|hostin|vps|idc|server'; then
    echo "机房/数据中心 IP（非住宅）❌"
  elif printf '%s' "$lc" | grep -Eq 'comcast|at&t|verizon|spectrum|charter|cox communi|centurylink|frontier|t-mobile|xfinity|residential|broadband|cable|fios|fiber|dsl'; then
    echo "住宅 IP ✅"
  else
    echo "未知类型，需人工确认（org=$1）"
  fi
}

# 3) 终端出口 IP + 住宅/机房判定（等价于终端设 HTTP_PROXY 后 curl ipinfo.io）
hr
echo "▶ 终端出口（curl -x $GATEWAY ipinfo.io）——是否静态住宅 IP："
ipinfo=$(curl -fsS -x "http://$GATEWAY" --max-time 20 https://ipinfo.io/json 2>/dev/null)
if [ -n "$ipinfo" ]; then
  ip=$(echo "$ipinfo" | jq -r '.ip'); org=$(echo "$ipinfo" | jq -r '.org')
  echo "  IP: $ip   地区: $(echo "$ipinfo" | jq -r '"\(.country) \(.region) \(.city)"')"
  echo "  ISP/组织: $org"
  echo "  ▶ 类型判定: $(classify_org "$org")"
else
  echo "  ⚠ 经网关请求失败：检查网关是否在 $GATEWAY 监听、节点是否可用。"
fi

# 4) 各 AI 服务能否使用 + 出口地区/类型（Cloudflare trace）
check_ai() {
  local name="$1" domain="$2"
  hr
  echo "▶ $name（$domain）能否使用："
  local trace code loc aip info aorg
  code=$(curl -s -x "http://$GATEWAY" -o /dev/null -w '%{http_code}' --max-time 20 "https://$domain/cdn-cgi/trace" 2>/dev/null)
  trace=$(curl -fsS -x "http://$GATEWAY" --max-time 20 "https://$domain/cdn-cgi/trace" 2>/dev/null)
  if [ -z "$trace" ]; then
    echo "  ✗ 无法连通（HTTP ${code:-超时}）：检查 AI 组节点是否可用，或该站是否被封锁。"
    return 1
  fi
  loc=$(echo "$trace" | awk -F= '/^loc=/{print $2}')
  aip=$(echo "$trace" | awk -F= '/^ip=/{print $2}')
  echo "  连通: ✓ HTTP $code    出口地区 loc=$loc    出口 IP=$aip"
  info=$(curl -fsS --max-time 15 "https://ipinfo.io/${aip}/json" 2>/dev/null)
  aorg=$(echo "$info" | jq -r '.org // empty' 2>/dev/null)
  [ -n "$aorg" ] && echo "  出口归属: $aorg → $(classify_org "$aorg")"
  if [ "$loc" = "US" ]; then
    echo "  ▶ 结论: 出口在美国，$name 通常可正常使用 ✅"
  else
    echo "  ▶ 结论: 出口地区为 $loc（非美国），$name 可能触发地区限制，请确认锁定了美国节点 ⚠"
  fi
}

check_ai "Claude"  "claude.ai"
check_ai "ChatGPT" "chatgpt.com"

hr
echo "验证结束。"
echo "· AI 组为空 / 出口非美国 → 检查 nodes/ai.yaml 节点命名与 config.yaml 的 filter 正则。"
echo "· 若需要「静态住宅 IP」而上面判定为机房 IP → 你的机场节点是数据中心节点，"
echo "  需改用住宅代理节点放进 nodes/ai.yaml（这是节点来源问题，非本网关配置问题）。"
