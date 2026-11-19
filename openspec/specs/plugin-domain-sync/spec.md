# plugin-domain-sync Specification

## Purpose
TBD - created by archiving change multi-airport. Update Purpose after archive.
## Requirements
### Requirement: AI 域名同步能力退役

网关侧 AI 域名同步能力 MUST NOT 继续存在；本 spec 退役后 SHALL 仅保留本退役记录，所有活跃 requirement 已随机制回退移除，重新引入 SHALL 以新变更显式提案。

- 回退原因：网关规则是全局共享状态，插件同步上来的任何用户级 AI 域名列表必然对所有用户生效，用户隔离无法靠「域名同步」实现；AI 域名判断回到插件侧（插件 PAC 按用户自己的配置列表决定走哪个网关端口），网关侧不再需要知道任何用户的 AI 域名列表。
- 迁移路径：删除 `nodes/ai-domains.txt`、`scripts/gen-rules.sh`、`rules/ai-plugin.yaml`；网关配置不再包含 `rule-providers.ai-plugin`、`RULE-SET,ai-plugin`、内联 AI 兜底规则与远程 AI 规则集；插件仓库 `chatgpt-block-bypass` 单独开变更完成 PAC 双端口化（AI `7890` / 通用 `7891`）。

#### Scenario: 退役后仅存记录

- **WHEN** 查看 plugin-domain-sync spec
- **THEN** 只存在本退役记录 requirement，不存在任何 AI 域名同步活跃 requirement

