## Why

插件仓库 `chatgpt-block-bypass` 已归档 Change `2026-11-19-domain-country-routing`，完成「域名按国家选节点」能力：用户在插件里为代理域名绑定目标国家（香港/日本/美国/新加坡/台湾/韩国/英国/德国 8 选 1），一键导出「`域名<TAB>国家代码`」文本到剪贴板，人工粘贴落地到网关 `nodes/ai-domains-country.txt`。

但网关侧目前没有任何配套能力，粘贴落地的数据是「死数据」，国家分流完全不生效：

1. **国家出口组缺失**：`config.yaml` 的 `proxy-groups` 只有 `HK-STICKY` 一个地区聚合组，`JP-STICKY`/`US-STICKY`/`SG-STICKY`/`TW-STICKY`/`KR-STICKY`/`GB-STICKY`/`DE-STICKY` 这 7 个国家组不存在，导出文件里的国家代码没有对应出口组可指；
2. **无规则生成脚本**：没有脚本把两列格式的 `ai-domains-country.txt` 转成 clash 规则，国家绑定不进入任何路由判定；
3. **规则未接入**：`config.yaml` 没有引用国家分流规则集，即使生成了规则也不生效；
4. **无部署检查**：`verify.sh` 没有国家组非空检查，组为空/组缺失无法在部署时发现（mihomo 加载悬空组规则会直接失败）。

结果：插件侧「按国家选节点」能力在网关侧完全失效，用户绑定国家后流量仍走默认出口（`AI-STICKY` 或 `HK-STICKY`）。本变更为网关侧配套，补齐「数据文件 → 规则生成 → 路由生效 → 部署校验」的完整链路。

## What Changes

在 `ai-proxy-gateway` 仓库完成 5 项能力，对应插件侧定稿「决策 5」的 G0-G7 改动清单：

1. **G0 前置验证（7 国正则 dry-run 命中率）**：建组前对当前 `nodes/_merged.yaml` 节点名统计 7 国地区关键词命中数；真实节点数据下任一国家命中为 0 需先补节点或调整正则，通过后再建组；模板/示例数据或 build 产物无节点行（`proxies: []`）时产出「待部署环境复核」验证记录、不阻塞建组，部署环境 dry-run 复核为最终闸门。
2. **G1 国家节点组**：`config.yaml` `proxy-groups` 新增 `JP-STICKY`/`US-STICKY`/`SG-STICKY`/`TW-STICKY`/`KR-STICKY`/`GB-STICKY`/`DE-STICKY` 共 7 组，复用 `HK-STICKY` 的 `filter` 地区正则模式（对应国家关键词）+ 同款 `exclude-filter`，`strategy: sticky-sessions`，`use: [airport]`（全量池，非 `ai_airport`）。
3. **G2 独立脚本 `scripts/gen-country-rules.sh`**：读取两列格式 `nodes/ai-domains-country.txt`，产出 `rules/ai-plugin-country.yaml`（每行 `DOMAIN-SUFFIX,<域名>,<国家组>`），含完整解析健壮性（8 枚举校验、域名分段校验、组存在性运行时校验、超宽域名排除、重复行保留末行、按读入顺序生成、缺失文件降级）。
4. **G3/G4 rule-provider 接入与优先级**：`config.yaml` 新增 `rule-providers.ai-plugin-country`（`type: file` + `behavior: classical` + `format: text` + `path: rules/ai-plugin-country.yaml`），并在 `rules` **最前**加 `RULE-SET,ai-plugin-country`（置于 `RULE-SET,ai-plugin` 之前，保证国家分流最高优先级）。
5. **G5-G7 数据文件、产物与部署校验**：新增 `nodes/ai-domains-country.txt` 数据源文件（注释头 + 操作约定）；新增 `rules/ai-plugin-country.yaml` 脚本产物；`scripts/verify.sh` 新增国家组非空检查（完整锚定模式 `^(JP|US|SG|TW|KR|GB|DE)-STICKY$`）+ 7 国正则 dry-run；更新 `README.md`/`DEPLOY.md`。

## Capabilities

### New Capabilities

- `country-routing-gateway`: 网关侧国家分流配套能力，覆盖 4 个子能力：
  - **国家节点组聚合**：按节点名地区关键词跨机场聚合 7 个国家节点组（复用 `HK-STICKY` 已验证模式）；
  - **国家分流规则生成**：`gen-country-rules.sh` 将「域名 → 国家代码」两列数据转换为带组名的 `DOMAIN-SUFFIX` 规则片段；
  - **国家分流规则接入**：`rule-providers.ai-plugin-country` + `rules` 最前 `RULE-SET`，保证国家分流优先级高于 AI 默认出口；
  - **前置验证与部署校验**：G0 命中率 dry-run 前置验证 + `verify.sh` 国家组非空检查与持续 dry-run。

## Impact

- **配置文件**：`config.yaml`（`proxy-groups` 新增 7 组、`rule-providers` 新增 `ai-plugin-country`、`rules` 最前新增 `RULE-SET,ai-plugin-country`）
- **脚本**：新增 `scripts/gen-country-rules.sh`；修改 `scripts/verify.sh`
- **数据/产物**：新增 `nodes/ai-domains-country.txt`（数据源，插件导出产物落地于此）；新增 `rules/ai-plugin-country.yaml`（脚本产物）
- **文档**：`README.md`、`DEPLOY.md`（国家分流部署/维护流程）
- **跨仓库**：依赖 `chatgpt-block-bypass` 已完成的导出能力（仅消费其导出格式约定 `域名<TAB>国家代码`，不改插件仓库）；三条跨仓库强约束（组名公式 `<code>-STICKY`、超宽域名清单 `BROAD_DOMAINS`/`BROAD_DOMAIN_DENYLIST`、域名分段校验语义）列为一致性检查项
- **不修改**：`scripts/gen-rules.sh`、`nodes/ai-domains.txt`、`rules/ai-plugin.yaml`（现有 AI 域名链路）、`scripts/build-config.sh`、`scripts/apply.sh`、`scripts/reload-nodes.sh`、`docker-compose.yml`、`www/`、`.gitignore`
