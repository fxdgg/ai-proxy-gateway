#!/usr/bin/env bash
# 改了 config.yaml（规则/代理组/filter/策略 等）后，让改动生效。
# 用 mihomo API 热加载配置——【无需重启、无停机】，也避开 podman 上 restart 报
# "device or resource busy" 的问题。
#
# 用法: ./scripts/apply.sh [API地址]   默认 http://127.0.0.1:9090
set -uo pipefail
API="${1:-http://127.0.0.1:9090}"
CONFIG_IN_CONTAINER="/root/.config/mihomo/config.yaml"

echo "热加载 config.yaml（无停机）..."
code=$(curl -s -o /tmp/apply_resp.txt -w '%{http_code}' -X PUT "$API/configs" \
  -H 'Content-Type: application/json' \
  -d "{\"path\":\"$CONFIG_IN_CONTAINER\"}" 2>/dev/null)

if [ "$code" = "204" ] || [ "$code" = "200" ]; then
  echo " -> 配置已热加载生效 (HTTP $code)"
  echo "    查看各组: for g in AI-FIXED AI-STICKY GEN-STICKY; do echo \$g; curl -s $API/proxies/\$g | jq -c .all; done"
else
  echo " -> 热加载失败 (HTTP ${code:-无响应}): $(cat /tmp/apply_resp.txt 2>/dev/null)"
  echo "    退而求其次(会短暂停机): docker compose down && docker compose up -d"
fi
