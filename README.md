# ai-proxy-gateway

一台服务器，让全公司访问 ChatGPT / Claude / Gemini / Cursor 等 AI 服务。
**客户端零域名配置**——只设一次全局 PAC：通用流量走哪、怎么走由服务端 clash(mihomo) 决定，
AI 域名判定在客户端 PAC 完成。

- **网关引擎**：[mihomo](https://github.com/MetaCubeX/mihomo)（clash.meta 内核），
  **直接读取你现成的 clash 节点 YAML**，无需转换，**支持多机场**。
- **双实例隔离**：AI 流量与通用流量由两个独立实例分开处理——AI 实例全流量美国出口，
  通用实例国内直连 + 香港默认出口。**AI 域名判定在客户端 PAC 完成**，网关不再同步
  任何用户的域名清单（A 用户的配置不再影响 B 用户）。
- **智能分流**：AI 站 → 美国出口组（`AI-US-STICKY`，防封号）；其他海外站 → 香港组
  （`HK-STICKY`，默认出口）；国内 → 直连；广告/恶意 → 拦截。
- **管理员维护、员工无感**：加/删节点、更新配置都在服务端，员工什么都不用配。

> 📖 **要一步步部署？看 [DEPLOY.md](./DEPLOY.md)**（前置条件 → 部署 → 验证 → 接入 → 维护 → 排错）。
> ⚠ 从旧版（单实例 10800）升级？DEPLOY 的升级步骤**顺序定死**，请严格照做。

```
  客户端
   ├─ 浏览器插件 PAC（选择式：只代理用户清单里的 AI 域名）
   │        AI 域名 ─────────► 7890（AI 实例 gateway-ai）
   │                                └─ MATCH ──► AI-US-STICKY（美国节点聚合，固定出口防封号）
   └─ 系统全局 PAC（:19000/proxy.pac）
            ├─ 静态 AI 域名清单 ──► 7890（AI 实例，同上）
            └─ 其余流量 ─────────► 7891（通用实例 gateway-main）
                                       ├─ Private / China / GEOIP CN → 直连
                                       ├─ Block → 拦截（广告/恶意）
                                       └─ MATCH 兜底 ──► HK-STICKY（香港节点聚合，默认出口）
                                              │
                                              └─► 机场节点池（多机场 clash-<id>.yaml 合并产物，两实例共享）
```

---

## 一、管理员：部署网关

### 1. 放入你的节点（支持多机场，无需手工池）

每个机场一个文件，命名 `nodes/clash-<id>.yaml`（`<id>` 为机场标识，如 `clash-a.yaml`、
`clash-b.yaml`）；旧名 `nodes/clash.yaml` 作为「默认机场」继续兼容。有多少机场就放
多少个，**脚本自动发现、无需登记**：

```bash
cp /你的/机场A订阅.yaml ./nodes/clash-a.yaml       # 机场 A
cp /你的/机场B订阅.yaml ./nodes/clash-b.yaml       # 机场 B（可选，数量不限）
./scripts/build-config.sh                         # 合并各机场 → nodes/_merged.yaml（两实例共享）
```

> - 订阅文件**不用改格式、不用转换**：「订阅式（只有 proxies）」和「完整 clash 配置
>   （含 proxy-groups/rules）」都能直接用，mihomo 只读 `proxies:` 段，多余字段忽略。
> - **不需要 AI 手工池**（`nodes/ai.yaml` 已废弃）：AI 出口组（`AI-US-STICKY`）按节点名
>   里的「美国/US」等关键词从机场池**自动聚合**，无需命名约定（见第 5 节）。要指定
>   「美国住宅出口」时，把住宅节点命名为含「美国」（如 `美国-住宅-01`）放入任意机场
>   文件即可。
> - **重名节点需改名**：跨机场节点名重复时 build-config.sh 会报错退出（不自动加前缀），
>   请在其中一处改名后重跑，避免破坏 dialer-proxy 引用。
> - 真实文件已被 `.gitignore` 忽略（`nodes/*.yaml`），不会误提交。

### 2. 设置网关地址

```bash
cp .env.example .env
# 编辑 .env，两个变量都改成服务器内网 IP/主机名：
# GATEWAY_ADDR=10.0.0.8:7891          ← 通用实例（全局 PAC 兜底出口）
# AI_GATEWAY_ADDR=10.0.0.8:7890       ← AI 实例（插件 PAC、PAC 内 AI 域名清单指向它）
```

### 3. 启动

```bash
docker compose up -d
docker compose ps    # 三个容器：ai-proxy-gateway-ai / ai-proxy-gateway-main / ai-proxy-pac
```

**端口约定**（插件侧、PAC 模板、脚本均按此对齐，请勿修改）：

| 端口 | 服务 | 用途 |
|------|------|------|
| `7890` | AI 实例代理入口（http + socks5） | 插件 PAC 的 AI 域名、CLI（Claude Code 等）指向它 |
| `7891` | 通用实例代理入口（http + socks5） | 全局 PAC 兜底、macOS 手动代理脚本指向它 |
| `9090`（仅本机） | AI 实例管理 API | 热重载、看节点健康 |
| `9091`（仅本机） | 通用实例管理 API | 热重载、看节点健康 |
| `19000` | PAC 文件 `http://GATEWAY:19000/proxy.pac` | 员工系统全局代理指向它 |
| `10800`（迁移期） | AI 实例过渡监听 | 旧插件兼容；**过渡期内全流量美国出口**，见「迁移期说明」 |

### 4. 维护节点池（员工无感）

机场文件增删/改动后，**先合并再热重载**（reload 的前提是已 build，脚本开头会校验
`_merged.yaml` 是否比机场文件旧）。reload/apply 脚本**默认覆盖两个实例**，无需分别操作：

```bash
./scripts/build-config.sh    # 重新合并各机场 → nodes/_merged.yaml
./scripts/reload-nodes.sh    # 同时热重载两个实例的 provider + 即时健康检查
```

部署后建议跑一次验证，确认 AI 组（美国聚合）与香港组（默认出口）均非空、AI 服务可连通：

```bash
./scripts/verify.sh          # 无参执行即校验两个实例（API 9090/9091、网关 7890/7891）
# 或单看某个组筛出的节点：
curl -s http://127.0.0.1:9090/proxies/AI-US-STICKY | jq '.all'   # AI 实例
curl -s http://127.0.0.1:9091/proxies/HK-STICKY    | jq '.all'   # 通用实例
```

### 5. 两个实例的分流逻辑

**AI 实例**（`config-ai.yaml`）：规则只有一条 `MATCH → AI-US-STICKY`。发到 7890 的流量
默认全是 AI 域名（客户端 PAC 已过滤），一律美国出口。

> **AI-US-STICKY 美国聚合**：`use: [airport]` + 美国正则 filter 跨机场自动聚合，
> **节点名含「美国/US/USA/United States/America」即入组**（住宅节点同样只需命名含
> 「美国」，如 `美国-住宅-01`）。策略 `sticky-sessions`：多用户各自出口 IP + 会话内
> 稳定，避免「同一 IP 下多个账号登录」被风控。不需要手工池、不需要登记节点。

**通用实例**（`config-main.yaml`）：`Private` → 直连；`Block` → 拦截（广告/恶意）；
`China` / `GEOIP,CN` → 直连；`MATCH` 兜底 → `HK-STICKY`（按节点名里的「香港/HK」
跨机场聚合，默认出口）。`China`/`Private`/`Block` 远程规则集每天自动更新，**无需人肉维护**。

### 6. 可调开关

**分组策略**（`config-main.yaml` / `config-ai.yaml` 的 proxy-groups）：
- `AI-US-STICKY`：`sticky-sessions`，全量池 `airport` + 美国正则 filter → AI 实例唯一出口 ★
- `HK-STICKY`：`sticky-sessions`，全量池 `airport` + 香港正则 filter → 通用实例默认出口 ★
- `GEN-ROTATE`：`round-robin`，全量池 + 香港正则 → 备用（想轮询换 IP 时把
  `config-main.yaml` 的 MATCH 目标改过去）

**全局 PAC 的静态 AI 域名清单**（`www/proxy.pac.template`）：15 个公开 AI 站域名
（openai/chatgpt/claude/anthropic/gemini/cursor/…）写死在 PAC 模板内，全局 PAC 用户
访问这些站点时自动走 7890 美国出口。若希望全局 PAC 完全零域名（纯通用出口），把模板
中 AI 域名段注释掉即可。

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
或用脚本：`.\\scripts\\windows-proxy-on.ps1 -PacUrl "http://GATEWAY:19000/proxy.pac"` / `.\\scripts\\windows-proxy-off.ps1`

> 多数 Electron 桌面 app（Claude 桌面版、Cursor）遵循系统代理，设完即生效；个别 app 需重启。

### 命令行工具（Claude Code / Codex）——注意

CLI 工具**不读系统 PAC**，只读环境变量。CLI 流量以 AI 为主，默认指向 **AI 实例 7890**：

```bash
export HTTP_PROXY=http://GATEWAY:7890
export HTTPS_PROXY=http://GATEWAY:7890
```
辅助脚本：`./scripts/claude-code-setup.sh http://GATEWAY:7890`（打印含 `~/.claude/settings.json` 的多种配置方式，并输出 NO_PROXY 内网段豁免配置）。

> ⚠ **CLI 走 7890 时国内站点绕美国**：环境变量代理是**全量代理**（无 PAC 选择），而
> AI 实例的规则只有「全流量美国出口」、没有国内直连兜底——不设 NO_PROXY 时，内网/
> 国内站点流量会绕道美国出口甚至不可达。请务必同时设置 `NO_PROXY` 豁免内网段：
>
> - **大小写双写**：`NO_PROXY` 与 `no_proxy` 两个变量都导出（Node/Python 系工具只认
>   小写，curl 系认大写）：
>   ```bash
>   export NO_PROXY='localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<你的内网域名>'
>   export no_proxy='localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<你的内网域名>'
>   ```
> - **CIDR 段限制**：`10.0.0.0/8` 等 CIDR 写法仅 curl ≥ 7.86 / libcurl 系工具识别，
>   Node/Python 系不识别——关键内网主机建议**同时列出主机名/IP 字面量**（如
>   `git.corp.example.com,10.0.0.8`）。
> - **国内站点如需直连**：自行把域名追加到 NO_PROXY（如
>   `export NO_PROXY="$NO_PROXY,registry.npmjs.org"`）。

### 浏览器插件（独立可选，非必需）

仓库另有 Chrome 插件 [chatgpt-block-bypass](../chatgpt-block-bypass)，走**选择式域名**逻辑
（只代理内置清单里的 AI 域名），适合不想设系统全局代理、只想在浏览器里用的场景。
它与本文的全局 PAC 是**两条独立路径**，二选一即可，无需同时用。插件 PAC 的 AI 域名
指向 **AI 实例 7890**（旧版插件硬编码 10800 仍可用，见下方「迁移期说明」）。

### 迁移期说明（10800 过渡监听）

旧版插件 PAC 硬编码端口 `10800`。本版本在 AI 实例上以 mihomo `listeners` 段额外监听
`10800`，**旧插件零改动继续工作**。

> ⚠ **过渡期内 10800 = 全流量美国出口**：凡到达 10800 的流量（不止 AI 域名）一律命中
> `MATCH → AI-US-STICKY` 走美国节点。受影响人群：
> - 旧插件用户中把 `google.com` 裸域等**宽泛域名**配进个人清单的用户——这些域名的
>   流量会全部走美国；
> - **macOS 手动代理旧用户**——`macos-proxy-manual-on.sh` 旧默认端口 10800 是全量系统
>   代理，新版默认已改 7891，但**已打开的系统代理设置需手动切换**（重跑脚本或改系统设置）。
>
> 插件侧端口切换完成后，10800 过渡监听将在后续小版本移除。

---

## 三、为什么用 mihomo 而不是 gost

因为**已有 clash 格式节点**：mihomo 原生读取 clash YAML，零转换；proxy-group 天然就是节点池
（fallback/load-balance/url-test），健康检查与 rule-providers 内建。gost 需把 ss/vmess/vless/trojan
逐一转成自有格式，脆弱且多余。内网无认证的共享网关场景，mihomo 的 `allow-lan` 完全够用。

## 目录结构

```
ai-proxy-gateway/
├─ docker-compose.yml        # 双 mihomo 实例(gateway-ai / gateway-main) + nginx(PAC 服务)
├─ config-ai.yaml            # AI 实例：MATCH → AI-US-STICKY(美国出口) + 迁移期 10800 过渡监听
├─ config-main.yaml          # 通用实例：国内直连 + MATCH → HK-STICKY(香港出口)
├─ .env.example              # GATEWAY_ADDR(通用 7891) / AI_GATEWAY_ADDR(AI 7890)
├─ nodes/
│  ├─ clash.example.yaml     # 机场订阅格式示例 + 多机场命名规范
│  ├─ clash-<id>.yaml        # ← 各机场真实节点(gitignore)
│  ├─ clash.yaml             # ← 默认机场(兼容旧名,gitignore)
│  └─ _merged.yaml           # ← build-config.sh 合并产物(gitignore，两实例共享)
├─ www/
│  ├─ proxy.pac.template     # 全局 PAC 模板(双端口分流：AI 清单 → 7890，其余 → 7891)
│  ├─ 15-sanitize-gateway.envsh  # 剥掉 GATEWAY_ADDR 误加的 http(s):// 前缀(供 PAC 的 PROXY 指令)
│  └─ nginx.conf             # PAC 静态服务
└─ scripts/
   ├─ build-config.sh        # 合并各机场节点 → nodes/_merged.yaml（重名报错）
   ├─ reload-nodes.sh        # 改节点后热重载两个实例 + 即时健康检查(前提:已 build)
   ├─ verify.sh              # 部署后验证：两实例 provider/组非空/出口连通
   ├─ logs.sh                # 看网关日志，支持关键字过滤：./scripts/logs.sh claude
   ├─ apply.sh               # 改配置后热加载两个实例生效(无停机)
   ├─ macos-proxy-on/off.sh
   ├─ macos-proxy-manual-on/off.sh  # 手动全局代理(默认 7891；桌面 app 不认 PAC 时用)
   ├─ windows-proxy-on/off.ps1
   └─ claude-code-setup.sh   # CLI env 配置(默认 7890 + NO_PROXY 内网段豁免)
```
