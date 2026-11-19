# 降级验证记录（tasks 4.5）

> 对应 design.md「决策 G2 降级路径 + 验证清单」与 tasks.md 4.5。
> 目的：逐项构造输入验证 `scripts/gen-country-rules.sh` 的降级/校验路径与幂等性，以及 `scripts/verify.sh` 的本地降级与 API mock 行为；验证后恢复现场。
> 数据来源：Tester 验证报告（gen-country-rules.sh 12/12 用例 + verify.sh 降级/API mock 结论）；verify.sh 部分另附修复行内注释提取后的本地重跑实测。

## 1. gen-country-rules.sh 用例矩阵（Tester 报告：12/12 通过）

| # | 用例 | 构造方式 | 期望行为（design G2 定死） | 结果 |
|---|------|---------|---------------------------|------|
| 1 | 正常两列 | `example.com<TAB>JP` | 生成 `DOMAIN-SUFFIX,example.com,JP-STICKY` | ✅ |
| 2 | 非法国家代码 FR | `x.com<TAB>FR` | 告警「非法国家代码」跳过，产物无悬空 `FR-STICKY` 规则 | ✅ |
| 3 | 小写 jp | `y.com<TAB>jp` | 国家代码大小写不敏感（awk 统一大写），按 JP 正常生成 | ✅ |
| 4 | 缺失第二列 | 仅域名一列 | 告警「国家代码缺失」跳过 | ✅ |
| 5 | `bad..com` | 含空段的域名 | 域名白名单分段校验拒绝（无空段），告警跳过 | ✅ |
| 6 | `google.com` 裸域 | 与 `BROAD_DOMAIN_DENYLIST` 精确相等 | 超宽排除告警（过度代理风险），不生成 | ✅ |
| 7 | `google.com` 子域 | `gemini.google.com` | 子域不命中排除清单，正常生成 | ✅ |
| 8 | 同域名重复 | 两行同域名不同国家代码 | 告警忽略前一行、保留末行（追加粘贴改绑语义） | ✅ |
| 9 | 组存在性校验（注释掉 DE-STICKY） | 临时注释 `# - name: DE-STICKY` 起整块（不删除），数据行含 DE 代码 | DE 行告警「目标组未配置」跳过、其余行正常生成、产物无悬空组规则；同时验证组名解析排除注释行——注释态组名未污染组名集合 | ✅ |
| 10 | config 缺失/不可解析 | 移走/破坏 `config.yaml` | 组存在性校验跳过、不阻断生成（组真实缺失由 verify.sh 国家组非空检查兜底） | ✅ |
| 11 | 数据文件缺失 | 移走 `nodes/ai-domains-country.txt` | 降级生成空规则片段（仅注释头）+ 告警，exit 0（空片段被 `RULE-SET,ai-plugin-country` 消费无副作用） | ✅ |
| 12 | 幂等 | 同一输入连跑两遍 | 产物全量覆盖重写，两次输出逐字节一致 | ✅ |

**结论**：12/12 全部通过。校验链顺序（国家代码 8 枚举 → 域名白名单分段校验 → 超宽域名排除 → 组存在性校验）与重复行拦截（DUP 保留末行）行为均与 design G2 定死口径一致；验证后 `config.yaml` / 数据文件已恢复原状。

## 2. verify.sh 本地降级与 API mock（Tester 报告结论）

- **本地降级（API 不可达）**：三级口径 `nodes/_merged.yaml` → 不存在或无节点行先跑 `build-config.sh` → 「仍不可得」（build 后仍无节点行）降级扫描 `nodes/clash*.yaml`；零机场场景落模板/示例数据并标注「数据来源为模板/示例数据 → 待部署环境复核」，命中 0 仅软性提示、不误判硬失败。结论 ✅。
- **API mock**：`/proxies` 返回组与节点混合对象时，7 国 dry-run 只取节点名、排除组 key（组对象带 `.all` 字段，`select(.value.all == null)` 过滤），避免 `JP-STICKY` 等组名虚高命中；国家组非空检查用完整锚定模式 `^(JP|US|SG|TW|KR|GB|DE)-STICKY$`（禁止子串匹配），组空计入 `hard_fail`。结论 ✅。

## 3. 修复行内注释提取后的本地重跑（本次实测，Coder-Lite）

- 环境：mihomo API 不可达（`http://127.0.0.1:9090`）→ 自动走本地扫描降级，exit 0。
- 三级口径实测：`_merged.yaml` 为 `proxies: []` → 尝试 `build-config.sh` → build 后仍无节点行（零机场场景）→ 降级扫描 `nodes/clash*.yaml`，命中模板 `clash.example.yaml`（共 3 个节点），正确标注「降级数据源=模板/示例数据」，JP=1 命中、其余 0 命中均为软性提示，无硬失败。
- 行内注释提取端到端复测：临时放置含展开式「带引号/无引号 + 行内注释」节点 3 条、内联 JSON + 行内注释 1 条、注释态节点行 1 条的样本文件，重跑后统计到 7 个节点（注释态未计入），命中 JP=2 / US=1 / SG=1 / DE=1——带行内注释的展开式节点均被正确提取，与 4.0 口径对齐（详见 dry-run-verification.md「口径差异与 verify.sh（tasks 4.4）对齐说明」）。样本文件跑完即删，现场已恢复。
