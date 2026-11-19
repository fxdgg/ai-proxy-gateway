# country-routing-gateway Specification

## REMOVED Requirements

### Requirement: 国家节点组与地区聚合

**Reason**: 用户拍板撤销「域名→国家」功能（country-routing-gateway 全部回退）。国家分流的入口数据 `ai-domains-country.txt` 同样来自插件导出，与 AI 域名同步存在相同的全局生效/用户隔离问题；双实例架构下「域名→国家」的判定同样必须回到客户端，网关侧不再维护任何域名级绑定。

**Migration**: 删除 `config.yaml` 的 7 国组（`JP/US/SG/TW/KR/GB/DE-STICKY`）、`rule-providers.ai-plugin-country`、`RULE-SET,ai-plugin-country`；删除 `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`；`verify.sh` 移除国家组非空检查与 7 国 dry-run 节；README/DEPLOY 移除国家分流文档。插件侧「导出国家分流规则」功能的去留由插件仓库变更跟进。

### Requirement: 国家分流规则生成

**Reason**: 该需求描述 `gen-country-rules.sh` 将「域名→国家代码」两列数据转换为规则片段的解析/校验链；机制整体回退后脚本、数据源与产物全部删除，规则生成链路不复存在。

**Migration**: 删除 `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`。域名级分流由客户端 PAC 完成（插件 PAC 按用户配置、全局 PAC 按静态清单），无网关侧生成步骤。

### Requirement: 国家分流规则接入与优先级

**Reason**: 该需求描述 `rule-providers.ai-plugin-country` 与 `rules` 最前 `RULE-SET,ai-plugin-country` 的接入方式及最高优先级语义；国家分流回退后该接入不复存在，双实例规则收敛为 AI 实例 `MATCH` 单规则与通用实例 CN 直连 + HK 兜底。

**Migration**: 新配置文件 `config-main.yaml` / `config-ai.yaml` 不包含 `ai-plugin-country` 相关段；通用实例规则顺序为 `Private/Block → China → GEOIP,CN → MATCH,HK-STICKY`，AI 实例仅 `MATCH,AI-US-STICKY`。

### Requirement: 前置验证与部署校验

**Reason**: 该需求描述建组前的 7 国正则 dry-run 命中率验证与 `verify.sh` 的国家组非空检查；国家组全部移除后，校验对象不复存在。双实例下的部署校验由 `dual-instance-gateway` 能力承接（AI 组非空 + HK 组非空 + 两实例出口连通）。

**Migration**: `verify.sh` 删除 `is_country_group` 判定、国家组硬失败分支、2b 节（7 国 dry-run 全部逻辑）与结尾国家组提示行，改为双实例校验（AI 实例校验组名含 AI 的组、通用实例校验组名含 HK/香港 的组）；DEPLOY.md 删除「国家分流上线前复核（先复核、后上线）」段。

## ADDED Requirements

### Requirement: 国家分流能力退役

「域名→国家」分流能力 MUST NOT 继续存在于网关侧；本 spec 退役后 SHALL 仅保留本退役记录，所有活跃 requirement 已随机制回退移除，重新引入 SHALL 以新变更显式提案。

- 回退原因：国家分流的入口数据来自插件导出，与 AI 域名同步存在相同的全局生效/用户隔离问题；双实例架构下「域名→国家」判定同样必须回到客户端，网关侧不再维护任何域名级绑定。
- 迁移路径：删除 7 国组（`JP/US/SG/TW/KR/GB/DE-STICKY`）、`rule-providers.ai-plugin-country`、`RULE-SET,ai-plugin-country`；删除 `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml`；`verify.sh` 移除国家组非空检查与 7 国 dry-run 节；README/DEPLOY 移除国家分流文档。

#### Scenario: 退役后仅存记录

- **WHEN** 查看 country-routing-gateway spec
- **THEN** 只存在本退役记录 requirement，不存在任何国家分流活跃 requirement
