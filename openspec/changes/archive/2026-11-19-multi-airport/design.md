## Context

### 现状

`ai-proxy-gateway` 是 mihomo（clash.meta 内核）代理网关，架构如下：

- **节点加载**：`config.yaml` 用 `proxy-providers`（`type: file`）读取 `nodes/clash.yaml`（全量池 `airport`）与 `nodes/ai.yaml`（AI 专用池 `ai_airport`）。mihomo 只读文件里的 `proxies:` 段，多余字段忽略。
- **分组**：`proxy-groups` 用 `use: [provider名]` 引用 provider，再用 `filter`/`exclude-filter` 正则按节点名锁定地区（当前锁定美国）。
- **规则**：`rules` 依赖远程 `rule-providers`（`gh-proxy.com` 镜像，`geosite`/`classical` 规则集）＋ 内联兜底域名。
- **脚本**：`reload-nodes.sh`、`verify.sh` 硬编码 `airport ai_airport` 与 `AI-FIXED GEN-ROTATE AI-STICKY`。

### 真实机场订阅格式（已分析 `/Users/penguin/Downloads/clash.yaml`）

1845 行，结构为：

```
allow-lan / mode / log-level / external-controller / dns
proxies:        # 140-279 行，约 140 个节点，内联 JSON（ss / vless 两种协议）
proxy-groups:   # 280-431 行，仅 Proxy(select) + Steam(select) 两组，无 use/filter
rules:          # 432-1845 行，DOMAIN-SUFFIX / PROCESS-NAME / IP-CIDR / GEOIP / MATCH
```

顶层 key（无缩进、以 `key:` 结尾）共 6 个，顺序固定：`allow-lan` → `mode` → `log-level` → `external-controller` → `dns` → `proxies` → `proxy-groups` → `rules`。

关键结论：

1. **无 `proxy-providers` 段**——这是「订阅式」而非「provider 式」配置。机场把全部节点内联在 `proxies:` 下。
2. **节点是内联 JSON**（`- {"name":"...","type":"ss",...}`，单行一条），节点名含在 `"name":"..."` 字段，可用正则 `"name"\s*:\s*"([^"]*)"` 提取。
3. **节点命名高度结构化**，前缀带线路 + 地区 + 特性，可据以分组：
   - `IEPL企业专线-香港01-ss-x4`（IEPL 线路 / 香港）
   - `BGP智能路由-日本01-流媒体AI-ss-x2`（BGP 线路 / 日本 / AI）
   - `IX精品专线-美国01-禁止大流量-x10`（IX 线路 / 美国 / 限大流量）
   - `VLESS-香港1-三网优化-x1`（VLESS / 香港 / 三网优化）
4. **proxy-groups 只有一个 `Proxy` select 组**，含全部节点；`Steam` 组指向 `Proxy`。机场自己的 rules 用 `Proxy` 作为目标组。
5. 节点名里地区关键词：香港/日本/美国/台湾/新加坡/韩国/德国/英国/法国/荷兰/马来西亚/澳大利亚/加拿大/印度/越南/菲律宾/泰国/巴西/墨西哥/土耳其/埃及/俄罗斯/乌克兰/意大利/印度尼西亚。AI 关键词：「流媒体AI」。
6. 节点名里的倍率/特性后缀：`-x1`/`-x2`/`-x4`/`-x10`（倍率）、`禁止大流量`、`家宽`、`大带宽`、`低倍率`、`三网优化`。

### 插件域名列表格式（已分析 `chatgpt-block-bypass`）

- 权威域名列表硬编码在 `background.js` 第 9-24 行 `defaultProxyDomains`，14 个 PAC glob 字符串，如 `https://*.openai.com/*`、`https://chatgpt.com/*`、`https://*.coze.com/*`、`https://gemini.google.com/*`。
- 用户自定义域名存在 `chrome.storage.local` 的 `proxyDomains`（popup.js 增删，统一补成 `https://…/*` 格式）。
- **没有独立配置文件**，域名列表是 JS 代码里的数组常量。因此网关侧要复用，必须约定一个「可被网关读取」的导出产物（见 Decisions）。

## Goals / Non-Goals

**Goals:**
- 支持 `nodes/` 下任意数量的机场订阅文件（`clash-<id>.yaml` + 兼容 `clash.yaml` 作为 default id），脚本/config 无需逐一登记。
- 跨机场按「地区/线路特征」聚合节点到逻辑组（AI 组、香港组等）。
- `reload-nodes.sh` / `verify.sh` 彻底去硬编码，动态发现 provider 与组。
- 网关侧生成/合并三级分流规则，并与插件域名列表联动。
- 保持现有「全局 PAC、服务端判定」架构不变，员工零配置。

**Non-Goals:**
- 不改 `docker-compose.yml`、`www/` PAC 模板（全局转发模型不变）。
- 不修改 `chatgpt-block-bypass` 仓库代码（仅读取其域名列表作为数据源；插件自身的同步改造留作后续独立变更）。
- 不引入除 bash + curl + jq（三者均已存在、为当前脚本既有依赖）外的运行时依赖——**保持纯 shell 工具链，不引入 python3/pyyaml**。build-config.sh 对「订阅式机场（内联 JSON 节点）」的解析采用「整段拷贝 + 正则重名检测」，不逐字段解析 YAML/JSON（见「build-config.sh 算法」）。
- 不实现自动「订阅 URL 拉取更新」（本期仅支持「本地文件 + 热重载」；远程订阅拉取留待后续）。

## Decisions

### 决策 1：机场文件命名与发现约定

- **命名**：`nodes/clash-<id>.yaml`，`<id>` 为机场标识（`[a-z0-9-]+`）。例如 `clash-a.yaml`、`clash-b.yaml`。
- **发现**：脚本与生成器用 `nodes/clash-*.yaml` glob 扫描，排除 `*.example.yaml`。
- **向后兼容（P3 拍板）**：现有 `nodes/clash.yaml`（无 `-<id>`）视为「默认机场」，其 `<id>` 记作 `default`，**与 `clash-<id>.yaml` 并存**——即扫描规则同时纳入：
  1. `nodes/clash.yaml` → id=`default`
  2. `nodes/clash-<id>.yaml` → id=`<id>`（`clash-*.yaml` glob 命中）
  - 两者同时存在时都参与合并；只有 `clash.yaml` 时等价于单机场默认模式（平滑迁移）。
  - `nodes/ai.yaml` 继续作为「AI 出口专用手工池」保留——**AI 组是固定出口组，仅由 `ai.yaml` 手工选定的通用节点组成，不依赖机场节点名标称 AI**。`ai.yaml` 不参与 build-config.sh 的合并与去重前缀（P14）。
- **`.gitignore`（P11）**：现有 `nodes/*.yaml` 已匹配 `clash.yaml`、`clash-a.yaml`、`_merged.yaml`、`ai.yaml` 等全部 yaml（含未来任意 `<id>`）。需显式补注释说明 `_merged.yaml` 命中 `nodes/*.yaml` 被忽略，防误提交；example 白名单维持 `!nodes/clash.example.yaml` 与 `!nodes/ai.example.yaml`（若未来新增 `rules/*.example.yaml` 再扩白名单，本期不新增 example 文件）。

### 决策 2：节点分组策略（跨机场聚合）

核心思路：**`proxy-groups` 不再绑定固定 provider 名，改为按「节点名特征正则」跨 provider 聚合**。mihomo 的 `use:` 支持多 provider 列表，且 `filter` 对「节点名」做正则匹配。

实现方式（二选一）：

- **方案 A：多 provider + filter 聚合**。为每个机场建一个 file provider（`airport_a`、`airport_b`…），逻辑组用 `use: [airport_a, airport_b]` + `filter` 正则聚合。缺点：机场数量变化时 `use:` 列表要重生成。
- **方案 B（采用）：生成式合并**。用一个生成脚本（`scripts/build-config.sh`）扫描 `nodes/clash-*.yaml`，把各机场 `proxies:` 合并写入一个中间 `nodes/_merged.yaml`，再由单个 provider `airport` 读取；逻辑组用 `filter` 正则聚合。机场数量变化对 config 透明。

**结论**：采用 **方案 B**。理由：
- 合并后 `config.yaml` 的 `proxy-providers` 保持极简（一个 `airport` + 一个 `ai_airport`），机场数量变化不改 config，符合「脚本动态发现」目标。
- 分组统一靠 `filter` 正则，天然跨机场聚合，且节点名特征已在真实订阅中验证稳定存在。

**逻辑组定义（三类）**：

1. **香港组（默认出口组，组名定为 `HK-STICKY`）**：`name: HK-STICKY`，`type: load-balance`，`strategy: sticky-sessions`，`use: [airport]`，`filter: "(?i)(香港|Hong ?Kong|\\bHK\\b)"`，并 `exclude-filter` 排除「禁止大流量/测试/倍率过高」等特征节点（见 Risks）。香港组作为「未匹配 AI、也非国内」的海外流量默认出口。组名 `HK-STICKY` 三处保持一致：`config.yaml` 的 `proxy-groups` 组名、`config.yaml` rules 的 `MATCH` 目标、`verify.sh` 的「组名含 `HK`/`香港`」判定。
2. **AI 出口组（固定出口组，组名沿用 `AI-STICKY`）**：`use: [ai_airport]`，**不依赖节点名正则**。AI 组是「AI 域名的出口分组名」，节点来源仅为 `nodes/ai.yaml` 手工池——人工从各机场（或住宅代理服务商）挑选若干通用节点放入 `ai.yaml`，**不要求节点标称「AI」**。可选的地区 filter（如锁定某地区）作为附加约束，但节点名不含「AI」也可入组。**现有 `AI-STICKY`（`sticky-sessions`）组保留沿用，不再用地区 filter 锁定美国**（移除原「只用美国节点」的 filter，AI 出口不依赖地区）。
3. **国内直连**：不走 proxy-group，由 `RULE-SET,China,DIRECT` + `GEOIP,CN,DIRECT` 直接命中。

> **旧组处置（S2 落定）**：现有 `config.yaml` 共 4 个 load-balance 组，本次变更后的处置如下，避免遗留「美国 filter 锁定」的组继续兜底：

| 旧组名 | 处置 | 说明 |
|--------|------|------|
| `GEN-STICKY` | **改造为 `HK-STICKY`** | 原为 `MATCH` 兜底 + `filter` 锁定美国节点；改为香港组（`filter` 香港正则 + `exclude-filter`），继续作为 `MATCH` 兜底目标 |
| `AI-STICKY` | **保留** | AI 出口组，`use: [ai_airport]` 不变，仅移除「锁定美国」的地区 filter（AI 出口不依赖地区） |
| `GEN-ROTATE` | **改造为香港轮询备用** | 原「美国节点轮询」备用组，未引用；`filter` 改为香港正则，`strategy: round-robin` 不变，作为「想轮询换 IP 时改 MATCH 目标」的备用组 |
| `AI-FIXED` | **保留（备用）** | 原「consistent-hashing 永久固定 IP」备用组，未引用；`use: [ai_airport]` 不变，仅移除「锁定美国」的地区 filter，与 `AI-STICKY` 语义对齐 |

  - **不得删除任何组后再另起炉灶**：`MATCH` 兜底目标、rules 引用必须统一指向 `HK-STICKY`，避免出现「旧 `GEN-STICKY` 遗留 + 新 `HK-STICKY` 并存」的双兜底歧义。

> **语义澄清（已拍板）**：AI 组只是一个「出口分组名」，与机场节点名里标称的「流媒体AI」线路无关。选一个或几个通用节点（如某香港/美国节点）作为 AI 域名出口即可，不要求节点本身标称 AI。因此 design 中**不引入「AI 线路节点组」这一概念**，避免实现时误把机场「流媒体AI」线路当出口。

### 决策 3：脚本去硬编码方案

- **`reload-nodes.sh`**：
  1. 用 `curl $API/providers/proxies` 列出所有 proxy-provider（mihomo 提供 `/providers/proxies` 端点，返回全部 provider），动态遍历重载 + 触发 healthcheck。
  2. 组名校验：用 `curl $API/proxies` 列出所有代理组，动态遍历打印 `.all`；不再写死 `AI-FIXED GEN-ROTATE AI-STICKY`。
- **`verify.sh`**：
  1. provider 部分：`curl $API/providers/proxies` 动态遍历，打印各 provider 节点数。
  2. 组部分：`curl $API/proxies` 动态遍历所有组，复用 `check_group` 逐组校验 filter 命中；AI 出口组（组名含 `AI`）额外做「非空」检查，香港组（组名含 `HK`/`香港`）做「非空」检查（香港组是默认出口，非空是硬性要求）。
  3. 保留 `classify_org`、`check_ai`（Claude/ChatGPT 连通性）逻辑；**`check_ai` 移除「出口必须是美国」的硬编码判定**（P2），改为「可连通即通过 + 打印出口地区 loc 供人工参考」，因为 AI 组是固定出口组、不依赖地区。

- **动态发现的数据源优先级（P9 拍板）**：mihomo API（运行时真值）优先。**两个脚本对「API 不通」的处理语义不同，须区分**：
  - **`reload-nodes.sh`**：依赖 API 执行重载，API 不通时**直接失败退出**（非零退出码），并提示「mihomo API 不可达，请先确认网关运行，或执行 `docker compose restart gateway`」。
  - **`verify.sh`**：API 不通时**降级到本地扫描** `nodes/clash-*.yaml` + `config.yaml`，仅用于「列出应存在的 provider/组名」并提示「以下项应存在，但运行时无法确认（API 不可达）」——verify 的定位是「诊断」，不是「执行」，故软降级而非硬失败。

### 决策 4：分流规则生成与合并

三级分流（顺序固定，**香港组为默认出口**，已拍板）：

```
① 插件域名 + AI 规则集 + 内联兜底 → AI 出口组（AI-STICKY）
② 国内(geosite:cn/geoip:cn)      → DIRECT
③ MATCH 兜底                     → 香港组（HK-STICKY）
```

- **AI 域名数据源（三源合并）**：
  1. **插件域名**（新）：从 `chatgpt-block-bypass` 的 `defaultProxyDomains` 同步，转换为 clash 规则，放最前（最高优先级）。
  2. **远程 rule-providers**（保留）：现有 `AI`/`ChatGPT`/`Claude`/`Gemini`/`Copilot`/`Grok`/`Perplexity` 规则集，作为兜底。
  3. **内联兜底**（保留）：核心 AI 站硬编码规则，防规则集拉取失败。
- **国内直连**：沿用 `RULE-SET,China,DIRECT` + `GEOIP,CN,DIRECT`（geosite/geoip 规则集，远程维护、免手写）。
- **香港组兜底（默认出口）**：`MATCH,HK-STICKY` 替代原 `MATCH,GEN-STICKY`。即「未命中 AI、也未命中国内」的海外流量 → 香港组。**默认出口从「美国（原 filter 锁定美国）」改为「香港」，与需求 4 一致。**
- **生成方式（P6 拍板）**：新增 `scripts/gen-rules.sh`，**只产出规则片段，不直接改写 `config.yaml`**：
  1. 读取插件域名导出文件（见决策 5），转成 `DOMAIN-SUFFIX`/`DOMAIN` 规则片段，写入 `rules/ai-plugin.yaml`；
  2. `config.yaml` 通过 **一次性手工** 增加一个 `rule-providers`（`ai-plugin`，`type: file`）引用 `rules/ai-plugin.yaml`，并在 rules 里加一行 `RULE-SET,ai-plugin,AI-STICKY` 放在最前；
  3. 输出顺序保证三级分流。

- **`rule-providers.ai-plugin` 完整字段定义（Q1 落定）**：与现有 config 中「http 型 classical 文本规则集」（`Claude`/`Gemini`/`Copilot`/`Grok`/`Block`）保持同一惯例——均带 `behavior` + `format`。`ai-plugin` 为 `type: file` 型，同样必须显式声明这两个字段：

  ```yaml
  rule-providers:
    ai-plugin:
      type: file
      behavior: classical   # 逐行匹配 classical 规则（DOMAIN-SUFFIX / DOMAIN）
      format: text          # 纯文本行，非 mrs 二进制，非 yaml
      path: rules/ai-plugin.yaml
  ```

  > **为何 `behavior: classical` + `format: text`（而非 domain/mrs 或 yaml）**：`gen-rules.sh` 产出的每一行是带规则类型的完整规则（`DOMAIN-SUFFIX,openai.com`、`DOMAIN,chatgpt.com`），属于 mihomo 的 **classical 文本规则**格式；`domain`/`mrs` 是纯域名集合格式（不含 `DOMAIN-SUFFIX,` 前缀），`yaml` 是 `payload:` 列表格式，均与产出物不匹配。因此必须 `classical` + `text`。

- **`rules/ai-plugin.yaml` 内容格式（Q1 落定）**：**纯 classical 规则行，非 `payload:` 列表**。文件内容为每行一条完整规则，无 `payload:` 键包裹（与上述 `format: text` + `behavior: classical` 自洽）：

  ```yaml
  # 由 scripts/gen-rules.sh 生成，勿手工编辑
  DOMAIN-SUFFIX,openai.com
  DOMAIN-SUFFIX,chatgpt.com
  DOMAIN,chatgpt.com
  ```

  - 每行格式：`<规则类型>,<域名>`（`DOMAIN-SUFFIX` 或 `DOMAIN`），与决策 5 转换规则表一致。
  - **禁止**使用 `payload:` 列表包裹（那是 `format: yaml` 的格式，与本 design 选定的 `classical`+`text` 冲突）。coder 若产出 `payload:` 格式即为实现错误。
  - `gen-rules.sh` 全量覆盖写，重复运行幂等；`ai-domains.txt` 缺失时产出仅含注释头的空文件。
- **幂等性（P6）**：`gen-rules.sh` 重复运行**覆盖写同一个 `rules/ai-plugin.yaml`**（全量重写，非增量），天然幂等。脚本**禁止** sed/awk 改写 `config.yaml`（避免破坏人工维护的注释与结构）。

### 决策 5：与插件联动的数据流

插件域名列表当前是 JS 数组常量，网关无法直接读取 JS。设计数据流（不改插件代码，只约定导出产物）：

```
chatgpt-block-bypass/background.js (defaultProxyDomains)
        │  (人工/脚本导出，一次性或定期)
        ▼
ai-proxy-gateway/nodes/ai-domains.txt
        │  (scripts/gen-rules.sh 读取)
        ▼
rules/ai-plugin.yaml（DOMAIN-SUFFIX / DOMAIN 规则片段）
        │  (config.yaml rule-providers 一次性引用)
        ▼
config.yaml 的 rules（RULE-SET,ai-plugin,AI-STICKY）
```

- **导出格式约定**：`nodes/ai-domains.txt`，每行一个裸域名（`openai.com`、`chatgpt.com`、`*.coze.com` → 去 `*` 得 `coze.com`），由人工或 CI 从插件的 `defaultProxyDomains` 生成。

- **转换规则表（P4 拍板）**：

  | PAC glob | 转换结果 | 说明 |
  |----------|----------|------|
  | `https://*.domain.com/*` | `DOMAIN-SUFFIX,domain.com` | 通配前缀 → 覆盖所有子域 |
  | `https://domain.com/*`（无通配、非超宽） | `DOMAIN,domain.com` | 精确域名，仅匹配裸域，不误伤子域 |
  | `https://domain.com/*`（超宽域名，如 `google.com`） | `DOMAIN-SUFFIX,google.com` + **告警** | 见下「超宽域名处理」 |

- **超宽域名处理（P4）**：`https://google.com/*`（无 `*.` 前缀）会把整个 google 纳入 AI 组，存在过度代理风险。`gen-rules.sh` 内置一个「超宽域名排除清单」（硬编码在脚本内）：对 `google.com` 这类超宽域名，**默认不生成规则**，并打印告警「`google.com` 已被排除（过度代理风险），如需纳入请手工编辑 ai-domains.txt 删除该行或调整规则」。已有内联兜底 `gemini.google.com`、`aistudio.google.com` 仍单独走 AI 组，不受影响。

- **同步频率**：本期为「手动导出 + 网关侧 `gen-rules.sh` 重新生成」，不引入自动拉取；后续可在插件侧加「导出域名文件」按钮或网关侧定时同步（留作后续变更）。
- **降级**：`ai-domains.txt` 缺失时，`gen-rules.sh` 跳过插件域名源，生成空的 `rules/ai-plugin.yaml`（或含注释头说明为空），日志告警。

## build-config.sh 提取/合并算法（P1 拍板，阻塞开发项落地方案）

> 本节为「整段拷贝 + 正则重名检测」算法的可验证步骤描述，coder 必须严格按此实现，不得改为「逐字段解析 JSON」或「引入 python3」。

**输入**：`nodes/clash-*.yaml` + `nodes/clash.yaml`（id=`default`），排除 `*.example.yaml`。
**输出**：`nodes/_merged.yaml`，仅含 `proxies:` 段。

**算法步骤**：

1. **扫描**：`shopt -s nullglob` 后遍历 `nodes/clash-*.yaml`，排除 `*.example.yaml`；再把 `nodes/clash.yaml`（若存在）作为 id=`default` 追加。按 id 字典序稳定排序（`default` 排最前）。
2. **定位 proxies 段**（对每个文件）：
   - 用 `grep -n '^proxies:' "$f"` 定位起始行号 `start`；无该行 → 记「该文件无 proxies 段」，按空文件处理（P10 fixture）。
   - 用 `awk 'NR>start && /^[a-zA-Z-]+:/ {print NR; exit}'` 定位下一个「顶层 key」行号 `end`（即 `proxy-groups:`/`rules:` 等）；若无下一个顶层 key，`end = 文件总行数`。
   - **整段拷贝** `sed -n "${start},$((end-1))p" "$f"`，得到 `proxies:` 行及其下属所有内联节点行，**不逐字段解析**。
3. **提取节点 name 做重名检测**：对拷贝段里除 `proxies:` 外的每个 `- {...}` 行，用正则 `"name"\s*:\s*"([^"]*)"` 提取 `name`（`grep -oE`）。若某行无法提取 name（非标准内联 JSON），记警告但保留原行原样拷贝。

   > **重名检测的作用范围（S3 落定，边界说明）**：该正则 `"name"\s*:\s*"([^"]*)"` **仅对「单行内联 JSON 节点」生效**（即 `- {"name":"...","type":"ss",...}` 一条一行）。若机场订阅采用 **展开式 YAML 格式**（节点名换行缩进写成 `- name: xxx`，其余字段各自换行），则该正则无法提取节点名——此时 `build-config.sh` **降级为打印一条警告**（提示「检测到展开式格式节点，跳过该文件的重名检测」），并**跳过该文件的重名检测**，但仍按「整段拷贝」原样保留节点行。换言之：**展开式格式的文件不参与重名检测，仅做整段拷贝**。此边界是「不逐字段解析 YAML」这一 Non-Goals 约束的直接结果，属**已知限制**而非缺陷。
4. **重名检测**：跨文件维护一个「已见 name」集合（bash 关联数组或临时文件）。发现重复 name → **立即报错退出（非零）**，打印：
   ```
   节点重名：<name>（出现在 <fileA> 与 <fileB>）
   请在两处之一改名后重跑（本脚本不自动加前缀，避免破坏 dialer-proxy 引用）。
   ```
   放弃「自动加 `<id>-` 前缀」方案（原方案 B 的风险缓解），原因：加前缀会破坏节点名与 `dialer-proxy`/组内引用的对应关系，且改名本应由人确认。
5. **拼接输出**：`echo "proxies:"` 写入 `_merged.yaml`，随后按 id 顺序逐个 `cat` 各文件的拷贝段（去掉各自 `proxies:` 行）追加。**保留节点行原样（含内联 JSON），不做任何字段级改写**。
6. **空边界（P5）**：
   - 零机场（无任何 `clash*.yaml`）→ 生成合法 `proxies: []`（mihomo 可读的空 provider）。
   - 合并后「所有文件都无节点」（`proxies:` 后无任何 `- ` 行）→ **fail-fast 非零退出**，打印「未发现任何节点，请检查 nodes/ 下是否有 clash-*.yaml 机场文件」。
7. **退出码约定**：`0` 成功生成；非 `0` 失败（重名 / 全空 / 文件不可读）。`reload-nodes.sh` 依赖此退出码判断是否继续。

**可验证性**：第 2/3/6 步均可由 tasks 6 的 fixture 测试逐一断言（空 proxies、无 proxies 段、重名、name 含特殊字符如 `"` 转义）。此外新增「展开式格式节点」fixture：当节点写成 `- name: xxx` 换行缩进格式时，断言 `build-config.sh` 打印「跳过该文件重名检测」的降级警告、仍整段拷贝节点行、且不报重名错误（S3）。

## 文件范围

| 文件路径 | 修改类型 | 说明 |
|---------|---------|------|
| `config.yaml` | 修改 | proxy-providers 改为读 `_merged.yaml`（单 `airport`）+ 保留 `ai_airport`；proxy-groups 改为 filter 正则分组（`HK-STICKY` 香港组 + `AI-STICKY` AI 出口组，`GEN-STICKY`→改造为 `HK-STICKY`，`GEN-ROTATE`→香港轮询备用，`AI-FIXED`→保留备用）；rules 三级分流 + 一次性接入 `ai-plugin` rule-providers（`type: file` + `behavior: classical` + `format: text`） |
| `scripts/reload-nodes.sh` | 修改 | 去硬编码：动态遍历 `/providers/proxies` 与 `/proxies`；开头调用 `build-config.sh` 或校验 `_merged.yaml` 已 build（见编排）；API 不通失败退出 |
| `scripts/verify.sh` | 修改 | 去硬编码：动态遍历 provider 与组；移除 `check_ai` 美国硬编码判定 |
| `scripts/build-config.sh` | 新增 | 扫描 `nodes/clash-*.yaml`（+`clash.yaml`=default）整段拷贝合并到 `_merged.yaml`，正则重名检测、重名报错 |
| `scripts/gen-rules.sh` | 新增 | 读取 `nodes/ai-domains.txt` 生成 `rules/ai-plugin.yaml` 规则片段（不写 config.yaml） |
| `rules/ai-plugin.yaml` | 新增 | 插件域名规则片段（gen-rules.sh 产物，被 config rule-providers 引用） |
| `nodes/ai-domains.txt` | 新增 | 插件域名导出文件（每行一裸域名） |
| `nodes/clash.example.yaml` | 修改 | 补充多机场命名规范说明与示例 |
| `nodes/ai.example.yaml` | 修改 | 补充「AI 组是固定出口组、节点无需标称 AI」语义；说明 ai.yaml 不参与合并去重前缀 |
| `.gitignore` | 修改 | 补注释：`_merged.yaml` 命中 `nodes/*.yaml` 忽略；example 白名单维持 |
| `README.md` | 修改 | 更新多机场部署/维护说明 |
| `DEPLOY.md` | 修改 | 更新多机场部署/验证流程 |
| `openspec/changes/multi-airport/gate-review.md` | 修改 | 闸门评审结论（本变更产出物） |
| `docker-compose.yml` | ❌ 不修改 | 全局转发模型不变 |
| `www/proxy.pac.template`、`www/nginx.conf`、`www/15-sanitize-gateway.envsh` | ❌ 不修改 | PAC 客户端逻辑不变 |
| `scripts/{logs,claude-code-setup,macos-proxy-*,windows-proxy-*}.{sh,ps1}` | ❌ 不修改 | 与本次变更无关 |
| `chatgpt-block-bypass/**` | ❌ 不修改（跨仓库） | 仅作为域名列表数据源读取 |

## 同类路径对照

| 路径/脚本 | provider/组 来源 | 是否本次修改 | 备注 |
|----------|----------------|------------|------|
| `scripts/reload-nodes.sh` L13/23/30 | 硬编码 `airport ai_airport`、`AI-FIXED GEN-ROTATE AI-STICKY` | ✅ 修改为动态发现 | 本次核心去硬编码点 |
| `scripts/verify.sh` L38/44-46 | 硬编码 `airport ai_airport`、`AI-FIXED GEN-ROTATE AI-STICKY` | ✅ 修改为动态发现 | 与 reload 保持一致的发现逻辑 |
| `scripts/verify.sh` `check_ai` 函数 | 硬编码 `loc=US` 判定 | ✅ 修改为「可连通即通过 + 打印 loc」 | P2：AI 组不依赖地区 |
| `scripts/apply.sh` L18 | 提示语里硬编码组名 `AI-FIXED AI-STICKY GEN-STICKY` | ✅ 修改（提示语改为动态/泛化） | 仅 echo 提示，非逻辑，但应一并清理避免误导 |
| `config.yaml` proxy-groups `use:` | 硬编码 `[ai_airport]` / `[airport]` | ✅ 修改为 filter 聚合 | `HK-STICKY` 用 `filter` 正则；`AI-STICKY` 仍 `use: [ai_airport]`（固定出口，不依赖节点名） |
| `config.yaml` `proxy-providers.airport.path` | 指向 `nodes/clash.yaml` | ✅ 修改为指向 `nodes/_merged.yaml` | 合并产物 |
| `config.yaml` rules `MATCH` 兜底 | 指向 `GEN-STICKY`（美国 filter） | ✅ 修改为指向 `HK-STICKY` | 默认出口从美国改香港（决策已拍板）；`GEN-STICKY` 改造为 `HK-STICKY` |
| `config.yaml` rules 内联兜底 | 硬编码 AI 域名 | ✅ 修改（新增 `RULE-SET,ai-plugin` 于最前，保留内联兜底） | 三级分流改造 |
| `README.md` / `DEPLOY.md` | 文档中写死两文件、写死组名 | ✅ 修改 | 文档同步 |

## Risks / Trade-offs

- **节点名特征正则的脆弱性**：香港组依赖节点名含「香港/HK」关键词，机场命名不规范会导致分组为空，进而默认出口失效。缓解：`verify.sh` 对香港组做「非空告警」（香港组是默认出口，非空为硬性要求），提示检查正则。
- **重名节点即报错（P1 后）**：多机场节点同名时，合并脚本**报错退出而非自动加前缀**，要求用户改名。缓解：报错信息明确指出重名节点名与来源文件，改名成本低且安全（不破坏 dialer-proxy 引用）；README 记录此约定。
- **展开式格式不参与重名检测（S3）**：重名检测正则仅对「单行内联 JSON」节点生效，展开式 YAML 格式（`- name: xxx` 换行缩进）节点名无法提取，脚本降级为警告并跳过该文件重名检测。缓解：真实订阅（`/Users/penguin/Downloads/clash.yaml`）经分析为内联 JSON 格式，本期目标输入均命中重名检测；展开式格式属已知限制，`build-config.sh` 会打印明确警告提示人工核对重名。
- **香港组需排除特性节点（P8 修订）**：真实订阅里存在「禁止大流量-x10」「测试」等后缀节点，作为默认出口不应选中。缓解：香港组 `exclude-filter` 覆盖 `禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅`。**「家宽」已从排除列表移除**——住宅 IP 是 AI 出口的优质特征（与现有 config 注释、verify.sh 的 `classify_org` 把住宅 IP 当优质特征一致），不应在默认出口排除。
- **AI 出口组与节点名无关**：AI 组仅由 `nodes/ai.yaml` 手工池决定，节点名无需标称 AI。缓解：`ai.example.yaml` 说明文档明确「AI 组 = 固定出口组，节点来源任意」。
- **插件域名同步是手动**：本期无自动同步，域名变更需手动导出。缓解：明确记录为已知限制，后续变更补充自动同步。
- **超宽域名过度代理（P4）**：`google.com` 等无通配域名转 DOMAIN-SUFFIX 会过度代理。缓解：gen-rules.sh 内置排除清单 + 告警，超宽域名默认不生成规则。
- **geosite/geoip 依赖远程**：国内直连依赖规则集拉取，与现状一致（已有 China 规则集），不新增风险。
- **脚本编排顺序**：`build-config.sh`（合并节点）→ `gen-rules.sh`（生成规则）→ `reload-nodes.sh`（重载 provider）→ `apply.sh`（热加载 config）有依赖顺序，顺序错误会导致节点/规则不生效。缓解：`DEPLOY.md` 明确执行顺序，`build-config.sh` 末尾提示「下一步需 reload」。

## 脚本编排顺序（阻塞上线项的落地方案）

部署/更新流程固定顺序如下（写入 `DEPLOY.md`）：

```
1. scripts/build-config.sh    # 扫描 nodes/clash-*.yaml → 合并生成 nodes/_merged.yaml
2. scripts/gen-rules.sh       # 读 ai-domains.txt → 生成 rules/ai-plugin.yaml（首次还需手工接入 config rule-providers）
3. scripts/reload-nodes.sh    # 重载 provider（让 _merged.yaml 新节点生效）
4. scripts/apply.sh           # 热加载 config.yaml（让新 proxy-groups/rules 生效）
```

- `_merged.yaml` 为**每次 reload 前由 build-config.sh 重新生成**（非一次性）：机场文件增删后必须先跑 build 再 reload。
- **reload 前提是已 build（P13 澄清）**：`reload-nodes.sh` 只负责「重载已生成好的 provider」，**不隐式自动 build**。若 `_merged.yaml` 不存在或比 `nodes/clash-*.yaml` 旧，reload 开头检测并提示「请先执行 `scripts/build-config.sh`」（或直接退出非零）。这样 spec 中「新增机场后 reload 自动覆盖」的 Scenario 语义修正为「新增机场后需先 build 再 reload，reload 覆盖的是已 build 的新机场」，与方案 B 一致。
- `build-config.sh` 与 `reload-nodes.sh` 的编排：脚本保持单一职责，编排靠文档 + 人工流程 + reload 开头的前置校验，避免 reload 脚本隐式依赖。

## 待确认项（未阻塞，实现时可继续推进）

1. **google.com 等超宽域名的最终取舍**：本期由 gen-rules.sh 告警 + 排除清单缓解（默认不生成 google 规则，gemini/aistudio 已内联兜底），最终是否纳入由人工确认后调整 `ai-domains.txt`。
2. **香港组是否还需在地区之外叠加「线路质量」约束**（如仅选 IEPL/精品专线）：本期仅按「香港地区 + 排除特性节点」聚合，线路质量约束留待上线后根据实测节点质量人工调整 `exclude-filter`。
