# multi-airport Specification

## RENAMED Requirements

- FROM: `### Requirement: 分流规则三级生成`
- TO: `### Requirement: 分流规则生成`

## MODIFIED Requirements

### Requirement: 多机场节点聚合分组

跨机场节点 MUST 按「地区特征」聚合到逻辑分组（香港节点组、美国节点组等），使不同机场的同地区节点 SHALL 落入同一组。AI 出口组为美国地区聚合组（`AI-US-STICKY`），同样按节点名地区正则聚合，不依赖任何手工池文件。

- 香港组分组依据节点名中的地区关键词（正则），而非文件名或 provider 名。
- AI 出口组 `AI-US-STICKY` 依据美国地区关键词正则（`(?i)(美国|United ?States|America|\bUS\b|\bUSA\b)`）+ 同款 `exclude-filter` 从全量池 `airport`（`nodes/_merged.yaml`）聚合，SHALL 复用 `HK-STICKY` 的组模式（`sticky-sessions`）。
- `AI-US-STICKY` 的 exclude-filter MUST NOT 含「中国」——刻意不同于旧 `AI-STICKY`（美国落地节点常带「中国优化」字样，排除反而误杀）；实现 MUST 以 design 决策 3 的组定义为准，MUST NOT 照抄旧 `AI-STICKY`。
- AI 出口组 MUST NOT 依赖 `ai_airport` 手工池 provider（`nodes/ai.yaml`）；该手工池机制已废弃，住宅等补充节点 SHALL 通过命名含「美国」的机场节点进入 `_merged.yaml` 后被聚合。
- 聚合结果为「逻辑组 → 节点列表」的映射，供 proxy-groups 使用。

#### Scenario: 跨机场香港节点聚合

- **WHEN** 机场 A 有节点 `IEPL企业专线-香港01`，机场 B 有节点 `香港-BGP-01`
- **THEN** 香港节点组同时包含这两个节点，且可追溯到各自来源机场

#### Scenario: 美国节点自动聚合为 AI 出口组

- **WHEN** `nodes/_merged.yaml` 中存在节点名含「美国」等关键词的机场节点（如 `IX精品专线-美国01-...`）
- **THEN** `AI-US-STICKY` 组自动包含这些节点，无需手工池文件、无需节点登记

#### Scenario: AI 出口组不依赖手工池

- **WHEN** 仓库不存在 `nodes/ai.yaml`（手工池机制已废弃）
- **THEN** `AI-US-STICKY` 仍从共享节点池按美国正则聚合出全部美国节点，AI 出口能力不受影响

### Requirement: 分流规则生成

网关 MUST 以双实例拆分的方式实现分流：AI 出口实例（`MATCH → AI-US-STICKY`）与通用出口实例（国内直连 + `MATCH → HK-STICKY`），AI 域名判定 SHALL 由客户端（插件 PAC / 全局 PAC）完成，网关侧 SHALL NOT 维护任何 AI 域名规则。

- AI 出口实例 `rules` SHALL 仅含 `MATCH,AI-US-STICKY`，无 `rule-providers`、无域名规则。
- 通用出口实例 `rules` 顺序 SHALL 固定且不可颠倒：① 内网/拦截（`Private` DIRECT、`Block` REJECT）；② 国内（`geosite:cn`/`geoip:cn`）→ 直连；③ 其余（MATCH 兜底）→ 香港组（默认出口）。
- 国内直连数据源 MUST 使用 geosite/geoip 规则集（`China` 规则集 + `GEOIP,CN`），而非手写域名清单。
- 未命中直连规则的海外流量，默认出口为香港组。
- 客户端 PAC（插件或全局 PAC）SHALL 负责把 AI 域名发往 AI 实例端口（`7890`），其余流量发往通用实例端口（`7891`）。

#### Scenario: AI 域名经客户端 PAC 走 AI 实例

- **WHEN** 客户端 PAC 命中用户/静态 AI 域名清单
- **THEN** PAC 把请求发往 `7890`，AI 实例以 `MATCH → AI-US-STICKY` 美国出口

#### Scenario: 国内域名直连

- **WHEN** 请求域名/IP 命中 `geosite:cn` 或 `geoip:cn`（通用实例）
- **THEN** DIRECT 直连，不经过任何代理节点

#### Scenario: 未匹配海外走香港组

- **WHEN** 请求既非国内、也非客户端 PAC 判定的 AI 域名
- **THEN** 经通用实例走香港节点组出口

### Requirement: 脚本动态发现（去硬编码）

`reload-nodes.sh` 与 `verify.sh` MUST NOT 硬编码任何 provider 名或组名，SHALL 全部动态发现；脚本 SHALL 按固定端口约定默认作用于两个实例。

- provider 名、组名通过调用 mihomo API 或扫描配置文件动态获取，脚本对任意数量的机场、任意数量的逻辑组均正确工作。
- 实例 API 地址 SHALL 为固定约定（AI `127.0.0.1:9090`、通用 `127.0.0.1:9091`），支持位置参数覆盖；实例地址属于部署约定而非 provider/组名，不违反本要求。
- `reload-nodes.sh` 默认 MUST 对两个实例均执行 provider 重载与健康检查；`verify.sh` 默认 MUST 分别校验两实例的硬性组（AI 实例「组名含 AI」、通用实例「组名含 HK/香港」）。

#### Scenario: 新增机场后无需改脚本

- **WHEN** 在 `nodes/` 下新增 `clash-c.yaml`，先执行 `build-config.sh` 合并，再执行 `reload-nodes.sh` 重载
- **THEN** `reload-nodes.sh` 自动覆盖两个实例的 provider 与节点，无需修改脚本代码（reload 前提是已 build，见 design 编排顺序）

#### Scenario: 组名变化后无需改脚本

- **WHEN** 配置文件中逻辑组名调整（如香港组改名）
- **THEN** `verify.sh` 自动发现新组名并按「组名含 HK/香港、组名含 AI」的判定逐实例校验，无需修改脚本

#### Scenario: 双实例默认全覆盖

- **WHEN** 管理员不带参数执行 `reload-nodes.sh` 或 `verify.sh`
- **THEN** 脚本默认对 `9090`（AI 实例）与 `9091`（通用实例）均执行，无需管理员分别指定
