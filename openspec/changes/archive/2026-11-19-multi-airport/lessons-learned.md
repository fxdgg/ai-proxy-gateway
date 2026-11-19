# 归档经验记录：multi-airport

归档时间：2026-11-19。全流程：方案设计 → 双评审（2 轮通过）→ 三任务并行实现 + 验证 + 审查（评分 A）→ 建议项修复 + 回归 → 最终审查（评分 A）。

## 技术决策

- **纯 bash 整段拷贝合并，不解析 JSON、不引入 python3**：真实机场订阅节点为内联 JSON 格式（`- {"name":...}`），合并时整段拷贝 `^proxies:` 到下一顶层 key 之间的内容，仅用正则 `"name"\s*:\s*"([^"]*)"` 提取节点名做跨文件重名检测。逐字段解析 JSON 需要引入 python3/jq 依赖，收益低。
- **重名报错退出而非自动加前缀**：静默加前缀会让同名节点无法追溯来源，报错强制机场侧改名更可维护。
- **AI 组改为「固定出口组」（`use: [ai_airport]` 人工池）**：AI 节点没有统一的命名特征，节点名正则选不出来，改为人工选定通用节点作为出口，移除原美国 filter 锁定。
- **默认兜底出口从 `GEN-STICKY` 改为 `HK-STICKY`**：香港线路延迟低、带宽大，适合作为海外流量的默认出口；规则三级分流「插件域名 → AI 组 → 国内直连 → 香港组兜底」。

## 踩坑记录

- **macOS bash 3.2 多字节 bug**：`$VAR` 紧跟中文字符时会被解析为变量名延续（如 `$VAR中文` → 变量名 `VAR中文`），必须用 `${VAR}` 包裹；BSD `grep -oE` 对 UTF-8 多字节会丢字节，改用 awk 按引号切分提取字段。
- **mihomo file 型 rule-provider 必须带 `behavior` + `format` 字段**（`behavior: classical` + `format: text`），省略会导致规则解析失败；生成规则片段应为纯 classical 行（`DOMAIN-SUFFIX,xxx`），不能包 `payload:` 列表。
- **chatgpt-block-bypass 插件域名硬编码在 `background.js` 的 `defaultProxyDomains`**，无独立配置文件，无法直接复用；本期采用手工导出 `nodes/ai-domains.txt` + `gen-rules.sh` 生成 `rules/ai-plugin.yaml` 的联动方案，插件侧改动留待后续立项。

## 改进建议

- **agent frontmatter 不要指定不存在的 model 别名**：coder-lite/recorder 的 `model: hy3` 导致首次调用即失败，已由 Leader 删除（继承主模型）。后续新增 agent 时先确认 model 别名在环境中存在。
- **展开式 YAML 节点格式**：build-config.sh 的重名检测仅覆盖单行内联 JSON 节点，展开式格式（`- name: xxx` 换行）降级为警告跳过重名检测。若后续机场普遍使用展开式格式，需补充 yq/awk 状态机解析。
