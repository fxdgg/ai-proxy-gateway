#!/usr/bin/env bash
# 热重载 mihomo 节点池（改完 nodes/*.yaml 后调用，员工无感知）。
# 双实例：无参时依次处理 AI / 通用两实例（默认 API 127.0.0.1:9090 / 127.0.0.1:9091），
#   传参则只对给定 API 执行（兼容单实例场景）。
# 依赖 external-controller(AI 实例默认 127.0.0.1:9090、通用实例默认 127.0.0.1:9091) 与 jq。
#
# 去硬编码：provider 列表与代理组名全部从 mihomo API 动态发现，不写死固定名单。
#
# 前置条件（P13）：必须先执行 scripts/build-config.sh 生成 nodes/_merged.yaml，
#   且该文件不得比机场订阅文件旧；否则本脚本提示并失败退出（不做隐式 auto-build）。
#   _merged.yaml 两实例共享，时效校验只做一次。
#
# 注意：
#  · reload 只影响【新连接】；已建立的长连接(如 websocket)会保持在旧节点直到重连。
#  · 要彻底断掉所有旧连接、强制全部走新节点池：
#      docker compose restart gateway-ai gateway-main
#
# 用法: ./scripts/reload-nodes.sh [API地址...]
#   无参: 默认 http://127.0.0.1:9090 http://127.0.0.1:9091（AI / 通用两实例）
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

AI_API_DEFAULT=http://127.0.0.1:9090
MAIN_API_DEFAULT=http://127.0.0.1:9091
MERGED_FILE="$PROJECT_ROOT/nodes/_merged.yaml"

# 无参 → 默认两实例；传参 → 仅处理给定 API
if [ "$#" -eq 0 ]; then
  APIS=("$AI_API_DEFAULT" "$MAIN_API_DEFAULT")
else
  APIS=("$@")
fi

die() { echo "✗ $*" >&2; exit 1; }
warn() { echo "  ⚠ $*" >&2; }
hr() { printf '%.0s─' {1..60}; echo; }

command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装：brew install jq / apt install jq"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装。"

# ─────────────────────────────────────────────────────────────────
# 1. 前置校验：nodes/_merged.yaml 已 build 且不比机场文件旧（P13）
#    两实例共享同一份 _merged.yaml，只校验一次。
# ─────────────────────────────────────────────────────────────────
check_merged_up_to_date() {
  if [ ! -f "$MERGED_FILE" ]; then
    echo "✗ 未找到 $MERGED_FILE" >&2
    echo "  该文件由 scripts/build-config.sh 生成，请先执行：" >&2
    echo "    ./scripts/build-config.sh" >&2
    exit 1
  fi

  # 机场订阅文件：clash.yaml（默认机场）+ clash-<id>.yaml，排除 *.example.yaml
  local airport_files=""
  local f
  shopt -s nullglob
  for f in "$PROJECT_ROOT"/nodes/clash-*.yaml "$PROJECT_ROOT"/nodes/clash.yaml; do
    case "$f" in
      *.example.yaml|*_merged.yaml) continue ;;
    esac
    [ -f "$f" ] && airport_files="$airport_files $f"
  done
  shopt -u nullglob

  if [ -z "$airport_files" ]; then
    warn "未发现机场订阅文件（nodes/clash.yaml 或 nodes/clash-*.yaml），跳过「是否已 build」的时效校验。"
    return 0
  fi

  # -nt：源文件比 _merged.yaml 新即为「未重新 build」
  local newer=""
  for f in $airport_files; do
    if [ "$f" -nt "$MERGED_FILE" ]; then
      newer="$newer $f"
    fi
  done
  if [ -n "$newer" ]; then
    echo "✗ $MERGED_FILE 比下列机场文件旧，说明尚未重新 build：" >&2
    for f in $newer; do
      echo "    - ${f#"$PROJECT_ROOT"/}" >&2
    done
    echo "  请先执行：./scripts/build-config.sh" >&2
    exit 1
  fi
  return 0
}

check_merged_up_to_date

# ─────────────────────────────────────────────────────────────────
# 2. 单实例处理：API 探测（失败记录继续）→ provider 动态发现 + reload
#    → 即时健康检查 → 组校验打印。
#    返回：0=成功；1=provider 重载失败；2=API 不可达/响应非法。
# ─────────────────────────────────────────────────────────────────
reload_instance() {
  local api="$1" label="$2"

  hr
  echo "▶ 实例 [${label}]（API: ${api}）"

  # 2.1 API 可达性探测：失败仅记录，继续下一实例
  local proxies_json
  proxies_json=$(curl -fsS --max-time 10 "$api/providers/proxies" 2>/dev/null)
  if [ -z "$proxies_json" ]; then
    echo "✗ mihomo API 不可达：$api/providers/proxies" >&2
    echo "  该实例可能未运行；可用 docker compose restart gateway-ai gateway-main 重启两实例。" >&2
    return 2
  fi
  if ! printf '%s' "$proxies_json" | jq -e . >/dev/null 2>&1; then
    echo "✗ mihomo API 返回内容不是合法 JSON：$api/providers/proxies" >&2
    echo "  请检查该实例 external-controller 配置与端口是否正确。" >&2
    return 2
  fi

  # 2.2 动态发现全部 provider 名（数组元素为 {name:..., type:...} 或 {name: {...}} 两种返回形态都兼容）
  local providers
  providers=$(printf '%s' "$proxies_json" | jq -r '
    .providers
    | (if type == "array" then . else (to_entries | map(.value)) end)
    | .[]?.name // empty
  ' 2>/dev/null | grep -v '^$' || true)

  local reload_failed=0
  if [ -z "$providers" ]; then
    warn "未从 API 发现任何 proxy-provider，跳过重载（检查该实例配置的 proxy-providers 段）。"
  else
    hr
    provider_cnt=$(printf '%s' "$providers" | grep -c .)
    echo "▶ 重载 proxy-provider（动态发现 ${provider_cnt} 个）："
    while IFS= read -r prov; do
      [ -n "$prov" ] || continue
      if curl -fsS -X PUT --max-time 15 "$api/providers/proxies/${prov}" >/dev/null 2>&1; then
        echo "  -> provider [${prov}] 已重载"
      else
        echo "  ✗ provider [${prov}] 重载失败（provider 可能已被移除，或 API 中途不可用）" >&2
        reload_failed=$((reload_failed + 1))
      fi
    done < <(printf '%s\n' "$providers")

    # 2.3 立即健康检查：让超时/失效节点【马上】被标记剔除，
    #     之后的新连接会立刻改选存活节点（不必干等健康检查周期）。
    hr
    echo "▶ 触发即时健康检查："
    while IFS= read -r prov; do
      [ -n "$prov" ] || continue
      # healthcheck 是耗时操作，部分 provider 可能不支持，失败仅告警不中断
      if curl -fsS --max-time 30 "$api/providers/proxies/${prov}/healthcheck" >/dev/null 2>&1; then
        echo "  -> provider [${prov}] 已触发即时健康检查"
      else
        warn "provider [${prov}] 健康检查触发失败（可稍后由定时检查兜底）"
      fi
    done < <(printf '%s\n' "$providers")

    if [ "$reload_failed" -gt 0 ]; then
      echo
      echo "✗ 实例 [${label}] 有 ${reload_failed} 个 provider 重载失败，请检查上面的输出。" >&2
      return 1
    fi
  fi

  # 2.4 组校验：动态遍历全部代理组，打印各组成员（不写死组名）
  local groups_json
  groups_json=$(curl -fsS --max-time 10 "$api/proxies" 2>/dev/null)
  if [ -z "$groups_json" ]; then
    echo "✗ mihomo API 不可达：$api/proxies" >&2
    return 2
  fi

  # 只取「有 all 字段」的项，即 selector/urltest/load-balance/falb 等代理组
  local group_names
  group_names=$(printf '%s' "$groups_json" | jq -r '
    .proxies // {}
    | to_entries
    | map(select(.value.all != null))
    | .[].key
  ' 2>/dev/null | grep -v '^$' || true)

  hr
  if [ -z "$group_names" ]; then
    warn "未从 API 发现任何代理组（检查该实例配置的 proxy-groups 段）。"
  else
    echo "▶ 各组当前节点（确认增删已生效）："
    local empty_groups=""
    while IFS= read -r grp; do
      [ -n "$grp" ] || continue
      members=$(printf '%s' "$groups_json" | jq -c --arg g "$grp" '.proxies[$g].all' 2>/dev/null)
      cnt=$(printf '%s' "$groups_json" | jq -r --arg g "$grp" '(.proxies[$g].all // []) | length' 2>/dev/null)
      echo "  [${grp}] (${cnt:-0} 个): ${members}"
      # 空组只告警：reload 期间节点可能尚未就绪，不作为失败条件
      [ "${cnt:-0}" -eq 0 ] 2>/dev/null && empty_groups="$empty_groups $grp"
    done < <(printf '%s\n' "$group_names")

    if [ -n "$empty_groups" ]; then
      echo
      warn "以下代理组当前为空，请检查 filter 正则与节点命名：${empty_groups}"
    fi
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────
# 3. 主流程：逐实例执行并汇总；任一实例 provider 重载失败 / API 不可达 → 非零退出
# ─────────────────────────────────────────────────────────────────
fail_cnt=0
for api in "${APIS[@]}"; do
  label="$api"
  case "$api" in
    "$AI_API_DEFAULT")   label="AI" ;;
    "$MAIN_API_DEFAULT") label="通用" ;;
  esac
  reload_instance "$api" "$label" || fail_cnt=$((fail_cnt + 1))
done

hr
if [ "$fail_cnt" -gt 0 ]; then
  echo "✗ 有 ${fail_cnt} 个实例处理失败（API 不可达或 provider 重载失败），请检查上面的输出。" >&2
  exit 1
fi
hr
echo "提示：若旧节点仍在服务(长连接残留)，执行 docker compose restart gateway-ai gateway-main 彻底刷新。"
exit 0
