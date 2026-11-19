# Design: 双实例网关重构 + 机制回退

## Context

- 仓库：`ai-proxy-gateway`（mihomo/clash.meta 单实例网关，host 网络 + mixed-port `10800` + 管理 API `9090` + nginx PAC 服务 `19000`）。
- 工作区含两个已归档变更的未提交产物：`multi-airport`（多机场合并、AI 手工池 `nodes/ai.yaml`、插件域名同步）与 `country-routing-gateway`（7 国分流组、`ai-domains-country.txt` 数据链）。
- 核心矛盾：网关规则是全局共享状态，插件同步上来的用户级 AI 域名列表全局生效，A 用户的配置影响 B 用户 → 用户隔离无法靠域名同步解决。
- 用户已拍板（不可更改）：双实例（AI 实例 `MATCH→AI-US` + 通用实例 `CN→DIRECT`/`MATCH→HK`）；AI 域名判断回插件侧；country-routing-gateway 全部回退。
- 插件仓库 `chatgpt-block-bypass` 现状：`background.js` 第 4-8 行 `proxyServer = { scheme:'http', host:'10.1.31.132', port:10800 }` 单端口硬编码；插件 PAC 按 `proxyDomains` 选择式代理。插件侧改造单独开变更，本变更只定死端口约定。

## Goals / Non-Goals

**Goals:**

- G1 双 mihomo 实例部署（gateway-ai / gateway-main），共享同一节点池，端口约定固定且互不冲突。
- G2 AI 实例规则收敛为 `MATCH → AI-US-STICKY`（美国节点聚合），通用实例 `CN 直连 + MATCH → HK-STICKY`。
- G3 网关侧彻底移除「用户 AI 域名列表」相关的一切机制（本地规则集、远程 AI 规则集、内联兜底）。
- G4 country-routing-gateway 机制 100% 回退（文件、配置段、脚本检查、文档）。
- G5 脚本（reload/apply/verify/logs 等）适配双实例，默认即覆盖两个实例，管理员操作零新增负担。
- G6 全局 PAC 模板升级为双端口分流，普通员工（非插件用户）仍可访问 AI 站。

**Non-Goals:**

- 不改插件仓库（`chatgpt-block-bypass` 的 PAC/端口改造单独开变更）。
- 不引入 TUN 透明代理、不增加认证/租户体系。
- 不改变机场合并算法（`build-config.sh` 保持原样）。
- 不实现「网关按来源 IP 区分用户」的任何变体方案（已被用户否决的方向）。

---

## 决策

### 决策 1：双实例部署形态 —— 推荐 docker-compose 两个独立服务（gateway-ai / gateway-main）

**推荐**：`docker-compose.yml` 定义两个 mihomo 服务，**否决**「单容器两进程」。

理由：

1. mihomo 官方镜像 `metacubex/mihomo:latest` 是单进程设计（entrypoint 直接启动 mihomo）。单容器两进程必须自造 supervisor/s6 entrypoint 或嵌套 shell，维护面与排障成本高，得不偿失。
2. **故障隔离**：AI 实例 reload/重启不影响通用实例（反之亦然），`docker compose restart gateway-ai` 可单独执行。
3. **日志/操作正交**：`docker compose logs gateway-ai` / `gateway-main` 天然分离；现有 `logs.sh` 的服务参数直接复用。
4. host 网络模式下两容器共享宿主机网络栈，端口各自独立（AI `7890/9090`、通用 `7891/9091`），无端口映射冲突；单容器两进程同样需要两个端口，双服务方案无任何额外代价。

**共享节点池**：两个服务都挂载 `./nodes:/root/.config/mihomo/nodes:ro`，`_merged.yaml` 由 `build-config.sh` 生成一次、两实例共同消费。`rules/` 目录在回退后清空删除，不再挂载。

**compose 关键结构**（两个 mihomo 服务各自把独立配置文件映射到**同一个容器内路径** `/root/.config/mihomo/config.yaml`，apply.sh 热加载两个实例时路径统一，见决策 7）：

```yaml
services:
  gateway-ai:
    image: metacubex/mihomo:latest
    container_name: ai-proxy-gateway-ai
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config-ai.yaml:/root/.config/mihomo/config.yaml:ro
      - ./nodes:/root/.config/mihomo/nodes:ro
  gateway-main:
    image: metacubex/mihomo:latest
    container_name: ai-proxy-gateway-main
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config-main.yaml:/root/.config/mihomo/config.yaml:ro
      - ./nodes:/root/.config/mihomo/nodes:ro
  pac: # nginx PAC 服务，见决策 5（GATEWAY_ADDR + AI_GATEWAY_ADDR）
```

### 决策 2：端口约定（定死，插件侧变更以此对齐）

| 用途 | 端口 | 说明 |
|------|------|------|
| AI 出口实例 mixed-port（http+socks5） | `7890` | 插件 PAC 中 AI 域名指向它；CLI（claude-code-setup.sh）默认指向它 |
| 通用出口实例 mixed-port（http+socks5） | `7891` | 全局 PAC 兜底、手动代理脚本默认指向它 |
| AI 实例管理 API（external-controller） | `127.0.0.1:9090` | 仅本机；reload/apply/verify 用 |
| 通用实例管理 API | `127.0.0.1:9091` | 仅本机 |
| PAC 文件服务 | `19000`（不变） | nginx，PAC 内部自行双端口分流 |
| 旧单实例端口 | `10800` **弃用** | 迁移过渡见决策 8（AI 实例以 mihomo `listeners` 段额外监听，**不是**顶层 `ports` 字段——mihomo 无此字段，见决策 8 说明） |

规则：**mixed-port 与 external-controller 的尾号对齐（7890↔9090、7891↔9091），好记且脚本常量一致**。与现有 `19000` 无冲突；`7890/7891/9090/9091` 均未在仓库出现（现只有 10800/9090/19000，9090 从单实例挪给 AI 实例）。

### 决策 3：AI-US 组节点来源 —— 推荐 filter 美国正则自动聚合（废弃 ai.yaml 手工池）

**推荐**：`AI-US-STICKY` 用 `use: [airport]` + 美国正则 `filter` 跨机场自动聚合，**否决**继续使用 `ai_airport`（`nodes/ai.yaml` 手工池）。

理由：

1. 机场美国节点命名普遍带「美国」（如用户例证 `IX精品专线-美国01-...`），正则 `(?i)(美国|United ?States|America|\bUS\b|\bUSA\b)` 可稳定命中；该正则与 country-routing-gateway 中 `US-STICKY` 已验证的同款正则一致。
2. 手工池要求用户自己持续维护「哪些节点给 AI 用」；多机场场景下每次机场换节点都要手工同步，而「AI 组=美国节点」的用户语义下 filter 聚合天然覆盖机场节点增删（`reload-nodes.sh` 后自动生效）。
3. filter 聚合是 `HK-STICKY` 已运行验证的成熟模式，AI 实例复用同款组结构 + 同款 `exclude-filter`，零新概念。
   - ⚠ **实现注意（刻意不同，不得照抄旧 AI-STICKY）**：旧 `AI-STICKY` 的 exclude-filter 是 `(?i)(中国|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅|expire|traffic)`，**含「中国」**；新 `AI-US-STICKY` 沿用 `HK-STICKY` 同款（**不含「中国」**）。这是刻意的：美国落地节点常带「中国优化/回国优化」字样，若像旧 AI-STICKY 那样排除「中国」关键词，会把大量目标美国节点误杀。实现时以本 design 决策 3 的组定义为唯一基准，**不得**从旧 config.yaml 的 AI-STICKY 复制 exclude-filter。
4. **住宅节点逃生舱仍然存在**：若未来要指定「美国住宅出口」，把住宅节点命名为含「美国」（如 `美国-住宅-01`）放入任意 `clash-<id>.yaml`（或新建 `clash-ai.yaml`），经 `build-config.sh` 合并进 `_merged.yaml` 后同样被 AI-US-STICKY 聚合——**手工池机制彻底不需要**。

`config-ai.yaml` 的组定义（与 HK-STICKY 同模式，仅 filter 换美国正则）：

```yaml
proxy-groups:
  - name: AI-US-STICKY
    type: load-balance
    strategy: sticky-sessions
    use: [airport]
    filter: "(?i)(美国|United ?States|America|\\bUS\\b|\\bUSA\\b)"
    exclude-filter: "(?i)(禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅)"
    url: https://www.gstatic.com/generate_204
    interval: 60
    lazy: true
```

策略延续 `sticky-sessions`：多用户各自出口 IP + 会话内稳定，防「同一 IP 多账号登录」风控（原 AI-STICKY 的卖点，双实例下语义不变）。

**通用实例组去留（设计要点 2）**：

| 组 | 去留 | 理由 |
|----|------|------|
| `HK-STICKY` | ✅ 保留（config-main） | 通用实例默认出口，用户拍板指定 |
| `GEN-ROTATE` | ✅ 保留（config-main） | 香港轮询备胎组，README「可调开关」语义延续，成本一个组定义 |
| `AI-STICKY` / `AI-FIXED` | ❌ 删除 | AI 出口职责移交 AI 实例；手工池机制废弃 |
| 7 国组 | ❌ 删除 | country-routing-gateway 回退 |
| `RELAY-POOL` + `relay` provider | ✅ 保留（config-main 注释态） | 链式代理可选能力，香港节点可能需中转，删除无收益；⚠ 注释块内原文引用 `nodes/ai.yaml` 的「落地节点写 dialer-proxy」示例，落地时措辞改为中性描述（「在机场节点的落地节点上写 dialer-proxy: "RELAY-POOL"」），不得再出现 ai.yaml 字样 |

### 决策 4：config 组织 —— 拆成对称的 config-main.yaml + config-ai.yaml，删除 config.yaml

**推荐**：`config.yaml` → `config-main.yaml` + `config-ai.yaml` 两个平级文件，旧 `config.yaml` 删除。

理由：① 双实例等地位，文件名即实例语义，杜绝「config.yaml 到底是哪个实例」的歧义；② compose 挂载一一对应（两文件都映射到容器内 `/root/.config/mihomo/config.yaml`，`apply.sh` 对两实例 PUT 同一路径）；③ 单实例时代遗留的 `config.yaml` 若保留为主配置，git diff 上会出现「config.yaml 与 config-ai.yaml 职责不清」的长期认知负担。

**config-ai.yaml 完整形态**（用户拍板：规则只有 `MATCH → AI-US 组`）：

```yaml
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

proxy-providers:
  airport:          # 与通用实例完全相同的节点池（共享 nodes/_merged.yaml）
    type: file
    path: ./nodes/_merged.yaml
    health-check: { enable: true, url: https://www.gstatic.com/generate_204, interval: 180 }

proxy-groups:
  - name: AI-US-STICKY   # 见决策 3

rules:
  - MATCH,AI-US-STICKY

# ── 迁移期兼容（默认启用，插件侧端口切换完成后移除，见决策 8）──────
# 旧插件 PAC 硬编码 10800；用 mihomo 官方 listeners 入站段额外监听，
# 流量进入全局 rules 命中 MATCH → AI-US-STICKY（美国出口），语义与 AI 实例一致。
# ⚠ 必须用 listeners 段：mihomo 不存在顶层 ports 字段（那是 Surge 语法，
#   写了会被忽略、过渡监听静默失效）。插件侧端口切换完成后的下一变更移除本段。
listeners:
  - name: legacy-10800
    type: mixed
    port: 10800
    listen: 0.0.0.0
```

**无任何 rule-providers、无内联域名规则**：AI 域名判定由客户端 PAC 完成，发到 7890 的流量默认全是 AI 域名（插件 PAC 已过滤），一律美国出口。防御性的 `Private,DIRECT` 不加入——插件 PAC 已处理内网直连，遵守拍板「规则只有 MATCH」。（迁移期 10800 过渡监听见决策 8。）

**config-main.yaml 完整形态**：

```yaml
mixed-port: 7891
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
external-controller: 127.0.0.1:9091

proxy-providers:
  airport:    # 同上，共享 _merged.yaml
  # relay:  # 注释态保留（链式代理可选）

rule-providers:
  China:    # geosite cn.mrs（CN 直连数据源，保留）
  Private:  # private.mrs（内网直连，保留）
  Block:    # Block.list（广告拦截，保留）
  # AI / ChatGPT / Claude / Gemini / Copilot / Grok / Perplexity → 全部删除（AI 域名判断回客户端）

proxy-groups:
  - name: HK-STICKY    # 默认出口，同现有定义
  - name: GEN-ROTATE   # 备用轮询组，同现有定义
  # - name: RELAY-POOL # 注释态保留

rules:
  - RULE-SET,Private,DIRECT
  - RULE-SET,Block,REJECT
  - RULE-SET,China,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,HK-STICKY
```

**远程 rule-providers 保留原则**：通用实例只保留与「通用流量」相关的三个数据源（China/Private/Block）；7 个 AI 远程规则集删除——AI 域名不会（也不应）到达通用实例，留着只会让通用实例在拉取失败时产生无意义告警。

### 决策 5：全局 PAC 双端口分流（www/proxy.pac.template）

- PAC 模板升级为**双端口选择式**：内网/本机 → DIRECT；**静态核心 AI 域名清单** → `PROXY ${AI_GATEWAY_ADDR}; DIRECT`；其余 → `PROXY ${GATEWAY_ADDR}; DIRECT`。
- 新增环境变量 `AI_GATEWAY_ADDR`（host:7890），`GATEWAY_ADDR` 改为 host:7891；`www/15-sanitize-gateway.envsh` 对两个变量做同样的「剥 http:// 前缀、去结尾斜杠」清洗；`.env.example` 同步两个变量。
- **静态 AI 域名清单**（写死在 PAC 模板内，非网关侧规则、非用户级数据）：`openai.com`、`chatgpt.com`、`claude.ai`、`anthropic.com`、`gemini.google.com`、`aistudio.google.com`、`x.ai`、`grok.com`、`cursor.com`、`cursor.sh`、`coze.com`、`meta.ai`、`oaistatic.com`、`oaiusercontent.com`、`perplexity.ai`——**共 15 个**。
  - **清单构成口径**（tasks 2.4 与 spec 均以此为准，防止数量口径漂移）：**旧内联兜底保留项 10 个**（3 条 `DOMAIN-KEYWORD` openai/anthropic/claude 裸域化为 `openai.com`/`anthropic.com`/`claude.ai` + 7 条 `DOMAIN-SUFFIX`：`chatgpt.com`/`cursor.com`/`cursor.sh`/`x.ai`/`grok.com`/`gemini.google.com`/`aistudio.google.com`）**+ 插件 `defaultProxyDomains` 独有项 4 个**（`coze.com`/`meta.ai`/`oaistatic.com`/`oaiusercontent.com`，**已剔除 `google.com` 裸域**——超宽，不纳入）**+ 旧远程 `Perplexity` 规则集核心站 1 个**（`perplexity.ai`，该规则集随回退删除后静态保留）= **15 个**。**「与插件同源」表述限定为前 4 个**（插件 `background.js` 的 `defaultProxyDomains`，列为本变更的跨仓库一致性检查项，插件侧默认清单变更时本模板需同步）；`perplexity.ai` 标注为**回退保留项**（旧远程 Perplexity 规则集删除后的静态保留站，出处不是插件默认清单）。
- 不纳入 `google.com` 裸域（超宽，覆盖整个 Google 生态），与 gen-rules.sh 曾有的 BROAD_DOMAIN_DENYLIST 口径一致。
- **为何不违背拍板**：拍板要求「网关侧不再需要知道任何用户的 AI 域名列表」——本清单是公开 AI 站静态清单、随仓库分发，不含任何用户个人配置；它服务于「不用插件、只用全局 PAC」的员工路径。若用户认为全局 PAC 也应完全零域名，可把模板中 AI 域名段注释掉（纯通用端口），design 保留该开关。
- ⚠ **envsubst 硬约束（第 2 轮主审 S3，已修订）**：PAC 模板的 JS 代码中**除 `${GATEWAY_ADDR}` 与 `${AI_GATEWAY_ADDR}` 两个注入点外，不得出现任何 `${...}` 字面量**——nginx 官方 entrypoint 的 envsubst 默认替换模板内全部 `${VAR}` 语法，JS 模板字符串（如 `` `${host}` ``）会被 envsubst 误替换为空、损坏 PAC 语法；JS 内需拼接字符串处一律用 `+` 连接。tasks 2.4 带同名实现注意与渲染验收。

### 决策 6：回退清单（删除文件 / 删配置段 / 恢复原文）

| 文件/位置 | 处理方式 | 具体内容 |
|-----------|---------|---------|
| `nodes/ai-domains.txt` | 删除文件 | AI 域名同步数据源 |
| `scripts/gen-rules.sh` | 删除文件 | AI 域名规则生成脚本 |
| `rules/ai-plugin.yaml` | 删除文件 | gen-rules.sh 产物 |
| `config.yaml` → 新配置 | 删配置段 | `rule-providers.ai-plugin`（type: file / classical / text）+ `rules` 的 `RULE-SET,ai-plugin,AI-STICKY` |
| 新配置 | 删配置段 | 内联 AI 兜底 10 条：`DOMAIN-KEYWORD,openai/anthropic/claude`、`DOMAIN-SUFFIX,chatgpt.com/cursor.com/cursor.sh/x.ai/grok.com/gemini.google.com/aistudio.google.com`（均 → AI-STICKY） |
| 新配置 | 删配置段 | 远程 AI 规则集 7 个：`AI`/`ChatGPT`/`Claude`/`Gemini`/`Copilot`/`Grok`/`Perplexity` |
| `scripts/gen-country-rules.sh` | 删除文件 | 国家分流规则生成脚本 |
| `nodes/ai-domains-country.txt` | 删除文件 | 国家分流数据源 |
| `rules/ai-plugin-country.yaml` | 删除文件 | gen-country-rules.sh 产物 |
| 新配置 | 删配置段 | 7 国组 `JP/US/SG/TW/KR/GB/DE-STICKY` |
| 新配置 | 删配置段 | `rule-providers.ai-plugin-country` + `rules` 的 `RULE-SET,ai-plugin-country` |
| `nodes/ai.example.yaml` | 删除文件 | 手工池机制废弃（住宅节点改走机场文件聚合，见决策 3） |
| `nodes/ai.yaml` | 用户手工删除 | gitignore 内的真实文件，仓库无此文件，文档提示用户删除 |
| `.gitignore` | 删行 + 改注释 | ① 删 `!nodes/ai.example.yaml` 白名单行（保留 `!nodes/clash.example.yaml`）；② 删 `nodes/ai.yaml` 忽略行（`nodes/*.yaml` 通配已覆盖，该行本就冗余）；③ 顶部注释「nodes/*.yaml 已覆盖：clash.yaml、clash-<id>.yaml（多机场）、ai.yaml、」中的 `ai.yaml` 字样一并删除（含 ai.yaml 的注释文字属 T1.3 范围） |
| `scripts/verify.sh` | 删代码段 | `is_country_group`、国家组 hard fail 分支、2b 节（7 国 dry-run 全部，含 `extract_proxy_names`、`COUNTRY_*` 数组、三级降级数据源逻辑）、结尾国家组提示行 |
| `README.md` | 删文档段 | 5b 国家分流整节、7 国组名表、分组策略中国家组条目、插件域名规则集说明、目录结构中 ai-domains*/gen-*.sh/ai-plugin*.yaml 条目 |
| `DEPLOY.md` | 删文档段 | 国家分流接入/维护/FAQ 段、gen-rules 编排步（2/2b）、7 国 dry-run 复核段、国家组相关验证/排错条目 |

**处理方式三类**：`删除文件`（git rm）、`删配置段`（在拆分出的新配置中不出现该段）、`删代码段/删文档段`（编辑保留文件时移除对应段落）。`config.yaml` 整体按「删除文件 + 新增两个新文件」处理，其内容回退通过**新文件不携带回退段**实现，不做「先回退后拆分」两步。

### 决策 7：脚本双实例改造方案

**实例 API 端口的知晓方式（定死）**：脚本内常量默认值 + 环境变量/位置参数覆盖。所有脚本共享同一约定：

```bash
AI_API_DEFAULT=http://127.0.0.1:9090
MAIN_API_DEFAULT=http://127.0.0.1:9091
```

| 脚本 | 改造 | 说明 |
|------|------|------|
| `build-config.sh` | ❌ 不修改 | 合并算法与实例数无关；`_merged.yaml` 两实例共享 |
| `reload-nodes.sh` | ✅ 双实例循环 | 用法 `./scripts/reload-nodes.sh [API...]`：无参 → 默认对两个实例执行；传参 → 只对给定 API 执行（向后兼容单实例场景）。`_merged.yaml` 时效校验只做一次；per-instance：API 可达性探测（失败记录并继续下一实例）→ provider 动态发现+reload → 即时健康检查 → 组校验打印；任一实例 provider 重载失败 → 汇总非零退出。结尾提示改为 `docker compose restart gateway-ai gateway-main`。⚠ **头部注释同步更新**：删「去硬编码 ai_airport / AI-FIXED / GEN-ROTATE / AI-STICKY 固定名单」字样与「编排顺序 build-config.sh → gen-rules.sh → reload-nodes.sh → apply.sh」（gen-rules.sh 已随回退删除），改为双实例语义说明（无参=双实例、默认 API 端口 9090/9091） |
| `apply.sh` | ✅ 双实例循环 | 无参默认双实例；容器内路径统一 `/root/.config/mihomo/config.yaml`（决策 4 的挂载设计保证）；逐实例打印结果，任一失败非零退出 |
| `verify.sh` | ✅ 双实例校验 + 回退 | 参数 `./scripts/verify.sh [AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]`，默认 `127.0.0.1:9090` / `127.0.0.1:9091` / `127.0.0.1:7890` / `127.0.0.1:7891`。⚠ **位置参数语义变化：现行为 2 参（`[API地址] [网关host:port]`），改造后为 4 参（AI API / 通用 API / AI 网关 / 通用网关），旧 2 参调用不兼容**——DEPLOY 升级说明必须注明（见 T4.2）。校验函数化 `check_instance <label> <api> <gateway> <硬性组判定>`：AI 实例硬性检查「组名含 AI 的组非空」（锚定 AI-US-STICKY 语义）+ 出口连通（ipinfo + claude/chatgpt `cdn-cgi/trace`，可连通即通过、loc 参考）；通用实例硬性检查「组名含 HK/香港 的组非空」+ 默认出口连通。本地扫描降级模式分别扫 `config-ai.yaml` / `config-main.yaml`。删除国家组检查与 7 国 dry-run（决策 6） |
| `logs.sh` | ✅ 小改 | `SERVICE` 默认值 `gateway` → `gateway-main`；用法注释补 `gateway-ai` |
| `claude-code-setup.sh` | ✅ 端口常量 + NO_PROXY | 默认 `http://gateway.corp.example.com:7890`（AI 实例——CLI 流量以 AI 为主）；注释说明双端口（AI 7890 / 通用 7891）。⚠ **新增 `NO_PROXY` 内网段导出与提示**（localhost、127.0.0.1、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 及常用内网域名），并在提示文案中说明「CLI 环境变量代理是全量代理（无 PAC），走 7890 时内网/国内站点会绕道美国出口」。⚠ **大小写双导出（第 2 轮主审 S2/辅审问题 3，已修订）**：`NO_PROXY` 与 `no_proxy` 同时输出（Node/Python 等工具只认小写，curl 系认大写，双写全覆盖）。⚠ **提示注明 CIDR 限制**：`10.0.0.0/8` 等 CIDR 段仅 curl ≥7.86 / libcurl 系工具识别，Node/Python 系不识别 CIDR——关键内网主机建议同时列出主机名/IP 字面量。⚠ **提示补「国内站点如需直连，请自行把域名追加到 NO_PROXY」**。副作用与指引同步写入 README（见 Risks 与 T4.1） |
| `macos-proxy-manual-on.sh` | ✅ 端口常量 | 默认 PORT `10800` → `7891`（通用实例）；注释更新 |
| `macos-proxy-on.sh` / `macos-proxy-off.sh` | ❌ 不修改 | 只引用 PAC URL（19000 不变），PAC 内部自行分流 |
| `windows-proxy-on.ps1` / `windows-proxy-off.ps1` | ❌ 不修改 | 同上 |
| `gen-rules.sh` / `gen-country-rules.sh` | ✅ 删除 | 回退 |

### 决策 8：迁移过渡（10800）

- 旧插件硬编码 `host:10800`（background.js 第 4-8 行）。插件侧变更与本变更存在上线时序差。
- ⚠ **语法硬约束（第 1 轮主审阻塞项，已修订）**：mihomo **不存在顶层 `ports` 字段**——`ports` 是 Surge 语法，写进 mihomo 配置会被静默忽略，过渡监听将不生效。过渡监听必须用 mihomo 官方 **`listeners` 入站监听段**（官方 wiki「入站 → listeners」，支持 `name/type/port/listen`，`type: mixed` 为 http+socks5 混合）。
- **过渡方案（默认启用）**：`config-ai.yaml` 用 `listeners` 段额外监听 `10800`（mixed 协议），listener 不写 `proxy` 字段——流量进入全局 `rules`，命中唯一规则 `MATCH → AI-US-STICKY`，与 AI 实例主端口 7890 语义完全一致，**旧插件零改动平滑过渡**（`docker compose down → up -d` 的升级窗口内 10800 有秒级中断、建议低峰执行，见「上线顺序」）：
  ```yaml
  # 迁移期兼容：旧插件 PAC 硬编码 10800，切换完成后的下一变更移除本段
  listeners:
    - name: legacy-10800
      type: mixed
      port: 10800
      listen: 0.0.0.0
  ```
- ⚠ **过渡期语义提醒（第 1 轮评审 F4，已修订）**：10800 挂在 AI 实例上，**过渡期内 10800 = 全流量美国出口**——凡到达 10800 的流量（不止 AI 域名）一律命中 `MATCH → AI-US-STICKY` 走美国节点。受影响人群：① 旧插件用户中把 `google.com` 裸域等宽泛域名配进个人清单的用户（这些域名的流量会全部走美国）；② `macos-proxy-manual-on.sh` 的旧用户（该脚本旧默认端口 10800，是全量系统代理——本变更已将其默认改 7891，但已打开的系统代理设置需用户手动切换）。缓解：过渡段默认启用是为了旧插件零改动（升级窗口内 10800 有秒级中断、建议低峰执行），插件侧端口切换完成后立即在小变更中移除；README/DEPLOY 显式记录该语义与切换指引。
- 插件侧变更完成（proxyServer 双端口化 + PAC 按用户配置分流）后，在后续小变更中移除该 `listeners` 段。
- 10800 挂在 AI 实例而非通用实例的原因：旧插件的流量本来就是「用户 AI 域名清单」，落点必须是美国出口。

### 同类路径对照表（防遗漏——AI 域名判定与端口引用的全部同类路径）

| 路径/位置 | 处理 | 备注 |
|----------|------|------|
| `rule-providers.ai-plugin`（本地文件规则集） | ✅ 删除（回退） | AI 域名同步 |
| `rules` 的 `RULE-SET,ai-plugin,AI-STICKY` | ✅ 删除（回退） | 同上 |
| `rules` 内联 AI 兜底 10 条 | ✅ 删除 | AI 域名判断回插件侧 |
| `rule-providers` AI 远程 7 个（AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity） | ✅ 删除 | 两实例均不再需要 |
| `rule-providers.ai-plugin-country` + `RULE-SET,ai-plugin-country` | ✅ 删除（回退） | 国家分流 |
| `proxy-groups` 7 国组 + AI-STICKY/AI-FIXED + ai_airport provider | ✅ 删除（回退/废弃） | 见决策 3/4 |
| 插件 PAC（chatgpt-block-bypass background.js proxyServer） | ❌ 本变更不修改（单独变更） | 端口约定对齐 7890/7891 |
| `www/proxy.pac.template` 全局 PAC | ✅ 修改为双端口 + 静态 AI 清单 | 决策 5 |
| `scripts/claude-code-setup.sh` 默认代理端口 | ✅ 改 7890（AI 实例）+ 新增 NO_PROXY 内网段导出 | CLI 场景（全量代理副作用见决策 7/Risks） |
| `scripts/macos-proxy-manual-on.sh` 默认代理端口 | ✅ 改 7891（通用实例） | 全局流量 |
| `config-ai.yaml` 迁移期 10800 过渡监听 | ✅ 新增（mihomo `listeners` 段，非顶层 `ports`——mihomo 无此字段） | 决策 8，插件切换后移除 |
| `.gitignore` ai.yaml 相关行 | ✅ 删除（`nodes/ai.yaml` 忽略行、`!nodes/ai.example.yaml` 白名单行、注释中 ai.yaml 字样） | 手工池废弃（F2） |
| `docker-compose.yml` GATEWAY_ADDR（pac 服务 env） | ✅ 改 7891 + 新增 AI_GATEWAY_ADDR | 决策 5 |
| `.env.example` GATEWAY_ADDR | ✅ 改 7891 + 新增 AI_GATEWAY_ADDR | 决策 5 |

**正确基准（不得修改）**：`HK-STICKY` 的 filter/exclude-filter 正则与组结构（AI-US-STICKY 复刻它，只换美国正则）；`build-config.sh` 全部逻辑；`China/Private/Block` 三个 rule-providers 的 URL 与格式。

---

## 文件范围

| 文件路径 | 修改类型 | 说明 |
|---------|---------|------|
| `config.yaml` | 删除 | 拆分为下面两个新文件 |
| `config-main.yaml` | 新增 | 通用实例：CN 直连 + MATCH→HK-STICKY；HK-STICKY/GEN-ROTATE 组；China/Private/Block 规则集；relay/RELAY-POOL 注释态保留 |
| `config-ai.yaml` | 新增 | AI 实例：MATCH→AI-US-STICKY（美国 filter）；airport provider；迁移期 10800 `listeners` 过渡段（默认启用，见决策 8） |
| `docker-compose.yml` | 修改 | gateway → gateway-ai + gateway-main 双服务；pac 服务 env 增 AI_GATEWAY_ADDR |
| `.env.example` | 修改 | GATEWAY_ADDR 改 7891、新增 AI_GATEWAY_ADDR=...:7890 |
| `www/proxy.pac.template` | 修改 | 双端口分流 PAC（静态 AI 清单 → AI 端口，其余 → 通用端口） |
| `www/15-sanitize-gateway.envsh` | 修改 | 对 GATEWAY_ADDR 与 AI_GATEWAY_ADDR 双变量清洗 |
| `scripts/reload-nodes.sh` | 修改 | 双实例循环 + 端口常量 + 头部注释更新（删 ai_airport/AI-STICKY/gen-rules 字样） |
| `scripts/apply.sh` | 修改 | 双实例循环 + 端口常量 |
| `scripts/verify.sh` | 修改 | 双实例校验；删除国家组检查与 7 国 dry-run |
| `scripts/logs.sh` | 修改 | SERVICE 默认 gateway-main |
| `scripts/claude-code-setup.sh` | 修改 | 默认端口 7890（AI 实例）+ 新增 NO_PROXY 内网段导出与提示 |
| `scripts/macos-proxy-manual-on.sh` | 修改 | 默认端口 7891（通用实例） |
| `scripts/macos-proxy-manual-off.sh` | ❌ 不修改 | 只关闭手动代理设置，与端口无关 |
| `scripts/gen-rules.sh` | 删除 | AI 域名同步回退 |
| `scripts/gen-country-rules.sh` | 删除 | 国家分流回退 |
| `nodes/ai-domains.txt` | 删除 | AI 域名同步回退 |
| `nodes/ai-domains-country.txt` | 删除 | 国家分流回退 |
| `nodes/ai.example.yaml` | 删除 | 手工池机制废弃 |
| `rules/ai-plugin.yaml` | 删除 | 回退（rules/ 目录清空） |
| `rules/ai-plugin-country.yaml` | 删除 | 回退（rules/ 目录清空） |
| `.gitignore` | 修改 | 删 `!nodes/ai.example.yaml` 白名单行、`nodes/ai.yaml` 忽略行；注释中 ai.yaml 字样清理 |
| `README.md` | 修改 | 双实例架构重写；删国家分流/域名同步章节 |
| `DEPLOY.md` | 修改 | 双实例部署流程重写；删国家分流/域名同步章节 |
| `scripts/build-config.sh` | ❌ 不修改 | 合并算法与实例数无关，`_merged.yaml` 两实例共享 |
| `nodes/clash.example.yaml` | ❌ 不修改 | 机场格式示例仍有效 |
| `nodes/_merged.yaml` | ❌ 不修改 | 脚本产物（gitignore） |
| `www/nginx.conf` | ❌ 不修改 | PAC 服务不变 |
| `scripts/macos-proxy-on.sh` | ❌ 不修改 | 只引用 PAC URL（19000 不变） |
| `scripts/macos-proxy-off.sh` | ❌ 不修改 | 同上 |
| `scripts/windows-proxy-on.ps1` | ❌ 不修改 | 同上 |
| `scripts/windows-proxy-off.ps1` | ❌ 不修改 | 同上 |
| `openspec/` | ❌ 不修改 | 由 architect 维护 |

> coder 修改边界：只允许改上表「修改/新增/删除」行；❌ 行出现 diff 即为越界（reviewer 审计基准）。

---

## 上线顺序（与插件变更的时序配合）

1. 本变更合入 → **先补 `.env`**（DEPLOY 升级步骤显式列出，见 T4.2）：新增 `AI_GATEWAY_ADDR=...:7890`、`GATEWAY_ADDR` 由 `...:10800` 改 `...:7891`——**必须放在 `docker compose down` 之前**：新版 compose 的 pac 服务 env 含 `${AI_GATEWAY_ADDR:?...}` 强校验，`down` 同为 compose 命令、同样做 env 插值，先补 .env 可避免 `down` 本身因缺变量报错（第 3 轮主审重要建议，已修订）→ **`docker compose down`**（停掉旧 gateway 容器与 pac 服务；pac 服务 19000 与过渡监听 10800 在 down→up 窗口内各有秒级中断，需提前知会全局 PAC 用户与旧插件用户，**建议低峰执行**）→ `docker compose up -d --remove-orphans`（新服务 gateway-ai/gateway-main 启动；**不带 `--build`**——本 compose 无 build 段，加了无意义）。**为何必须 down（第 2 轮阻塞项，已修订）**：docker compose v2 的 `up -d` 不会删除服务改名后的旧容器（仅警告 orphaned）——旧 gateway 容器继续占用 10800/9090，新 AI 实例的 10800 过渡监听与 9090 管理 API 绑定失败、陷入崩溃循环，脚本/管理员的 API 调用还会误打旧容器；先 `down` 再 `--remove-orphans` 双保险。**默认启用**决策 8 的 10800 过渡监听（`listeners` 段），旧插件**零改动**继续工作（除 down→up 窗口内 10800 秒级中断外，建议低峰执行）。⚠ 过渡期内 10800 = 全流量美国出口（google 裸域等宽泛清单用户、macos-proxy-manual-on.sh 旧用户受影响的语义见决策 8）。
2. 插件仓库变更（单独变更）：`background.js` 双端口（AI 7890 / 通用 7891）+ PAC 按用户 `proxyDomains` 分流。
3. 插件变更发布后：移除 `config-ai.yaml` 的 10800 `listeners` 过渡段（小变更）。
4. 全局 PAC 用户无需任何操作（PAC 模板已双端口分流）；macos 手动代理旧用户需切到 7891（本变更已改脚本默认值，但已生效的系统代理设置需手工重设或重跑脚本）。

## Risks / Trade-offs

- **AI 实例「全流量美国出口」**：7890 上的任何流量都走美国节点（MATCH 兜底），若插件 PAC 误把非 AI 域名发到 7890，会浪费美国节点流量。缓解：插件 PAC 是选择式（只代理用户清单内域名），风险窗口小；verify.sh 出口连通性检查可发现异常。
- **CLI 环境变量代理绕美副作用（第 1 轮辅审阻塞项 B1，已修订）**：`claude-code-setup.sh` 的 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量代理是**全量代理**（无 PAC 选择），默认改指 AI 实例 7890 后，内网/国内站点流量会绕道美国出口甚至不可达——旧 10800 单实例有 `Private/China/GEOIP CN` 直连兜底，7890 的 AI 实例没有（规则只有 MATCH）。缓解：脚本同时导出 `NO_PROXY`/`no_proxy` **大小写双变量**内网段（localhost、127.0.0.1、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 及常用内网域名）并在输出中提示；提示注明 CIDR 段仅 curl ≥7.86/libcurl 系识别（Node/Python 系不识别，关键内网主机建议同时列主机名/IP 字面量），并补「国内站点如需直连请自行把域名追加到 NO_PROXY」；README 显式记录「CLI 走 7890 时国内站点绕美国」副作用与 NO_PROXY 指引（T4.1）。
- **filter 聚合依赖节点命名**：美国正则命中依赖机场节点名含「美国/US」等关键词；命名不规范（如纯拼音 `meiguo`、代码 `US1` 等）可能漏聚合。缓解：沿用与 HK-STICKY 相同的已验证正则；verify.sh 硬性检查 AI 组非空（空组即 fail）；README 提示命名要求。
- **全局 PAC 静态清单与插件默认清单的漂移**：两处清单（插件 background.js、网关 PAC 模板）可能不同步。缓解：列为跨仓库一致性检查项；PAC 模板中该段带注释指向插件源文件。
- **10800 过渡端口（全流量美国出口）**：迁移期 AI 实例以 `listeners` 段额外监听 10800，**过渡期内 10800 = 全流量美国出口**——不只 AI 域名，凡到达 10800 的流量一律命中 `MATCH → AI-US-STICKY` 走美国节点；任何知晓 10800 的人都能直连 AI 实例（无鉴权，与现状一致——现状 10800 本就可访问 AI 出口）。受影响：google 裸域等宽泛清单用户、macos-proxy-manual-on.sh 旧全量代理用户。缓解：过渡期结束即移除该段；README/DEPLOY 显式记录语义与切换指引；macos 手动代理脚本本变更已默认改 7891。
- **无鉴权共享网关**：双实例后仍无鉴权（allow-lan），与单实例时代一致，不引入新风险面。
