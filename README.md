# ai-proxy-gateway

一台服务器，让全公司访问 ChatGPT / Claude / Gemini / Cursor 等 AI 服务。
**客户端零域名配置**——只设一次全局 PAC，走哪、怎么走全部由服务端 clash(mihomo) 决定。

- **网关引擎**：[mihomo](https://github.com/MetaCubeX/mihomo)（clash.meta 内核），
  **直接读取你现成的 clash 节点 YAML**，无需转换。
- **路由规则**：用 `rule-providers` 远程规则集（每天自动更新），
  **AI 站清单无需人肉维护、不会漏**。
- **智能分流**：AI 站 → 固定出口 IP（防封号）；其他海外站 → 轮询换 IP；
  国内 → 直连；广告/恶意 → 拦截。
- **管理员维护、员工无感**：加/删节点、更新规则都在服务端，员工什么都不用配。

> 📖 **要一步步部署？看 [DEPLOY.md](./DEPLOY.md)**（前置条件 → 部署 → 验证 → 接入 → 维护 → 排错）。

```
  客户端(系统全局 PAC) ──全部流量──► mihomo 网关(rule-providers 全权判定)
                                       ├─ Private        → 直连
                                       ├─ Block          → 拦截(广告/恶意)
                                       ├─ AI 全集(自动更新)→ AI-FIXED  固定出口 IP
                                       ├─ China / GEOIP CN → 直连
                                       └─ 其余(海外)      → GEN-ROTATE 轮询换 IP
                                              │
                                              └─► 机场节点池(ss/vmess/… 由你的 clash.yaml 提供)
```

---

## 一、管理员：部署网关

### 1. 放入你的节点

把现成的 clash 节点 YAML 原样拷进来（**不用改格式、不用转换**）：

```bash
cp /你的/clash订阅.yaml ./nodes/clash.yaml          # 通用/全量节点池
cp nodes/ai.example.yaml ./nodes/ai.yaml           # AI 专用节点池(必需)
# 然后编辑 nodes/ai.yaml，把要【专门给 AI 用】的节点粘进去(任意机场/命名)
```

> `nodes/clash.yaml` 供普通海外站轮询用；`nodes/ai.yaml` 是 AI 专用出口池
> （AI 站固定出口 IP 就从这里挑）。**两个文件都必须存在**，否则 mihomo 起不来。
> mihomo 只读文件里的 `proxies:` 段，多余字段忽略。真实文件已被 `.gitignore` 忽略。

### 2. 设置网关地址

```bash
cp .env.example .env
# 编辑 .env，GATEWAY_ADDR 改成服务器内网 IP/主机名，例如：
# GATEWAY_ADDR=10.0.0.8:10800   或   gateway.corp.example.com:10800
```

### 3. 启动

```bash
docker compose up -d
```

| 服务 | 地址 | 用途 |
|------|------|------|
| 代理入口 | `GATEWAY:10800`（http + socks5，mixed-port） | PAC 指向它 / CLI 用它 |
| PAC 文件 | `http://GATEWAY:19000/proxy.pac` | 员工系统全局代理指向它 |
| 管理 API | `127.0.0.1:9090`（仅本机） | 热重载、看节点健康 |

### 4. 维护节点池（员工无感）

改 `nodes/clash.yaml` 后热重载，无需重启：

```bash
./scripts/reload-nodes.sh
curl -s http://127.0.0.1:9090/providers/proxies/airport | jq   # 看节点健康
```

部署后建议跑一次验证，确认各组 filter 命中(尤其 AI 组锁美国后非空)、出口 IP 确为美国：

```bash
./scripts/verify.sh                       # 默认 API 127.0.0.1:9090、网关 127.0.0.1:10800
# 或单看某个组筛出的节点：
curl -s http://127.0.0.1:9090/proxies/AI-FIXED | jq '.all'
```

### 5. 路由规则（rule-providers，自动更新）

`config.yaml` 用远程规则集判定路由，每天自动更新，**新 AI 站自动纳入、无需手改**：

- `AI`(category-ai-!cn) + ChatGPT/Claude/Gemini/Copilot/Grok/Perplexity → `AI-FIXED`
- `China` / `GEOIP,CN` → 直连；`Private` → 直连；`Block` → 拦截
- 其余海外 → `GEN-ROTATE`
- **内联兜底**：核心 AI 站(openai/anthropic/claude/chatgpt/cursor/grok/gemini…)硬编码在
  规则最前，**即使远程规则集拉取失败，也绝不会掉进轮询而封号**。
- 依赖：网关需能访问 `gh-proxy.com` 镜像拉取规则集。

### 6. 两个可调开关

**池策略**（`config.yaml` 的 proxy-groups）：
- `AI-FIXED`：`consistent-hashing`，用 **AI 专用池** `ai_airport`(nodes/ai.yaml) → 每个 AI 站固定出口 IP ★ 默认 AI 走这个
- `GEN-ROTATE`：`round-robin`，用全量池 `airport`(nodes/clash.yaml) → 轮询换 IP ★ 其他海外站
- `AI-STICKY`：`sticky-sessions`，用 AI 专用池 → 会话粘连（多人共享网关时的 AI 备选，见下）

**加 AI 节点**：往 `nodes/ai.yaml` 粘一段即可，无需命名约定、无需改 config。
`use:` 可填多个 provider，如 `use: [ai_airport, airport]` 表示两个池合并。

**AI-FIXED vs AI-STICKY 怎么选**：
- 少量用户 / 每站固定一个出口 IP → 用默认 `AI-FIXED`（同一 AI 站所有请求走同一 IP）。
- **多用户共享网关、各自有 AI 账号** → 建议改用 `AI-STICKY`：它按「用户+目标」粘连，
  让**不同用户分散到不同出口 IP**且各自会话内 IP 稳定，避免"同一 IP 下多个账号登录"被风控。
- 切换方法：把 `config.yaml` 的 rules 里所有 `AI-FIXED` 改成 `AI-STICKY`（含内联兜底那几条）。

**PAC 的 DIRECT 兜底**（`www/proxy.pac.template`）：
- 保留 `; DIRECT` → 网关不可达时直连（不断网）；删掉 → 网关挂了直接失败。

---

## 二、员工：接入（只需设一次全局 PAC，零域名配置）

所有 GUI 应用（浏览器、Claude 桌面版、Cursor 等遵循系统代理的 app）只需设置系统全局 PAC，
**不配置任何域名**，走哪全由服务端 clash 决定。把下面的 `GATEWAY` 换成管理员给的网关地址。

### macOS

```bash
# 开启（Wi-Fi 有线请换成 Ethernet）
networksetup -setautoproxyurl "Wi-Fi" "http://GATEWAY:19000/proxy.pac"
# 关闭
networksetup -setautoproxystate "Wi-Fi" off
```
或用脚本：`./scripts/macos-proxy-on.sh http://GATEWAY:19000/proxy.pac Wi-Fi` / `./scripts/macos-proxy-off.sh Wi-Fi`

### Windows（PowerShell）

```powershell
# 开启
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
  -Name AutoConfigURL -Value "http://GATEWAY:19000/proxy.pac"
# 关闭
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name AutoConfigURL
```
或用脚本：`.\scripts\windows-proxy-on.ps1 -PacUrl "http://GATEWAY:19000/proxy.pac"` / `.\scripts\windows-proxy-off.ps1`

> 多数 Electron 桌面 app（Claude 桌面版、Cursor）遵循系统代理，设完即生效；个别 app 需重启。

### 命令行工具（Claude Code / Codex）——注意

CLI 工具**不读系统 PAC**，只读环境变量。仍然零域名配置（全部流量交给网关，clash 决定）：

```bash
export HTTP_PROXY=http://GATEWAY:10800
export HTTPS_PROXY=http://GATEWAY:10800
```
辅助脚本：`./scripts/claude-code-setup.sh http://GATEWAY:10800`（打印含 `~/.claude/settings.json` 的多种配置方式）。

### 浏览器插件（独立可选，非必需）

仓库另有 Chrome 插件 [chatgpt-block-bypass](../chatgpt-block-bypass)，走**选择式域名**逻辑
（只代理内置清单里的 AI 域名），适合不想设系统全局代理、只想在浏览器里用的场景。
它与本文的全局 PAC 是**两条独立路径**，二选一即可，无需同时用。

---

## 三、为什么用 mihomo 而不是 gost

因为**已有 clash 格式节点**：mihomo 原生读取 clash YAML，零转换；proxy-group 天然就是节点池
（fallback/load-balance/url-test），健康检查与 rule-providers 内建。gost 需把 ss/vmess/vless/trojan
逐一转成自有格式，脆弱且多余。内网无认证的共享网关场景，mihomo 的 `allow-lan` 完全够用。

## 目录结构

```
ai-proxy-gateway/
├─ docker-compose.yml        # mihomo(网关) + nginx(PAC 服务)
├─ config.yaml               # mihomo：读 clash 节点 + rule-providers 规则集 + 分流组
├─ .env.example              # GATEWAY_ADDR 网关地址
├─ nodes/
│  ├─ clash.example.yaml     # 节点格式示例
│  └─ clash.yaml             # ← 你的真实节点(gitignore)
├─ www/
│  ├─ proxy.pac.template     # 全局 PAC 模板(envsubst 注入网关地址)
│  └─ nginx.conf             # PAC 静态服务
└─ scripts/
   ├─ macos-proxy-on/off.sh
   ├─ windows-proxy-on/off.ps1
   ├─ claude-code-setup.sh   # CLI env 配置
   ├─ verify.sh              # 部署后验证：节点池/各组 filter 命中/出口 IP 地区
   └─ reload-nodes.sh        # 热重载节点池
```
