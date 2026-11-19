#!/usr/bin/env bash
# 部署后验证脚本：分别校验 AI / 通用双实例的节点池、代理组 filter 命中、出口连通性。
# 依赖 mihomo 的 external-controller 与 jq。
#
# 去硬编码（设计决策 3 / P9）：
#  · provider / 代理组列表从 mihomo API 动态发现，不写死固定名单。
#  · API 不可达时【软降级】：本地扫描 config-ai.yaml / config-main.yaml，
#    仅「列出应存在的 provider / 组」并提示无法运行时确认（verify 是诊断工具，不硬失败）。
#
# 双实例硬性检查（设计决策 7）：
#  · AI 实例：组名含 AI 的组非空 + 出口连通（ipinfo + claude/chatgpt cdn-cgi/trace，
#    可连通即通过、出口地区 loc 仅参考）。
#  · 通用实例：组名含 HK/香港 的组非空 + 默认出口连通。
#  · 任一实例硬失败 → 非零退出。
#
# 用法: ./scripts/verify.sh [AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]
#   AI_API       默认 http://127.0.0.1:9090
#   MAIN_API     默认 http://127.0.0.1:9091
#   AI_GATEWAY   默认 127.0.0.1:7890（AI 实例出口，用于连通性测试）
#   MAIN_GATEWAY 默认 127.0.0.1:7891（通用实例出口，用于连通性测试）
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

AI_API_DEFAULT=http://127.0.0.1:9090
MAIN_API_DEFAULT=http://127.0.0.1:9091
AI_GATEWAY_DEFAULT=127.0.0.1:7890
MAIN_GATEWAY_DEFAULT=127.0.0.1:7891

AI_API="${1:-$AI_API_DEFAULT}"
MAIN_API="${2:-$MAIN_API_DEFAULT}"
AI_GATEWAY="${3:-$AI_GATEWAY_DEFAULT}"
MAIN_GATEWAY="${4:-$MAIN_GATEWAY_DEFAULT}"

# 硬性组判定模式（组名含 AI / 组名含 HK/香港），供 check_instance 对两实例通用
AI_GROUP_PATTERN='(^|[^A-Za-z])AI([^A-Za-z]|$)'
MAIN_GROUP_PATTERN='HK|香港'

hr() { printf '%.0s─' {1..60}; echo; }
warn() { echo "  ⚠ $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，请先安装：brew install jq / apt install jq"
  exit 1
fi

echo "== ai-proxy-gateway 双实例验证 =="
echo "AI 实例:   API: $AI_API    网关: $AI_GATEWAY"
echo "通用实例:  API: $MAIN_API    网关: $MAIN_GATEWAY"

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

# 检查某个代理组筛选出的节点：打印数量+列表，空则告警(通常是 filter 没匹配到)
check_group() {
  local api="$1" group="$2"
  hr
  echo "▶ 代理组 [${group}] 命中节点："
  local nodes
  nodes=$(curl -fsS --max-time 10 "$api/proxies/$group" 2>/dev/null | jq -r '.all[]?' 2>/dev/null)
  if [ -z "$nodes" ]; then
    echo "  ⚠ 空！filter 可能没匹配到任何节点(检查节点命名或正则)，或该组不存在。"
    return 1
  fi
  printf '%s\n' "$nodes" | sed 's/^/  - /'
  echo "  合计: $(printf '%s\n' "$nodes" | grep -c .) 个节点"
  return 0
}

# 单站点连通性（cdn-cgi/trace）：可连通即通过，出口地区 loc 仅打印供人工参考
check_trace() {
  local name="$1" domain="$2" gateway="$3"
  hr
  echo "▶ ${name}（${domain}）能否使用："
  local trace code loc aip info aorg
  code=$(curl -s -x "http://$gateway" -o /dev/null -w '%{http_code}' --max-time 20 "https://$domain/cdn-cgi/trace" 2>/dev/null)
  trace=$(curl -fsS -x "http://$gateway" --max-time 20 "https://$domain/cdn-cgi/trace" 2>/dev/null)
  if [ -z "$trace" ]; then
    echo "  ✗ 无法连通（HTTP ${code:-超时}）：检查该实例节点是否可用，或该站是否被封锁。"
    return 1
  fi
  loc=$(printf '%s' "$trace" | awk -F= '/^loc=/{print $2}')
  aip=$(printf '%s' "$trace" | awk -F= '/^ip=/{print $2}')
  echo "  连通: ✓ HTTP ${code}    出口地区 loc=${loc:-未知}    出口 IP=${aip:-未知}"
  info=$(curl -fsS --max-time 15 "https://ipinfo.io/${aip}/json" 2>/dev/null)
  aorg=$(printf '%s' "$info" | jq -r '.org // empty' 2>/dev/null)
  [ -n "$aorg" ] && echo "  出口归属: ${aorg} → $(classify_org "$aorg")"
  # 可连通即判通过，出口地区仅供参考（不因地区而判失败）
  echo "  ▶ 结论: 可连通即通过 ✅（出口地区 loc=${loc:-未知} 仅供参考）"
  return 0
}

# ─────────────────────────────────────────────────────────────────
# 单实例校验：<label> 为 AI/main 实例标签；<api> 管理 API；<gateway> 出口代理
# host:port；<group_pattern> 硬性组判定模式（「组名含 AI」/「组名含 HK/香港」）。
# 硬性检查：硬性组非空 + 出口连通（可连通即通过、loc 参考）。
# 本地降级：API 不可达时分别扫 config-ai.yaml / config-main.yaml（仅列应存在项）。
# 返回：0=通过；1=硬失败（硬性组为空 或 出口连不通）。
# ─────────────────────────────────────────────────────────────────
check_instance() {
  local label="$1" api="$2" gateway="$3" group_pattern="$4"
  # 本地降级扫描的配置文件：AI → config-ai.yaml；main → config-main.yaml
  local config_file
  case "$label" in
    AI)   config_file="$PROJECT_ROOT/config-ai.yaml" ;;
    main) config_file="$PROJECT_ROOT/config-main.yaml" ;;
  esac
  local fail=0

  hr
  echo "== 实例 [$label] 校验 ==（API: $api   网关: $gateway   配置: $(basename "$config_file")）"

  # ── 0. API 可达性探测（决定走「运行时真值」还是「本地扫描降级」）──
  local providers_json proxies_json api_ok=1
  providers_json=$(curl -fsS --max-time 10 "$api/providers/proxies" 2>/dev/null)
  proxies_json=$(curl -fsS --max-time 10 "$api/proxies" 2>/dev/null)
  [ -z "$providers_json" ] && api_ok=0
  if [ -n "$proxies_json" ] && ! printf '%s' "$proxies_json" | jq -e . >/dev/null 2>&1; then
    # 返回内容不是合法 JSON，同样视为不可用
    api_ok=0
  fi

  if [ "$api_ok" -eq 0 ]; then
    warn "实例 [$label] mihomo API 不可达（${api}）。以下为【本地扫描降级】结果。"
    warn "降级结果仅列出「应存在」的 provider / 组名，无法确认运行时真实状态。"
    warn "若该实例应正在运行，请执行：docker compose restart gateway-ai gateway-main"
  fi

  # ── 1. 节点池健康（provider 动态发现 / 本地降级扫描）──
  hr
  if [ "$api_ok" -eq 1 ]; then
    echo "▶ proxy-providers 健康状态（API 动态发现）："
    local prov_names
    prov_names=$(printf '%s' "$providers_json" | jq -r '
      .providers
      | (if type == "array" then . else (to_entries | map(.value)) end)
      | .[]?.name // empty
    ' 2>/dev/null | grep -v '^$' || true)
    if [ -z "$prov_names" ]; then
      warn "未从 API 发现任何 proxy-provider（检查该实例配置的 proxy-providers 段）。"
    else
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # 节点数优先取 provider 自身统计，缺失时遍历 proxies
        cnt=$(printf '%s' "$providers_json" | jq -r --arg p "$p" '
          (.providers | if type == "array" then map(select(.name == $p))[0] else .[$p] end)
          | if . == null then "N/A"
            elif (.proxies | type) == "object" then (.proxies | length | tostring)
            else "N/A" end
        ' 2>/dev/null)
        echo "  ${p}: ${cnt:-N/A} 个节点"
      done < <(printf '%s\n' "$prov_names")
    fi
  else
    echo "▶ proxy-providers（降级：本地扫描 $(basename "$config_file")，列出应存在的 provider）："
    if [ -f "$config_file" ]; then
      # 定位 proxy-providers: 段，取其「最外层」缩进的 key 作为 provider 名。
      # 关键：provider 的子键（type/path/health-check）缩进更深，须按最小缩进过滤，
      # 否则会把 health-check 之类的子键误当成 provider。
      awk '
        function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
        /^proxy-providers:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        inside {
          if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
          cur = indent($0)
          if (min == 0 || cur < min) min = cur
          if (cur == min && $0 ~ /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/) {
            name = $0; sub(/^[[:space:]]+/, "", name); sub(/:.*$/, "", name); print name
          }
        }
      ' "$config_file" 2>/dev/null | while IFS= read -r p; do
        [ -n "$p" ] || continue
        path=$(awk -v want="$p" '
          $0 ~ "^[[:space:]]+"want":[[:space:]]*$" { inside = 1; next }
          inside && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ { inside = 0 }
          inside && /^[[:space:]]+path:/ {
            line = $0; sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]+#.*$/, "", line); gsub(/["\047]/, "", line)
            print line; exit
          }
        ' "$config_file" 2>/dev/null)
        echo "  ${p}: 应存在（path=${path:-未知}，运行时无法确认）"
      done
      echo "  （以上为 $(basename "$config_file") 声明，非运行时真值）"
    else
      warn "未找到 $(basename "$config_file")，无法本地扫描 provider 声明。"
    fi
  fi

  # ── 2. 代理组 filter 命中（动态发现 + 硬性组非空判定）──
  if [ "$api_ok" -eq 1 ]; then
    local group_names
    group_names=$(printf '%s' "$proxies_json" | jq -r '
      .proxies // {} | to_entries | map(select(.value.all != null)) | .[].key
    ' 2>/dev/null | grep -v '^$' || true)

    if [ -z "$group_names" ]; then
      warn "未从 API 发现任何代理组（检查该实例配置的 proxy-groups 段）。"
    else
      while IFS= read -r grp; do
        [ -n "$grp" ] || continue
        if ! check_group "$api" "$grp"; then
          if printf '%s' "$grp" | grep -Eqi "$group_pattern"; then
            echo "  ✗ 实例默认出口组 [${grp}] 为空 —— 它是实例 [$label] 的 MATCH 兜底目标，非空是硬性要求！"
            fail=1
          fi
        fi
      done < <(printf '%s\n' "$group_names")
    fi
  else
    # 降级：从配置文件的 proxy-groups 段扫描 name 字段，列出应存在的组
    hr
    echo "▶ 代理组（降级：本地扫描 $(basename "$config_file")，列出应存在的组）："
    if [ -f "$config_file" ]; then
      # awk 单遍完成「取 name + 按硬性组模式标注」，避免 bash 逐行读取引入多字节问题
      awk -v pat="$group_pattern" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^proxy-groups:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        inside && /name:/ {
          # 排除注释行（行首 #）：注释态的组不存在，不得参与任何标注
          if ($0 ~ /^[[:space:]]*#/) next
          line = $0
          sub(/^.*name:[[:space:]]*/, "", line)
          gsub(/["\047]/, "", line)
          line = trim(line)
          if (line == "") next
          note = "应存在（运行时无法确认）"
          if (tolower(line) ~ tolower(pat))
            note = "应存在（实例默认出口组，非空为硬性要求，运行时无法确认）"
          printf "  %s: %s\n", line, note
        }
      ' "$config_file" 2>/dev/null
      echo "  （以上为 $(basename "$config_file") 声明，非运行时真值）"
    else
      warn "未找到 $(basename "$config_file")，无法本地扫描代理组声明。"
    fi
  fi

  # ── 3. 出口连通性（等价于终端设 HTTP_PROXY 后 curl ipinfo.io）──
  hr
  echo "▶ 实例 [$label] 出口（curl -x $gateway ipinfo.io）："
  local ipinfo ip org
  ipinfo=$(curl -fsS -x "http://$gateway" --max-time 20 https://ipinfo.io/json 2>/dev/null)
  if [ -n "$ipinfo" ]; then
    ip=$(printf '%s' "$ipinfo" | jq -r '.ip' 2>/dev/null)
    org=$(printf '%s' "$ipinfo" | jq -r '.org' 2>/dev/null)
    echo "  IP: ${ip}   地区: $(printf '%s' "$ipinfo" | jq -r '"\(.country) \(.region) \(.city)"' 2>/dev/null)"
    echo "  ISP/组织: ${org}"
    echo "  ▶ 类型判定: $(classify_org "$org")"
  else
    echo "  ✗ 经网关 [$gateway] 请求失败：检查实例 [$label] 是否在 $gateway 监听、节点是否可用。"
    fail=1
  fi

  # AI 实例：Claude / ChatGPT 连通性；通用实例：默认出口连通性
  if [ "$label" = "AI" ]; then
    check_trace "Claude" "claude.ai" "$gateway" || fail=1
    check_trace "ChatGPT" "chatgpt.com" "$gateway" || fail=1
  else
    check_trace "默认出口(Cloudflare)" "www.cloudflare.com" "$gateway" || fail=1
  fi

  hr
  if [ "$fail" -eq 1 ]; then
    echo "实例 [$label] 校验结果：❌ 存在硬性失败项（实例默认出口组为空或出口连不通），请按上面的告警逐项排查。"
    return 1
  fi
  echo "实例 [$label] 校验结果：✅ 通过。"
  return 0
}

# ─────────────────────────────────────────────────────────────────
# 主流程：AI / 通用两实例依次校验；任一实例硬失败 → 非零退出
# ─────────────────────────────────────────────────────────────────
overall_fail=0
check_instance "AI" "$AI_API" "$AI_GATEWAY" "$AI_GROUP_PATTERN" || overall_fail=1
check_instance "main" "$MAIN_API" "$MAIN_GATEWAY" "$MAIN_GROUP_PATTERN" || overall_fail=1

hr
if [ "$overall_fail" -eq 1 ]; then
  echo "验证结束：❌ 存在硬性失败项（实例默认出口组为空或出口连不通），请按上面的告警逐项排查。"
  exit 1
fi
echo "验证结束。"
echo "· AI 实例出口组（组名含 AI）为空 → 检查机场节点命名是否含「美国/US」关键词（config-ai.yaml 的 filter 正则）。"
echo "· 通用实例出口组（组名含 HK/香港）为空 → 检查节点命名与 config-main.yaml 的香港正则 filter。"
echo "· 若需要「静态住宅 IP」而上面判定为机房 IP → 你的机场节点是数据中心节点，"
echo "  需改用住宅代理节点（节点名含「美国」，见 README 节点命名要求——这是节点来源问题，非本网关配置问题）。"
exit 0
