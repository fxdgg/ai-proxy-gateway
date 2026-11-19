## 任务说明

- 复杂度标注：【低】【中】【高】，用于分级分派。
- 每个任务 ≤ 2 小时工作量。
- 任务描述引用 design.md 的「文件范围」，coder 不得越界修改「❌ 不修改」的文件。
- build-config.sh 的实现必须严格遵循 design.md「build-config.sh 提取/合并算法」章节（整段拷贝 + 正则重名检测 + 重名即报错），不得逐字段解析 JSON 或引入 python3。

---

## 1. 配置与示例文件改造【低-中】

- [ ] 1.1【低】更新 `nodes/clash.example.yaml`：补充多机场命名规范（`clash-<id>.yaml`）说明与「订阅式 vs 完整配置式」兼容说明。
- [ ] 1.2【低】更新 `nodes/ai.example.yaml`：补充「AI 组是固定出口组、节点无需标称 AI」语义说明；并注明「拷入 ai.yaml 的节点不参与 build-config.sh 的合并与去重前缀」（P14）。
- [ ] 1.3【低】确认并完善 `.gitignore`：确保 `nodes/clash-*.yaml`、`nodes/_merged.yaml` 被忽略（现有 `nodes/*.yaml` 已覆盖，补显式注释防误提交）、`*.example.yaml` 白名单维持（P11）。
- [x] 1.4【中】新增 `nodes/ai-domains.txt`：从 `chatgpt-block-bypass/background.js` 的 `defaultProxyDomains` 手工导出裸域名（每行一个，`*.domain.com` → `domain.com`；对 `google.com` 这类超宽域名标注待人工确认）。

## 2. 脚本去硬编码【中】

- [x] 2.1【中】改造 `scripts/reload-nodes.sh`：用 `curl $API/providers/proxies` 动态遍历所有 provider 重载 + healthcheck，删除 L13/23/30 写死名单；组校验改用 `curl $API/proxies` 动态遍历；**API 不通时失败退出**（非零）并提示 `docker compose restart gateway`；开头校验 `_merged.yaml` 已 build（比机场文件新），否则提示先执行 build-config.sh（P9/P13）。
- [x] 2.2【中】改造 `scripts/verify.sh`：provider 部分（L38）与组部分（L44-46）改为动态发现，复用 `check_group` 逐组校验；保留 `classify_org`/`check_ai` 逻辑，但 **`check_ai` 移除「出口必须是美国」硬编码判定**，改为「可连通即通过 + 打印出口地区 loc 供人工参考」（P2）；API 不通时降级本地扫描「列出应存在的 provider/组」（P9）。**香港组非空判定（S1）**：香港组的「非空硬性检查」通过「组名含 `HK`/`香港`」判定，须与 `config.yaml` 的组名 `HK-STICKY`、rules 的 `MATCH` 目标一致——组名定为 `HK-STICKY` 后，verify 判定正则 `HK|香港` 能命中该组名，无需额外改判定逻辑，但实现时须确认判定对 `HK-STICKY` 生效。
- [ ] 2.3【低】清理 `scripts/apply.sh` L18 提示语中的写死组名，改为泛化提示或动态取值。

## 3. 节点合并与分组生成【高】

- [ ] 3.1【高】新增 `scripts/build-config.sh`：严格按 design「build-config.sh 提取/合并算法」实现——扫描 `nodes/clash-*.yaml`（+`clash.yaml`=default，排除 example），`^proxies:` 到下一个顶层 key 之间**整段拷贝**合并到 `nodes/_merged.yaml`；正则 `"name"\s*:\s*"([^"]*)"` 提取节点名做**跨文件重名检测，重名即报错退出**（不自动加前缀）；零机场生成 `proxies: []`，合并后全空 fail-fast（P1/P5）。**展开式格式边界（S3）**：该重名检测正则仅对「单行内联 JSON」节点生效；对展开式 YAML 格式（`- name: xxx` 换行缩进）节点，脚本降级为打印警告「检测到展开式格式节点，跳过该文件的重名检测」并跳过该文件重名检测，但仍整段拷贝节点行、不报重名错误。
- [ ] 3.2【高】改造 `config.yaml` 的 `proxy-providers`：`airport.path` 改为读 `nodes/_merged.yaml`（保留 `ai_airport` 作为 AI 出口手工池）。
- [ ] 3.3【高】改造 `config.yaml` 的 `proxy-groups`：新增香港组 `name: HK-STICKY`（`type: load-balance` + `strategy: sticky-sessions`），用 `filter` 正则（`香港|Hong ?Kong|HK`）跨机场聚合，并加 `exclude-filter`（排除 `禁止大流量|测试|Pv|VPN|剩余|流量|到期|过期|官网|重置|订阅`，**不含「家宽」**）；AI 出口组 `AI-STICKY` 保持 `use: [ai_airport]`（固定出口，不依赖节点名正则），**移除原有美国 filter 锁定**（P8）。**旧组处置（S2）**：`GEN-STICKY` 改造为 `HK-STICKY`（不再单独保留美国兜底组）；`GEN-ROTATE` 的 `filter` 改为香港正则（香港轮询备用，`strategy: round-robin` 不变）；`AI-FIXED` 保留备用（`use: [ai_airport]` 不变，移除美国 filter）；**组名 `HK-STICKY` 须与 rules 的 `MATCH` 目标、verify.sh 的「组名含 HK/香港」判定三处一致**（S1）。

## 4. 分流规则生成【中-高】

- [x] 4.1【中】新增 `scripts/gen-rules.sh`：读取 `nodes/ai-domains.txt`，按 design「转换规则表」转为 `DOMAIN-SUFFIX`/`DOMAIN` 规则片段，写入 `rules/ai-plugin.yaml`（**禁止改写 config.yaml**，P6）；**输出格式为纯 classical 规则行（每行 `<规则类型>,<域名>`，如 `DOMAIN-SUFFIX,openai.com`），文件顶部加 `# 由 scripts/gen-rules.sh 生成，勿手工编辑` 注释头，禁止使用 `payload:` 列表包裹**（Q1，与 rule-providers 的 `classical`+`text` 自洽）；对 google.com 等超宽域名按内置排除清单跳过并告警（P4）；幂等=重复运行全量覆盖同一文件。
- [ ] 4.2【高】改造 `config.yaml` 的 `rules` + `rule-providers`：新增 `rule-providers.ai-plugin`，完整字段为 `type: file` + `behavior: classical` + `format: text` + `path: rules/ai-plugin.yaml`（与现有 Claude/Gemini/Copilot/Grok/Block 的 classical+text 惯例一致，**不得省略 behavior/format**，**不得用 domain/mrs 或 yaml**）；rules 最前加 `RULE-SET,ai-plugin,AI-STICKY`；三级分流（插件域名→AI 出口组、geosite/geoip CN→DIRECT、`MATCH`→`HK-STICKY` 兜底），保留远程 rule-providers 与内联兜底；`MATCH` 兜底目标从 `GEN-STICKY` 改为 `HK-STICKY`。
- [x] 4.3【低】`gen-rules.sh` 缺失 `ai-domains.txt` 时降级：生成空 `rules/ai-plugin.yaml`（含注释头）+ 日志告警。

## 5. 文档更新【低】

- [ ] 5.1【低】更新 `README.md`：多机场部署、分组策略（香港组默认出口 + AI 固定出口组）、重名节点需改名约定、分流规则、脚本用法。
- [ ] 5.2【低】更新 `DEPLOY.md`：多机场部署与验证流程，明确脚本编排顺序（`build-config.sh` → `gen-rules.sh` → `reload-nodes.sh` → `apply.sh`），以及「reload 前提是已 build」与「首次需手工接入 ai-plugin rule-providers」。

## 6. 验证与评审【中】

- [ ] 6.1【中】用 `/Users/penguin/Downloads/clash.yaml` 作为 `clash-a.yaml` 实测：验证合并、`HK-STICKY` 香港组分组（含 exclude-filter 排除「禁止大流量」）、`AI-STICKY` 出口组（ai.yaml 通用节点）、三级分流（`MATCH`→`HK-STICKY`）、脚本动态发现；确认旧组 `GEN-STICKY` 已消失、`GEN-ROTATE`/`AI-FIXED` 处置符合 design 决策 2 旧组处置表（S2）。
- [ ] 6.2【中】构造第二个机场订阅 fixture（`clash-b.yaml`）验证跨机场聚合（香港组同时含两机场节点），并验证 `build-config.sh` 重名检测（重名节点报错退出）。
- [ ] 6.3【中】build-config.sh 畸形输入 fixture 逐一验证（P10）：① 空 proxies 段；② 无 proxies 段；③ 跨文件重名节点；④ name 含特殊字符（如 `"` 转义、emoji）。断言退出码与输出符合 design 算法约定。**新增 ⑤ 展开式格式节点 fixture（S3）**：节点写成 `- name: xxx` 换行缩进格式时，断言脚本打印「跳过该文件重名检测」降级警告、仍整段拷贝节点行、不报重名错误。
- [ ] 6.4【低】验证 `.gitignore` 生效：`nodes/_merged.yaml`、`nodes/clash-a.yaml` 均不被 git 追踪，`nodes/*.example.yaml` 保留。
- [ ] 6.5【中】产出 `gate-review.md` 闸门评审结论（8 维度）。
