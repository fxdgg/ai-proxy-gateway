# country-routing-gateway Specification

## Purpose
TBD - created by archiving change country-routing-gateway. Update Purpose after archive.
## Requirements
### Requirement: 国家分流能力退役

「域名→国家」分流能力 MUST NOT 继续存在于网关侧；本 spec 退役后 SHALL 仅保留本退役记录，所有活跃 requirement 已随机制回退移除，重新引入 SHALL 以新变更显式提案。

- 回退原因：国家分流的入口数据来自插件导出，与 AI 域名同步存在相同的全局生效/用户隔离问题；双实例架构下「域名→国家」判定同样必须回到客户端，网关侧不再维护任何域名级绑定。
- 迁移路径：删除 7 国组（`JP/US/SG/TW/KR/GB/DE-STICKY`）、`rule-providers.ai-plugin-country`、`RULE-SET,ai-plugin-country`；删除 `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`；`verify.sh` 移除国家组非空检查与 7 国 dry-run 节；README/DEPLOY 移除国家分流文档。

#### Scenario: 退役后仅存记录

- **WHEN** 查看 country-routing-gateway spec
- **THEN** 只存在本退役记录 requirement，不存在任何国家分流活跃 requirement

