# Gate Review: dual-instance-gateway（第 3 轮）

评审人：Architect（架构师）　评审对象：`openspec/changes/dual-instance-gateway/`（proposal / design / specs / tasks）
评审轮次：第 3 轮（第 2 轮主审【驳回：2 阻塞（与辅审同源）+ 5 建议 S1-S5】、辅审【驳回：2 阻塞（与主审同源）+ 问题 3】，全部意见已修订并逐条记录处理，见文末「第 2 轮评审意见处理记录」；第 3 轮主审【重要建议 1 条 + 建议改进 3 条】、辅审【阻塞 1（清单口径出处）+ 非阻塞建议 4 条】，经**用户裁决**：按辅审意见修正后直接进入开发、不再开新一轮双评审，第 3 轮全部意见已一次性吸收，见文末「第 3 轮评审意见处理记录（含用户裁决）」；第 1 轮意见处理记录保留在文末）
结论：【可直接进入开发】

## 流程备注（开工前必读）

1. **固化工作区基线（第 2 轮主审 S1 收紧，必须遵守）**：本工作区含两个已归档变更（multi-airport、country-routing-gateway）的未提交产物。开工前**必须**先把上述两个变更的产物 `git commit` 固化——**不得使用 `git stash`**：stash 不保存未跟踪产物（或恢复时易丢失），未跟踪产物（如 `rules/*.yaml` 等）一旦消失，T1 回退任务将失去删除对象、`git status` 也无法呈现删除态。commit 后使 `git status` 干净，**后续所有回退审查（T1 残留扫描、grep 验收）均以该提交为对照基线**，避免新旧产物混杂导致回退残留无法判定。
2. coder 修改边界以 design「文件范围」表为准；❌ 标记文件出现 diff 即越界。
3. 上线顺序 3 条要求（见维度 7）须在合入说明中复述。

## 结论总览

| 维度 | 结论 | 阻塞项 |
|------|------|--------|
| 1. 需求完整性与歧义 | ✅ 通过 | 无 |
| 2. 技术方案合理性 | ✅ 通过 | 无（第 2 轮 2 项阻塞已修订：orphan 清理、清单口径公式；第 3 轮意见已一次性吸收） |
| 3. 落地可行性 | ✅ 通过 | 无 |
| 4. 安全性 | ✅ 通过 | 无 |
| 5. 稳定性与可靠性 | ✅ 通过 | 无（2 条上线注意事项） |
| 6. 可测试性 | ✅ 通过 | 无 |
| 7. 可上线与可运维性 | ✅ 通过 | 无（3 条上线顺序要求 + 基线固化流程备注） |
| 8. 实现前疑问点识别 | ✅ 已收敛 | 无未决阻塞 |

## 1. 需求完整性与歧义检查

- 用户拍板三点（双实例、AI 域名判断回插件侧、国家分流回退）在 proposal「Why」逐条落实，design 决策 1/3/4/5/6 一一对应，无遗漏。
- 拍板未明说的边界已显式决策并给依据：AI 实例 `sticky-sessions` 策略延续（design 决策 3）、GEN-ROTATE 去留（决策 3 表）、RELAY-POOL 注释态保留（决策 3，注释措辞中性化）、PAC 模板双端口化（决策 5，含「为何不违背拍板」说明）。
- 静态 AI 清单数量口径已统一且**出处准确（第 2 轮阻塞项 + 第 3 轮辅审阻塞 1，已修订）**：**旧内联兜底保留项 10 个 + 插件 `defaultProxyDomains` 独有项 4 个（`coze.com`/`meta.ai`/`oaistatic.com`/`oaiusercontent.com`，已剔除 `google.com` 裸域）+ 旧远程 `Perplexity` 规则集核心站 1 个（`perplexity.ai`，回退保留项）= 15 个**；「与插件同源」表述限定为前 4 个，`perplexity.ai` 出处更正为旧远程 Perplexity 规则集（回退后静态保留），域名集合不变。design 决策 5、tasks 2.4 与 spec 一致引用，无口径漂移。

## 2. 技术方案合理性

- 双服务（非单容器两进程）选型依据充分：官方镜像单进程 entrypoint（`docker-compose.yml` 现状仅挂配置+节点，无自建 entrypoint），两服务零新构件；host 网络下端口互斥由约定保证（7890/9090 vs 7891/9091，与现有 19000 无冲突）。
- **迁移期 10800 过渡监听已改为 mihomo 官方 `listeners` 入站段**（第 1 轮主审阻塞项）：已核实官方 wiki（「入站 → listeners」，`name/type/port/listen` 字段，`type: mixed` 合法）。mihomo 不存在顶层 `ports` 字段（Surge 语法），第 1 轮 design 若按原案落地，过渡监听将被静默忽略、旧插件迁移期断连。design 决策 8、spec 场景、tasks 2.2 已全部改为 `listeners` 段并加「禁止顶层 ports」硬约束；T4.3 新增 10800 可达性检查兜底验证。
- **升级路径已加 orphan 清理（第 2 轮阻塞项，已修订）**：docker compose v2 的 `up -d` 不会删除服务改名后的旧容器（仅警告 orphaned），旧 gateway 容器继续占用 10800/9090 会导致新 AI 实例绑定失败崩溃循环、脚本/管理员 API 误打旧容器。修订：design「上线顺序」第 1 步与 T4.2 升级步骤改为「**先补 `.env` → `docker compose down`（pac 19000 与过渡监听 10800 在 down→up 窗口内各有秒级中断、建议低峰执行）→ `docker compose up -d --remove-orphans`**」，并删除无意义的 `--build`（本 compose 无 build 段）；T4.2 验收新增 grep 校验，T4.3 验证步骤同步 `--remove-orphans` 与残留旧容器警示。**第 3 轮主审重要建议（已修订）**：补 `.env` 前移到 `down` 之前——新版 compose 的 pac env 含 `${AI_GATEWAY_ADDR:?...}` 强校验，`down` 同为 compose 命令、同样做 env 插值，先补 .env 可避免 `down` 因缺变量报错。
- **CLI 全量代理绕美副作用已治理**（第 1 轮辅审阻塞项 B1，第 2 轮 S2/辅审问题 3 再补强）：`claude-code-setup.sh` 的环境变量代理是全量代理（无 PAC），指向 AI 实例 7890 后内网/国内流量会绕道美国出口甚至不可达（7890 无 Private/China/CN 直连兜底）。修订：脚本三种配置方式均导出 `NO_PROXY` 内网段 + 副作用提示，且**大小写双导出**（`NO_PROXY` 与 `no_proxy` 同时输出——Node/Python 系只认小写，curl 系认大写）；提示注明 **CIDR 段仅 curl ≥7.86/libcurl 系工具识别**（Node/Python 系不识别 CIDR，关键内网主机建议同时列出主机名/IP 字面量）；提示补「**国内站点如需直连请自行把域名追加到 NO_PROXY**」。design Risks、README（T4.1）、spec 的 requirement 与 CLI scenario 均显式记录。
- `AI-US-STICKY` filter 聚合复用了已验证模式（HK-STICKY 同构 + country-routing 变更中 US-STICKY 同款正则），且有「住宅节点命名含美国入组」的逃生舱；**exclude-filter 刻意不同于旧 AI-STICKY（不含「中国」）**已写入 design 决策 3 + 两个 spec 的硬约束（美国落地节点常带「中国优化」字样，排除反而误杀），防止 coder 照抄旧组。
- 容器内统一路径 `/root/.config/mihomo/config.yaml`（design 决策 4）使 apply.sh 双实例热加载路径一致，避免了 per-instance 路径参数化，方案收敛性好。
- 全局 PAC 静态 AI 清单（决策 5）填补了「不用插件的员工如何访问 AI」的空白，且不含用户级数据、不含超宽裸域，不违背拍板。**envsubst 硬约束已写入 design 决策 5 与 tasks 2.4（第 2 轮主审 S3，已修订）**：PAC 模板 JS 代码中除 `${GATEWAY_ADDR}`/`${AI_GATEWAY_ADDR}` 两个注入点外不得出现任何 `${...}` 字面量（nginx envsubst 默认替换全部 `${VAR}`，会损坏 PAC 语法），JS 拼接字符串一律用 `+`。
- verify.sh 校验函数的签名已在 design 决策 7 与 tasks 3.3 统一为 `check_instance <label> <api> <gateway> <硬性组判定>`（第 2 轮主审 S4，已修订），消除两处 4 参/3 参不一致导致的实现歧义。

## 3. 落地可行性

- 所有改动均有现成落点：config 拆分（现有 config.yaml 19026 字节 → 两文件）、compose 双服务（现有单服务直接拆分）、脚本改造（reload/apply 现有单实例逻辑循环化，verify 有现成的函数化结构与 API 降级模式可复用）。
- 回退清单（design 决策 6）逐文件逐段列出，处理方式三分类明确，无「恢复原文」类模糊项（所有回退段在重写新配置时天然消失）。第 2 轮补入 `.gitignore` 三处 ai.yaml 清理（白名单行、忽略行、顶部注释字样）。
- 同类路径对照表（design 末尾）覆盖了 AI 域名判定的全部路径与端口引用点（第 2 轮补 `config-ai.yaml` listeners 过渡段、claude-code-setup NO_PROXY、.gitignore ai.yaml 三行），coder 逐条对照即可防漏。
- 运维细节已前置：T2.3/T2.4 验收前置注明先**新建本地 `.env` 并补全变量**（compose `${...:?}` 强校验，第 3 轮主审建议）；升级步骤含 orphan 清理（第 2 轮阻塞项）且补 .env 前移至 down 之前（第 3 轮主审重要建议）；verify.sh 位置参数 2 参 → 4 参的语义变化写入 DEPLOY 升级步骤（T4.2）。

## 4. 安全性

- 双实例后网关仍无鉴权（allow-lan），与单实例时代风险面一致，不引入新暴露面。
- 迁移期 10800 过渡监听的风险已在 design Risks 升级声明：**过渡期内 10800 = 全流量美国出口**（google 裸域等宽泛清单用户、macos 手动代理旧全量用户受影响），且为限期可移除的临时态；README/DEPLOY 显式记录切换指引。
- 静态 AI 清单不含 `google.com` 裸域，避免 PAC 侧过度代理放大面。
- CLI 代理场景新增 `NO_PROXY`/`no_proxy` 大小写双变量内网段豁免，并注明 CIDR 工具兼容性限制，降低「内网流量绕美」暴露面（B1 修订 + 第 2 轮 S2 补强）。
- 无新增凭据/密钥处理面；`AI_GATEWAY_ADDR` 与 `GATEWAY_ADDR` 同为 PAC 地址变量，sanitize 脚本清洗逻辑同款复用。

## 5. 稳定性与可靠性

- 双实例故障隔离是加分项（AI 实例宕机不影响通用流量）。
- reload/apply 的 per-instance 失败汇总（任一失败非零退出 + 继续处理其余实例）保证脚本不因单实例故障而半途中断、也不静默吞错。
- verify.sh 硬性组检查（AI 组非空 / HK 组非空）沿袭现有「空组=流量黑洞」的硬失败语义，仅检查对象随实例拆分。
- **升级窗口可靠性（第 2 轮阻塞项已治理 + 第 3 轮主审建议已修订）**：升级步骤改为「先补 .env → `down` → `up -d --remove-orphans`」，彻底消除旧容器占用 10800/9090 导致新 AI 实例绑定失败、崩溃循环的可靠性隐患；pac 服务 19000 与过渡监听 10800 在 down→up 窗口内各有秒级中断、建议低峰执行，已列为提示项；过渡段对旧插件的承诺措辞由「零窗口」改为「零改动」（down→up 之间 10800 确有秒级中断，不能承诺零窗口）。
- ⚠ **上线注意事项 1（非阻塞）**：`filter` 聚合依赖机场节点命名，若部署环境美国节点命名不含正则关键词（如 `US1`、拼音），AI 组可能为空——verify.sh 硬失败会拦住，属可发现可修复项，design Risks 已列。
- ⚠ **上线注意事项 2（非阻塞）**：AI 实例无国内直连规则是拍板语义（规则只有 MATCH），依赖客户端（插件 PAC / 全局 PAC / NO_PROXY）把非 AI 流量挡在 7890 之外；风险与缓解已写入 design Risks「AI 实例全流量美国出口」与「CLI 环境变量代理绕美副作用」。

## 6. 可测试性

- spec 每个 requirement 均含 ≥1 个 WHEN/THEN scenario，可直接映射为验收用例。**scenario 总数更正（第 2 轮主审 S5，已修订）**：dual-instance-gateway spec 5 个 requirement / **16 个** scenario，multi-airport spec 3 个 requirement / **9 个** scenario，**合计 16 + 9 = 25 个**；country-routing-gateway 与 plugin-domain-sync 为 REMOVED 需求、无 scenario。tasks 每个任务含验收标准（含 grep 反查命令）。
- 第 2 轮修正两处验收误报风险（第 1 轮意见）：① T3.3 回退残留 grep 锚定 `is_country_group|COUNTRY_CODES|COUNTRY_NAMES|COUNTRY_PATTERNS|国家分流`（verify.sh 的 ipinfo 输出行合法含 `.country` 字段，裸 grep `country` 会误报）；② T3.3 新增废弃机制 grep `ai_airport|AI-STICKY|AI-FIXED|10800`（组名/端口全动态发现后不得硬编码）。
- T3.4 验收新增 NO_PROXY 大小写双导出（`NO_PROXY` 与 `no_proxy` 双 grep 命中）、CIDR 工具兼容提示（grep `7.86`）与「追加到 NO_PROXY」指引（grep `追加`）校验（第 2 轮 S2）。
- T4.2 验收新增升级步骤 grep 校验：`docker compose down`、`remove-orphans`、`AI_GATEWAY_ADDR` 均命中（第 2 轮阻塞项）。
- T4.3 端到端验证步骤覆盖两实例出口地区断言（claude.ai → 美国、cloudflare → 香港）+ **过渡期 10800 可达性检查**（验证 listeners 过渡段真实生效）+ **apply.sh 热加载后 10800 复测**（第 3 轮主审建议：mihomo 热更新对 listeners 段支持情况需实测验证，不生效须记录结论与 restart 指引）+ `--remove-orphans` 与残留旧容器警示，是双实例语义与迁移兼容的关键验收。
- 回退类任务（T1）验收用「文件不存在/目录清空」的强断言；配置任务（T2）验收用 grep 负向断言防残留，适合自动化。
- README/DEPLOY 验收的 `10800` 检查口径已明确：仅允许出现在「迁移期/过渡期」说明中，不作为正式入口描述。

## 7. 可上线与可运维性

- 编排顺序简化：gen-rules/gen-country-rules 两步删除后，编排只剩 `build-config.sh → reload-nodes.sh → apply.sh`（reload 已覆盖两实例）。
- 运维心智模型清晰：AI 实例=美国出口、通用实例=香港兜底，端口尾号对齐（7890↔9090、7891↔9091）。
- 上线顺序已写入 design「上线顺序」节，3 条要求（须在合入说明中复述）：
  - **要求 1（第 2 轮阻塞项 + 第 3 轮主审重要建议）**：升级必须**先补 `.env`**（新增 `AI_GATEWAY_ADDR=...:7890`、`GATEWAY_ADDR` 改 `...:7891`；须放在 down 之前——`down` 同为 compose 命令会做 env 插值，缺 `${AI_GATEWAY_ADDR:?...}` 会导致 `down` 本身报错）→ **`docker compose down`**（旧 gateway 容器不显式 down 会继续占用 10800/9090 → 新 AI 实例绑定失败崩溃循环、API 误打旧容器；pac 19000 与过渡监听 10800 在 down→up 窗口内各有秒级中断需知会、建议低峰执行）→ `docker compose up -d --remove-orphans`（不带 `--build`，本 compose 无 build 段）；且必须默认启用 10800 过渡监听（`listeners` 段）后再上线，否则旧插件用户断连。
  - **要求 2**：插件侧变更发布后需跟进小变更移除过渡段。
  - **要求 3**：向用户同步 verify.sh 参数语义变化（2 参 → 4 参，DEPLOY 升级步骤已带说明）。
- 流程备注：开工前必须 `git commit` 固化工作区基线（见本文开头，第 2 轮 S1 收紧为必须 commit），审查基线为该提交。

## 8. 实现前疑问点识别

| 疑问 | 处置 | 状态 |
|------|------|------|
| 插件侧变更何时开工、是否同步改 `defaultProxyDomains` | 本变更仅定死端口约定（7890/7891）供对齐；插件变更单独开、不受阻塞 | 已收敛 |
| `rules/` 目录清空后是否保留空目录 | 删除目录（T1.2 验收明确） | 已收敛 |
| `nodes/ai.yaml`（gitignore 真实文件）由谁删 | 用户手工删除，DEPLOY 文档提示（T4.2 已列入）；`.gitignore` 中 ai.yaml 三处清理纳入 T1.3 | 已收敛 |
| 全局 PAC 用户是否接受静态 AI 清单方案 | design 决策 5 给出「可注释纯通用端口」开关，默认启用双端口 | 已收敛 |
| CLI 用户走 7890 的内网/国内流量绕美问题 | `NO_PROXY`/`no_proxy` 大小写双导出 + CIDR 兼容提示 + 国内站点追加指引 + README 副作用指引（B1 + 第 2 轮 S2 修订） | 已收敛 |
| 过渡期 10800 全流量美国出口的受影响人群 | google 裸域用户、macos 手动代理旧用户，README/DEPLOY 显式记录切换指引（F4 修订） | 已收敛 |
| 升级时旧容器 orphan 占用 10800/9090 | 升级步骤「先 down → 补 .env → up --remove-orphans」+ T4.2 验收校验（第 2 轮阻塞项） | 已收敛 |

## 阻塞项清单

- 阻塞开发：无
- 阻塞提测：无
- 阻塞上线：无（上线顺序 3 条要求见维度 7，须在合入说明中复述；开工前基线固化见流程备注）

---

## 第 3 轮评审意见处理记录（主审 + 辅审，含用户裁决，全部已修订）

**用户裁决**：按辅审意见修正后直接进入开发，不再开新一轮双评审；主审第 3 轮重要建议与建议改进、辅审非阻塞建议一并吸收。本记录为第 3 轮意见的最终处理凭证，结论维持【可直接进入开发】。

| # | 意见来源 | 级别 | 意见摘要 | 处理 | 落点 |
|---|---------|------|---------|------|------|
| 1 | 辅审阻塞 1 | 阻塞开发 | 清单口径出处错误：`perplexity.ai` 不在插件 `defaultProxyDomains` 中（出处应为旧远程 Perplexity 规则集），插件来源实为 4 个 | 三处口径统一为「**旧内联兜底保留项 10 个 + 插件 `defaultProxyDomains` 独有项 4 个（`coze.com`/`meta.ai`/`oaistatic.com`/`oaiusercontent.com`，已剔除 `google.com` 裸域）+ 旧远程 `Perplexity` 规则集核心站 1 个（`perplexity.ai`，回退保留项）= 15 个**」；「与插件同源」表述限定为前 4 个，`perplexity.ai` 标注为回退保留项；域名集合不变，只改出处标注 | design 决策 5、tasks 2.4、spec「全局 PAC 双端口分流」、gate-review 维度 1 |
| 2 | 主审重要建议 | 应修 | 「补 .env」应移到 `docker compose down` 之前：新版 compose 的 pac env 含 `${AI_GATEWAY_ADDR:?...}` 强校验，`down` 也是 compose 命令、同样做 env 插值 | design「上线顺序」第 1 步与 T4.2 升级步骤顺序改为「补 .env → down → up -d --remove-orphans」，并写明理由；gate-review 维度 2/5/7 现状描述同步；第 2 轮记录 #1 追加演进注记 | design 上线顺序、tasks 4.2、gate-review |
| 3 | 主审建议改进 | 应修 | 「零窗口」措辞不准：down→up 之间 10800 有秒级中断，实为「零改动」；down 提示应补 10800 中断说明与低峰建议 | design 决策 8（过渡方案/过渡期语义提醒）与上线顺序第 1 步的「旧插件零窗口平滑过渡/零窗口继续工作/为了旧插件零窗口」全部改为「零改动」，并补「down→up 窗口内 10800 有秒级中断、建议低峰执行」 | design 决策 8、上线顺序 |
| 4 | 主审建议改进 | 应修 | T4.3 应补 apply.sh 热加载后复测 10800 可达（mihomo 热更新对 listeners 段支持情况需验证） | T4.3 步骤补「apply.sh 热加载后复测 `curl -x http://127.0.0.1:10800` 可达」；验收补「若热更新对 listeners 段不生效，必须记录结论与 `docker compose restart gateway-ai` 指引」 | tasks 4.3 步骤/验收 |
| 5 | 主审建议改进 | 应修 | T2.3/T2.4 应显式列「新建本地 .env」为验收前置动作 | T2.3 验收前置改为「先新建本地 `.env`（如无则 `cp .env.example .env`）并补全变量」；T2.4 验收前置同样注明 | tasks 2.3/2.4 |
| 6 | 辅审非阻塞 | 建议 | tasks 2.4 应补 PAC 匹配函数语义：KEYWORD 裸域化后须用 `dnsDomainIs`（裸域名覆盖其全部子域）语义匹配，才能与原 DOMAIN-KEYWORD 覆盖等价 | tasks 2.4 补实现注意：3 条 KEYWORD 裸域化域名（openai.com/anthropic.com/claude.ai）MUST 用 `dnsDomainIs` 语义匹配（host 与裸域相等或以 `.裸域` 结尾），MUST NOT 退化为仅精确匹配主域的 `===` 判断；其余 12 个 suffix 域名维持 dnsDomainIs/等价后缀匹配 | tasks 2.4 |
| 7 | 辅审非阻塞 | 建议 | T3.1 头部注释更新范围补 reload-nodes.sh 第 12 行「docker compose restart gateway」字样（gateway 服务已不存在） | T3.1 内容补「同步更新第 12 行 restart gateway 字样，改为 `docker compose restart gateway-ai gateway-main`」；验收补 grep 校验（命中双实例服务名、无裸 gateway 单实例字样） | tasks 3.1 |
| 8 | 辅审非阻塞 | 建议 | decision 4 注释措辞「可选，见决策 8」与「默认启用」口径不一致 | 改为「默认启用，插件侧端口切换完成后移除（见决策 8）」；tasks 2.2 过渡段措辞同步统一为「插件侧端口切换完成后移除」 | design 决策 4、tasks 2.2 |
| 9 | 辅审非阻塞 | 建议 | 文件范围表缺 `scripts/macos-proxy-manual-off.sh` | 补「❌ 不修改」行（只关闭手动代理设置，与端口无关） | design 文件范围 |

---

## 第 2 轮评审意见处理记录（主审 + 辅审，全部已修订）

| # | 意见来源 | 级别 | 意见摘要 | 处理 | 落点 |
|---|---------|------|---------|------|------|
| 1 | 主审/辅审同源 | 阻塞开发 | 升级命令缺 orphan 清理：docker compose v2 的 `up -d` 不删除服务改名后的旧容器（仅警告），旧容器继续占用 10800/9090 → 新 AI 实例绑定失败崩溃循环、API 误打旧容器 | 上线顺序第 1 步与 DEPLOY 升级步骤改为「先 `docker compose down`（提示 pac 19000 秒级中断）→ 补 .env → `docker compose up -d --remove-orphans`」，删除无意义 `--build`；T4.2 验收加 `docker compose down`/`remove-orphans` grep 校验；T4.3 验证步骤同步 `--remove-orphans` 与残留旧容器警示。（第 3 轮再修订：补 .env 前移到 down 之前，见第 3 轮记录 #2） | design 上线顺序、tasks 4.2/4.3 |
| 2 | 主审/辅审同源 | 阻塞开发 | 清单口径公式算术矛盾：「10 + 5 − 1 = 14 ≠ 15」 | 采用方案 A 修正为「**内联兜底 10 + 插件核心子集 5（已剔除 `google.com` 裸域）= 15**」，design 决策 5 与 tasks 2.4 两处同步 | design 决策 5、tasks 2.4 |
| 3 | 主审 S1 | 应修 | gate-review 流程备注基线固化「stash/commit 二选一」宽松——stash 会让未跟踪产物消失，T1 回退任务失去删除对象 | 流程备注收紧为「必须 `git commit`」并删除 stash 选项，注明 stash 不保存未跟踪产物的危害 | gate-review 流程备注 |
| 4 | 主审 S2 / 辅审问题 3 | 应修 | `claude-code-setup.sh` 仅导出大写 NO_PROXY；CIDR 段（`10.0.0.0/8` 等）仅 curl ≥7.86/libcurl 系识别（Node/Python 系不识别）；缺「国内站点直连追加」指引 | 脚本/提示大小写双导出 `NO_PROXY`+`no_proxy`；README/脚本提示注明 CIDR 工具兼容限制、关键内网主机建议同时列主机名/IP 字面量；提示补「国内站点如需直连请自行把域名追加到 NO_PROXY」；design 决策 7/Risks、tasks 3.4（含验收）/4.1、spec requirement 与 CLI scenario 同步 | design 决策 7/Risks、tasks 3.4/4.1、spec |
| 5 | 主审 S3 | 应修 | PAC 模板 JS 代码不得出现 `${...}` 字面量（nginx envsubst 默认替换全部 `${...}`，会损坏 PAC 语法） | design 决策 5 新增 envsubst 硬约束（除 `${GATEWAY_ADDR}`/`${AI_GATEWAY_ADDR}` 注入点外 JS 一律用 `+` 拼接）；tasks 2.4 新增同名实现注意 | design 决策 5、tasks 2.4 |
| 6 | 主审 S4 | 应修 | design 决策 7（4 参）与 tasks 3.3（3 参）的 `check_instance` 签名表述不一致 | 统一为 design 的 4 参 `check_instance <label> <api> <gateway> <硬性组判定>`，tasks 3.3 对齐并注明 `<label>`/`<硬性组判定>` 语义 | tasks 3.3 |
| 7 | 主审 S5 | 应修 | gate-review 维度 6 scenario 计数错误（「共 18 个」） | 更正为 **25 个**（dual-instance-gateway 16 + multi-airport 9；另两个 REMOVED spec 无 scenario） | gate-review 维度 6 |

---

## 第 1 轮评审意见处理记录（主审 + 辅审，全部已修订）

| # | 意见来源 | 级别 | 意见摘要 | 处理 | 落点 |
|---|---------|------|---------|------|------|
| 1 | 主审 #1 | 阻塞开发 | mihomo 不存在顶层 `ports` 字段，10800 过渡监听会静默失效 | 改为 mihomo 官方 `listeners` 入站段（`name: legacy-10800` / `type: mixed` / `port: 10800` / `listen: 0.0.0.0`，不写 `proxy` 字段，流量走全局 rules 命中 MATCH）；已核实官方 wiki「入站 → listeners」 | design 决策 2/4/8、spec 端口约定与迁移期场景、tasks 2.2（禁止顶层 ports 硬约束）、T4.3 增 10800 可达性检查 |
| 2 | 辅审 B1 | 阻塞开发 | `claude-code-setup.sh` 全量代理指向 AI 实例 7890 的组合副作用（内网/国内流量绕美不可达，旧 10800 有 CN 直连兜底、7890 没有） | 脚本三种配置方式均新增 `NO_PROXY` 内网段导出（localhost/127.0.0.1/`10.0.0.0/8`/`172.16.0.0/12`/`192.168.0.0/16`/常用内网域名）+ 副作用提示；design Risks + README 显式记录副作用与 NO_PROXY 指引；spec 补规范条目 + CLI scenario。第 2 轮 S2 进一步补强（大小写双导出/CIDR 兼容提示/国内站点追加指引） | design 决策 7/Risks、spec「脚本双实例化」、tasks 3.4、T4.1 README |
| 3 | 主审 #2 / 辅审 F1 | 重要 | 静态 AI 清单数量不一致（design 15 个 vs tasks 14 个） | 统一为 **15 个**并显式定义构成口径：旧内联兜底保留项 10 个（3 KEYWORD 裸域化 + 7 SUFFIX）+ 插件 defaultProxyDomains 核心子集 5 个 − `google.com` 裸域。⚠ 该公式表述在第 2 轮被指出算术矛盾（10+5−1=14≠15），已按第 2 轮意见改为「10 + 5（已剔除 `google.com` 裸域）= 15」 | design 决策 5、tasks 2.4 |
| 4 | 主审 #3 / 辅审 F3 | 重要 | RELAY-POOL 注释块 ai.yaml 措辞；reload-nodes.sh 头部注释旧字样（gen-rules 编排步、ai_airport/AI-STICKY） | RELAY-POOL 注释态块改中性「落地节点」描述（不得出现 ai.yaml 字样）；reload-nodes.sh 头部注释更新；均纳入任务验收 | design 决策 3 表/决策 7、tasks 2.1/3.1 |
| 5 | 主审 #4 | 重要 | T3.3 验收 grep `country` 会误报（verify.sh ipinfo 输出含 `.country` 字段） | 回退残留 grep 锚定回退符号：`is_country_group\|COUNTRY_CODES\|COUNTRY_NAMES\|COUNTRY_PATTERNS\|国家分流` | tasks 3.3 验收 |
| 6 | 辅审 F5 | 应修 | 补 grep 验收 `ai_airport\|AI-STICKY\|AI-FIXED\|10800` | T3.3 新增废弃机制残留 grep（verify.sh 全动态发现后不得硬编码旧组名/端口） | tasks 3.3 验收 |
| 7 | 主审 #5 | 重要 | gate-review 补流程备注：开工前固化工作区基线 | 已在流程备注固化；第 2 轮 S1 进一步收紧为「必须 git commit」（stash 会让未跟踪产物消失） | gate-review 流程备注 |
| 8 | 主审 #6 / 辅审 F4 | 重要 | 过渡期 10800 = 全流量美国出口未显式说明（google 裸域、macos 手动代理用户受影响）；过渡段应默认启用 | design 决策 8 补过渡期语义与受影响人群；tasks 2.2 改为「默认启用过渡段；确认无旧插件用户后可注释」；上线顺序/Risks/README/DEPLOY 同步记录 | design 决策 8/上线顺序/Risks、tasks 2.2、T4.1/T4.2 |
| 9 | 主审 #7 | 重要 | DEPLOY 升级步骤未显式列出 `.env` 变更；T2.3 验收未注明先补 .env | DEPLOY 升级步骤显式列「新增 `AI_GATEWAY_ADDR=...:7890`、`GATEWAY_ADDR` 改 7891」；T2.3 验收前置注明先补 .env（compose `${...:?}` 强校验）；第 2 轮进一步补齐 down/orphan 清理 | tasks 2.3/4.2、design 上线顺序 |
| 10 | 主审 #8 | 重要 | DEPLOY 未说明 verify.sh 位置参数语义变化（2 参 → 4 参） | design 决策 7 与 T4.2 DEPLOY 升级步骤均带「旧 2 参调用不兼容」说明 | design 决策 7、tasks 3.3/4.2 |
| 11 | 主审 #9 | 重要 | 新 AI-US-STICKY 的 exclude-filter 刻意不同于旧 AI-STICKY（旧含「中国」，美国节点常带「中国优化」字样，排除反而错），实现时不得照抄 | design 决策 3 加 ⚠ 实现注意（含新旧 exclude-filter 对比）；dual-instance 与 multi-airport 两个 spec 均加 MUST NOT 含「中国」硬约束；tasks 2.2 验收加「exclude-filter 不含中国」 | design 决策 3、spec×2、tasks 2.2 |
| 12 | 主审 #10 | 重要 | design 决策 1 compose 结构注释「决策 6」→「决策 5」笔误 | 已修正 | design 决策 1 |
| 13 | 辅审 F2 | 应修 | `.gitignore` 的 `nodes/ai.yaml` 忽略行与含 ai.yaml 注释未列入回退清单 | design 决策 6 回退清单、文件范围表、同类路径对照表、proposal Impact、tasks 1.3 均补入三处 ai.yaml 清理（白名单行 + 忽略行 + 注释字样） | design 决策 6/文件范围/对照表、proposal、tasks 1.3 |
