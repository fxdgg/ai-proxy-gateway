# 闸门评审：country-routing-gateway（第 2 轮双评审意见与处理）

## 结论

**【可直接进入开发】**（第 3 轮修订版：第 2 轮辅审驳回 1 个阻塞项 + 2 条提示、主审 3 条非阻塞提示（其中 P3 轻微不处理）已全部修订落盘；第 1 轮意见此前已全部修订）。

**设计依据**：本变更的全部技术决策（G0-G7）为插件侧归档 Change `chatgpt-block-bypass/openspec/changes/archive/2026-11-19-domain-country-routing` 中「决策 5」的**完整搬运**，该决策已经过插件侧**三轮评审定稿**：

- **第 1 轮**：双评审提出 P1（`BROAD_DOMAIN_DENYLIST` 沿用、子域/父域排序）、P3（`use: [airport]` 澄清）、#5（独立脚本定死）、#8（降级验证任务）、#10（解析健壮性细则）、#11（G0 前置 dry-run）等，均已定死落盘；
- **第 2 轮**：两审共识阻塞项 1（域名正则放行 `bad..com` → 定死分段校验、两侧同款语义）、主审阻塞项 3（组缺失降级缺检查手段 → 定死组存在性运行时校验）、S1（重复行保留末行）、S5（verify.sh 锚定模式防子串误伤）、S6（awk 两段式框架）、辅审 1（规则类型统一 `DOMAIN-SUFFIX`）等，全部定死；
- **第 3 轮**：修订全部吸收，插件侧四件套交叉核对无矛盾、无「留给 coder 决定」的开放项，结论为可进入开发。

本 design 为纯搬运（无新增决策），并已与网关真实代码现状逐字对齐（`config.yaml` 的 `HK-STICKY` filter/exclude-filter 与注释态 `# - name: RELAY-POOL`、`gen-rules.sh` 的 awk 两段式框架与 `BROAD_DOMAIN_DENYLIST`、`verify.sh` 的动态发现与降级扫描、`build-config.sh` 的零机场 exit 0 分支均已核对，见 design「config.yaml 现状衔接」章节与「决策 G0」）。网关侧第 2 轮双评审意见均为既有决策的落地细化，不引入新决策。

## 第 2 轮双评审意见与处理

第 2 轮主审结论【通过（3 条提示）】，辅审【驳回 1 个阻塞项 + 2 条提示】。全部意见的处理记录如下：

### 辅审阻塞项（必改，已修订）

**问题 ④：4.0 无真实节点数据环境必然全 0 阻塞建组，与完成定义矛盾**

- **现状核查（已核对代码证实）**：`nodes/` 下无真实机场文件（仅 `clash.example.yaml`/`ai.example.yaml`，build-config.sh 排除 example）；`build-config.sh` 主流程「零机场」分支**成功退出（exit 0）并产出空 provider `proxies: []`**（`scripts/build-config.sh` 第 151-157 行）；`clash*.yaml` glob 当前只匹配模板 `clash.example.yaml`。因此：① 「任一国家命中为 0 → 阻塞建组」与「完成定义含 4.1 建组」矛盾；② G0 降级链「`_merged.yaml` 不存在 → build → 仍不可得则降级 clash*.yaml」在 build 成功产出空文件时**永不触发第三级**（`_merged.yaml` 已存在且为空）。
- **处理（G0 分级判定例外条款，定死）**：design 决策 G0「产出」段改写为三级分级判定；tasks 4.0、spec「国家节点组与地区聚合」「前置验证与部署校验」两处需求及新增场景、proposal What Changes 第 1 条同步落盘：
  1. **真实节点数据**：任一国家命中为 0 → 阻塞 4.1 建组（先补节点或调整正则，通过后再建组）；
  2. **模板/示例数据或空产物（例外条款）**：dry-run 数据源为模板/示例数据（如 `clash.example.yaml`）、或 build 产物无节点行（`proxies: []`）时——产出**标注模板来源 + 处置结论「待部署环境复核」**的验证记录，**不阻塞 4.1 建组（7 组照建）**；「命中为 0 → 阻塞建组」仅适用于真实节点数据；模板数据场景**禁止以命中数为依据放宽正则**（正则仍以 G0 初始建议集落盘，由部署环境复核裁决）；
  3. **部署环境 dry-run 复核为最终闸门**（DEPLOY.md 上线清单，tasks 4.4 承接）：真实节点数据下命中为 0 → 先补节点/调正则或临时移除对应组再上线。
- **同时把「仍不可得」明确定义为「build 后 `_merged.yaml` 无节点行（`proxies: []`）」**（design 决策 G0「数据源」段、tasks 4.0、spec 前置验证条款），不再以「文件不存在」为唯一降级判定——该口径同时回应辅审提示 ⑥。

### 辅审提示（已修订）

- **⑤ G0 示例命令剔除注释行噪声**：design 决策 G0 示例命令的两种格式提取前统一加 `grep -v -E '^[[:space:]]*#'` 过滤注释行，并注明「`# - {"name":"Tokyo-01",...}` 这类被注释掉的节点不得计入命中数」；tasks 4.0 节点名提取口径补「剔除注释行」；spec 前置验证条款同步「注释掉的节点行不参与统计」。
- **⑥ G7 降级链同步 G0 三级口径 + 「仍不可得」定义**：design 决策 G7 第 2 条「本地降级模式」改为与 G0 完全一致的三级口径（`nodes/_merged.yaml` → 不存在**或 build 后无节点行（`proxies: []`）**时提示先跑 `build-config.sh` → 「仍不可得」= build 后 `_merged.yaml` 仍无节点行 → 降级 `nodes/clash*.yaml` / `clash.yaml`）；tasks 4.4、spec「前置验证与部署校验」verify.sh dry-run 条款同步。

### 主审提示（已处理）

- **P1 G2 组存在性运行时校验排除注释行 + 4.5 注释掉方式验证**：design 决策 G2 校验链第 4 条补「解析 `name:` 必须排除注释行（`^[[:space:]]*#`）」，并引用真实场景——`config.yaml` 现存注释态示例块 `# - name: RELAY-POOL`（组⑤），不过滤会被误计入组名集合；一旦有人注释掉某个 `<code>-STICKY` 组，注释态组名会污染集合并使组存在性校验失效。tasks 4.2 同步；tasks 4.5 验证项 ① 改为**「临时注释掉 `DE-STICKY` 组（整块注释、不要删除）」**方式——同时验证「组名解析排除注释行」与「组缺失被检测」两个语义；design 降级验证清单同步。spec「国家分流规则生成」条款补排除注释行要求，并新增 Scenario「注释态组名不参与组存在性判定」。
- **P2 tasks 4.4 API 模式 dry-run 只取节点名**：design 决策 G7 第 2 条补「`/proxies` 返回对象同时含组与节点，**只取节点名、排除组 key**——组对象携带 `.all` 字段、节点对象无，用 `select(.value.all == null)` 或等效过滤，避免 `JP-STICKY`/`US-STICKY` 等组名造成命中虚高」；tasks 4.4 同步；spec verify.sh dry-run 条款同步并新增 Scenario「API 模式 dry-run 排除组 key」。
- **P3**：轻微问题，经评估不引入实质风险，无需处理（记录备查）。

## 第 1 轮双评审意见与处理（历史记录）

第 1 轮主审结论【通过（4 条非阻塞提示）】，辅审【驳回 3 个轻量问题】。全部意见的处理记录如下：

### 辅审驳回项（必改，已修订）

1. **G0 示例命令 `\\b` 转义层次错误**（辅审已实测复现 7 国 dry-run 全 0）
   - **字节核查**：design G0 示例命令经逐字节核查为 shell 单引号内单反斜杠 `\b`（正确形式）；**tasks 4.0 描述中为双反斜杠 `\\b`（错误形式，辅审复现全 0 的根因）**。本机实测（BSD grep 2.6.0-FreeBSD）：`grep -Ec '\bUS\b'` 对 `US-01` 命中 1（词边界生效）；`grep -Ec '\\bUS\\b'` 命中 0（ERE 中 `\\` 匹配字面反斜杠，节点名不含反斜杠 → 全 0）。
   - **处理**：tasks 4.0 双反斜杠改单反斜杠 `\b`；design G0 新增「转义层次警示」段、G7 第 2 条补同款警示、G1「YAML 转义注意」补对照句——明确「shell 单引号内写 `\b`（grep 词边界）与 G1 YAML 双引号内的 `\\b`（转义后为 `\b`）是两层不同转义，不得照搬」；tasks 4.0/4.1/4.4 同步补警示。
   - **同源问题一并修正**：G2/spec 的域名校验正则原写 `\\.`（shell 语境下 ERE 会误解释为「字面反斜杠 + 任意字符」，误拒全部合法域名），统一改为单反斜杠 `\.` 并附转义说明。
2. **G0 示例命令统计口径漏展开式节点**：原示例只 grep 内联 JSON `"name"`，漏掉展开式 `- name: ...`（build-config.sh 整段拷贝，两种格式并存，design「统计口径」与 multi-airport spec S3 边界均已确认）。
   - **处理**：design G0 示例命令补第二遍 grep 提取展开式 `- name:` 行（sed 提取，兼容带/不带引号），并注明「coder 亦可自行实现，但必须按两种格式口径并验证提取完整」；design G7、tasks 4.0/4.4、spec「前置验证与部署校验」条款与新增 Scenario「节点名提取覆盖两种格式」同步对齐。
3. **tasks 4.2 的跨仓库同步标注悬空**：design 约束 2 声称「tasks 4.2 显式标注」，但 tasks 4.2 无此标注。
   - **处理**：tasks 4.2 补「若变更 `BROAD_DOMAIN_DENYLIST` 内容，须同步插件 `popup.js` 的 `BROAD_DOMAINS` 常量」标注，design 约束 2 的引用自此成立。

### 主审非阻塞提示（已处理）

- **A. 验证记录标注数据来源 + 模板数据重跑**：tasks 4.0 补「验证记录必须标注数据来源（统计文件路径）；若来源为模板/示例数据（`clash.example.yaml` 等），须在真实部署环境重跑 dry-run 复核」，并将「部署环境 dry-run 复核」写入 DEPLOY.md 上线清单（tasks 4.4 承接）；design G0「产出」段、spec「前置验证与部署校验」条款同步。（第 2 轮辅审问题 ④ 在此基础上进一步升级为分级判定例外条款，见上。）
- **B. 4.0/4.4 节点名提取覆盖展开式**：与辅审问题 2 同源，已并入问题 2 的处理（见上）。
- **C. 工作区基线未提交**：流程提示，不改文档。**备注：实施前建议先提交 multi-airport 工作区基线**，确保本变更 diff 干净、reviewer 范围审计不受未提交改动干扰。
- **D. openspec delta 结构**：proposal 声明 `Modified Capabilities: multi-airport`，但 spec delta 无 MODIFIED Requirements。**处理（二选一已决策）**：选择「从 proposal 移除 Modified Capabilities 声明」。理由：本次 verify.sh 扩展是新增两项国家分流检查（国家组非空 + 7 国 dry-run），已完整归入新能力「前置验证与部署校验」的 ADDED Requirement；multi-airport 既有 4 个 Requirement（发现约定/聚合分组/三级分流/脚本动态发现）无一行为变化（既有 HK/AI 检查与动态发现机制均不动，design G7 定死），不存在可对应修改的既有 Requirement，声明 Modified 反而不准确。

## 任务内前置条件（不阻塞整体开发）

1. 4.1 建组须在 4.0（G0 dry-run）验证记录产出后执行——**分级判定**：真实节点数据下任一国家命中为 0 先补节点或调整正则（design 决策 G0 定死）；模板/示例数据或 build 产物无节点行（`proxies: []`）时产出「待部署环境复核」验证记录、不阻塞 4.1 建组（7 组照建），且禁止以模板命中数为依据放宽正则；
2. 4.3 接入须在 4.1 建组完成后执行；4.2（脚本）/4.4（verify.sh + 文档）可与 4.0/4.1 并行开发。

## 8 维度评估

### 1. 需求完整性与歧义检查 — 通过

数据流（插件导出 → 数据文件 → 脚本 → 规则 → config 接入 → 路由生效）、解析细则（行协议/8 枚举/域名分段校验/超宽排除/重复保留末行/组存在性校验含注释行排除/排序/降级）、优先级语义（国家分流 > AI 默认出口 > 远程规则集 > 国内直连 > HK 兜底）逐条定死。G0 分级判定（真实数据/模板数据/部署复核三级闸门）闭合了「无真实节点数据环境」与「完成定义含建组」的矛盾。spec 4 个 Requirement 共 23 个场景覆盖正常路径与全部降级路径。无歧义开放项。

### 2. 技术方案合理性 — 通过

零新技术栈：复用 `HK-STICKY` 已验证的「`use: [airport]` + filter 地区正则 + exclude-filter」组模式；复用 `gen-rules.sh` 已验证的 awk 两段式解析框架（规避 bash 3.2 多字节 bug）；复用 `verify.sh` 已验证的 awk 单遍降级扫描技术做组存在性校验（补注释行排除）；`rule-provider` 配置与既有 `ai-plugin` 同款。独立脚本、独立 provider、独立 rules 行，与现有 AI 域名链路完全隔离，零回归面。

### 3. 落地可行性 — 通过

- bash 3.2 限制已前置处理：无 `declare -A` → design 定死「重复行保留末行」用 awk 两遍处理纯 ASCII 中间文件，禁止关联数组方案；多字节行不进 bash（两段式框架）。
- grep `\b` 词边界已**本机实测**（BSD grep 2.6.0-FreeBSD）：单反斜杠 `'\bUS\b'` 命中 `US-01`（词边界生效）、不误伤 `BONUS`/`NODE`；「全 0」来自双反斜杠 `'\\bUS\\b'`（ERE 中 `\\` 匹配字面反斜杠），design G0/G7 已补两层转义显式警示，tasks 4.0/4.1/4.4 同步。老环境备选 `[[:<:]]`/`[[:>:]]`（已实测等效）。
- **无真实节点数据环境已闭合**（第 2 轮辅审问题 ④）：零机场场景 `build-config.sh` exit 0 产出 `proxies: []` 的实际情况已核对并写入 design；G0 分级判定例外条款保证 4.0 不阻塞 4.1，部署环境 dry-run 复核（DEPLOY.md 上线清单）为最终闸门；「仍不可得」定义为「build 后无节点行」，三级降级链（`_merged.yaml` → build → `clash*.yaml`）在 G0/G7 两侧口径一致。
- config.yaml 插入位置、引用格式差异（`RULE-SET,ai-plugin-country` 不带目标组参数）均已与真实文件逐字对齐；组存在性校验的注释行排除已引用真实场景（注释态 `# - name: RELAY-POOL`）。
- 节点名提取口径补齐：design G0 示例命令已覆盖内联 JSON 与展开式 `- name:` 两种格式（build-config.sh 整段拷贝使两种格式并存）并剔除注释行；API 模式 dry-run 排除组 key（`select(.value.all == null)`）防组名虚高命中。G7/tasks 4.0/4.4/spec 同步锁定口径。

### 4. 安全性 — 通过

脚本只读数据文件与 `config.yaml`、只写 `rules/ai-plugin-country.yaml`，禁止改写 `config.yaml`（与 `gen-rules.sh` 定位一致）；域名白名单收紧正则（拒绝 `bad..com` 等空段）防注入非法规则；国家代码 8 枚举校验防悬空组；无新增权限面、无网络依赖、无敏感信息落地（节点文件 gitignore 策略不变）。

### 5. 稳定性与可靠性 — 通过

三层防护：生成侧组存在性运行时校验（组缺失告警跳过、注释态组名不污染集合，不产出悬空组规则）→ 缺失文件降级空片段（exit 0，消费无副作用）→ 部署侧 `verify.sh` 国家组非空硬失败 + 7 国 dry-run 持续校验（API 模式排除组 key 防虚高）。脚本全量覆盖写幂等，重复运行产物一致。

### 6. 可测试性 — 通过

tasks 4.0（G0 dry-run 验证记录，分级判定 + 数据来源标注 + 模板数据待复核结论）、4.5（7 项降级验证清单：FR/小写 jp/缺失第二列、`bad..com`、`google.com` 排除、重复保留末行、**注释掉 `DE-STICKY` 方式验证组缺失跳过 + 注释行排除口径**、文件缺失空片段、config 不可解析跳过组校验）、4.4（verify.sh 运行时校验：锚定模式 + API 排除组 key）逐项可执行可判定；端到端验证路径明确（粘贴 → gen → apply → curl 出口地区）。

### 7. 可上线与可运维性 — 通过

部署顺序沿用既有编排（build → gen-country-rules → apply → verify），country 链路以独立脚本/独立 provider 融入，互不干扰现有 ai-plugin 链路；README/DEPLOY 更新部署与维护流程，DEPLOY 上线清单含「部署环境重跑 7 国 dry-run 复核」项（承接 4.0 模板数据重跑要求，并作为最终闸门——命中为 0 时先补节点/调正则或临时移除对应组再上线）；「先建组后放数据」由组存在性运行时校验脚本级守护；国家组空/缺失在 verify.sh 部署时即可发现。

### 8. 实现前疑问点识别 — 无阻塞疑问

design「实现前疑问点」5 项（Q1 正则最终值以 G0 为准、Q2 保留末行实现手段、Q3 文件入库策略、Q4 grep `\b` 可用性、Q5 无真实节点数据环境的 4.0 处置）均已给出定死答案（Q4 已补充本机实测数据与转义层次警示；Q5 由分级判定例外条款覆盖），coder 按 design 执行即可，无「留给 coder 决定」的开放项。

## 阻塞项清单

| 级别 | 状态 | 说明 |
|------|------|------|
| 阻塞开发 | 无 | — |
| 阻塞提测 | 无 | — |
| 阻塞上线 | 无 | 真实节点数据下 4.0 命中为 0 时「补节点/调正则」属任务内前置条件（G0 定死流程），非评审阻塞；模板/示例数据场景由部署环境 dry-run 复核（DEPLOY.md 上线清单）作为最终闸门，命中为 0 时先补节点/调正则或临时移除对应组再上线 |

## 遗留跨仓库一致性项（上线核对清单，code review 检查点）

插件侧 gate-review 明确的三条跨仓库强约束，网关侧 review 时显式核对：

1. **组名公式** `<code>-STICKY` 两侧各自拼接、禁止映射表（design 同类路径对照 + 跨仓库一致性约束 1）；
2. **超宽域名清单** 插件 `BROAD_DOMAINS` 与网关 `BROAD_DOMAIN_DENYLIST` 内容一致（当前均 `google.com`）（约束 2；同步义务已落 tasks 4.2 显式标注）；
3. **域名分段校验语义** 插件 `normalizeDomain` 与 `gen-country-rules.sh` 同款语义，两侧均拒绝 `bad..com`；`gen-rules.sh` 旧正则不纳入（约束 3）。

## 流程备注

- **实施前建议先提交基线**：工作区存在未提交的 multi-airport 改动（第 1 轮主审提示 C），建议 coder 在开始本变更前先提交该基线，保证本变更 diff 干净、reviewer 范围审计不受干扰。
- **无真实节点数据环境提示（第 2 轮辅审问题 ④ 相关）**：当前工作区 `nodes/` 仅模板 example 文件，4.0 验证记录将按例外条款产出「待部署环境复核」结论、4.1 照常建组；真实部署环境首次上线前必须执行 DEPLOY.md 上线清单中的 dry-run 复核，命中为 0 的国家先补节点/调正则或临时移除对应组再上线。

## 修订记录

- 初始版本（2026-11-19）：搬运插件侧三轮评审定稿的决策 5（G0-G7），完成 8 维度初评。结论【可直接进入开发】。待网关侧主审/辅审轮次确认。
- 第 2 轮（2026-11-19）：吸收第 1 轮双评审意见。辅审 3 项驳回全部修订：① tasks 4.0 双反斜杠改单反斜杠并补转义层次警示（design G0/G7 警示段 + G1 对照句，实测数据佐证）；同源修正 G2/spec 域名正则 `\\.` → `\.`；② design G0 示例命令补展开式 `- name:` 提取，G7/tasks 4.0/4.4/spec 同步锁定两种格式口径；③ tasks 4.2 补 `BROAD_DOMAIN_DENYLIST` 与插件 `BROAD_DOMAINS` 跨仓库同步标注。主审 4 条提示：A（数据来源标注 + 模板数据重跑 + DEPLOY 上线清单）已落 tasks 4.0/4.4/design/spec；B 并入②；C 记录为流程备注（实施前先提交基线）；D 选择「从 proposal 移除 Modified Capabilities 声明」（verify.sh 扩展归入新能力「前置验证与部署校验」，multi-airport 既有 Requirement 无变化）。`openspec validate country-routing-gateway` 通过。结论维持【可直接进入开发】。
- 第 3 轮（2026-11-19）：吸收第 2 轮双评审意见。辅审阻塞项 ④（无真实节点数据环境全 0 阻塞建组与完成定义矛盾）→ design 决策 G0「产出」段改写为分级判定例外条款（真实数据命中 0 阻塞建组；模板/示例数据或 build 产物无节点行（`proxies: []`）产出标注来源 + 「待部署环境复核」验证记录、不阻塞 4.1 建组（7 组照建）；禁止以模板命中数放宽正则；部署环境 dry-run 复核为最终闸门），并将「仍不可得」定义为「build 后 `_merged.yaml` 无节点行」（已核对 build-config.sh 零机场 exit 0 分支）；tasks 4.0、spec 两处需求与新增场景、proposal 同步落盘。辅审提示 ⑤ → design G0 示例命令加 `grep -v -E '^[[:space:]]*#'` 注释行过滤，tasks 4.0/spec 同步；⑥ → design G7 本地降级改三级口径与 G0 完全一致 + 「仍不可得」定义，tasks 4.4/spec 同步。主审提示 P1 → design G2 组存在性校验补「解析 `name:` 排除注释行（`^[[:space:]]*#`，真实场景：注释态 `# - name: RELAY-POOL`）」，tasks 4.5 验证项 ① 改为「注释掉 `DE-STICKY`」方式（同时验证注释行排除 + 组缺失检测），spec 补条款与场景；P2 → design G7/tasks 4.4/spec 补「API 模式 dry-run 只取节点名、排除组 key（`select(.value.all == null)` 或等效）」，新增 Scenario「API 模式 dry-run 排除组 key」；P3 轻微不处理（记录备查）。`openspec validate country-routing-gateway` 通过。结论维持【可直接进入开发】。
