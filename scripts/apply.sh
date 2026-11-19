#!/usr/bin/env bash
# 改了 config-ai.yaml / config-main.yaml（规则/代理组/filter/策略 等）后，让改动生效。
# 用 mihomo API 热加载配置——【无需重启、无停机】，也避开 podman 上 restart 报
# "device or resource busy" 的问题。
#
# 双实例：无参时依次对 AI(默认 API 9090) / 通用(默认 API 9091) 两实例 PUT /configs；
#   两实例的容器内路径统一为 /root/.config/mihomo/config.yaml。
#
# 用法: ./scripts/apply.sh [API地址...]
#   无参: 默认 http://127.0.0.1:9090 http://127.0.0.1:9091（AI / 通用两实例）
set -uo pipefail

AI_API_DEFAULT=http://127.0.0.1:9090
MAIN_API_DEFAULT=http://127.0.0.1:9091
CONFIG_IN_CONTAINER="/root/.config/mihomo/config.yaml"

# 无参 → 默认两实例；传参 → 仅处理给定 API
if [ "$#" -eq 0 ]; then
  APIS=("$AI_API_DEFAULT" "$MAIN_API_DEFAULT")
else
  APIS=("$@")
fi

failed=0
for api in "${APIS[@]}"; do
  echo "热加载 [$api] 的 config.yaml（无停机）..."
  code=$(curl -s --max-time 15 -o /tmp/apply_resp.txt -w '%{http_code}' -X PUT "$api/configs" \
    -H 'Content-Type: application/json' \
    -d "{\"path\":\"$CONFIG_IN_CONTAINER\"}" 2>/dev/null)

  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    echo " -> [$api] 配置已热加载生效 (HTTP $code)"
    echo "    查看各组(动态发现): for g in \$(curl -s $api/proxies | jq -r '.proxies // {} | to_entries | map(select(.value.all != null)) | .[].key'); do echo \$g; curl -s $api/proxies/\$g | jq -c .all; done"
  else
    echo " -> [$api] 热加载失败 (HTTP ${code:-无响应}): $(cat /tmp/apply_resp.txt 2>/dev/null)" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "✗ 存在实例热加载失败，请检查上面的输出。" >&2
  echo "  退而求其次(会短暂停机): docker compose restart gateway-ai gateway-main"
  exit 1
fi
