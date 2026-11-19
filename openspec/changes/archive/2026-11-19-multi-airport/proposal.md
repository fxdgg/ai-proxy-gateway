## Why

当前 `ai-proxy-gateway` 是「单机场」设计：`config.yaml` 里 `proxy-providers` 写死了两个 file provider——`airport`（读 `nodes/clash.yaml` 全量池）和 `ai_airport`（读 `nodes/ai.yaml` AI 专用池）。运维侧的两个脚本也硬编码了这些名字：

- `scripts/reload-nodes.sh` 第 13/23 行写死 `airport ai_airport` 两个 provider 名，第 30 行写死 `AI-FIXED GEN-ROTATE AI-STICKY` 三个组名。
- `scripts/verify.sh` 第 38 行写死 provider 名，第 44-46 行写死组名。

这带来三个痛点：

1. **无法接入多个机场**：真实机场订阅（如 `/Users/penguin/Downloads/clash.yaml`，1845 行）是「订阅式」格式，只含 `proxies:` + `proxy-groups:`（单 `Proxy` select 组）+ `rules:`，**没有 proxy-providers**，且各机场节点命名风格、线路划分、proxy-groups 结构差异很大。现有 config 只认 `nodes/clash.yaml`、`nodes/ai.yaml` 两个固定文件，加第二个机场就要手改 config + 脚本，无法规模化。
2. **脚本硬编码**：每加一个机场/组，就要改 `reload-nodes.sh` 和 `verify.sh` 的写死名单，易漏、易错、不可扩展。
3. **分流规则依赖远程规则集 + 内联兜底，未与浏览器插件联动**：`config.yaml` 的 rules 依赖 `gh-proxy.com` 镜像拉取的 rule-providers，且有内联兜底域名；而 `chatgpt-block-bypass` 插件在 `background.js` 里硬编码了一份 `defaultProxyDomains`（PAC glob 格式，如 `https://*.openai.com/*`）。两份 AI 域名清单各自维护、无法复用，插件里用户新增的域名不会同步到网关。

## What Changes

在 `ai-proxy-gateway` 仓库内完成四项能力（对应需求 1-4）：

1. **多机场文件发现与聚合**：约定 `nodes/` 下的机场订阅文件命名规范（`clash-a.yaml`、`clash-b.yaml` …，兼容 `clash.yaml` 作为默认机场），由脚本动态扫描发现，`config.yaml` 通过生成式合并（`build-config.sh` 产出 `_merged.yaml`）聚合多机场节点到「AI 节点组」「香港节点组」等逻辑组。
2. **节点分组策略**：从「按文件名固定池」演进为「按地区特征动态分组」，使不同机场的同地区节点能聚合到同一逻辑组（如所有机场的香港节点 → 香港组）。AI 组则是「固定出口组」——仅作为 AI 域名的出口分组名，由人工从通用节点中选定若干作为 AI 出口，**不要求节点本身标称 AI**。
3. **脚本去硬编码**：`reload-nodes.sh` / `verify.sh` 改为动态发现 provider 与组名，零硬编码。
4. **分流规则生成（网关侧三级分流）**：网关侧生成/合并 clash rules，三级分流为「插件域名 → AI 组 → 国内直连 → 香港组兜底」，并设计从 `chatgpt-block-bypass` 插件域名列表到网关规则的联动数据流。其中「未匹配插件域名、也非国内」的海外流量默认出口为香港组。

## Capabilities

### New Capabilities

- `multi-airport-discovery`: 自动扫描 `nodes/` 下多机场订阅文件，动态发现 provider 与节点分组，替代硬编码的 `airport`/`ai_airport`。
- `node-group-aggregation`: 按地区特征（香港等）跨机场聚合节点到逻辑分组；AI 组为「固定出口组」（人工选定通用节点，不依赖节点名标称 AI）。
- `rules-generation`: 网关侧生成/合并三级分流 rules（插件域名 → AI 组 → 国内直连 → 香港组兜底）。

### Modified Capabilities

- `plugin-domain-sync`: 读取 `chatgpt-block-bypass` 插件的域名列表（`background.js` 的 `defaultProxyDomains`），设计网关侧获取/合并该域名清单的数据流，替代当前「网关内联兜底 + 插件各自维护」的割裂状态。

## Impact

- **配置文件**：`config.yaml`（proxy-providers / proxy-groups / rules 结构改造）
- **脚本**：`scripts/reload-nodes.sh`、`scripts/verify.sh`（去硬编码），新增 `scripts/build-config.sh`（节点合并）、`scripts/gen-rules.sh`（规则片段生成）
- **节点/规则文件**：`nodes/` 目录约定（命名规范、`.gitignore` 调整、example 文件更新）、`rules/ai-plugin.yaml`（插件域名规则片段）
- **文档**：`README.md`、`DEPLOY.md`（部署/维护流程更新）
- **跨仓库**：`chatgpt-block-bypass` 仓库（仅读取其域名列表格式，作为数据源；本变更不修改该仓库，除非后续单独立项）
- **无**：docker-compose.yml、www/ 前端 PAC 逻辑（全局 PAC 仍「全量转发、服务端判定」，不改）
