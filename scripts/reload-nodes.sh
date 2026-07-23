#!/usr/bin/env bash
# 热重载 mihomo 节点池（改完 nodes/*.yaml 后调用，员工无感知）。
# 依赖 external-controller(默认 127.0.0.1:9090)。
#
# 注意：
#  · reload 只影响【新连接】；已建立的长连接(如 websocket)会保持在旧节点直到重连。
#  · 要彻底断掉所有旧连接、强制全部走新节点池：docker compose restart gateway
set -uo pipefail

API="${1:-http://127.0.0.1:9090}"

# 重载所有 file provider（airport=全量池，ai_airport=AI 专用池）
for prov in airport ai_airport; do
  if curl -fsS -X PUT "$API/providers/proxies/$prov" >/dev/null 2>&1; then
    echo " -> provider [$prov] 已重载"
  else
    echo " -> provider [$prov] 重载失败(不存在或 API 不通)"
  fi
done

# 立即做一次健康检查：让超时/失效的节点【马上】被标记剔除，
# 之后的新连接会立刻改选存活节点（不必干等健康检查周期）。
for prov in airport ai_airport; do
  curl -fsS "$API/providers/proxies/$prov/healthcheck" >/dev/null 2>&1 \
    && echo " -> provider [$prov] 已触发即时健康检查"
done

echo
echo "验证各组当前节点(确认增删已生效)："
for grp in AI-FIXED GEN-ROTATE AI-STICKY; do
  echo "  [$grp]: $(curl -fsS "$API/proxies/$grp" 2>/dev/null | jq -c '.all' 2>/dev/null)"
done
echo
echo "提示：若旧节点仍在服务(长连接残留)，执行 docker compose restart gateway 彻底刷新。"
