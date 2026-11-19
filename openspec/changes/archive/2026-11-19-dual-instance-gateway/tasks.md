# Tasks: 双实例网关重构 + 机制回退

> 分级说明：**【低】** 机械删除/常量替换；**【中】** 单脚本逻辑改造；**【高】** 架构性文件（配置拆分、compose、PAC、文档重写、端到端验证）。
> 每个任务 ≤ 2 小时。文件边界以 design.md「文件范围」表为准，❌ 标记文件出现 diff 即越界。
> 依赖：T1 组 → T2 组 → T3 组 → T4 组（同组内可并行，交叉文件的任务见备注）。

## 1. 机制回退：删除文件与数据（低）

- [ ] 1.1 删除 AI 域名同步三件套：`scripts/gen-rules.sh`、`nodes/ai-domains.txt`、`rules/ai-plugin.yaml`【低】
  - 范围：仅上述 3 个文件（git rm）；`rules/` 目录将在 1.2 后清空
  - 验收：`ls nodes/ | grep ai-domains` 为空；`rules/` 目录为空
- [ ] 1.2 删除国家分流三件套：`scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`【低】
  - 范围：仅上述 3 个文件；删除后若 `rules/` 目录为空则一并删除该目录
  - 验收：`ls rules/ 2>/dev/null` 不存在或为空
- [ ] 1.3 删除 `nodes/ai.example.yaml` 与 `.gitignore` 中 ai.yaml 相关行【低】
  - 范围：`nodes/ai.example.yaml`（git rm）；`.gitignore` 三处：① 删 `!nodes/ai.example.yaml` 白名单行（保留 `!nodes/clash.example.yaml`）；② 删 `nodes/ai.yaml` 忽略行（`nodes/*.yaml` 通配已覆盖，该行冗余）；③ 顶部注释「nodes/*.yaml 已覆盖：clash.yaml、clash-<id>.yaml（多机场）、ai.yaml、」中删去 `ai.yaml` 字样（F2）
  - 验收：`git status` 中 ai.example.yaml 为 deleted；`.gitignore` 白名单只剩 clash.example.yaml；`grep -n 'ai.yaml' .gitignore` 无输出
- [ ] 1.4 残留引用扫描：grep `gen-rules|gen-country-rules|ai-domains|ai-plugin|ai_airport|AI-STICKY|AI-FIXED|-STICKY` 于仓库（排除 openspec/、.git、待改造文件 config.yaml/docker-compose.yml/scripts/{verify,reload-nodes,apply,logs,claude-code-setup,macos-proxy-manual-on}.sh/README.md/DEPLOY.md）【低】
  - 范围：只读扫描，不改文件；输出残留清单供 T2/T3 任务核对
  - 验收：除「待改造文件」外零残留（`nodes/clash.example.yaml` 中的示例说明除外）

## 2. 双实例配置文件（高）

- [ ] 2.1 新建 `config-main.yaml` 并删除 `config.yaml`【高】
  - 范围：`config-main.yaml`（新增）、`config.yaml`（删除）
  - 内容（按 design.md 决策 4）：`mixed-port: 7891`、`external-controller: 127.0.0.1:9091`；`proxy-providers.airport`（file `./nodes/_merged.yaml` + health-check）、注释态 `relay`；`rule-providers` 仅 `China/Private/Block`（URL 与现 config.yaml 逐字一致，`ai-plugin`/`ai-plugin-country`/AI 远程 7 个一律不出现）；`proxy-groups`：`HK-STICKY`、`GEN-ROTATE`（与现 config.yaml 同定义）、注释态 `RELAY-POOL`；`rules` 顺序：`RULE-SET,Private,DIRECT` → `RULE-SET,Block,REJECT` → `RULE-SET,China,DIRECT` → `GEOIP,CN,DIRECT` → `MATCH,HK-STICKY`
  - 禁止出现：7 国组、AI-STICKY/AI-FIXED、ai_airport、任何 AI 域名规则（内联/本地/远程）
  - ⚠ RELAY-POOL 注释态块措辞中性化（F3）：原注释「在 nodes/ai.yaml 的落地节点上写 dialer-proxy: "RELAY-POOL"」改为中性描述（如「在机场节点的落地节点上写 dialer-proxy: "RELAY-POOL"」），注释块内不得再出现 ai.yaml 字样
  - 验收：`grep -iE 'AI-|ai_|ai-plugin|ai\.yaml' config-main.yaml` 无规则/组/provider 命中（注释说明文字除外，且含上述中性化要求——ai.yaml 字样连注释也不得出现）
- [ ] 2.2 新建 `config-ai.yaml`【高】
  - 范围：`config-ai.yaml`（新增）
  - 内容：`mixed-port: 7890`、`external-controller: 127.0.0.1:9090`；`proxy-providers.airport`（同上）；`proxy-groups` 仅 `AI-US-STICKY`（`use: [airport]` + 美国 filter 正则 + 与 HK-STICKY 同款 `exclude-filter`（⚠ 不含「中国」——刻意不同于旧 AI-STICKY，美国节点常带「中国优化」字样，不得照抄旧 AI-STICKY） + `sticky-sessions`）；`rules` 仅 `MATCH,AI-US-STICKY`；迁移期过渡段**默认启用**（插件侧端口切换完成后移除，见 design 决策 8），用 mihomo `listeners` 入站段：

    ```yaml
    listeners:
      - name: legacy-10800
        type: mixed
        port: 10800
        listen: 0.0.0.0
    ```

  - ⚠ 禁止写顶层 `ports` 字段——mihomo 无此字段（Surge 语法），写了会被忽略、过渡监听静默失效
  - 验收：`config-ai.yaml` 无 `rule-providers` 段；`rules:` 下仅 MATCH 一行；`listeners` 段含 `legacy-10800`（mixed/10800/0.0.0.0）且无顶层 `ports` 字段；`AI-US-STICKY` 的 exclude-filter 不含「中国」
- [ ] 2.3 `docker-compose.yml` 双服务改造【高】
  - 范围：`docker-compose.yml`
  - 内容：`gateway` 服务替换为 `gateway-ai`（挂 `./config-ai.yaml:/root/.config/mihomo/config.yaml:ro`）与 `gateway-main`（挂 `./config-main.yaml:...`），两者共享 `./nodes:/root/.config/mihomo/nodes:ro`；`pac` 服务 env 增加 `AI_GATEWAY_ADDR=${AI_GATEWAY_ADDR:?...}`；移除 rules 挂载（如曾有）
  - 验收：**前置——先新建本地 `.env` 并补全变量**（第 3 轮主审建议，已修订：本机尚无 `.env` 时先 `cp .env.example .env` 新建，再新增 `AI_GATEWAY_ADDR=...:7890`、`GATEWAY_ADDR` 改 `...:7891`，否则 compose 的 `${...:?}` 强校验直接报错）；`docker compose config` 无报错；服务名/容器名为 gateway-ai、gateway-main、pac
- [ ] 2.4 双端口 PAC：`.env.example`、`www/proxy.pac.template`、`www/15-sanitize-gateway.envsh`【高】
  - 范围：上述 3 个文件（`www/nginx.conf` ❌ 不修改）
  - 内容：`.env.example` 的 `GATEWAY_ADDR` 改 `...:7891`、新增 `AI_GATEWAY_ADDR=...:7890`；PAC 模板双端口分流（内网 DIRECT → 静态 AI 清单 `PROXY ${AI_GATEWAY_ADDR}; DIRECT` → 其余 `PROXY ${GATEWAY_ADDR}; DIRECT`），静态清单按 design 决策 5（**15 个**核心域名：旧内联兜底保留项 10 个（openai/anthropic/claude 三 KEYWORD 裸域化 + chatgpt/cursor/cursor.sh/x.ai/grok/gemini.google/aistudio.google 七 suffix）+ 插件 defaultProxyDomains 独有项 4 个（coze/meta.ai/oaistatic/oaiusercontent，**已剔除** `google.com` 裸域——超宽，不纳入）+ 旧远程 Perplexity 规则集核心站 1 个（perplexity.ai，**回退保留项**））；sanitize 脚本对双变量做同款清洗；⚠ **PAC 匹配函数语义（第 3 轮辅审建议，已修订）**：3 条 KEYWORD 裸域化后的域名（`openai.com`/`anthropic.com`/`claude.ai`）MUST 用 `dnsDomainIs` 语义匹配——该函数定义即「host 与裸域相等或以 `.裸域` 结尾」，覆盖裸域及其全部子域，才能与原 `DOMAIN-KEYWORD` 的覆盖范围等价（官方域名全部子域不丢）；MUST NOT 退化为「仅精确匹配主域」的 `===` 判断（会丢失 `api.openai.com` 等全部子域流量）。其余 12 个 DOMAIN-SUFFIX 域名维持 `dnsDomainIs`/等价后缀匹配
  - ⚠ **envsubst 硬约束（第 2 轮主审 S3，已修订）**：PAC 模板 JS 代码**不得出现任何 `${...}` 字面量**（`${GATEWAY_ADDR}`/`${AI_GATEWAY_ADDR}` 两个注入点除外）——nginx 官方 entrypoint 的 envsubst 默认替换模板内全部 `${VAR}`，JS 模板字符串会被误替换为空、损坏 PAC 语法；JS 内需拼接字符串处一律用 `+` 连接
  - 验收：**前置——本地 `.env` 已按 T2.3 新建并补全变量**（缺 `AI_GATEWAY_ADDR` 时 compose `${...:?}` 强校验直接报错）；`docker compose up -d pac` 后 `curl -s http://127.0.0.1:19000/proxy.pac` 渲染出两个 `PROXY` 常量且无残留 `${...}`

## 3. 脚本双实例化（中）

- [ ] 3.1 `scripts/reload-nodes.sh` 双实例循环【中】
  - 范围：`scripts/reload-nodes.sh`
  - 内容：常量 `AI_API_DEFAULT=http://127.0.0.1:9090`、`MAIN_API_DEFAULT=http://127.0.0.1:9091`；无参 → 循环两实例，传参 → 仅给定 API；`check_merged_up_to_date` 只跑一次；per-instance：API 探测（失败记录继续）→ provider 动态发现+reload → 即时 healthcheck → 组打印；任一实例 provider 重载失败 → 非零退出；结尾提示 `docker compose restart gateway-ai gateway-main`；⚠ **头部注释同步更新（F3 + 第 3 轮辅审建议，已修订）**：删「去硬编码 airport/ai_airport、AI-FIXED/GEN-ROTATE/AI-STICKY 固定名单」字样，删「编排顺序 build-config.sh → gen-rules.sh → reload-nodes.sh → apply.sh」（gen-rules.sh 已删除），并同步更新第 12 行「要彻底断掉所有旧连接：`docker compose restart gateway`」字样——`gateway` 服务已不存在，改为 `docker compose restart gateway-ai gateway-main`；整体改为双实例语义（无参=双实例、默认 API 9090/9091、`docker compose restart gateway-ai gateway-main`）
  - 验收：双实例运行时无参执行成功且两实例 provider 均 reload；停掉 AI 实例后执行 → 通用实例正常 + AI 实例告警 + 非零退出；`head -30 scripts/reload-nodes.sh` 注释中无 `ai_airport|AI-STICKY|gen-rules` 字样；`grep -n 'docker compose restart' scripts/reload-nodes.sh` 命中 `gateway-ai gateway-main`（无裸 `gateway` 单实例字样）
- [ ] 3.2 `scripts/apply.sh` 双实例循环【低】
  - 范围：`scripts/apply.sh`
  - 内容：无参默认对两个 API 依次 `PUT /configs`（容器内路径统一 `/root/.config/mihomo/config.yaml`）；逐实例打印结果；任一失败非零退出
  - 验收：双实例运行时无参执行，两个 API 均返回 204/200
- [ ] 3.3 `scripts/verify.sh` 双实例校验 + 国家分流回退删除【中】
  - 范围：`scripts/verify.sh`
  - 删除：`is_country_group`、国家组 hard fail 分支、2b 节（7 国 dry-run 全部：`extract_proxy_names`、`COUNTRY_*` 数组、三级降级）、结尾国家组提示行
  - 改造：参数 `[AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]`（默认 `127.0.0.1:9090 127.0.0.1:9091 127.0.0.1:7890 127.0.0.1:7891`）——⚠ 位置参数语义变化（现行为 2 参 → 4 参），旧 2 参调用不兼容，DEPLOY 升级说明必须注明（T4.2）；函数化 `check_instance <label> <api> <gateway> <硬性组判定>`（与 design 决策 7 签名一致，第 2 轮主审 S4 统一：`<label>` 为 AI/main 实例标签，`<硬性组判定>` 为「组名含 AI」/「组名含 HK/香港」的匹配模式，供函数对两实例通用）：AI 实例硬性「组名含 AI 的组非空」+ 出口连通（ipinfo + claude/chatgpt cdn-cgi/trace，可连通即通过、loc 参考）；通用实例硬性「组名含 HK/香港 的组非空」+ 默认出口连通；本地降级模式分别扫 `config-ai.yaml`/`config-main.yaml`；任一实例硬失败非零退出
  - 验收：双实例运行无参执行输出两实例两组校验结果；回退残留 grep（**锚定回退符号**，勿 grep 裸 `country`——ipinfo 输出行合法含 `.country` 字段会误报）：`grep -nE 'is_country_group|COUNTRY_CODES|COUNTRY_NAMES|COUNTRY_PATTERNS|国家分流' scripts/verify.sh` 无输出；废弃机制残留 grep：`grep -nE 'ai_airport|AI-STICKY|AI-FIXED|10800' scripts/verify.sh` 无输出（组名/端口全动态发现，不得硬编码）
- [ ] 3.4 端口常量更新：`logs.sh`、`claude-code-setup.sh`、`macos-proxy-manual-on.sh`【低】
  - 范围：上述 3 个文件
  - 内容：`logs.sh` SERVICE 默认 `gateway` → `gateway-main`（注释补 `gateway-ai`）；`claude-code-setup.sh` 默认 `http://gateway.corp.example.com:7890`（AI 实例，注释说明双端口）+ ⚠ **新增 `NO_PROXY` 内网段导出与提示（B1 + 第 2 轮主审 S2/辅审问题 3，已修订）**：三种方式（临时 export / 写入 ~/.zshrc / settings.json）均同时输出 `export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<常用内网域名>"` **与 `export no_proxy="$NO_PROXY"`（大小写双导出**——Node/Python 等工具只认小写，curl 系认大写，双写全覆盖），并在提示文案中说明「CLI 环境变量代理是全量代理（无 PAC），走 7890 时内网/国内站点会绕道美国出口，NO_PROXY 已豁免内网段」+ ⚠ **提示注明 CIDR 限制**：`10.0.0.0/8` 等 CIDR 段仅 curl ≥7.86 / libcurl 系工具识别，Node/Python 系不识别——关键内网主机建议同时列出主机名/IP 字面量 + ⚠ **提示补「国内站点如需直连，请自行把域名追加到 NO_PROXY」**；`macos-proxy-manual-on.sh` 默认 PORT `10800` → `7891`（通用实例，注释更新）
  - 验收：grep 三文件不再出现 `10800` 默认值；`grep -n 'NO_PROXY' scripts/claude-code-setup.sh` 有命中且含内网段；`grep -n 'no_proxy' scripts/claude-code-setup.sh` 有命中（小写双导出）；提示文案含 CIDR 工具兼容限制（grep `7.86` 命中）与「追加到 NO_PROXY」指引（grep `追加` 命中）

## 4. 文档重写与端到端验证（高/中）

- [ ] 4.1 `README.md` 双实例架构重写（含回退删除）【高】
  - 范围：`README.md`
  - 删除：5b 国家分流整节、7 国组名表、「插件域名规则集/国家分流规则集」条目、分组策略中国家组与 AI-STICKY/AI-FIXED/ai.yaml 条目、目录结构中 ai-domains*/gen-*.sh/ai-plugin*.yaml 条目、旧端口 10800 描述
  - 新增：双实例架构图（插件 PAC → 7890 / 全局 PAC → 7891 双端口）、端口约定表（7890/7891/9090/9091/19000）、AI-US-STICKY 美国聚合说明（住宅节点命名含「美国」即入组）、维护流程（build → reload 覆盖两实例）、⚠ **「CLI 走 7890 时国内站点绕美国」副作用与 NO_PROXY 指引（B1，见 design Risks；指引需注明 NO_PROXY/no_proxy 大小写双写、CIDR 段仅 curl ≥7.86/libcurl 系识别——Node/Python 系不识别，关键内网主机建议同时列主机名/IP 字面量、国内站点如需直连自行把域名追加到 NO_PROXY）**、⚠ **过渡期 10800 = 全流量美国出口说明（google 裸域、macos 手动代理旧用户受影响，见 design 决策 8）**
  - 验收：`grep -nE '国家分流|ai-domains|gen-country|gen-rules|ai_airport|AI-STICKY|AI-FIXED' README.md` 无残留；`10800` 仅允许出现在「迁移期/过渡期」说明中（不得作为正式入口描述）
- [ ] 4.2 `DEPLOY.md` 双实例部署流程重写（含回退删除）【高】
  - 范围：`DEPLOY.md`
  - 删除：国家分流接入/维护/FAQ、gen-rules/gen-country-rules 编排步、7 国 dry-run 复核段、国家组验证/排错条目、ai.yaml 手工池步骤
  - 新增：双服务部署步骤（无需 ai.yaml；只需机场文件 + build）、端口表、双实例验证指引（verify.sh 双实例输出解读）、`docker compose ps` 三容器预期、FAQ 增加「AI 组为空 → 机场节点名补『美国』」「插件端口切换过渡期 10800 = 全流量美国出口」
  - ⚠ 升级步骤必须显式列出（第 1 轮评审意见已修订、第 2 轮阻塞项已修订、第 3 轮主审重要建议已修订）：① **先补 `.env`**：新增 `AI_GATEWAY_ADDR=<服务器>:7890` 且 `GATEWAY_ADDR` 由 `...:10800` 改 `...:7891`（缺 `AI_GATEWAY_ADDR` 时 compose `${...:?}` 强校验直接报错）——**必须放在 `docker compose down` 之前**：新版 compose 的 pac 服务 env 含 `${AI_GATEWAY_ADDR:?...}` 强校验，`down` 同为 compose 命令、同样做 env 插值，先补 .env 可避免 `down` 本身因缺变量报错；② **`docker compose down`**——停掉旧 gateway 容器（pac 服务 19000 与过渡监听 10800 在 down→up 窗口内各有秒级中断、**建议低峰执行**，文档需提示）。⚠ **必须显式 down**：docker compose v2 的 `up -d` 不会删除服务改名后的旧容器（仅警告 orphaned），旧 gateway 容器继续占用 10800/9090 → 新 AI 实例的 10800 过渡监听与 9090 管理 API 绑定失败、崩溃循环，脚本/管理员的 API 调用误打旧容器；③ `docker compose up -d --remove-orphans`（**不带 `--build`**——本 compose 无 build 段，加了无意义）；④ **verify.sh 位置参数语义变化**：旧用法 2 参（`[API] [网关host:port]`）→ 新用法 4 参（`[AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]`），升级说明带一句「旧 2 参命令不再兼容，无参执行即校验两实例」
  - 验收：`grep -nE '国家分流|ai-domains|gen-country|gen-rules|ai_airport|AI-STICKY|AI-FIXED' DEPLOY.md` 无残留；升级步骤含 `docker compose down`、`--remove-orphans`、`AI_GATEWAY_ADDR` 与 verify.sh 4 参说明（`grep -nE 'docker compose down|remove-orphans|AI_GATEWAY_ADDR' DEPLOY.md` 均命中）；`10800` 仅允许出现在「迁移期/过渡期」说明中
- [ ] 4.3 端到端本地验证【高】
  - 范围：不改代码，执行验证并记录结论（如需要可写入变更目录下 verify-report.md）
  - 步骤：`./scripts/build-config.sh` → 先补 `.env`（`AI_GATEWAY_ADDR=127.0.0.1:7890`、`GATEWAY_ADDR=127.0.0.1:7891`）→ `docker compose up -d --remove-orphans`（验证机若残留旧单实例 gateway 容器会占用 10800/9090 导致 AI 实例绑定失败，必要时先 `docker compose down` 再 up）→ `docker compose ps`（gateway-ai/gateway-main/pac）→ `./scripts/reload-nodes.sh` → `./scripts/verify.sh` → `curl -x http://127.0.0.1:7890 https://claude.ai/cdn-cgi/trace`（应美国出口）→ `curl -x http://127.0.0.1:7891 https://www.cloudflare.com/cdn-cgi/trace`（应香港出口）→ **过渡期 10800 可达性检查：`curl -x http://127.0.0.1:10800 https://claude.ai/cdn-cgi/trace`（应可达且美国出口——验证 `listeners` 过渡段真实生效，顶层 `ports` 写法会导致此处连接被拒）** → **`./scripts/apply.sh` 热加载后复测 `curl -x http://127.0.0.1:10800 https://claude.ai/cdn-cgi/trace` 可达（第 3 轮主审建议，已修订：mihomo 热更新对 `listeners` 段的支持情况需实测验证——若 apply 后 10800 不可达，记录到验证报告，并在 design/T4.2 注明「过渡段变更需 `docker compose restart gateway-ai` 生效」）** → PAC 渲染检查
  - 验收：AI 组与 HK 组均非空、verify.sh 全绿或按 design 风险说明给出可解释的告警记录；10800 可达性检查通过（含 apply.sh 热加载后复测；若热更新对 listeners 段不生效，必须记录结论与 restart 指引）

---

**分派建议**：T1 组（1.1-1.4）给初级 coder 并行；T2.1/T2.2 给同一人顺序做（配置语义强相关）；T2.3/T2.4 可并行；T3.1/T3.3 给同一人（reload/verify 动态发现逻辑同源）；T3.2/T3.4 可并行；T4.1/T4.2 可并行，T4.3 最后统一做。
