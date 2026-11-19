## ADDED Requirements

### Requirement: 插件域名列表数据流

网关侧 SHALL 获取并合并 `chatgpt-block-bypass` 插件维护的 AI 默认域名列表，形成统一的 AI 分流数据源，替代「插件各自硬编码 + 网关内联兜底」的割裂状态。

> **覆盖范围标注（P7）**：本 Requirement 本期**部分覆盖**——网关侧 MUST 仅覆盖 `defaultProxyDomains`（插件 `background.js` 中的硬编码默认域名）。`chrome.storage.local` 中用户自定义的 `proxyDomains` 因无导出机制，**本期不实现同步**，留待后续变更（需插件侧先增加导出能力）。

- 插件域名列表的权威存储位置是 `background.js` 中的 `defaultProxyDomains`（PAC glob 格式，如 `https://*.openai.com/*`）。用户自定义域名在 `chrome.storage.local` 的 `proxyDomains`，本期不纳入同步范围。
- 网关侧通过约定机制（人工导出 `nodes/ai-domains.txt`）读取该列表，并转换为 clash 的 `DOMAIN-SUFFIX` / `DOMAIN` 规则。
- PAC glob 格式到 clash 规则的转换需正确处理 `*.domain.com` 通配（转换为 `DOMAIN-SUFFIX,domain.com`）与精确域名（转换为 `DOMAIN,domain.com`，超宽域名如 google.com 由脚本告警排除）。

#### Scenario: 从插件默认域名生成规则

- **WHEN** 插件 `defaultProxyDomains` 含 `https://*.openai.com/*`、`https://chatgpt.com/*`
- **THEN** 网关生成 `DOMAIN-SUFFIX,openai.com,AI出口组` 与 `DOMAIN-SUFFIX,chatgpt.com,AI出口组` 规则

#### Scenario: 用户新增域名同步到网关（后续变更）

- **WHEN** 用户在插件 popup 中新增域名 `*.foo.com/*`
- **THEN** 本期**不实现**同步（用户自定义域名无导出机制）；需插件侧先提供「导出域名文件」能力后再由后续变更纳入 AI 分流

### Requirement: 兜底与可降级

网关侧域名同步失败时，系统 MUST 仍能基于现有 rule-providers 与内联兜底规则正常工作，不因插件不可用而失效。

#### Scenario: 插件仓库不可用时

- **WHEN** 无法读取插件域名列表（文件缺失/网络不可达）
- **THEN** 网关仍使用 rule-providers 与内联兜底规则完成 AI 分流，日志给出警告
