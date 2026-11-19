# dual-instance-gateway Specification

## ADDED Requirements

### Requirement: 双实例部署形态与端口约定

网关 MUST 以两个独立 mihomo 容器服务部署（`gateway-ai` 与 `gateway-main`），SHALL 共享同一份节点池，端口约定 SHALL 固定且互不冲突。

- 两个服务 MUST 使用同一镜像 `metacubex/mihomo:latest`、`network_mode: host`、`restart: unless-stopped`。
- 两个服务 MUST 各自把独立配置文件挂载到容器内同一路径 `/root/.config/mihomo/config.yaml`（只读），并 SHALL 共享只读挂载 `./nodes`（`nodes/_merged.yaml` 为两实例共同节点池）。
- 端口约定 SHALL 固定：AI 实例 mixed-port `7890`、external-controller `127.0.0.1:9090`；通用实例 mixed-port `7891`、external-controller `127.0.0.1:9091`；PAC 服务保持 `19000`。
- 旧单实例端口 `10800` SHALL NOT 作为正式入口；迁移期 MAY 由 AI 实例以 mihomo `listeners` 入站段额外监听（过渡兼容，`type: mixed`、`listen: 0.0.0.0`、不写 `proxy` 字段），插件侧端口切换完成后 SHALL 移除。MUST NOT 使用顶层 `ports` 字段——mihomo 不存在该字段（Surge 语法），使用会导致过渡监听静默失效。
- 网关侧 MUST NOT 维护任何用户级 AI 域名列表；AI 域名判定由客户端（插件 PAC / 全局 PAC）完成。

#### Scenario: 双实例按约定端口启动

- **WHEN** 管理员执行 `docker compose up -d`
- **THEN** `gateway-ai` 在 `7890` 提供 http+socks5 代理、`9090` 提供管理 API；`gateway-main` 在 `7891` 提供代理、`9091` 提供管理 API；两实例均从 `nodes/_merged.yaml` 加载相同节点池

#### Scenario: 单实例配置不复存在

- **WHEN** 部署完成后查看仓库配置文件
- **THEN** 仓库仅存在 `config-main.yaml` 与 `config-ai.yaml`，不存在 `config.yaml`

#### Scenario: 迁移期旧端口过渡

- **WHEN** 迁移期 `config-ai.yaml` 启用了 `10800` 的 `listeners` 过渡段（`name: legacy-10800`、`type: mixed`），且旧插件把 AI 域名发往 `10800`
- **THEN** 该流量进入 AI 实例全局 `rules`、命中 `MATCH` 规则走美国出口；过渡期 `curl -x http://<服务器>:10800` 可达（10800 可达性检查通过）；插件完成端口切换后移除该过渡段，`10800` 不再监听

### Requirement: AI 出口实例规则

AI 出口实例的规则 MUST 收敛为仅 `MATCH → AI-US-STICKY`（美国节点组），SHALL NOT 包含任何域名规则、rule-providers 或内联兜底。

- `AI-US-STICKY` 组 MUST 使用 `use: [airport]`（共享节点池 `nodes/_merged.yaml`）与美国地区正则 `filter` 跨机场聚合节点，SHALL 复用 `HK-STICKY` 同款 `exclude-filter`（排除「禁止大流量/测试/Pv/VPN/剩余/流量/到期/过期/官网/重置/订阅」特征节点）与 `strategy: sticky-sessions`。
- `AI-US-STICKY` 的 exclude-filter MUST NOT 包含「中国」（与旧 `AI-STICKY` 刻意不同）：美国落地节点常带「中国优化/回国优化」字样，排除「中国」会误杀目标节点；实现时 MUST 以本 spec 与 design 决策 3 的组定义为基准，MUST NOT 照抄旧 `AI-STICKY` 的 exclude-filter。
- AI 实例 MUST NOT 引用 `ai_airport` 手工池 provider，MUST NOT 包含任何 `rule-providers`。
- AI 实例 MUST NOT 配置 `RULE-SET`、`DOMAIN-*`、`GEOIP` 等规则，`rules` 段 SHALL 仅含 `MATCH,AI-US-STICKY`。

#### Scenario: 美国节点自动聚合

- **WHEN** `nodes/_merged.yaml` 中存在节点名含「美国」或「United States」等美国关键词的机场节点（如 `IX精品专线-美国01-...`）
- **THEN** `AI-US-STICKY` 组自动包含这些节点，无需任何手工池文件或节点登记

#### Scenario: 发往 AI 端口的流量全部走美国出口

- **WHEN** 客户端把 AI 域名请求发往 `7890`
- **THEN** 请求命中唯一规则 `MATCH,AI-US-STICKY`，经美国节点组出口，无任何域名级判定

#### Scenario: AI 实例不存在域名规则

- **WHEN** 查看 `config-ai.yaml`
- **THEN** 文件不存在 `rule-providers` 段，`rules` 段仅 `MATCH,AI-US-STICKY` 一行

### Requirement: 通用出口实例规则

通用出口实例 MUST 实现「国内直连 + 其余香港兜底」：`geosite/geoip CN → DIRECT`、`MATCH → HK-STICKY`，SHALL 不包含任何 AI 域名规则。

- 通用实例的 `rule-providers` SHALL 仅保留 `China`（geosite cn）、`Private`（内网直连）、`Block`（广告拦截）三个数据源；AI 远程规则集（AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity）SHALL NOT 存在。
- `rules` 顺序 SHALL 固定：`RULE-SET,Private,DIRECT` → `RULE-SET,Block,REJECT` → `RULE-SET,China,DIRECT` → `GEOIP,CN,DIRECT` → `MATCH,HK-STICKY`。
- `HK-STICKY` 组 MUST 保持 `use: [airport]` + 香港正则 `filter` + 同款 `exclude-filter` + `sticky-sessions`（作为默认出口组）。
- 通用实例 SHALL 保留备用组 `GEN-ROTATE`（香港轮询）与注释态的 `relay` provider / `RELAY-POOL` 链式代理示例。

#### Scenario: 国内流量直连

- **WHEN** 发往通用实例 `7891` 的请求域名/IP 命中 `China` 规则集或 `GEOIP,CN`
- **THEN** 请求 DIRECT 直连，不经过任何代理节点

#### Scenario: 未命中直连规则的流量走香港

- **WHEN** 发往通用实例的请求既非国内也非内网/拦截
- **THEN** 请求命中 `MATCH,HK-STICKY` 经香港节点组出口

#### Scenario: 通用实例不感知 AI 域名

- **WHEN** 查看 `config-main.yaml`
- **THEN** 文件不存在任何 AI 域名规则集、内联 AI 域名规则或 AI 出口组

### Requirement: 脚本双实例化

`reload-nodes.sh`、`apply.sh`、`verify.sh` MUST 默认作用于两个实例，SHALL 按固定端口约定发现实例 API，任一实例失败 SHALL 汇总为非零退出。

- 实例 API 地址约定 SHALL 为脚本内常量默认值（AI `http://127.0.0.1:9090`、通用 `http://127.0.0.1:9091`），SHALL 支持位置参数覆盖。
- `reload-nodes.sh` MUST 只做一次 `_merged.yaml` 时效前置校验，然后对每个可达实例执行 provider 动态发现+重载+即时健康检查；单个实例 API 不可达 SHALL 记录告警并继续处理其余实例，最终任一实例重载失败 SHALL 非零退出。
- `apply.sh` MUST 对两个实例以同一容器内路径 `/root/.config/mihomo/config.yaml` 热加载各自配置。
- `verify.sh` MUST 分别校验两实例：AI 实例硬性要求「组名含 AI 的组非空」并做出口连通性检查；通用实例硬性要求「组名含 HK/香港 的组非空」并做默认出口连通性检查；任一实例硬性失败 SHALL 非零退出。
- `verify.sh` MUST NOT 包含国家分流组检查与 7 国 dry-run 逻辑（已随机制回退删除）。
- `claude-code-setup.sh` 默认 MUST 指向 AI 实例 `7890`，且 MUST 在导出 `HTTP_PROXY`/`HTTPS_PROXY` 的同时导出 `NO_PROXY` 与 `no_proxy` 两套大小写变量（内网段：localhost、127.0.0.1、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 及常用内网域名），SHALL 在输出提示中说明「CLI 环境变量代理为全量代理，走 7890 时内网/国内站点会绕道美国出口」；提示 SHALL 注明 CIDR 段仅 curl ≥7.86/libcurl 系工具识别（Node/Python 系不识别，关键内网主机建议同时列出主机名/IP 字面量），SHALL 提示「国内站点如需直连请自行把域名追加到 NO_PROXY」。

#### Scenario: 默认重载两个实例

- **WHEN** 管理员修改机场节点后依次执行 `build-config.sh` 与无参数的 `reload-nodes.sh`
- **THEN** 脚本对 `9090` 与 `9091` 两个 API 分别完成 provider 重载与健康检查，两个实例的节点池同时更新

#### Scenario: 单实例 API 不可达不阻断另一实例

- **WHEN** AI 实例宕机而通用实例正常时执行 `reload-nodes.sh`
- **THEN** 脚本对通用实例正常重载，对 AI 实例输出告警，最终以非零退出码提示管理员存在失败实例

#### Scenario: 验证脚本分别校验两实例

- **WHEN** 管理员执行 `verify.sh`
- **THEN** 脚本输出 AI 实例（AI 组非空 + AI 站连通）与通用实例（HK 组非空 + 默认出口连通）两组结果，任一硬性项失败则非零退出

#### Scenario: CLI 环境变量代理含内网直连豁免

- **WHEN** 管理员执行 `claude-code-setup.sh` 生成 CLI 代理配置
- **THEN** 配置中 `HTTP_PROXY`/`HTTPS_PROXY` 指向 AI 实例 `7890`，且同时导出 `NO_PROXY`/`no_proxy` 大小写双变量内网段（localhost、127.0.0.1、内网 IP 段与常用内网域名），脚本提示「CLI 环境变量代理为全量代理、走 7890 时国内站点绕美国出口」的副作用说明、CIDR 段工具兼容性限制（curl ≥7.86/libcurl 系识别，Node/Python 系不识别）与「国内站点追加到 NO_PROXY」指引

### Requirement: 全局 PAC 双端口分流

`www/proxy.pac.template` MUST 按「静态核心 AI 域名 → AI 实例端口、其余 → 通用实例端口」双端口分流，SHALL 保留 DIRECT 兜底与内网直连判断。

- 模板 MUST 通过 `AI_GATEWAY_ADDR`（host:7890）与 `GATEWAY_ADDR`（host:7891）两个环境变量注入端口，SHALL 由 nginx envsubst 渲染。
- AI 域名 SHALL 为仓库内静态清单，共 15 个，构成口径 MUST 与 design 决策 5 一致：旧内联兜底保留项 10 个 + 插件 `defaultProxyDomains` 独有项 4 个（`coze.com`/`meta.ai`/`oaistatic.com`/`oaiusercontent.com`，已剔除超宽裸域 `google.com`）+ 旧远程 `Perplexity` 规则集核心站 1 个（`perplexity.ai`，回退保留项）；「与插件同源」SHALL 仅指前 4 个独有项。清单 MUST NOT 包含用户个人配置，MUST NOT 包含超宽裸域 `google.com`。
- 网关不可达时 SHALL 走 `; DIRECT` 兜底（与现状一致）。

#### Scenario: 全局 PAC 用户访问 AI 站

- **WHEN** 全局 PAC 用户的请求域名命中 PAC 内静态 AI 清单（如 `claude.ai`）
- **THEN** PAC 返回 `PROXY 服务器:7890; DIRECT`，流量走 AI 实例美国出口

#### Scenario: 全局 PAC 用户访问其他站点

- **WHEN** 全局 PAC 用户的请求域名未命中 AI 清单且非内网
- **THEN** PAC 返回 `PROXY 服务器:7891; DIRECT`，流量走通用实例（CN 直连或香港兜底）

#### Scenario: 静态清单不含超宽域名

- **WHEN** 查看 PAC 模板的 AI 域名清单
- **THEN** 清单不含 `google.com` 裸域（`gemini.google.com` 等子域不受影响）
