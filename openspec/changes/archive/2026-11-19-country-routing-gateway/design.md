# 设计：country-routing-gateway（国家分流网关侧配套）

> 本设计为插件侧归档 Change `chatgpt-block-bypass/openspec/changes/archive/2026-11-19-domain-country-routing` 中「**决策 5：与网关的联动数据流 + 网关侧配套改动清单**」的完整搬运。决策 5 已经过插件侧**三轮评审定稿**（第 1 轮 P1/P3、#5/#8/#10/#11；第 2 轮两审共识阻塞项 1、主审阻塞项 3、S1/S5/S6、辅审 1；第 3 轮修订落盘），本设计**不引入任何新决策**，仅将定稿规格落到 `ai-proxy-gateway` 仓库语境，并与网关真实代码现状（`config.yaml`、`scripts/gen-rules.sh`、`scripts/verify.sh`、`scripts/build-config.sh`）对齐。本版（第 3 轮修订）吸收网关侧第 2 轮双评审意见：辅审阻塞项 ④（无真实节点数据环境的 G0 例外条款）、提示 ⑤（注释行过滤）、⑥（G7 降级链同步 G0 三级口径）；主审提示 P1（G2 组存在性校验排除注释行）、P2（API 模式 dry-run 排除组 key）；P3 轻微不处理。均为既有决策的落地细化，不引入新决策。
>
> 证据引用：插件侧 `design.md`「决策 5」、`tasks.md`「4. 网关侧」、`gate-review.md` 三轮评审处理记录（阻塞项 1/3、S1/S5/S6、辅审 1、P1/P3、#5/#8/#10/#11 均已定死并落盘）。

## 背景与数据流

**新增一条「带组名」的并列链路，与现有 ai-plugin 链路同构：**

```
chatgpt-block-bypass 插件
  domainCountries（storage）+ COUNTRIES 常量（组名公式 <code>-STICKY）
        │  （用户点「导出国家分流规则」→ 剪贴板 → 清空后全量覆盖粘贴落地 ai-domains-country.txt）
        ▼
ai-proxy-gateway/nodes/ai-domains-country.txt   （两列：域名<TAB>国家代码）
        │  （scripts/gen-country-rules.sh【新增独立脚本】读取，不改动 gen-rules.sh）
        ▼
rules/ai-plugin-country.yaml   （每行 DOMAIN-SUFFIX,域名,<国家组>）
        │  （config.yaml rule-providers 一次性引用）
        ▼
config.yaml rules（RULE-SET,ai-plugin-country，置于 ai-plugin 之前，最高优先级）
```

## 决策 G0：7 国正则 dry-run 前置验证（定死）

**建组前对当前节点名统计 7 国地区关键词命中数；真实节点数据下任一国家命中为 0 需先补节点或调整正则，通过后再执行 G1 建组；模板/示例数据或空产物场景按例外条款不阻塞建组**（回应插件侧评审建议项 #11 与网关侧第 2 轮辅审阻塞项 ④，tasks 4.0）。

- **数据源（三级降级口径，定死）**：`nodes/_merged.yaml`（`build-config.sh` 合并产物）的节点名。若该文件不存在，先执行 `scripts/build-config.sh` 生成；「仍不可得」明确定义为**build 后 `_merged.yaml` 无节点行（`proxies: []`）**——零机场场景下 `build-config.sh` 会 `exit 0` 并成功产出空 provider（已核对 build-config.sh 主流程「零机场」分支），仅以「文件不存在」判定降级将永不触发。此时降级为直接对 `nodes/clash*.yaml` / `nodes/clash.yaml` 统计（注意：当前工作区该 glob 仅匹配模板 `clash.example.yaml`）。
- **统计口径**：提取全部节点名（兼容内联 JSON `"name": "..."` 与展开式 `- name: ...` 两种格式），对每个国家的关键词正则统计命中行数。命中 ≥ 1 即该国有候选节点。
- **7 国关键词初始建议集**（与 G1 filter 完全一致，见决策 G1；以 dry-run 结果为准可调整）：

| 国家 | 代码 | 地区关键词初始建议（正则片段） |
|------|------|------------------------------|
| 日本 | JP | `日本\|Japan\|Tokyo\|Osaka\|\bJP\b` |
| 美国 | US | `美国\|United ?States\|America\|\bUS\b\|\bUSA\b` |
| 新加坡 | SG | `新加坡\|Singapore\|\bSG\b` |
| 台湾 | TW | `台湾\|Taiwan\|Taipei\|\bTW\b` |
| 韩国 | KR | `韩国\|Korea\|Seoul\|\bKR\b` |
| 英国 | GB | `英国\|United ?Kingdom\|London\|\bGB\b\|\bUK\b` |
| 德国 | DE | `德国\|Germany\|Frankfurt\|\bDE\b` |

- **示例命令（coder 可封装为独立检查或并入 verify.sh G7 的 dry-run）**：

```bash
# 提取节点名：必须覆盖两种格式（build-config.sh 整段拷贝，内联 JSON 与展开式会并存）
# 先剔除注释行（grep -v '^[[:space:]]*#'）：注释掉的节点行不参与命中统计，
#   否则「# - {"name":"Tokyo-01",...}」这类被注释掉的节点会被误计入命中数（噪声）。
# ① 内联 JSON： "name": "xxx"；② 展开式 YAML：- name: xxx（换行缩进，引号可有可无）
names=$(
  grep -v -E '^[[:space:]]*#' nodes/_merged.yaml \
    | grep -hoE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  grep -v -E '^[[:space:]]*#' nodes/_merged.yaml \
    | grep -E '^[[:space:]]*-[[:space:]]*name:[[:space:]]*' \
    | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*"?([^"#]+)"?[[:space:]]*$/\1/'
)
for p in '(日本|Japan|Tokyo|Osaka|\bJP\b)' '(美国|United ?States|America|\bUS\b|\bUSA\b)' \
         '(新加坡|Singapore|\bSG\b)' '(台湾|Taiwan|Taipei|\bTW\b)' \
         '(韩国|Korea|Seoul|\bKR\b)' '(英国|United ?Kingdom|London|\bGB\b|\bUK\b)' \
         '(德国|Germany|Frankfurt|\bDE\b)'; do
  printf '%s\n' "$names" | grep -Eic "$p"
done
# 依次输出 7 个命中数（顺序：JP US SG TW KR GB DE）；判定规则见「产出」段（真实数据/模板数据分级）
# coder 亦可自行实现节点名提取，但必须按「两种格式 + 剔除注释行」口径，并验证两种格式的节点名均提取完整
```

- **转义层次警示（定死，第 2 轮修订）**：本命令的 shell **单引号**内写 `\b`（grep ERE 词边界；单引号不做任何转义，`\b` 原样交给 grep）。这与 G1 `filter` 的 **YAML 双引号**内写法 `\\b`（YAML 转义后 mihomo 实际收到 `\b`）是**两层不同转义，不得照搬**。本机实测（BSD grep 2.6.0-FreeBSD）：单反斜杠 `'\bUS\b'` 对 `US-01` 命中 1（词边界生效）；照抄双反斜杠 `'\\bUS\\b'` 命中 0——ERE 把 `\\` 解释为「匹配字面反斜杠」，节点名不含反斜杠 → 7 国命中全 0 并错误阻塞建组（第 2 轮辅审实测复现的正是双反斜杠形式）。
- **词边界可行性（已实测）**：macOS BSD grep 现版本支持 `\b` 词边界，`\bUS\b` 不会误命中 `BONUS`、`\bDE\b` 不会误命中 `NODE`（本机实测通过）。dry-run 可直接复用与 mihomo `filter` 相同的 `\b` 语义；如遇更老环境不支持，等价替代写法为 `[[:<:]]`/`[[:>:]]`。
- **产出（分级判定，定死，第 3 轮修订——回应第 2 轮辅审阻塞项 ④）**：验证记录（7 国 × 命中数表 + 处置结论）写入 tasks 4.0 交付物；**验证记录必须标注数据来源**（统计的文件路径：`_merged.yaml` 或降级的 `clash*.yaml`）。判定分级如下：
  - **真实节点数据**：`_merged.yaml` 存在节点行、或降级数据源为真实机场订阅文件——**任一国家命中为 0 → 阻塞 4.1 建组**（先补节点或调整正则，通过后方可建组）；
  - **模板/示例数据或空产物（例外条款）**：dry-run 数据源为模板/示例数据（如 `clash.example.yaml`），或 build 产物无节点行（`proxies: []`，零机场场景 `build-config.sh` exit 0 但产物为空）——产出**标注模板来源 + 处置结论「待部署环境复核」**的验证记录，**不阻塞 4.1 建组（7 组照建）**。「命中为 0 → 阻塞建组」**仅适用于真实节点数据**；模板数据场景**禁止以命中数为依据放宽正则**（正则仍以 G0 初始建议集落盘，由部署环境复核裁决）；
  - **部署环境 dry-run 复核为最终闸门**（写入 DEPLOY.md 上线清单，tasks 4.4 承接）：真实节点数据下命中为 0 → 先补节点/调正则或**临时移除对应组**再上线。

## 决策 G1：7 个国家节点组（定死）

`config.yaml` `proxy-groups` 新增 `JP-STICKY`/`US-STICKY`/`SG-STICKY`/`TW-STICKY`/`KR-STICKY`/`GB-STICKY`/`DE-STICKY` 共 7 组，**逐字复用 `HK-STICKY` 的组模式**：

- `type: load-balance`，`strategy: sticky-sessions`（与 HK-STICKY 相同）；
- **`use: [airport]`（全量池 `nodes/_merged.yaml`，非 `ai_airport`）**——定死，理由见下「use 澄清」；
- `filter`：地区正则，把 HK-STICKY 的 `(香港|Hong ?Kong|\bHK\b)` 换成对应国家关键词（G0 初始建议集，G0 验证通过后落盘）；
- `exclude-filter`：**与 HK-STICKY 逐字同款** `"(?i)(禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅)"`（排除机场信息/无效节点；不含「家宽」——住宅 IP 是优质特征不排除）；
- `url: https://www.gstatic.com/generate_204`、`interval: 60`、`lazy: true`：与 HK-STICKY 同款健康检查配置。

**单组模板（以 JP 为例，其余 6 组同构替换 filter 与组名/注释）：**

```yaml
  # ── 国家分流组：日本（JP）──
  # 跨机场聚合日本节点：用 filter 正则命中节点名里的日本关键词，
  # exclude-filter 与 HK-STICKY 同款（排除机场信息/无效节点）。
  # 消费方：rules 最前的 RULE-SET,ai-plugin-country（gen-country-rules.sh 产物的规则 payload 指定本组）。
  - name: JP-STICKY
    type: load-balance
    strategy: sticky-sessions
    use: [airport]           # 全量池（nodes/_merged.yaml，多机场合并产物），非 ai_airport
    filter: "(?i)(日本|Japan|Tokyo|Osaka|\\bJP\\b)"
    exclude-filter: "(?i)(禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅)"
    url: https://www.gstatic.com/generate_204
    interval: 60
    lazy: true
```

> **YAML 转义注意**：`filter` 双引号内的 `\\b` 与 `HK-STICKY` 现有写法逐字一致（YAML 双引号标量中 `\\` 转义为字面 `\`，mihomo 实际收到 `\b`）。coder 不得改写转义形式。**与 G0/G7 示例命令的 shell 单引号写法 `\b` 是两层不同转义**（shell 单引号不做转义、YAML 双引号需转义），两侧写法不得互换照搬——在 YAML 中写单反斜杠 `\b` 会被 YAML 报非法转义，在 shell 单引号中照抄 `\\b` 会导致命中全 0（见 G0 警示）。

**`use: [airport]` vs `[ai_airport]` 澄清（回应第 1 轮评审阻塞项 P3，定死）**：国家组 `use: [airport]`（**全量池** `nodes/_merged.yaml`），**不是** `[ai_airport]`（AI 专用池 `nodes/ai.yaml`）。理由：国家分流的本质是「按节点名的地区关键词（日本/新加坡/美国…）跨机场聚合节点」，只有全量池 `_merged.yaml` 才包含各机场的完整节点清单；`ai.yaml` 是「手工圈定的 AI 专用出口」，不含「按地区选节点」所需的全部地区节点。`HK-STICKY` 已用 `use: [airport]` + `filter` 地区正则的模式验证可行，7 个新国家组照抄该模式即可。

> **产品语义（写入 Risks）**：国家分流使「绑定了国家的域名」**脱离 AI 专用出口池 `ai_airport`**，改走「全量池按地区聚合」的国家组出口。这意味着：① 该域名的出口 IP 不再限定为「AI 专用节点」，而是「该国任意节点」（含非 AI 专用节点）；② 若某国节点池里没有「AI 友好」节点，该域名的 AI 访问稳定性可能弱于走 `AI-STICKY`。这是「按国家选节点」能力的固有语义，用户主动绑定即接受此取舍。

## 决策 G2：独立脚本 `scripts/gen-country-rules.sh`（定死，完整规格）

**新增独立脚本，不改动现有 `gen-rules.sh`**（避免现有 AI 域名链路回归，回应 #5）。定位与 `gen-rules.sh` 一致：**只产出规则片段，禁止改写 `config.yaml`**；`config.yaml` 由 G3/G4 一次性手工接入。

**骨架**：沿用 `gen-rules.sh` 的样板——`set -uo pipefail`、`SCRIPT_DIR`/`PROJECT_ROOT`、参数默认值、`warn`/`info` 函数、`write_out` 全量覆盖写（`mkdir -p` 输出目录）、退出码约定（0 成功含降级成功；非 0 写入失败）。

```
用法: ./scripts/gen-country-rules.sh [数据文件] [输出文件]
  数据文件  默认 nodes/ai-domains-country.txt
  输出文件  默认 rules/ai-plugin-country.yaml
```

**产物注释头**（规则行紧随其后，格式仿 gen-rules.sh）：

```
# 由 scripts/gen-country-rules.sh 生成，勿手工编辑
# 数据源: nodes/ai-domains-country.txt（从 chatgpt-block-bypass 插件「导出国家分流规则」落地）
# 消费方: config.yaml 的 rule-providers.ai-plugin-country（type: file / behavior: classical / format: text）
```

**解析框架（定死，回应 S6——awk 两段式）**：沿用 `gen-rules.sh` 的「**awk 先转纯 ASCII 中间文件再 `while IFS= read -r` 逐行读**」两段式，规避 bash 3.2（macOS 自带）多字节字符 bug（`set -u` 下按字节拆分多字节字符触发 unbound variable）。**含中文注释的原始行不得直接逐行读**。

- **第一段 awk**（产出纯 ASCII 中间文件，两列 TAB 分隔 `域名\t国家代码`）：
  - 行首 `#` → 整行注释忽略；行内 `#` 后内容视为行内注释忽略；空行忽略；行首行尾与列间容忍任意 `[ \t]+` 空白（awk 分割，同时兼容插件侧的 TAB 与手工粘贴的空格）；剥离 `\r`；
  - 第一列域名统一 `tolower`，第二列国家代码统一 `toupper`（大小写不敏感后统一转大写）；
  - **awk 不输出「原始行」**（原始行含中文行内注释，bash 3.2 读入含多字节字符的组合行会按字节处理导致字段错位）；
  - 两列提取后输出 `printf "%s\t%s\n", dom, code`；第二列缺失时输出空 code（由 bash 阶段告警跳过，保证「缺失第二列」可见）。
- **第二段 bash 逐行**（`while IFS= read -r line`，`cut -f1`/`cut -f2` 拆两列），逐条执行下述校验链，任一不通过 → **告警并跳过该行**（不生成规则、不中断其余行）：

1. **国家代码校验**：第二列必须 ∈ 8 枚举（`HK/JP/US/SG/TW/KR/GB/DE`，awk 已统一大写）；非法（含非国家内容、缺失第二列）→ 告警并跳过，不生成悬空组规则。
2. **域名白名单校验（定死，回应第 2 轮阻塞项 1）**：**与插件 `normalizeDomain` 同款分段校验语义**（两侧校验语义一致）——shell 侧用等价收紧正则 `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`（无空段、段首尾字母数字、段数 ≥ 2；**转义注意**：shell 单引号内写 `\.` 匹配字面点，**不得写成 `\\.`**——ERE 中 `\\` 匹配字面反斜杠 + `.` 匹配任意字符，会误拒全部合法域名，与 G0 的 `\b` 属同类两层转义问题），awk 已统一小写；非法（含 `bad..com`、`openai`）→ 告警并跳过。**旧正则 `^[a-z0-9]([a-z0-9.-]*\.[a-z0-9-]+)$` 会放行 `bad..com`，不得照抄**（`gen-rules.sh` 的旧正则不纳入本次一致性要求，其链路标 ❌ 不修改）。
3. **超宽域名排除**：命中 `BROAD_DOMAIN_DENYLIST`（**沿用**现有 `gen-rules.sh` 的清单，当前仅 `google.com`，**精确相等**排除，仅排除裸域本身、不涉及子域）→ 告警并跳过。回应第 1 轮评审阻塞项 P1「沿用排除」，避免重新引入「google.com 全生态过度代理」风险；子域（如 `gemini.google.com`、`www.google.com`）不受影响，正常生成。
4. **组存在性运行时校验（定死，回应第 2 轮阻塞项 3 与主审提示 P1）**：生成每条规则前，**运行时解析 `config.yaml` 的 `proxy-groups` 段 `name:` 字段**得到真实组名集合（awk 单遍解析，与 `verify.sh` 降级扫描同款技术，已验证可行），目标组 `<code>-STICKY` 不在集合 → **告警并跳过该行**（如注释掉 `DE-STICKY` 后数据含 `DE` 行 → 不生成 `DOMAIN-SUFFIX,x,DE-STICKY`，避免 mihomo 加载失败）；`config.yaml` 缺失或不可解析 → 告警并**跳过组存在性校验**（不阻断生成，由 `verify.sh` 国家组非空检查兜底）。**解析 `name:` 必须排除注释行（定死，回应第 2 轮主审提示 P1）**：awk 匹配 `name:` 前须跳过行首为 `#` 的行（`^[[:space:]]*#`）——`config.yaml` 现存注释态示例块 `# - name: RELAY-POOL`（组⑤），若不过滤会把 `RELAY-POOL` 误计入组名集合；该口径错误当前虽不产生实际影响（`RELAY-POOL` 不在 8 枚举映射内），但一旦有人注释掉某个 `<code>-STICKY` 组，注释态组名会污染集合并使组存在性校验失效（tasks 4.5 以「注释掉 DE-STICKY」方式验证此口径）。**与「禁止静态映射表」决策不冲突**：此为运行时读取真实组名集合做成员判定，而非维护「代码 → 组名」静态表；组名仍由 `<code>-STICKY` 公式拼接。
5. **同域名重复（定死，回应 S1）**：同一域名出现多行 → 告警并**保留末行**（追加粘贴场景下末行为用户改绑国家后的最新意图；保留首行会残留旧值，与「改绑后重新导出」意图相反）。与插件侧「清空文件全量覆盖粘贴」操作约定互为双保险。**实现提示（bash 3.2 无关联数组）**：禁止用 `declare -A`（macOS bash 3.2 不支持）；推荐方案——中间文件已纯 ASCII，可安全交由 awk 处理：第一遍 awk 统计「域名 → 末次出现行号」并输出重复告警，第二遍仅对末次出现行号生成规则；或等价的两遍方案。
6. **组名派生**：`<code>-STICKY` 直接字符串拼接，**禁止网关侧另建映射表**。
7. **规则类型统一（定死，回应第 2 轮辅审 1）**：每行一律 `DOMAIN-SUFFIX,<域名>,<国家组>`，**不产出 `DOMAIN` 精确规则**。语义明示：**绑定父域即覆盖其全部子域**；配合插件侧「子域在前」排序（插件决策 4），用户可对父域绑国家 A、对其子域绑国家 B 实现细粒度覆盖。
8. **排序**：**按读入顺序生成，不二次排序**（插件侧已按「子域在前」排序——域名段数降序、同段数字典序；单一排序源，避免两侧排序规则不一致）。

**降级（数据文件缺失）**：数据文件不存在 → 生成**仅注释头空规则片段** + 告警（与现有 `gen-rules.sh` 降级路径一致；`config.yaml` 的 `RULE-SET,ai-plugin-country` 消费空片段无副作用），`exit 0`。

**统计输出**（仿 gen-rules.sh）：总有效行数、生成规则数、跳过数（按原因归类告警）、重复行数。

## 决策 G3/G4：rule-provider 接入与 rules 优先级（定死）

**G3 — `config.yaml` `rule-providers` 新增 `ai-plugin-country`**（与 `ai-plugin` 同款本地文件 classical 文本配置）：

```yaml
rule-providers:
  # 国家分流（域名按国家绑定 → 对应国家组，最高优先级，本地生成）：
  #   scripts/gen-country-rules.sh 读取 nodes/ai-domains-country.txt 生成 rules/ai-plugin-country.yaml，
  #   为 classical 文本规则（每行 DOMAIN-SUFFIX,域名,国家组），故 behavior=classical + format=text。
  ai-plugin-country:
    type: file
    behavior: classical
    format: text
    path: rules/ai-plugin-country.yaml
```

**G4 — `config.yaml` `rules` 最前加 `RULE-SET,ai-plugin-country`**（置于 `RULE-SET,ai-plugin` 之前，保证「指定国家域名」优先于「默认 AI 出口」）：

```yaml
rules:
  # ── 国家分流（最高优先级，本地生成，目标组在规则 payload 第三列）──
  - RULE-SET,ai-plugin-country
  # ── 插件域名（AI 出口，本地生成，引用处统一指定 AI-STICKY）──
  - RULE-SET,ai-plugin,AI-STICKY
```

> **引用格式差异（重要）**：`RULE-SET,ai-plugin-country` **不带目标组参数**——组名来自每条规则的 payload 第三列（classical 文本规则带组名的标准用法）；与 `RULE-SET,ai-plugin,AI-STICKY`（payload 无组名、引用时统一指定）不同。coder 不得给 `ai-plugin-country` 引用加第三列组名（会与 payload 冲突）。

## 决策 G5/G6：数据源文件与规则产物（定死）

- **G5 — `nodes/ai-domains-country.txt`（新增数据源文件）**：头部注释说明格式、来源与落地操作约定：
  - 格式：每行 `域名<TAB>国家代码`（国家代码 ∈ 8 枚举，大小写不敏感）；
  - 来源：插件「导出国家分流规则」剪贴板内容；
  - 操作约定（定死，回应 S1）：**每次更新须先清空文件再全量覆盖粘贴**（导出内容为 `domainCountries` 全量快照，避免旧行残留与新行混杂）；
  - 消费方：`scripts/gen-country-rules.sh`。
  - 初始提交内容：**仅注释头、无数据行**（数据行由用户粘贴落地；是否将个人绑定数据 git 提交由用户决定，脚本对文件缺失已有优雅降级）。
- **G6 — `rules/ai-plugin-country.yaml`（新增产物）**：由 `gen-country-rules.sh` 生成，**全量覆盖写，重复运行天然幂等**；首次运行脚本即生成，无需手工创建。

## 决策 G7：verify.sh 检查扩展（定死）

`scripts/verify.sh` 新增两项，**不改动既有 HK/AI 组检查与去硬编码动态发现机制**：

1. **国家组非空检查**：国家组判定用**完整锚定模式 `^(JP|US|SG|TW|KR|GB|DE)-STICKY$`**（`grep -Eq`，**禁止子串匹配**——避免 `NODE-POOL` 命中 `DE`、`BONUS-EXTRA` 命中 `US` 被误判为国家组，回应第 2 轮评审 S5）：
   - API 模式：从 `/proxies` 动态发现的组名中筛出匹配锚定模式的组，复用 `check_group` 逐组校验非空；**组为空 → 计入 `hard_fail`**（国家组承载 `ai-plugin-country` 规则指向的流量，组空即流量黑洞，与 HK 组非空硬性要求同思路）；
   - 本地扫描降级模式（API 不可达）：扫描 `config.yaml` `proxy-groups` 段 `name:` 字段，对匹配锚定模式的组标注「应存在（国家分流组，非空为硬性要求，运行时无法确认）」。
2. **7 国正则命中率 dry-run**：统计 7 国地区关键词对当前节点名的命中数。
   - **API 模式（定死，回应第 2 轮主审提示 P2）**：`/proxies` 返回对象**同时含组与节点**，**只取节点名、排除组 key**——组对象携带 `.all` 字段、节点对象没有，用 `select(.value.all == null)`（或等效判定）过滤后再对节点名统计，避免 `JP-STICKY`/`US-STICKY` 等组名造成命中虚高；
   - **本地降级模式**：**三级口径与 G0 完全一致**（回应第 2 轮辅审提示 ⑥）——优先 `nodes/_merged.yaml`；不存在**或 build 后无节点行（`proxies: []`）**时提示先跑 `build-config.sh`；「仍不可得」= **build 后 `_merged.yaml` 仍无节点行**（零机场场景 `build-config.sh` exit 0 但产物为空）→ 降级 `nodes/clash*.yaml` / `clash.yaml`。**节点名提取必须覆盖两种格式并剔除注释行**（内联 JSON `"name": "..."` 与展开式 `- name: ...`，复用 G0 示例命令的提取逻辑——build-config.sh 整段拷贝使两种格式并存，漏掉展开式会低估命中数；注释行不参与统计）。**转义同 G0 警示**：`grep -Eq` 的 shell 单引号内写 `\b`（词边界），**不得照搬 G1 YAML 双引号内的 `\\b`**——两层不同转义，照搬双反斜杠会命中全 0 并误报。
   - **处置口径与 G0 例外条款一致**：命中为 0 的国家 → 告警提示「补节点或调整正则」（G0 前置验证的持续校验；软性提示不阻断，组为空已有第 1 项硬失败兜底）；模板/示例数据或空产物场景 → 标注数据来源 + 「待部署环境复核」，**不以此放宽正则**，部署环境 dry-run 复核（DEPLOY.md 上线清单）为最终闸门。
3. **文档更新（同任务）**：`README.md`、`DEPLOY.md` 补充国家分流部署流程——数据落地位置（`nodes/ai-domains-country.txt` 清空后全量覆盖粘贴）、`gen-country-rules.sh` 执行步骤、`apply.sh` 热加载、`verify.sh` 校验、7 国组名表与「绑定国家即脱离 AI 专用出口池」产品语义说明。

## 优先级语义（定死）

```
RULE-SET,ai-plugin-country（国家分流，最高优先级，新增）
→ RULE-SET,ai-plugin → AI-STICKY（AI 默认出口）
→ 内联兜底 DOMAIN-KEYWORD/DOMAIN-SUFFIX → AI-STICKY
→ RULE-SET,Private → DIRECT；RULE-SET,Block → REJECT
→ RULE-SET,AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity → AI-STICKY
→ RULE-SET,China → DIRECT；GEOIP,CN → DIRECT
→ MATCH → HK-STICKY（默认出口）
```

即：`ai-plugin-country`（带国家组）→ `ai-plugin`（默认 AI 组）→ 远程 AI 规则集 → 国内直连 → `MATCH,HK-STICKY`。**用户绑定了国家的域名永远优先于 AI 默认出口**；未绑定的 AI 域名维持现状走 `AI-STICKY`，零回归。

## config.yaml 现状衔接（已核对真实代码）

以下现状摘自已核对的 `config.yaml`（2026-11-19 工作区版本），design 描述与之逐字对齐：

- **`proxy-groups` 现状**：现有 `AI-FIXED`（consistent-hashing，`use: [ai_airport]`）、`GEN-ROTATE`（round-robin，`use: [airport]` + 香港 filter）、`AI-STICKY`（sticky-sessions，`use: [ai_airport]`）、`HK-STICKY`（sticky-sessions，`use: [airport]` + `filter: "(?i)(香港|Hong ?Kong|\\bHK\\b)"` + `exclude-filter: "(?i)(禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅)"`），其后是注释态的 `RELAY-POOL` 示例块。**插入位置**：7 个国家组追加在 `HK-STICKY` 块之后、`RELAY-POOL` 注释块之前，新增节注释「── 国家分流组（域名按国家绑定 → 按节点名地区关键词聚合，共 7 组）──」；既有组①-⑤ 的编号注释不强改（最小 diff）。
- **`rule-providers` 现状**：`ai-plugin`（type: file / behavior: classical / format: text / path: rules/ai-plugin.yaml）位于列表首位。**插入位置**：`ai-plugin-country` 紧邻 `ai-plugin` 之前插入（同为本地生成 classical 文本，注释说明成对）。
- **`rules` 现状**：首条为 `- RULE-SET,ai-plugin,AI-STICKY`，其后依次为内联兜底（DOMAIN-KEYWORD/DOMAIN-SUFFIX → AI-STICKY）、Private/Block、AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity 规则集、China、`GEOIP,CN,DIRECT`、`MATCH,HK-STICKY`。**插入位置**：`- RULE-SET,ai-plugin-country` 置于 `- RULE-SET,ai-plugin,AI-STICKY` **之前**（rules 列表第一行）。
- **`scripts/gen-rules.sh` 现状（已核对）**：awk 两段式框架（先产出纯 ASCII 中间文件再 `while IFS= read -r` 逐行读）、`BROAD_DOMAIN_DENYLIST="google.com"`（精确相等排除 + `is_broad_domain` 函数，形参名避开 bash 3.2 local 坑用 `d`）、`write_out` 全量覆盖写、数据文件缺失降级空片段、统计输出。`gen-country-rules.sh` 沿用该框架与清单，但**校验链、规则格式、去重语义均不同**（见 G2），不得直接拷贝 `gen-rules.sh` 改参数了事。
- **`scripts/verify.sh` 现状（已核对）**：已实现 provider/组动态发现、`check_group` 逐组校验、HK/AI 组非空硬失败、API 不可达本地扫描降级（awk 单遍解析 `proxy-providers`/`proxy-groups` 段）。G7 扩展挂接在既有「组名分类标注」逻辑上，新增国家组锚定模式分类，不改动既有分类函数。

## 文件范围

| 文件路径 | 修改类型 | 说明 |
|---------|---------|------|
| `config.yaml` | 修改 | `proxy-groups` 新增 7 个国家组（G1，追加在 HK-STICKY 后）；`rule-providers` 新增 `ai-plugin-country`（G3）；`rules` 最前新增 `- RULE-SET,ai-plugin-country`（G4） |
| `scripts/gen-country-rules.sh` | 新增 | 独立国家分流规则生成脚本（G2 完整规格） |
| `nodes/ai-domains-country.txt` | 新增 | 数据源文件（G5，初始仅注释头，两列格式与操作约定说明） |
| `rules/ai-plugin-country.yaml` | 新增（脚本产物） | G6，由 `gen-country-rules.sh` 全量覆盖写生成，首次运行脚本即产出 |
| `scripts/verify.sh` | 修改 | 国家组非空检查（锚定模式 `^(JP\|US\|SG\|TW\|KR\|GB\|DE)-STICKY$`）+ 7 国正则 dry-run（G7） |
| `README.md` | 修改 | 国家分流部署/维护流程、7 国组名表、产品语义说明（G7） |
| `DEPLOY.md` | 修改 | 部署步骤补国家分流（数据落地 → gen → apply → verify）（G7） |
| `scripts/gen-rules.sh` | ❌ 不修改 | 现有 AI 域名链路正确基准；其旧域名正则不纳入本次一致性要求 |
| `nodes/ai-domains.txt` | ❌ 不修改 | 现有 AI 域名数据源，与本次两列数据文件无关 |
| `rules/ai-plugin.yaml` | ❌ 不修改 | 现有 AI 链路产物（由 gen-rules.sh 生成） |
| `scripts/build-config.sh` | ❌ 不修改 | 节点合并逻辑无关（G0 仅读其产物 `_merged.yaml`） |
| `scripts/apply.sh` / `scripts/reload-nodes.sh` | ❌ 不修改 | 热加载/重载编排沿用既有流程，无需改动 |
| `docker-compose.yml` | ❌ 不修改 | 容器编排无关 |
| `www/` | ❌ 不修改 | 前端 PAC 逻辑无关 |
| `nodes/clash.example.yaml` / `nodes/ai.example.yaml` | ❌ 不修改 | 节点模板无关 |
| `.gitignore` | ❌ 不修改 | `nodes/*.yaml` 忽略策略已覆盖产物；txt 数据文件入库策略见 G5 |

## 同类路径对照

> 网关侧存在多条「域名数据源 → 规则 → 出口组」链路，需在设计阶段统一审视，防止 coder 只改一条而遗漏其他。

| 链路 | 数据源格式 | 产物规则格式 | 目标组来源 | 本次是否修改 | 备注 |
|------|-----------|-------------|-----------|------------|------|
| `ai-plugin`（AI 域名分流） | `nodes/ai-domains.txt` 单列裸域名（`=` 前缀表精确） | `DOMAIN-SUFFIX,域名` / `DOMAIN,域名`（无组名） | `config.yaml` 引用处统一指定 `AI-STICKY` | ❌ 不修改（正确基准） | multi-airport 已定案，`gen-rules.sh`（含其旧域名正则）不动 |
| **`ai-plugin-country`（国家分流，本次新增）** | `nodes/ai-domains-country.txt` 两列（域名 + 国家代码，TAB 分隔） | **`DOMAIN-SUFFIX,域名,<code>-STICKY>`（规则类型定死，带组名）** | **规则 payload 第三列**，组名由 `<code>-STICKY` 公式派生（禁止映射表） | ✅ 新增 | 独立脚本 `gen-country-rules.sh`；域名白名单与插件 `normalizeDomain` 同款分段校验语义 |
| 内联兜底 + 远程 AI 规则集 | — | 指向 `AI-STICKY` | `AI-STICKY` | ❌ 不修改 | G4 仅在其前新增一行，既有规则行不动 |
| `HK-STICKY`（地区聚合基准） | — | `filter` 地区正则 + `exclude-filter` | — | ❌ 不修改（正确基准） | 7 个新国家组逐字复刻其组模式（filter 换国家关键词） |
| `BROAD_DOMAIN_DENYLIST`（`google.com`） | — | 超宽域名精确相等排除 | — | ❌ 不修改（正确基准） | `gen-country-rules.sh` 沿用同清单；插件侧同内容常量 `BROAD_DOMAINS` 为跨仓库一致性项 |
| `MATCH,HK-STICKY` 兜底 | — | — | `HK-STICKY` | ❌ 不修改 | 国家分流未命中的流量仍走默认出口 |

## 跨仓库一致性约束（与插件侧三轮评审一致，定死）

1. **组名一致性**：组名一律由 `<国家代码>-STICKY` 公式在插件侧与网关侧各自拼接，任何一侧不得维护「代码 → 组名」映射表；插件不导出组名字符串，网关侧 `verify.sh` 国家组非空检查守护「网关侧组名已建」，`gen-country-rules.sh` 组存在性运行时校验守护「组名真实存在」。8 个映射：`HK→HK-STICKY`、`JP→JP-STICKY`、`US→US-STICKY`、`SG→SG-STICKY`、`TW→TW-STICKY`、`KR→KR-STICKY`、`GB→GB-STICKY`、`DE→DE-STICKY`。
2. **超宽域名清单一致性**：插件 `BROAD_DOMAINS` 与网关 `BROAD_DOMAIN_DENYLIST` 必须内容一致（当前均为 `google.com`）；网关侧变更清单时需同步插件常量（tasks 4.2 显式标注）。
3. **域名校验语义一致性**：插件 `normalizeDomain` 与 `gen-country-rules.sh` 采用同款**分段校验**（无空段、段首尾字母数字、段数 ≥ 2），两侧均拒绝 `bad..com`；现有 `gen-rules.sh` 的旧正则不纳入本一致性要求（其链路标 ❌ 不修改）。

## Risks / Trade-offs

- **跨仓库一致性风险（高）**：插件 `COUNTRIES` 组名与网关 `proxy-groups` 组名若不逐字一致，国家分流规则会指向悬空组。缓解：`<国家代码>-STICKY` 单一公式两侧各自拼接、禁止映射表；网关侧组存在性运行时校验 + `verify.sh` 锚定模式非空检查；同类路径对照表显式锁定组名公式。
- **国家组为空风险（高）**：若节点池无某国节点（如无韩国节点），对应国家组为空，分流到该组失败。缓解：G0 前置 dry-run（真实节点数据下命中为 0 先补节点/调正则，通过后才建组；模板/示例数据或空产物由部署环境 dry-run 复核兜底）；`gen-country-rules.sh` 组缺失告警跳过；`verify.sh` 国家组非空硬失败。
- **「国家分流脱离 AI 专用出口池」产品语义（高，评审阻塞项 P3 相关）**：国家组 `use: [airport]` 全量池，绑定国家的域名出口 IP 不再限定为 AI 专用节点，若该国节点池无「AI 友好」节点，稳定性可能弱于 `AI-STICKY`。缓解：产品语义写入 design/Risks/README 说明，用户主动绑定即接受此取舍；后续如需「AI 专用国家池」可另立变更（本期不做）。
- **超宽域名绑定被网关排除的认知偏差（中，评审阻塞项 P1 相关）**：用户给 `google.com` 绑国家，网关侧 `BROAD_DOMAIN_DENYLIST` 排除该规则，绑定「看起来成功、实际不生效」。缓解：沿用排除（避免过度代理回归）；插件侧绑定/导出时明确提示「改用子域」；网关侧脚本对该行显式告警，运维可见。
- **组存在性校验依赖 `config.yaml` 可读性（低）**：脚本运行时解析 `config.yaml` 校验组存在性，文件缺失/不可解析时该校验降级跳过（不阻断生成），组真实缺失由 `verify.sh` 国家组非空检查兜底；config.yaml 格式变更时需回归该解析（tasks 4.5 验证项）。
- **bash 3.2 兼容性（中）**：macOS 自带 bash 3.2 无关联数组（`declare -A` 不可用），「同域名重复保留末行」不能照抄现代 bash 写法。缓解：design 已定死推荐实现（awk 两遍处理纯 ASCII 中间文件）；多字节行不进入 bash（awk 两段式框架）。
- **导出文件手动落地（中）**：与 multi-airport 一致，插件剪贴板导出内容需人工粘贴到网关 `nodes/` 目录，非自动同步。缓解：记录为已知限制；「清空后全量覆盖粘贴」操作约定 + 网关侧重复行保留末行双保险。
- **verify.sh 新增硬失败对既有部署的影响（低）**：新增 7 个国家组后，若组为空（如某国节点缺失），`verify.sh` 会新增硬失败项。缓解：这是预期行为（空组 = 流量黑洞）；G0 前置验证保证建组时非空；README/DEPLOY 说明处置方式（补节点或移除该组）。

## 可测试性 / 可验证性

- **G0 dry-run**（tasks 4.0）：7 国 × 命中数表，产出验证记录；分级判定——真实节点数据任一为 0 阻塞建组；模板/示例数据或空产物（`proxies: []`）标注来源 + 「待部署环境复核」、不阻塞 4.1 建组（7 组照建）；模板数据场景禁止放宽正则。
- **脚本幂等**：`gen-country-rules.sh` 全量覆盖写，重复运行产物一致（对同一输入）；空输入/缺失文件生成仅注释头空片段。
- **降级验证清单**（tasks 4.5）：非法国家代码（含 `FR`、小写 `jp` 大小写不敏感、缺失第二列）、`bad..com` 域名白名单拒绝、`google.com` 超宽排除、同域名重复保留末行、组缺失（**注释掉** `DE-STICKY` 组，验证注释行排除口径 + 组缺失跳过）告警跳过且产物无悬空组规则、数据文件缺失空片段——逐项构造输入验证，验证后恢复现场。
- **端到端**（联动，依赖插件侧完成）：粘贴导出内容 → 重跑脚本 → 确认 `rules/ai-plugin-country.yaml` 生成 `DOMAIN-SUFFIX,openai.com,JP-STICKY` 且子域行在父域行前、`google.com` 行被排除告警 → `apply.sh` 热加载 → 确认绑定域名流量走对应国家节点。
- **上线检查**：`verify.sh` 国家组非空 + 7 国 dry-run；`curl -x` 实测绑定域名出口地区（`check_ai` 同款思路）。

## 实现前疑问点

无阻塞性疑问（设计已三轮定稿）。以下为已作答的落地细节，coder 按设计执行即可：

| # | 疑问 | 已定答案 |
|---|------|---------|
| Q1 | 7 国正则关键词最终值 | G0 初始建议集已给出（与 G1 filter 一致）；以 G0 dry-run 结果为准，真实节点数据下命中为 0 先补节点/调正则、通过后落盘；模板/示例数据场景以初始建议集落盘、禁止放宽 |
| Q2 | 「重复行保留末行」在 bash 3.2 下的实现手段 | 定死语义（保留末行 + 告警）；推荐 awk 两遍处理纯 ASCII 中间文件（bash 3.2 无 `declare -A`，禁止关联数组方案） |
| Q3 | `nodes/ai-domains-country.txt` 与 `rules/ai-plugin-country.yaml` 是否 git 提交 | 数据文件初始仅提交注释头模板；规则产物由脚本生成，是否入库与 `rules/ai-plugin.yaml` 现状策略一致；脚本对两者缺失均有降级 |
| Q4 | dry-run 的 `\b` 词边界在 macOS grep 是否可用 | 已实测可用（`\bUS\b` 不误命中 `BONUS`、`\bDE\b` 不误命中 `NODE`）；老环境备选 `[[:<:]]`/`[[:>:]]`；mihomo `filter` 的 `\b` 为引擎语义不受影响 |
| Q5 | 当前工作区无真实节点数据（nodes/ 仅模板 example 文件），4.0 命中全 0 如何处理 | 例外条款（G0 产出段分级判定）：模板/示例数据或 build 产物无节点行（`proxies: []`）→ 产出标注来源 + 「待部署环境复核」的验证记录，**不阻塞 4.1 建组（7 组照建）**；「命中为 0 → 阻塞建组」仅适用真实节点数据；禁止以模板命中数为依据放宽正则；部署环境 dry-run 复核（DEPLOY.md 上线清单）为最终闸门 |
