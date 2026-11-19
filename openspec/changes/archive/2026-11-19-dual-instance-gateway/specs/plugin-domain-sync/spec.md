# plugin-domain-sync Specification

## REMOVED Requirements

### Requirement: 插件域名列表数据流

**Reason**: 用户拍板废弃整套 AI 域名同步机制——网关规则是全局共享状态，插件同步上来的任何用户级 AI 域名列表必然对所有用户生效，用户隔离无法靠「域名同步」实现。AI 域名判断回到插件侧（插件 PAC 按用户自己的配置列表决定走哪个网关端口），网关侧不再需要知道任何用户的 AI 域名列表。

**Migration**: 删除 `nodes/ai-domains.txt`、`scripts/gen-rules.sh`、`rules/ai-plugin.yaml`；网关配置不再包含 `rule-providers.ai-plugin`、`RULE-SET,ai-plugin`、内联 AI 兜底规则与远程 AI 规则集。插件仓库 `chatgpt-block-bypass` 单独开变更：`background.js` 的 `proxyServer` 双端口化（AI `7890` / 通用 `7891`），PAC 按用户 `proxyDomains` 直接分流，不再向网关导出域名。

### Requirement: 兜底与可降级

**Reason**: 该需求服务于「网关侧域名同步失败时仍能靠规则集与内联兜底完成 AI 分流」的降级路径；同步机制整体废弃后，网关侧已不存在 AI 域名规则与兜底需求——AI 域名判定全部由客户端 PAC 完成，客户端判定失败时请求落点即通用实例（香港兜底），不存在网关侧降级场景。

**Migration**: 网关配置移除全部 AI 域名规则（本地规则集、远程规则集、内联兜底）。全局 PAC 模板内置静态核心 AI 域名清单（旧内联兜底保留项 10 个 + 插件 `defaultProxyDomains` 独有项 4 个 + 旧远程 Perplexity 规则集核心站 1 个，共 15 个，构成口径见 dual-instance-gateway spec「全局 PAC 双端口分流」与 design 决策 5）作为非插件用户的 AI 分流路径，其降级语义为 `PROXY ...; DIRECT` 兜底。

## ADDED Requirements

### Requirement: AI 域名同步能力退役

网关侧 AI 域名同步能力 MUST NOT 继续存在；本 spec 退役后 SHALL 仅保留本退役记录，所有活跃 requirement 已随机制回退移除，重新引入 SHALL 以新变更显式提案。

- 回退原因：网关规则是全局共享状态，插件同步上来的任何用户级 AI 域名列表必然对所有用户生效，用户隔离无法靠「域名同步」实现；AI 域名判断回到插件侧（插件 PAC 按用户自己的配置列表决定走哪个网关端口），网关侧不再需要知道任何用户的 AI 域名列表。
- 迁移路径：删除 `nodes/ai-domains.txt`、`scripts/gen-rules.sh`、`rules/ai-plugin.yaml`；网关配置不再包含 `rule-providers.ai-plugin`、`RULE-SET,ai-plugin`、内联 AI 兜底规则与远程 AI 规则集；插件仓库 `chatgpt-block-bypass` 单独开变更完成 PAC 双端口化（AI `7890` / 通用 `7891`）。

#### Scenario: 退役后仅存记录

- **WHEN** 查看 plugin-domain-sync spec
- **THEN** 只存在本退役记录 requirement，不存在任何 AI 域名同步活跃 requirement
