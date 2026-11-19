# 闸门评审：multi-airport

## 第 2 轮结论

**【补充后进入开发】**（第 2 轮评审通过后，已按主审落盘建议完成低成本补充修订，见「第 2 轮后补充修订」章节；补充修订后结论升级为【可直接进入开发】）

第 1 轮双评审主审【驳回】、辅审【有条件通过】。合并后共 14 项修订意见（1 项阻断项 P1 + 6 项重要问题 P2-P7 + 7 项建议 P8-P14），已在第 2 轮全部修订落实，`openspec validate multi-airport` 通过。

第 2 轮双评审：主审【B+ 有条件通过】、辅审【通过】。主审提出 4 项低成本补充修订（Q1/S1/S2/S3），不涉及整体方案变更，无需再走完整评审。补充修订完成后，无剩余「阻塞开发」「阻塞提测」级问题，结论标记升级为【可直接进入开发】。

---

## 第 2 轮后补充修订（主审落盘建议）

主审以「B+ 有条件通过」通过第 2 轮评审，给出 4 项低成本补充修订，均已落盘，如下：

| # | 级别 | 补充项 | 处理结果 |
|---|------|--------|----------|
| Q1 | 阻塞提测 | `rule-providers.ai-plugin` 字段定义与 `rules/ai-plugin.yaml` 内容格式不明确 | **落定**：`ai-plugin` = `type: file` + `behavior: classical` + `format: text` + `path: rules/ai-plugin.yaml`（对齐现有 Claude/Gemini/Copilot/Grok/Block 的 classical+text 惯例）；`rules/ai-plugin.yaml` 内容为**纯 classical 规则行**（每行 `<规则类型>,<域名>`，如 `DOMAIN-SUFFIX,openai.com`），顶部注释头，**禁止 `payload:` 列表包裹**。写入 design 决策 4 + tasks 4.1/4.2 |
| S1 | 建议 | 香港组具体组名未落定 | **落定组名 `HK-STICKY`**，三处对齐：`config.yaml` proxy-groups 组名、rules `MATCH` 目标、`verify.sh`「组名含 HK/香港」判定。写入 design 决策 2/4 + tasks 3.3/2.2 |
| S2 | 建议 | 旧组处置（GEN-STICKY/GEN-ROTATE/AI-FIXED）未明确 | **落定**：`GEN-STICKY` 改造为 `HK-STICKY`（原 MATCH 兜底 + 美国 filter）；`AI-STICKY` 保留（移除美国 filter）；`GEN-ROTATE` 改造为香港轮询备用（filter 改香港）；`AI-FIXED` 保留备用（移除美国 filter）。写入 design 决策 2「旧组处置表」+ tasks 3.3/6.1 |
| S3 | 建议 | 重名检测正则对展开式格式的边界未说明 | **落定**：重名检测正则 `"name"\s*:\s*"([^"]*)"` 仅对「单行内联 JSON」节点生效；展开式格式（`- name: xxx` 换行缩进）降级为警告 + 跳过该文件重名检测，仍整段拷贝。写入 design 算法步骤 3「作用范围」+ 可验证性 + Risks，tasks 3.1/6.3 新增展开式 fixture |

补充修订仅改动 `openspec/changes/multi-airport/` 下 design.md / tasks.md / gate-review.md，未改整体方案，`openspec validate multi-airport` 通过。

---

## 第 1 轮评审意见记录

### 主审结论：驳回

核心驳回理由：build-config.sh 的 YAML/内联 JSON 解析手段未定义（P1），与 Non-Goals「不引入 bash+curl+jq 外依赖」冲突；连带 P2/P3/P4/P5/P6/P7 等语义矛盾。

### 辅审结论：有条件通过

同意主审对 P1 的阻断判断；另提出 P6（gen-rules.sh 落盘方式）、P7（plugin-domain-sync spec 与 design 矛盾）、P10（fixture 测试）等。

### 合并修订清单与处理结果

| # | 级别 | 意见 | 处理结果 |
|---|------|------|----------|
| P1 | 阻塞开发 | build-config.sh 的 YAML/内联 JSON 解析手段未定义，与 Non-Goals 冲突 | **拍板「整段拷贝 + 正则重名检测 + 重名即报错」**：从 `^proxies:` 行到下一个顶层 key 之间整段拷贝合并；重名检测用正则提取内联 JSON 的 `"name"` 字段；重名即报错退出让用户改名（放弃自动加前缀）。算法步骤写入 design 决策 1/2 + 新增「build-config.sh 算法」章节；Non-Goals 明确「依赖 bash + curl + jq（已存在）」，不再引入 python3 |
| P2 | 阻塞提测 | verify.sh `check_ai` 美国硬编码判定与「AI 组固定出口、不依赖地区」冲突 | 移除 `loc=US` 硬编码判定，改为「可连通即通过 + 打印出口地区供人工参考」；tasks 2.2 同步 |
| P3 | 阻塞提测 | 扫描 glob `clash-*.yaml` 与「默认机场 `clash.yaml` 向后兼容」矛盾 | 明确：`clash.yaml` 作为「default id」纳入扫描（`<id>=default`），与 `clash-<id>.yaml` 并存；写入 design 决策 1 + spec |
| P4 | 阻塞提测 | 无通配域名转 DOMAIN 还是 DOMAIN-SUFFIX 有歧义 | design 决策 5 新增「转换规则表」；对 google.com 这类超宽域名 gen-rules.sh 自动告警 + 内置排除清单（gemini/aistudio 已内联兜底） |
| P5 | 阻塞提测 | 零机场/空 proxies 边界 | build-config.sh 零机场生成合法空 `proxies: []`；合并后全空 fail-fast 非零退出；tasks 6 新增 fixture |
| P6 | 阻塞提测 | gen-rules.sh 落盘方式 | 拍板「生成 `rules/ai-plugin.yaml` 片段 + config.yaml 一次性手工接入 rule-providers 引用」，禁止脚本改写 config.yaml；幂等性=重复运行覆盖同一文件 |
| P7 | 阻塞提测 | plugin-domain-sync spec「用户自定义域名同步」本期无法实现 | spec 该 Requirement 标注「部分覆盖：仅 defaultProxyDomains，用户自定义域名留待后续变更」 |
| P8 | 建议 | 香港组 exclude-filter 排除「家宽」与价值判断矛盾 | 从 exclude 列表去掉「家宽」（住宅 IP 是 AI 出口优质特征，不应排除） |
| P9 | 建议 | API 不通时回退分支语义 | design 决策 3 区分：reload 失败即退出提示 restart；verify 回退本地扫描仅用于「列出应存在的 provider/组」 |
| P10 | 建议 | build-config.sh 畸形输入 fixture 测试 | tasks 6 新增：空 proxies / 无 proxies 段 / 重名 / name 含特殊字符 的 fixture 逐一验证 |
| P11 | 建议 | .gitignore 策略 | 明确 `_merged.yaml` 被 `nodes/*.yaml` 忽略（显式注释）；example 白名单策略写入 |
| P12 | 建议 | 复杂度重新分级 | gen-rules.sh 降【中】；build-config.sh 明确算法步骤 |
| P13 | 建议 | spec「reload 自动覆盖新机场」与方案 B 的 gap | design 澄清「reload 前提是已 build」 |
| P14 | 轻微 | ai.example.yaml 说明 | 明确：拷入 ai.yaml 的节点不参与合并去重前缀 |

---

## 已拍板决策记录（历史，仍有效）

| 阻塞项 | 原描述 | 用户决策 | 落地点 |
|--------|--------|----------|--------|
| 歧义 1：AI 组语义 | 「AI 线路节点」vs「AI 出口组」 | **AI 组只是出口分组名**，选一个或几个通用节点作为 AI 域名出口，不要求节点本身标称 AI | design.md 决策 2 |
| 歧义 2：默认出口地区 | 未匹配海外从美国改香港是否有意 | **默认出口改为香港节点组** | design.md 决策 4 |
| 歧义 3（第 2 轮新增）：解析手段 | 内联 JSON 无法用 bash+sed 可靠解析 | **整段拷贝 + 正则重名检测 + 重名即报错**（不自动加前缀、不引入 python3） | design.md「build-config.sh 算法」 |

---

## 八维度评估（第 2 轮更新后）

### 1. 需求完整性与歧义检查

- ✅ 四个需求点映射四个能力；两个历史歧义已拍板；P3/P4/P7 语义矛盾已消除。
- ✅ 「AI 组 = 固定出口组」「默认出口 = 香港组」「reload 前提是已 build」贯穿全文一致。

### 2. 技术方案合理性

- ✅ 方案 B（生成式合并 + filter 聚合）符合 mihomo 能力边界。
- ✅ P1 后 build-config.sh 算法明确（整段拷贝 + 正则重名检测），不依赖 python3/pyyaml，与 Non-Goals 自洽。
- ✅ P6 后 gen-rules.sh 只产出规则片段、不写 config.yaml，职责边界清晰。

### 3. 落地可行性

- ✅ 全部改动在仓库既有文件 + 3 个新 shell 脚本 + 1 个规则片段文件，无新运行时依赖。
- ✅ P3 后向后兼容路径明确（`clash.yaml` → default id）。

### 4. 安全性

- ✅ 节点/订阅文件 `.gitignore` 覆盖（`nodes/*.yaml`），`_merged.yaml` 命中该模式；P11 显式注释防误提交。
- ✅ 插件域名列表仅含域名，无凭证。

### 5. 稳定性与可靠性

- ✅ P5 后空 proxies 边界 fail-fast 明确。
- ✅ P4 后超宽域名告警 + 排除清单，避免 google.com 误纳入 AI 组。
- ✅ P9 后 API 回退语义区分清楚（reload 硬失败 vs verify 软降级）。

### 6. 可测试性

- ✅ P10 后 build-config.sh 畸形输入 fixture 测试覆盖空/无段/重名/特殊字符。
- ✅ tasks 6.1/6.2 覆盖合并、分组、三级分流、跨机场聚合。

### 7. 可上线与可运维性

- ✅ P13 后 reload 前提明确（先 build 后 reload），编排顺序文档化。
- ✅ P12 后复杂度分级合理（gen-rules.sh 降【中】）。

### 8. 实现前疑问点识别

- ❓ 香港组是否叠加「线路质量」约束——降级为待确认项（design「待确认项」）。
- ❓ google.com 超宽域名最终取舍——由 gen-rules.sh 告警 + 排除清单缓解，人工确认后调整（design「待确认项」）。

---

## 结论标记

【可直接进入开发】

- P1（阻塞开发）已拍板并落实算法，无剩余阻塞开发项。
- P2-P7（阻塞提测级）已全部在设计/tasks/specs 中自洽，并配测试用例。
- P8-P14（建议级）已全部采纳修订。
- 第 2 轮后补充修订 Q1/S1/S2/S3 已落盘（Q1 阻塞提测级已消除；S1/S2/S3 建议级已采纳），无剩余阻塞开发/阻塞提测项。
- `openspec validate multi-airport` 通过。
