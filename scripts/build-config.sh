#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build-config.sh —— 扫描 nodes/ 下所有机场订阅文件，合并其 `proxies:` 段到
#                     nodes/_merged.yaml，供 config.yaml 的 airport provider 读取。
#
# 算法（严格遵循 design.md「build-config.sh 提取/合并算法」章节）：
#   1. 扫描 nodes/clash-*.yaml（排除 *.example.yaml），再把 nodes/clash.yaml
#      （若存在）作为 id=default 追加；按 id 字典序稳定排序（default 排最前）。
#   2. 对每个文件定位 `^proxies:` 段，到下一个顶层 key（无缩进、key: 结尾）之间
#      「整段拷贝」，不逐字段解析 YAML/JSON。
#   3. 用正则 \"name\"\s*:\s*\"([^\"]*)\" 提取「单行内联 JSON」节点的 name 做
#      跨文件重名检测；重名即报错退出（不自动加前缀）。
#      已知限制：节点名含转义引号 \" 时 name 提取会截断（「不逐字段解析 JSON」的
#      固有限制），该行重名检测可能失效，节点行仍原样保留。
#   4. 拼接输出：proxies: 头 + 各文件节点行（去掉各自 proxies: 行）原样追加。
#   5. 空边界：零机场 → proxies: []；合并后全空 → fail-fast 非零退出。
#
# 依赖：仅 bash + grep + awk + sed（不引入 python3，不逐字段解析）。
# 退出码：0 成功；非 0 失败（重名 / 全空 / 文件不可读）。
# 用法：./scripts/build-config.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

# 脚本所在目录的上一级即项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODES_DIR="$ROOT_DIR/nodes"
OUT_FILE="$NODES_DIR/_merged.yaml"

# 已见节点名集合（跨文件重名检测）。每行格式：<id><TAB><name>。
SEEN_FILE="$(mktemp "${TMPDIR:-/tmp}/build-config-seen.XXXXXX")"
trap 'rm -f "$SEEN_FILE"' EXIT

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "⚠ $*" >&2; }
# err 只打印错误、不退出；供「命令替换子 shell」内的函数使用，错误码由调用方检查。
err()  { printf '%s\n' "✗ $*" >&2; }
# die 直接退出（仅用于主流程等非子 shell 场景）。
die()  { printf '%s\n' "✗ $*" >&2; exit 1; }

# ── 收集机场文件列表 ─────────────────────────────────────────────────────────
# 结果写入两个全局数组：FILE_IDS / FILE_PATHS（下标一一对应）。
collect_files() {
  local f
  shopt -s nullglob
  for f in "$NODES_DIR"/clash-*.yaml; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.example.yaml) continue ;;
    esac
    local base id
    base="$(basename "$f")"
    id="${base#clash-}"
    id="${id%.yaml}"
    FILE_IDS+=("$id")
    FILE_PATHS+=("$f")
  done
  shopt -u nullglob

  # nodes/clash.yaml 作为 id=default（若存在）
  if [[ -f "$NODES_DIR/clash.yaml" ]]; then
    FILE_IDS=("default" "${FILE_IDS[@]}")
    FILE_PATHS=("$NODES_DIR/clash.yaml" "${FILE_PATHS[@]}")
  fi
}

# ── 稳定排序：default 恒最前，其余按 id 字典序 ───────────────────────────────
# 输出 <id>\t<path> 行到 stdout。
sorted_run() {
  local i
  # 先单独输出 default
  for i in "${!FILE_IDS[@]}"; do
    [[ "${FILE_IDS[$i]}" == "default" ]] && printf 'default\t%s\n' "${FILE_PATHS[$i]}"
  done
  # 其余按 id 排序
  for i in "${!FILE_IDS[@]}"; do
    [[ "${FILE_IDS[$i]}" != "default" ]] && printf '%s\t%s\n' "${FILE_IDS[$i]}" "${FILE_PATHS[$i]}"
  done | sort -t $'\t' -k1,1
}

# ── 提取单个文件的 proxies 段节点行（不含 proxies: 头），并做重名检测 ─────────
# 参数：$1=文件路径  $2=id
# stdout：该文件 proxies: 段内所有行（原样，不含 proxies: 头行）。
# 返回：0 成功；非 0 表示重名或文件不可读（内部 err 打印错误后 return 1）。
extract_segment() {
  local f="$1" id="$2"
  [[ -r "$f" ]] || { err "文件不可读：$f"; return 1; }

  local total; total="$(wc -l < "$f" | tr -d '[:space:]')"

  # 定位 proxies: 起始行
  local start; start="$(grep -n '^proxies:' "$f" | head -n1 | cut -d: -f1)"
  if [[ -z "$start" ]]; then
    warn "文件 [$id] ($f) 无 proxies: 段，按空文件处理"
    return 0
  fi

  # 定位下一个顶层 key（无缩进、^[a-zA-Z-]+:）行号；无则到文件末尾
  # end 表示「下一个顶层 key 的行号」，seg 拷贝到 end-1 行（即 proxies 段最后一行）。
  # 无下一个 key 时 end = total + 1，使 end-1 = total（覆盖到文件最后一行）。
  local end; end="$(awk -v s="$start" 'NR>s && /^[a-zA-Z-]+:/ {print NR; exit}' "$f")"
  [[ -z "$end" ]] && end="$((total + 1))"

  # 整段拷贝（去掉 proxies: 头行）
  local seg; seg="$(sed -n "$((start + 1)),$((end - 1))p" "$f")"

  # ── 展开式格式检测 + 重名检测 ──
  local has_expanded=0
  local line name
  while IFS= read -r line; do
    # 跳过空行
    [[ -z "${line//[[:space:]]/}" ]] && continue

    # 展开式 YAML 节点：`- name: xxx` 换行缩进（非单行内联 JSON）
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]* ]]; then
      has_expanded=1
      continue
    fi

    # 提取单行内联 JSON 节点名：\"name\":\"...\"
    # macOS BSD grep 的 -oE 对 UTF-8 多字节会损坏（\"香\"字丢字节），改用 awk 按引号字段
    # 精确取出 name 值：按 \" 切分后，\"name\" 字段的后一个字段即节点名。
    name="$(printf '%s' "$line" | awk -F '"' '{ for(i=1;i<NF;i++) if($i ~ /^name[[:space:]]*$/) { print $(i+2); exit } }')"
    if [[ -z "$name" ]]; then
      warn "无法从节点行提取 name（非标准内联 JSON），保留原行并跳过该行重名检测：$line"
      continue
    fi

    # 跨文件重名检测（SEEN_FILE 每行 <id><TAB><name>，用 awk 按 TAB 分隔精确匹配 name）
    local prev_id; prev_id="$(awk -F '\t' -v n="$name" '$2 == n {print $1; exit}' "$SEEN_FILE" 2>/dev/null)"
    if [[ -n "$prev_id" ]]; then
      err "节点重名：${name}（出现在 ${prev_id} 与 ${id}）
请在两处之一改名后重跑（本脚本不自动加前缀，避免破坏 dialer-proxy 引用）。"
      return 1
    fi
    printf '%s\t%s\n' "$id" "$name" >> "$SEEN_FILE"
  done <<< "$seg"

  # 展开式格式降级警告（仍整段拷贝，仅跳过该文件重名检测）
  if [[ "$has_expanded" -eq 1 ]]; then
    warn "检测到展开式格式节点（- name: xxx 换行缩进），跳过该文件 [$id] 的重名检测"
  fi

  # 原样输出节点段
  printf '%s\n' "$seg"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
main() {
  mkdir -p "$NODES_DIR"

  FILE_IDS=()
  FILE_PATHS=()
  collect_files

  # 零机场：生成合法 proxies: []
  if [[ "${#FILE_IDS[@]}" -eq 0 ]]; then
    warn "未发现任何机场文件（nodes/clash-*.yaml 或 nodes/clash.yaml）"
    printf 'proxies: []\n' > "$OUT_FILE"
    log "已生成空 provider：$OUT_FILE (proxies: [])"
    exit 0
  fi

  # 逐文件提取（按稳定排序）
  local output=""
  local node_count=0
  local id path seg n
  while IFS=$'\t' read -r id path; do
    [[ -z "$id" ]] && continue
    log "处理机场 [$id] <- $path"
    seg="$(extract_segment "$path" "$id")" || exit 1
    n="$(printf '%s\n' "$seg" | grep -cE '^[[:space:]]*-' || true)"
    node_count=$((node_count + n))
    output+="${seg}
"
  done < <(sorted_run)

  # 合并后全空 fail-fast
  if [[ "$node_count" -eq 0 ]]; then
    die "未发现任何节点，请检查 nodes/ 下是否有 clash-*.yaml 机场文件"
  fi

  # 写输出：proxies: 头 + 各段节点行
  {
    printf 'proxies:\n'
    printf '%s' "$output"
  } > "$OUT_FILE"

  log "✓ 合并完成：共 ${#FILE_IDS[@]} 个机场、$node_count 个节点 → $OUT_FILE"
  log "  下一步请执行 scripts/reload-nodes.sh 使新节点生效。"
}

main "$@"
