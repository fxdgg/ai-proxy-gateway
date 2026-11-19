# country-routing-gateway Specification

## ADDED Requirements

### Requirement: 国家节点组与地区聚合

网关 MUST 在 `config.yaml` 的 `proxy-groups` 中提供 7 个国家节点组（`JP-STICKY`/`US-STICKY`/`SG-STICKY`/`TW-STICKY`/`KR-STICKY`/`GB-STICKY`/`DE-STICKY`），按节点名的地区关键词跨机场聚合节点，作为「域名按国家绑定」的出口组。

- 国家组 MUST 复用 `HK-STICKY` 的组模式：`type: load-balance` + `strategy: sticky-sessions`，`filter` 为对应国家的地区关键词正则（如日本组命中 `日本/Japan/Tokyo/Osaka/JP` 等关键词），`exclude-filter` 与 `HK-STICKY` 逐字同款（排除「禁止大流量/测试/Pv/VPN/剩余/流量/到期/过期/官网/重置/订阅」特征节点）。
- 国家组 MUST 使用 `use: [airport]`（全量池 `nodes/_merged.yaml`），**不得**使用 `[ai_airport]`（AI 专用池不含按地区选节点所需的全部地区节点）。
- 国家组名 MUST 由公式 `<国家代码>-STICKY` 派生（`HK→HK-STICKY`、`JP→JP-STICKY`、`US→US-STICKY`、`SG→SG-STICKY`、`TW→TW-STICKY`、`KR→KR-STICKY`、`GB→GB-STICKY`、`DE→DE-STICKY`），网关侧**不得**维护「代码 → 组名」静态映射表。
- 建组前 MUST 完成 7 国正则 dry-run 命中率验证（前置验证，见「前置验证与部署校验」需求）；**真实节点数据**下任一国家节点名命中为 0 时 SHALL 先补节点或调整正则，通过后方可建组。**例外（模板/示例数据或空产物）**：dry-run 数据源为模板/示例数据（如 `clash.example.yaml`）、或 build 产物无节点行（`proxies: []`）时，SHALL NOT 阻塞建组——产出标注数据来源与处置结论「待部署环境复核」的验证记录后 7 组照建；模板数据场景 SHALL NOT 以命中数为依据放宽正则；部署环境 dry-run 复核为最终闸门（命中为 0 时先补节点/调正则或临时移除对应组再上线）。

#### Scenario: 按地区关键词聚合节点

- **WHEN** `nodes/_merged.yaml` 中存在节点名含 `日本`、`Japan`、`Tokyo` 或独立词 `JP` 的节点
- **THEN** `JP-STICKY` 组包含这些节点，且其余 6 个国家组按各自国家关键词（美国/新加坡/台湾/韩国/英国/德国）聚合

#### Scenario: 国家组使用全量节点池

- **WHEN** 网关加载 `config.yaml`
- **THEN** 7 个国家组的 `use` 均为 `[airport]`（全量池 `nodes/_merged.yaml`），不使用 `ai_airport`

#### Scenario: 国家组排除机场信息节点

- **WHEN** 节点名含「禁止大流量」「测试」「到期」「官网」等特征
- **THEN** 该节点被所有国家组的 `exclude-filter` 排除，不进入任何国家组

#### Scenario: 建组前置命中率验证

- **WHEN** **真实节点数据**下 7 国正则对当前节点名的 dry-run 统计中某一国家命中数为 0（如无任何韩国节点）
- **THEN** 暂不创建该国家组（先补节点或调整正则），直至重新验证命中 ≥ 1

#### Scenario: 模板/示例数据或空产物不阻塞建组

- **WHEN** dry-run 数据源为模板/示例数据（如 `clash.example.yaml`），或 build 产物无节点行（`proxies: []`）
- **THEN** 产出标注数据来源与处置结论「待部署环境复核」的验证记录，**不阻塞** 7 个国家组照常创建；正则不因模板数据命中数为 0 而放宽，部署环境 dry-run 复核为最终闸门

### Requirement: 国家分流规则生成

网关 MUST 提供独立脚本 `scripts/gen-country-rules.sh`，读取两列格式的 `nodes/ai-domains-country.txt`（`域名<TAB>国家代码`），生成 `rules/ai-plugin-country.yaml` 规则片段（每行 `DOMAIN-SUFFIX,<域名>,<国家组>`），且**不得**改动现有 `gen-rules.sh` 及其链路。

- 规则类型 MUST 统一为 `DOMAIN-SUFFIX`（**不产出** `DOMAIN` 精确规则），语义为「绑定父域即覆盖其全部子域」。
- 组名 MUST 由 `<国家代码>-STICKY` 字符串拼接派生，禁止另建映射表。
- 脚本 MUST 沿用 `gen-rules.sh` 的两段式解析框架：先由 awk 产出「纯 ASCII 中间文件」（剥离注释/空白、统一小写域名与大写国家代码），再逐行读取完成校验与规则组装（规避 bash 3.2 多字节字符 bug，含中文注释的原始行不得直接逐行读）。
- 解析健壮性 MUST 满足：空行/整行注释/行内注释忽略；行首行尾与列间容忍任意空白；国家代码大小写不敏感后必须 ∈ 8 枚举（`HK/JP/US/SG/TW/KR/GB/DE`），非法（含缺失第二列）告警跳过；域名白名单校验与插件 `normalizeDomain` 同款分段校验语义（等价收紧正则 `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`，shell 单引号内写 `\.` 匹配字面点，拒绝 `bad..com` 等空段域名）并统一小写，非法告警跳过。
- 脚本 MUST 沿用 `BROAD_DOMAIN_DENYLIST`（当前仅 `google.com`，精确相等）排除超宽域名并告警；子域（如 `gemini.google.com`）不受影响。
- 同域名出现多行时 MUST **保留末行**并告警（末行为用户最新意图），保留首行视为缺陷。
- 脚本 MUST 运行时解析 `config.yaml` 的 `proxy-groups` 段 `name:` 字段得到真实组名集合；解析时 MUST **排除注释行**（行首 `#`，如注释态 `# - name: RELAY-POOL` 不得计入组名集合）；目标组 `<code>-STICKY` 不在集合 → 告警跳过该行（不生成悬空组规则）；`config.yaml` 缺失或不可解析 → 告警并跳过组存在性校验（不阻断生成，由 `verify.sh` 兜底）。
- 脚本 MUST 按读入顺序生成、不二次排序（子域在前排序由插件侧导出时完成，单一排序源）。
- 数据文件缺失时 MUST 降级生成仅注释头空规则片段并告警（exit 0）。
- 产物 MUST 全量覆盖写，重复运行幂等；脚本只产出规则片段，**不得**改写 `config.yaml`。

#### Scenario: 生成带组名规则

- **WHEN** `ai-domains-country.txt` 含 `openai.com<TAB>JP`
- **THEN** `rules/ai-plugin-country.yaml` 生成 `DOMAIN-SUFFIX,openai.com,JP-STICKY`

#### Scenario: 规则类型统一 DOMAIN-SUFFIX

- **WHEN** 数据含 `chatgpt.com<TAB>US` 等任意合法行
- **THEN** 产物全部为 `DOMAIN-SUFFIX` 规则，不产出 `DOMAIN` 精确规则

#### Scenario: 非法国家代码告警跳过

- **WHEN** 数据含 `openai.com<TAB>FR`（非法代码）或某行缺失第二列
- **THEN** 脚本告警并跳过该行，不生成规则，其余合法行正常生成

#### Scenario: 非法域名拒绝

- **WHEN** 数据含 `bad..com<TAB>JP`（空段）或 `openai<TAB>JP`（无点）
- **THEN** 脚本按分段校验语义告警并跳过该行，不生成规则

#### Scenario: 超宽域名排除

- **WHEN** 数据含 `google.com<TAB>US`（命中 `BROAD_DOMAIN_DENYLIST`）
- **THEN** 脚本告警并跳过该行；`gemini.google.com<TAB>SG`（子域）不受影响，正常生成

#### Scenario: 同域名重复保留末行

- **WHEN** 数据同时含 `openai.com<TAB>JP` 与后续的 `openai.com<TAB>SG`
- **THEN** 脚本告警重复并仅生成 `DOMAIN-SUFFIX,openai.com,SG-STICKY`（末行为最新意图）

#### Scenario: 组存在性运行时校验

- **WHEN** 数据含 `x.com<TAB>DE` 但 `config.yaml` 的 `proxy-groups` 无 `DE-STICKY` 组
- **THEN** 脚本告警并跳过该行（不生成指向悬空组的规则），其余行正常生成

#### Scenario: 注释态组名不参与组存在性判定

- **WHEN** `config.yaml` 的 `proxy-groups` 含注释态示例块（如 `# - name: RELAY-POOL`），或 `DE-STICKY` 组被整块注释掉
- **THEN** 组名解析排除注释行：注释态组名不得计入组名集合（被注释掉的 `DE-STICKY` 视为组不存在，`x.com<TAB>DE` 行告警跳过）

#### Scenario: config.yaml 不可用时跳过组校验

- **WHEN** `config.yaml` 缺失或不可解析
- **THEN** 脚本告警并跳过组存在性校验（不阻断生成），组真实缺失由 `verify.sh` 国家组非空检查兜底

#### Scenario: 数据文件缺失降级

- **WHEN** `nodes/ai-domains-country.txt` 不存在
- **THEN** 脚本告警并生成仅注释头的空规则片段（exit 0），`config.yaml` 消费空片段无副作用

#### Scenario: 按读入顺序生成不二次排序

- **WHEN** 数据行顺序为 `gemini.google.com<TAB>SG` 在前、`google.com<TAB>US` 在后（插件侧已按子域在前排序）
- **THEN** 产物保持该读入顺序（子域行在前），脚本不重新排序

### Requirement: 国家分流规则接入与优先级

网关 MUST 在 `config.yaml` 新增 `rule-providers.ai-plugin-country`（`type: file` + `behavior: classical` + `format: text` + `path: rules/ai-plugin-country.yaml`），并在 `rules` **最前**加入 `RULE-SET,ai-plugin-country`，保证国家分流优先级高于 AI 默认出口。

- `RULE-SET,ai-plugin-country` 引用 MUST **不带**目标组参数——组名来自每条规则的 payload 第三列。
- 优先级顺序 MUST 为：`ai-plugin-country`（国家分流，最高）→ `ai-plugin`（AI 默认出口）→ 内联兜底与远程 AI 规则集（`AI-STICKY`）→ 国内直连 → `MATCH,HK-STICKY` 兜底。
- 未绑定国家的 AI 域名 MUST 维持现状走 `AI-STICKY`，国家分流接入不得影响既有分流链路。

#### Scenario: 国家分流优先于 AI 默认出口

- **WHEN** 域名 `openai.com` 绑定了日本（规则 `DOMAIN-SUFFIX,openai.com,JP-STICKY`）且同时命中 `ai-plugin` 的 `AI-STICKY` 规则
- **THEN** `openai.com` 流量走 `JP-STICKY`（`RULE-SET,ai-plugin-country` 位于 rules 最前，先命中）

#### Scenario: 未绑定国家的域名维持现状

- **WHEN** 域名 `coze.com` 在 `ai-domains.txt`（AI 默认清单）但不在 `ai-domains-country.txt`
- **THEN** `coze.com` 仍走 `AI-STICKY`，与接入前行为一致

### Requirement: 前置验证与部署校验

网关 MUST 在建组前完成 7 国正则 dry-run 命中率验证（前置验证），并 MUST 在 `scripts/verify.sh` 中新增国家组非空检查与 7 国正则命中率 dry-run，使国家组问题在部署时可发现。

- 前置验证 MUST 对当前 `nodes/_merged.yaml` 节点名统计 7 国地区关键词命中数，节点名提取 MUST 覆盖内联 JSON `"name"` 与展开式 `- name:` 两种格式（`build-config.sh` 整段拷贝使两种格式并存）并 MUST 剔除注释行（注释掉的节点行不参与统计）；真实节点数据下任一国家命中为 0 → 先补节点或调整正则，通过后再建组（真实数据下命中为 0 仍建组视为缺陷）。例外：数据源为模板/示例数据、或 build 产物无节点行（`proxies: []`）时，SHALL NOT 阻塞建组——产出标注数据来源与「待部署环境复核」处置结论的验证记录后 7 组照建，且 SHALL NOT 以命中数为依据放宽正则。
- 前置验证数据源采用三级口径：`nodes/_merged.yaml` → 不存在或 build 后无节点行（`proxies: []`）时先执行 `build-config.sh` → 「仍不可得」（build 后 `_merged.yaml` 仍无节点行）则降级 `nodes/clash*.yaml` / `clash.yaml`。
- 前置验证记录 MUST 标注数据来源与真实数据/模板数据分级结论；若来源为模板/示例数据或空产物，SHALL 在真实部署环境重跑 dry-run 复核（复核为最终闸门：命中为 0 时先补节点/调正则或临时移除对应组再上线）。
- `verify.sh` 国家组判定 MUST 使用完整锚定模式 `^(JP|US|SG|TW|KR|GB|DE)-STICKY$`（`grep -Eq`），**禁止子串匹配**（`NODE-POOL` 含 `DE`、`BONUS-EXTRA` 含 `US` 不得被误判为国家组）。
- 国家组非空为硬性要求：运行时任一国家组为空，`verify.sh` MUST 计入硬失败（国家组承载国家分流规则指向的流量，组空即流量黑洞）。
- `verify.sh` 的 7 国 dry-run 命中为 0 时 SHALL 告警提示补节点或调整正则（软性提示，不阻断）；API 模式 MUST 只取节点名、排除组 key（组对象携带 `.all` 字段、节点对象无，用 `select(.value.all == null)` 或等效过滤，组名不得计入命中）；本地降级模式 SHALL 采用与前置验证一致的三级口径（`_merged.yaml` → build 后无节点行提示先跑 `build-config.sh` → 「仍不可得」降级 `clash*.yaml` / `clash.yaml`），其节点名提取 SHALL 同样覆盖内联 JSON 与展开式两种格式并剔除注释行。

#### Scenario: 锚定模式避免子串误判

- **WHEN** 运行时存在组 `NODE-POOL`（含 `DE` 子串）或 `BONUS-EXTRA`（含 `US` 子串）
- **THEN** `verify.sh` 不将其判为国家组（不匹配 `^(JP|US|SG|TW|KR|GB|DE)-STICKY$`），仅对真实国家组做非空检查

#### Scenario: 国家组为空硬失败

- **WHEN** 运行时 `KR-STICKY` 组存在但 filter 命中 0 个节点
- **THEN** `verify.sh` 报告该组为空并计入硬失败，提示补节点或调整正则

#### Scenario: 命中为 0 的持续校验

- **WHEN** `verify.sh` 的 7 国 dry-run 中某国（如德国）节点名命中为 0
- **THEN** 输出告警提示「补节点或调整正则」，不阻断其余检查项

#### Scenario: 节点名提取覆盖两种格式

- **WHEN** `nodes/_merged.yaml` 同时含内联 JSON 节点（`"name": "..."`）与展开式节点（`- name: ...`）
- **THEN** 前置验证与 `verify.sh` 本地降级 dry-run 均提取到两种格式的节点名并统计命中数（漏掉展开式导致命中数为 0 视为缺陷）

#### Scenario: API 模式 dry-run 排除组 key

- **WHEN** `/proxies` 返回对象同时含组（携带 `.all` 字段，如 `JP-STICKY`）与节点（无 `.all` 字段）
- **THEN** `verify.sh` API 模式 dry-run 仅以节点名统计命中数，组名不计入（`JP-STICKY` 等组名不得造成命中虚高）
