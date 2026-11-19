# T1.4 残留引用扫描报告

> 生成时间：T1 机制回退任务组执行时（1.1-1.3 删除完成后）
> 扫描性质：只读，未修改任何被扫描文件

## 扫描参数

- 模式：`gen-rules|gen-country-rules|ai-domains|ai-plugin|ai_airport|AI-STICKY|AI-FIXED|-STICKY`
- 范围：仓库根目录（`/Users/penguin/workspace/git.woa.com/ai-proxy-gateway`）全量递归
- 排除：
  - 目录：`openspec/`、`.git/`
  - 待改造文件（属 T2-T4 范围）：`config.yaml`、`docker-compose.yml`、`scripts/verify.sh`、`scripts/reload-nodes.sh`、`scripts/apply.sh`、`scripts/logs.sh`、`scripts/claude-code-setup.sh`、`scripts/macos-proxy-manual-on.sh`、`README.md`、`DEPLOY.md`
- 工具：BSD `grep -rnE --exclude-dir=openspec --exclude-dir=.git --exclude=<file> ...`

## 结论

**排除范围之外零残留** ✅（`nodes/clash.example.yaml` 亦零命中，连预期豁免的示例说明也不存在）

## 待改造文件命中清单（供 T2/T3 任务核对）

### config.yaml（68 处 → T2.1 重建 config-main.yaml 时消除）

| 行号 | 内容摘要 |
|------|---------|
| 39 | `ai_airport:` provider 定义 |
| 66,68,72 | `ai-plugin-country` rule-provider（注释 + 定义 + path `rules/ai-plugin-country.yaml`） |
| 75,77,81 | `ai-plugin` rule-provider（注释 + 定义 + path `rules/ai-plugin.yaml`） |
| 154,156,158,161 | `AI-FIXED` 组（consistent-hashing，use `ai_airport`，注释含 `nodes/ai.yaml`） |
| 181,184,187 | `AI-STICKY` 组（use `ai_airport`，注释含 `nodes/ai.yaml`） |
| 193,197 | `HK-STICKY` 组（保留） |
| 211-213 | `JP-STICKY` 组（注释：消费方 `ai-plugin-country`/`gen-country-rules.sh`） |
| 225-227 | `US-STICKY` 组（同上） |
| 239-241 | `SG-STICKY` 组（同上） |
| 253-255 | `TW-STICKY` 组（同上） |
| 267-269 | `KR-STICKY` 组（同上） |
| 281-283 | `GB-STICKY` 组（同上） |
| 295-297 | `DE-STICKY` 组（同上） |
| 321,323,324 | rules 注释（AI-STICKY / AI-FIXED 说明） |
| 331,333 | `RULE-SET,ai-plugin-country`、`RULE-SET,ai-plugin,AI-STICKY` |
| 337-346 | 内联 AI 域名兜底 10 行（DOMAIN-KEYWORD/DOMAIN-SUFFIX → AI-STICKY） |
| 354-360 | AI 远程规则集 7 行（AI/ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity → AI-STICKY） |
| 367 | `MATCH,HK-STICKY`（保留，组名命中 -STICKY） |

### docker-compose.yml（0 处，无需清理）

### README.md（约 33 处 → T4.1 重写时消除）

- 10-11：特性描述（AI-STICKY/HK-STICKY/国家组）
- 21-24：架构图（国家分流、AI-STICKY、HK-STICKY）
- 92-98：验证命令（HK-STICKY/AI-STICKY、`nodes/ai.yaml`）
- 106-121：分流流程（`ai-plugin-country`、`ai-plugin`、AI-STICKY、`gen-rules.sh`/`gen-country-rules.sh` 及产物）
- 135,141：国家分流维护步骤（`ai-domains-country.txt`、`gen-country-rules.sh`）
- 149-170：7 国组名表、`ai_airport`、AI-STICKY/AI-FIXED 分组策略
- 177-181：AI-STICKY vs AI-FIXED 选择说明
- 250-265：目录结构（`ai-domains.txt`、`ai-domains-country.txt`、`ai-plugin.yaml`、`ai-plugin-country.yaml`、`gen-rules.sh`、`gen-country-rules.sh`）

### DEPLOY.md（约 20 处 → T4.2 更新时消除）

- 51-52：部署步骤（`gen-rules.sh`/`gen-country-rules.sh`）
- 57-67：rule-provider 手工接入说明（`ai-plugin`、`ai-plugin-country`、`ai-domains-country.txt`）
- 122-130：节点池检查（`ai_airport`、国家组硬性要求、`gen-country-rules.sh`）
- 139-140,189,213：验证命令与日志（AI-STICKY）
- 225-231,241-250：维护矩阵（`ai-domains.txt`、`ai-domains-country.txt`、`gen-rules.sh`、`gen-country-rules.sh`）
- 273：故障排查（`gen-country-rules.sh`）

### scripts/verify.sh（12 处 → T3.3 改造时消除）

- 6-7,14,16：头部注释（ai_airport、AI-FIXED/AI-STICKY、国家组锚定模式）
- 148,152,174,201,262：`is_country_group`、国家组 hard fail 分支、COUNTRY 判定
- 406：结尾国家组提示行

### scripts/reload-nodes.sh（3 处 → T3.1 改造时消除）

- 6：头部注释（ai_airport、AI-FIXED/GEN-ROTATE/AI-STICKY 固定名单）
- 10：编排顺序注释（含 `gen-rules.sh`）

### scripts/apply.sh / logs.sh / claude-code-setup.sh / macos-proxy-manual-on.sh

- 各 0 处命中 ✅

## 已删除文件确认（1.1-1.3 产物）

- `scripts/gen-rules.sh`、`nodes/ai-domains.txt`、`rules/ai-plugin.yaml` ✅
- `scripts/gen-country-rules.sh`、`nodes/ai-domains-country.txt`、`rules/ai-plugin-country.yaml` ✅
- `rules/` 目录（清空后删除）✅
- `nodes/ai.example.yaml`（git rm，deleted 状态）✅
