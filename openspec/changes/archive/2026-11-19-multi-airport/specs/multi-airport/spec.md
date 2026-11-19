## ADDED Requirements

### Requirement: 机场订阅文件命名与发现约定

`nodes/` 目录下的机场订阅文件 MUST 采用统一命名前缀，脚本 SHALL 自动扫描发现，无需在 config 或脚本中逐一登记机场。

- 机场订阅文件命名约定为 `clash-<id>.yaml`，`<id>` 为机场标识（小写字母/数字/短横线），例如 `clash-a.yaml`、`clash-b.yaml`。
- 向后兼容：`nodes/clash.yaml`（无 `-<id>`）视为「默认机场」，其 `<id>` 记作 `default`，与 `clash-<id>.yaml` 并存，均参与合并。
- `nodes/` 目录下所有匹配 `clash-*.yaml` 的文件及 `clash.yaml` 视为机场订阅；`.example.yaml` 结尾的文件与 `ai.example.yaml` 等示例文件除外。
- 每个机场订阅文件保持「原样放入」，只提取其 `proxies:` 段（兼容订阅式与完整 clash 配置式两种格式，多余字段如 `proxy-groups`/`rules` 被忽略）。
- 合并时多机场节点若重名，SHALL 报错退出（要求用户改名），不得自动加前缀破坏 dialer-proxy 引用。
- 重名检测 SHALL 仅对「单行内联 JSON」节点名生效；展开式 YAML 格式（`- name: xxx` 换行缩进）节点名提取降级为警告并跳过该文件重名检测，节点行仍整段拷贝保留（S3 边界）。

#### Scenario: 扫描发现多个机场

- **WHEN** `nodes/` 下存在 `clash-a.yaml`、`clash-b.yaml`、`ai.example.yaml`、`clash.example.yaml`
- **THEN** 扫描结果仅包含 `clash-a.yaml`、`clash-b.yaml` 两个机场（排除 `.example.yaml` 结尾文件），并解析出各自的 `proxies` 节点列表

#### Scenario: 单个机场订阅文件

- **WHEN** `nodes/` 下仅存在一个 `clash-a.yaml`
- **THEN** 系统仍正常工作，等价于单机场模式，不要求至少两个文件

#### Scenario: 默认机场向后兼容

- **WHEN** `nodes/` 下仅存在 `clash.yaml`（无 `-<id>`）
- **THEN** 该文件作为 `default` 机场参与合并，等价于既有单机场模式，平滑迁移

#### Scenario: 零机场生成空节点池

- **WHEN** `nodes/` 下无任何 `clash*.yaml`
- **THEN** `build-config.sh` 生成合法的 `proxies: []`（mihomo 可读），不报错；若合并后所有文件都无节点则 fail-fast 非零退出

#### Scenario: 重名节点报错退出

- **WHEN** 两个机场存在同名节点
- **THEN** `build-config.sh` 报错退出（非零），打印重名节点名与来源文件，要求用户改名，不自动加前缀

### Requirement: 多机场节点聚合分组

跨机场节点 MUST 按「地区特征」聚合到逻辑分组（香港节点组等），使不同机场的同地区节点 SHALL 落入同一组。AI 组为「固定出口组」，由人工选定通用节点组成，不依赖节点名标称 AI。

- 香港组分组依据节点名中的地区关键词（正则），而非文件名或 provider 名。
- AI 出口组依据「文件圈定」（`nodes/ai.yaml`），不依赖节点名正则，节点名无需含「AI」。
- 聚合结果为「逻辑组 → 节点列表」的映射，供 proxy-groups 使用。

#### Scenario: 跨机场香港节点聚合

- **WHEN** 机场 A 有节点 `IEPL企业专线-香港01`，机场 B 有节点 `香港-BGP-01`
- **THEN** 香港节点组同时包含这两个节点，且可追溯到各自来源机场

#### Scenario: AI 出口组不依赖节点名

- **WHEN** `nodes/ai.yaml` 中手工放入节点 `通用节点-01`（节点名不含「AI」）
- **THEN** 该节点仍进入 AI 出口组，AI 组节点来源与节点名标称无关

### Requirement: 分流规则三级生成

网关侧 MUST 生成/合并 clash rules，实现三级分流：插件域名 → AI 出口组、国内 → 直连、未匹配海外 → 香港组兜底。三级顺序 SHALL 固定。

- 三级顺序固定且不可颠倒：① 插件/规则集命中的 AI 域名 → AI 出口组；② 国内（geosite/geoip CN）→ 直连；③ 其余（MATCH 兜底）→ 香港组（默认出口）。
- 国内直连数据源建议使用 geosite/geoip 规则集（如 `geosite:cn`、`geoip:cn`），而非手写域名清单。
- 未匹配插件域名、也非国内的海外流量，默认出口为香港组（与需求 4 一致）。

#### Scenario: AI 域名命中 AI 组

- **WHEN** 请求域名命中插件域名清单或 AI 规则集
- **THEN** 走 AI 节点组出口

#### Scenario: 国内域名直连

- **WHEN** 请求域名/IP 命中 geosite:cn 或 geoip:cn
- **THEN** DIRECT 直连，不经过任何代理节点

#### Scenario: 未匹配海外走香港组

- **WHEN** 请求既非 AI 域名、也非国内
- **THEN** 走香港节点组出口

### Requirement: 脚本动态发现（去硬编码）

`reload-nodes.sh` 与 `verify.sh` MUST NOT 硬编码任何 provider 名或组名，SHALL 全部动态发现。

- provider 名、组名通过调用 mihomo API 或扫描 `nodes/` 目录动态获取。
- 脚本对任意数量的机场、任意数量的逻辑组均正确工作。

#### Scenario: 新增机场后无需改脚本

- **WHEN** 在 `nodes/` 下新增 `clash-c.yaml`，先执行 `build-config.sh` 合并，再执行 `reload-nodes.sh` 重载
- **THEN** `reload-nodes.sh` 与 `verify.sh` 自动覆盖新机场的 provider 与节点，无需修改脚本代码（reload 前提是已 build，见 design 编排顺序）

#### Scenario: 组名变化后无需改脚本

- **WHEN** `config.yaml` 中逻辑组名调整（如香港组改名）
- **THEN** `verify.sh` 自动发现新组名并逐组校验，无需修改脚本
