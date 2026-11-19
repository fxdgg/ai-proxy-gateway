# Proposal: 双实例网关重构 + 机制回退

## Why

当前网关是**单 mihomo 实例**，网关侧规则对全部用户全局生效。用户发现多人共享网关时存在根本性的隔离缺陷：A 用户在浏览器插件里配置的 AI 域名经「域名同步」落地到网关 `nodes/ai-domains.txt` 后，B 用户访问同一域名也会走 AI 节点——**用户隔离无法靠「域名同步」实现**。因为网关规则是共享的全局状态，任何用户级配置一旦进入网关就必然全局生效。

用户最终拍板三条（不可更改）：

1. **双实例网关**：docker 起两个 mihomo 实例（共享同一份节点池文件）——AI 出口实例（端口 7890）：规则只有 `MATCH → AI-US 组`（美国节点）；通用出口实例（端口 7891）：`geosite/geoip CN → DIRECT`、`MATCH → HK-STICKY`（香港节点兜底）。
2. **AI 域名判断回到插件侧**：插件 PAC 按用户自己的配置列表决定走哪个端口。网关侧不再需要知道任何用户的 AI 域名列表 → **废弃整套 AI 域名同步机制**（`nodes/ai-domains.txt`、`scripts/gen-rules.sh`、`rules/ai-plugin.yaml`、`rule-providers.ai-plugin` 与 `RULE-SET,ai-plugin,AI-STICKY`）。
3. **撤销「域名→国家」功能**：上一变更 country-routing-gateway 全部回退（7 国组、`ai-plugin-country` 规则链、`gen-country-rules.sh`、数据/产物文件、verify.sh 国家组检查与 7 国 dry-run、README/DEPLOY 国家分流文档）。

双实例后，用户隔离天然成立：A 用户的插件 PAC 把 A 的 AI 域名发往 AI 端口，B 用户的插件 PAC 把 B 的 AI 域名发往 AI 端口——**每个用户的域名清单留在各自浏览器里，网关对 AI 域名零感知**；不走插件的流量一律去通用实例，走香港兜底，互不干扰。

## What Changes

在 `ai-proxy-gateway` 仓库完成「双实例重构 + 两项机制回退」，共 6 大块：

1. **回退 AI 域名同步机制**：删除 `nodes/ai-domains.txt`、`scripts/gen-rules.sh`、`rules/ai-plugin.yaml`；新配置不再包含 `rule-providers.ai-plugin` 与 `RULE-SET,ai-plugin`，同时删除内联 AI 兜底规则（10 条 `DOMAIN-KEYWORD/DOMAIN-SUFFIX`）与全部远程 AI 规则集（AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity）——AI 域名判定完全回到客户端。
2. **回退国家分流（country-routing-gateway 全部撤销）**：删除 `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`；新配置不再包含 7 国组（JP/US/SG/TW/KR/GB/DE-STICKY）、`rule-providers.ai-plugin-country`、`RULE-SET,ai-plugin-country`；`verify.sh` 移除国家组检查与 7 国 dry-run 节；README/DEPLOY 移除国家分流文档。
3. **双实例部署形态**：`docker-compose.yml` 改为 `gateway-ai` + `gateway-main` 两个 mihomo 服务（host 网络），共享 `./nodes` 只读挂载；端口约定 AI `7890`/通用 `7891`（管理 API `9090`/`9091`），旧 `10800` 弃用（迁移期由 AI 实例以 mihomo `listeners` 入站段默认启用过渡监听——mihomo 无顶层 `ports` 字段，见 design 决策 8）。
4. **配置文件拆分**：`config.yaml` 拆为 `config-main.yaml`（通用实例：CN 直连 + MATCH→HK-STICKY）与 `config-ai.yaml`（AI 实例：MATCH→AI-US-STICKY，美国正则 filter 聚合机场节点）；AI 手工池 `ai_airport`/`nodes/ai.yaml` 机制废弃，`AI-US-STICKY` 与 `HK-STICKY` 同模式（`use: [airport]` + filter）。
5. **脚本双实例改造**：`reload-nodes.sh`/`apply.sh` 默认作用于两个实例（API 端口常量约定 + 环境变量/参数覆盖）；`verify.sh` 双实例校验（AI 组非空 + HK 组非空 + 各自出口连通），移除国家分流检查；`logs.sh`/`claude-code-setup.sh`/`macos-proxy-manual-on.sh` 端口常量更新；`claude-code-setup.sh` 同时新增 `NO_PROXY` 内网段导出与「CLI 全量代理绕美」副作用提示（CLI 环境变量代理无 PAC，7890 无国内直连兜底）。
6. **全局 PAC 双端口分流**：`www/proxy.pac.template` 改为「静态核心 AI 域名 → AI 实例端口、其余 → 通用实例端口」，新增 `AI_GATEWAY_ADDR` 环境变量；README/DEPLOY 全面更新双实例架构、端口约定、部署流程。

## Capabilities

### New Capabilities

- `dual-instance-gateway`: 双实例网关架构能力，覆盖 5 个子能力：
  - **双实例部署形态**：两个 mihomo 容器服务 + 共享节点池挂载 + 固定端口约定（AI 7890/9090、通用 7891/9091）；
  - **AI 出口实例**：仅 `MATCH → AI-US-STICKY`（美国正则 filter 跨机场聚合）；
  - **通用出口实例**：CN 直连 + `MATCH → HK-STICKY` 香港兜底；
  - **脚本双实例化**：reload/apply/verify 默认作用于两个实例，端口约定统一；
  - **全局 PAC 双端口分流**：静态核心 AI 域名 → AI 端口、其余 → 通用端口。

### Modified Capabilities

- `multi-airport`: AI 出口组语义变化（手工池 `ai.yaml` → 美国正则 filter 聚合）；三级分流被双实例拆分取代；脚本动态发现扩展为双实例维度。

### Removed Capabilities

- `plugin-domain-sync`: AI 域名同步机制整体废弃（AI 域名判断回到插件侧）。
- `country-routing-gateway`: 「域名→国家」功能全部回退。

## Impact

- **配置文件**：删除 `config.yaml`；新增 `config-main.yaml`、`config-ai.yaml`（AI 出口组 filter 聚合、通用组去留、规则回退全在此落地）
- **部署**：`docker-compose.yml` 双服务改造；`.env.example` 新增 `AI_GATEWAY_ADDR`、`GATEWAY_ADDR` 改通用端口
- **PAC**：`www/proxy.pac.template` 双端口分流；`www/15-sanitize-gateway.envsh` 清洗双变量
- **脚本**：修改 `reload-nodes.sh`、`apply.sh`、`verify.sh`、`logs.sh`、`claude-code-setup.sh`、`macos-proxy-manual-on.sh`；删除 `gen-rules.sh`、`gen-country-rules.sh`
- **数据/产物**：删除 `nodes/ai-domains.txt`、`nodes/ai-domains-country.txt`、`nodes/ai.example.yaml`、`rules/ai-plugin.yaml`、`rules/ai-plugin-country.yaml`（`rules/` 目录清空）；`.gitignore` 移除 `ai.example.yaml` 白名单、`nodes/ai.yaml` 忽略行与注释中 ai.yaml 字样
- **文档**：`README.md`、`DEPLOY.md` 双实例架构重写
- **跨仓库**：插件仓库 `chatgpt-block-bypass` 的 PAC 端口改造**单独开变更**（本变更仅定死端口约定供其对齐：AI `7890`、通用 `7891`）；旧 `10800` 的迁移过渡在本变更中提供可选兼容监听
- **不修改**：`scripts/build-config.sh`（合并算法与实例数无关，`_merged.yaml` 两实例共享）、`nodes/clash.example.yaml`、`www/nginx.conf`、`scripts/macos-proxy-on.sh`/`macos-proxy-off.sh`、`scripts/windows-proxy-on.ps1`/`windows-proxy-off.ps1`
