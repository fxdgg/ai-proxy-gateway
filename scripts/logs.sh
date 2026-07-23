#!/usr/bin/env bash
# 查看网关(mihomo)最新日志，可选关键字过滤并持续跟踪。
# 用法:
#   ./scripts/logs.sh              # 跟踪最新日志(默认最近 200 行起)
#   ./scripts/logs.sh claude       # 只显示含 "claude" 的行(忽略大小写)并跟踪
#   ./scripts/logs.sh claude 500   # 从最近 500 行里过滤并继续跟踪
#   ./scripts/logs.sh "" 500       # 不过滤，看最近 500 行
#   ./scripts/logs.sh error 300 pac  # 看 pac 服务日志里含 error 的行
set -uo pipefail

KEYWORD="${1:-}"
TAIL="${2:-200}"
SERVICE="${3:-gateway}"

# 兼容 docker compose(v2) 与 docker-compose(v1)
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "未找到 docker compose / docker-compose，请在装了 Docker 的机器上运行。"; exit 1
fi

if [ -n "$KEYWORD" ]; then
  echo "== 跟踪 [$SERVICE] 日志，过滤关键字: \"$KEYWORD\"（最近 $TAIL 行起，Ctrl+C 退出）=="
  $DC logs -f --tail="$TAIL" "$SERVICE" | grep --line-buffered -i "$KEYWORD"
else
  echo "== 跟踪 [$SERVICE] 日志（最近 $TAIL 行起，Ctrl+C 退出）=="
  $DC logs -f --tail="$TAIL" "$SERVICE"
fi
