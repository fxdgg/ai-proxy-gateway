# 部署文档（一步步操作 + 验证）

面向管理员：把网关部署到一台服务器，全公司连它访问 AI 服务。全程约 10 分钟。

> ⚠ **从旧版（单实例，端口 10800）升级？** 先看 [第 2 节「旧版升级」](#2-旧版单实例升级顺序固定勿跳步)，步骤顺序定死，勿跳步。

---

## 0. 前置条件

- **一台服务器**（Linux，devcloud/云主机均可），装好 **Docker** 与 **Docker Compose v2**。
  ```bash
  docker --version && docker compose version   # 确认可用
  ```
- 该服务器**能连到你的机场节点**，且**能访问 `gh-proxy.com`**（用于拉取通用实例的 rule-providers 规则集）。
- 你手上有 **clash 格式的节点 YAML**（订阅式或完整配置都行，只取其中 `proxies:` 段）。
- 员工机器与服务器**网络可达**（同内网/VPN），能访问服务器的 `7890`、`7891` 和 `19000` 端口。
- 验证阶段服务器上装了 `jq`、`curl`：`apt install -y jq curl` 或 `yum install -y jq curl`。

---

## 1. 获取代码

```bash
git clone git@github.com:fxdgg/ai-proxy-gateway.git
cd ai-proxy-gateway
```

## 2. 旧版（单实例）升级（顺序固定，勿跳步）

> 全新部署请跳过本节，直接看第 3 节。以下 4 步顺序**定死**：跳步/乱序会导致缺变量报错，
> 或旧容器占端口、新实例绑定失败。

**① 先补 `.env`（必须放在 `docker compose down` 之前）**

```bash
vim .env
# 新增一行（AI 实例入口）：
AI_GATEWAY_ADDR=<服务器>:7890
# 修改既有行（通用实例入口）：
GATEWAY_ADDR=<服务器>:7891        # 原来是 <服务器>:10800
```

> 为什么必须在 down 之前：新版 compose 的 pac 服务 env 含 `${AI_GATEWAY_ADDR:?...}`
> 强校验；`down` 同为 compose 命令、同样做 env 插值——不先补 .env，`down` 本身就会
> 因缺变量报错。

**② `docker compose down`**

```bash
docker compose down
```

> - 停掉旧单实例 gateway 容器与 pac 服务。pac 服务（19000）与过渡监听（10800）在
>   down→up 窗口内**各有秒级中断**，请**建议低峰执行**、提前知会全局 PAC 用户与旧插件用户。
> - **必须显式 down**：docker compose v2 的 `up -d` 不会删除服务改名后的旧容器（仅警告
>   orphaned）——旧 gateway 容器继续占用 10800/9090，会导致新 AI 实例的 10800 过渡监听
>   与 9090 管理 API 绑定失败、陷入崩溃循环，脚本/管理员的 API 调用还会误打旧容器。

**③ `docker compose up -d --remove-orphans`**

```bash
docker compose up -d --remove-orphans
```

> - `--remove-orphans` 清掉改名后遗留的旧孤儿容器，与第 ② 步 down 双保险。
> - **不带 `--build`**：本 compose 无 build 段，加了无意义。

**④ verify.sh 位置参数语义变化（旧 2 参命令不再兼容）**

- 旧用法（2 参）：`./scripts/verify.sh [API地址] [网关host:port]`
- 新用法（4 参）：`./scripts/verify.sh [AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]`，
  默认 `127.0.0.1:9090 127.0.0.1:9091 127.0.0.1:7890 127.0.0.1:7891`。
- **旧 2 参命令不再兼容**；无参执行即按默认值校验两个实例（见第 6 节）。

**升级后的兼容状态**：

- 旧插件**零改动**继续工作：AI 实例通过过渡监听继续提供 10800（⚠ 过渡期内
  10800 = 全流量美国出口，见第 9 节 FAQ）。
- `nodes/ai.yaml` 手工池已废弃、不再被读取，升级后删除该文件即可。
- macOS 手动代理旧用户：脚本新版默认端口已改 7891，已打开的系统代理设置需手动切换
  （重跑 `./scripts/macos-proxy-manual-on.sh` 或改系统设置）。

## 3. 放入节点（只需机场文件 + build，无需手工池）

```bash
# 每个机场一个文件，命名 nodes/clash-<id>.yaml，数量不限
cp /你的/机场A订阅.yaml  ./nodes/clash-a.yaml
cp /你的/机场B订阅.yaml  ./nodes/clash-b.yaml    # 可选；旧名 clash.yaml 仍兼容(默认机场)

# 合并各机场节点 → nodes/_merged.yaml（两个实例共享它）
./scripts/build-config.sh
```

> - **无需 ai.yaml 手工池**：AI 出口组（`AI-US-STICKY`）按节点名里的「美国/US」等关键词
>   从机场池自动聚合；要指定美国住宅出口，把住宅节点命名为含「美国」（如 `美国-住宅-01`）
>   放入任意机场文件即可。
> - 机场文件（`clash-<id>.yaml` / `clash.yaml`）至少一个，否则 mihomo 起不来。
> - **订阅式 vs 完整配置式**：两种都行，mihomo 只读 `proxies:` 段，多余字段忽略。
> - **重名节点需改名**：多机场节点同名时 build-config.sh 会报错退出（不自动加前缀），在其中一处改名后重跑。
> - 真实节点文件已被 `.gitignore` 忽略（`nodes/*.yaml` 覆盖 `_merged.yaml` 等全部 yaml），不会误提交。

## 4. 设置网关地址（双变量）

```bash
cp .env.example .env
vim .env
```

把两个变量改成**员工能访问到的服务器地址**（内网 IP 或主机名）：

```
GATEWAY_ADDR=10.0.0.8:7891        # 通用实例：全局 PAC 兜底出口
AI_GATEWAY_ADDR=10.0.0.8:7890     # AI 实例：插件 PAC、PAC 内 AI 域名清单指向它
```

这两个地址会被写进 PAC（AI 域名 → 7890，其余 → 7891），员工的系统代理据此连网关。

> ⚠ **只填 `host:port`，不要带 `http://`**（PAC 的 `PROXY` 指令只认 host:port，带 scheme 会失效）。
> 即使误加了前缀，容器也会自动剥掉（`www/15-sanitize-gateway.envsh`）。渲染结果可核对：
> `curl -s http://127.0.0.1:19000/proxy.pac | grep PROXY` 应看到 7890/7891 两个 PROXY 常量。

## 5. 启动

```bash
docker compose up -d
docker compose ps          # 三个容器均应为 running：
                           #   ai-proxy-gateway-ai    （AI 实例）
                           #   ai-proxy-gateway-main  （通用实例）
                           #   ai-proxy-pac           （PAC 服务）
docker compose logs -f gateway-main   # 看通用实例日志，确认节点/规则加载无报错（Ctrl+C 退出）
docker compose logs -f gateway-ai     # 看 AI 实例日志
```

启动后对外提供：

| 端口 | 服务 | 用途 |
|------|------|------|
| `7890` | AI 实例代理入口（http+socks5） | 插件 PAC 的 AI 域名、CLI 指向它 |
| `7891` | 通用实例代理入口（http+socks5） | 全局 PAC 兜底、手动代理脚本 |
| `9090`（仅本机） | AI 实例管理 API | 验证/热重载 |
| `9091`（仅本机） | 通用实例管理 API | 验证/热重载 |
| `19000` | PAC 文件 `http://服务器:19000/proxy.pac` | 员工系统代理指向它 |
| `10800`（迁移期） | AI 实例过渡监听 | 旧插件兼容；过渡期内全流量美国出口（见 FAQ） |

---

## 6. 验证（关键，务必执行）

在**服务器上**跑验证脚本：

```bash
./scripts/verify.sh
```

> 无参执行默认校验两个实例。位置参数（4 参）：`./scripts/verify.sh [AI_API] [MAIN_API] [AI_GATEWAY] [MAIN_GATEWAY]`，
> 默认 `127.0.0.1:9090` / `127.0.0.1:9091` / `127.0.0.1:7890` / `127.0.0.1:7891`
> （⚠ 旧版 2 参用法已不兼容，见第 2 节升级说明第 ④ 步）。

输出为**两个实例各一组**校验结果，逐项确认：

1. **节点池**：两个实例共用同一 `airport` provider（`nodes/_merged.yaml`），节点数 > 0
   （provider 由 API 动态发现，机场数变化无需改脚本）。
2. **各组非空（硬性要求）**：
   - AI 实例：**组名含 AI 的组**（`AI-US-STICKY`）非空。为空 → 机场节点名不含「美国/US」
     等关键词 → 给美国节点名补「美国」字样后 `build-config.sh` → `reload-nodes.sh`（见 FAQ）。
   - 通用实例：**组名含 HK/香港 的组**（`HK-STICKY`）非空。为空 → 机场节点名不含
     「香港/HK」→ 检查节点命名或 `config-main.yaml` 的香港正则。
3. **出口连通**：AI 实例 `claude.ai`/`chatgpt.com` 的 `cdn-cgi/trace` **可连通即通过**
   （`loc=` 仅供参考），并打印两实例出口 IP/地区。
4. **迁移期 10800 检查**：`curl -x http://127.0.0.1:10800 https://claude.ai/cdn-cgi/trace`
   应可达且美国出口（验证 AI 实例过渡监听真实生效）。

也可手动单查某组筛出的节点：

```bash
curl -s http://127.0.0.1:9090/proxies/AI-US-STICKY | jq '.all'   # AI 实例
curl -s http://127.0.0.1:9091/proxies/HK-STICKY    | jq '.all'   # 通用实例
```

PAC 是否正常吐出：

```bash
curl -s http://127.0.0.1:19000/proxy.pac | head    # 应看到 FindProxyForURL + 7890/7891 两个 PROXY 常量
```

---

## 7. 员工接入（客户端零域名配置）

把下面的 `服务器` 换成 `.env` 里的 `GATEWAY_ADDR` 主机部分。

> **⚠ 两个地址别搞混（常见坑）：**
> - **PAC 文件的 URL** 要带 `http://`：`http://服务器:19000/proxy.pac` —— 这是「去哪下载 PAC 文件」。
> - **PAC 文件内部的 `PROXY host:port`** 不带 scheme：AI 域名 → `服务器:7890`、其余 →
>   `服务器:7891` —— 这是 PAC 语法，由 `.env` 的 `AI_GATEWAY_ADDR` / `GATEWAY_ADDR`
>   决定，带了 `http://` 会失效（容器已自动剥掉）。
>
> **⚠ 命令写在同一行**：`networksetup -setautoproxyurl "Wi-Fi" "http://…/proxy.pac"` 整条别换行，
> 否则 URL 掉到下一行会报 `The amount of parameters was not correct`。

**macOS（GUI 应用/浏览器）：**
```bash
networksetup -listallnetworkservices                                   # 先确认服务名(Wi-Fi/Ethernet…)
networksetup -setautoproxyurl "Wi-Fi" "http://服务器:19000/proxy.pac"   # 开(整条一行)
networksetup -setautoproxystate "Wi-Fi" on
networksetup -getautoproxyurl "Wi-Fi"                                   # 验证:URL + Enabled: Yes
networksetup -setautoproxystate "Wi-Fi" off                            # 关
```

**Windows（PowerShell）：**
```powershell
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
  -Name AutoConfigURL -Value "http://服务器:19000/proxy.pac"            # 开
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name AutoConfigURL   # 关
```

**命令行工具（Claude Code / Codex，不读系统 PAC，用环境变量）：**
```bash
export HTTP_PROXY=http://服务器:7890
export HTTPS_PROXY=http://服务器:7890
# ⚠ 必配 NO_PROXY（大小写双写），否则内网/国内站点流量绕道美国出口（详见 README「命令行工具」节）：
export NO_PROXY='localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<你的内网域名>'
export no_proxy='localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,<你的内网域名>'
```

### 桌面 app（Claude 桌面版 / Cursor 等）

多数桌面 app 是 Electron，**遵循 macOS/Windows 系统代理**，设完上面的系统 PAC 就已覆盖，但：

1. **必须完全重启 app**（macOS 用 `Cmd+Q` 退出后重开，不是关窗口）——app 启动时才读代理。
2. 重启后验证：网关服务器上 `./scripts/logs.sh claude 200 gateway-ai`（或
   `docker compose logs -f gateway-ai | grep -i claude`），用桌面版发条消息，
   日志出现 `你的客户端IP --> claude.ai ... using AI-US-STICKY` 即生效。
3. **若桌面版不认 PAC**（个别 Electron 只认手动代理），改用「手动全局代理」（走通用实例）：
   ```bash
   ./scripts/macos-proxy-manual-on.sh  服务器 7891  Wi-Fi   # 开(http+https 全指通用实例)
   ./scripts/macos-proxy-manual-off.sh Wi-Fi               # 关
   ```
   Windows 手动代理：系统设置 → 网络 → 代理 → 手动，填 `服务器:7891`。
   > 手动代理与 PAC 二选一，别同时开；手动兼容性更好，PAC 更「选择式」。设完同样要重启 app。
4. **仍不走网关**：说明该 app 完全绕过系统代理、自己直连。终极方案是 TUN 透明代理接管全部流量（需额外配置）。

员工侧验证：浏览器打开 https://claude.ai 能正常访问即成功；或
`curl -x http://服务器:7890 https://claude.ai/cdn-cgi/trace`（AI 实例，应美国出口）、
`curl -x http://服务器:7891 https://www.cloudflare.com/cdn-cgi/trace`（通用实例，应香港出口）。

> **⚠ 如何确认系统 PAC 真的生效（尤其公司网络本来就能出海时）：**
> - `curl` **默认不走系统 PAC**，只认 `-x`/`HTTP(S)_PROXY`。所以裸 `curl ipinfo.io` 是直连，测不出网关。
>   只有浏览器等 GUI 应用才走系统 PAC。
> - **对比直连 vs 网关出口**（cloudflare trace 不限流）：
>   ```bash
>   echo "直连:"; curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|loc)='
>   echo "网关:"; curl -s -x http://服务器:7891 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|loc)='
>   ```
>   两组 `colo`/`ip` 不同即证明网关走了不同出口。
> - **浏览器验证**：打开 `https://www.cloudflare.com/cdn-cgi/trace`，其 `ip/colo` 应与上面「网关」一致。
> - **服务器铁证**：网关上 `./scripts/logs.sh claude 200 gateway-ai`，客户端浏览器访问 claude.ai，
>   日志出现 `客户端IP --> claude.ai ... using AI-US-STICKY` 即生效。

---

## 8. 日常维护（员工无感）

**改动生效方式——按改了什么选，多数无需重启、无停机：**

| 改了什么 | 用什么生效 | 是否停机 |
|----------|-----------|----------|
| 机场文件增删/改动 `nodes/clash-<id>.yaml` | `./scripts/build-config.sh` → `./scripts/reload-nodes.sh` | 否（先合并再热重载，覆盖两个实例）|
| 配置 `config-main.yaml` / `config-ai.yaml`（规则/组/filter/策略）| `./scripts/apply.sh` | 否（API 热加载，覆盖两个实例）|
| `.env`（GATEWAY_ADDR / AI_GATEWAY_ADDR）| `docker compose up -d pac` | 极短（仅 PAC 服务重启）|
| `docker-compose.yml` / 换镜像 | `docker compose up -d` | 极短 |

> 所以你**不用背 `down && up`**：改机场先 build 再 reload，改配置跑 `apply.sh`（两个脚本
> 都**默认覆盖两个实例**，无需分别操作）。只有在 API 热加载失败、或需要彻底断掉所有旧连接时，
> 才用 `docker compose down && docker compose up -d`
> （podman 环境别用 `restart`，会报 device or resource busy）。

**加/删机场或改机场节点**：
```bash
./scripts/build-config.sh        # ① 合并各机场 → nodes/_merged.yaml（重名节点会报错，需改名）
./scripts/reload-nodes.sh        # ② 热重载两个实例 provider + 即时健康检查（前提是已 build，脚本会校验）
```

**改配置**：改 `config-main.yaml` / `config-ai.yaml` 后：
```bash
./scripts/apply.sh               # API 热加载两个实例，无停机
```

**更新规则集**：通用实例的远程 rule-providers（China/Private/Block）每天自动更新，无需手动。

**看日志**：`./scripts/logs.sh [关键字] [行数] [服务]`（默认通用实例 gateway-main；AI 实例传 gateway-ai）

---

## 9. 常见问题（FAQ）

| 现象 | 排查 |
|------|------|
| 容器起不来 | `docker compose logs gateway-ai` / `docker compose logs gateway-main`；多半是机场文件缺失或 YAML 格式错 |
| AI 组为空 | 见下方 FAQ「AI 组为空怎么办」 |
| 香港组为空 | 机场节点名不含「香港/HK」→ 检查节点命名或 `config-main.yaml` 香港正则（第 6 节第 2 项）|
| 访问 AI 失败 | 节点是否可用（verify 第 2/3 项）；插件 PAC/CLI 是否指向 7890（旧插件走 10800 过渡监听）|
| build 报「节点重名」 | 按报错提示找到重名节点与来源文件，在其中一处改名后重跑 build-config.sh |
| 拉不到规则集 | 服务器是否能访问 `gh-proxy.com`（仅通用实例的 China/Private/Block 依赖）|
| `restart` 报 device or resource busy | 该环境是 podman，用 `docker compose down && docker compose up -d` 代替 restart |
| 改了节点仍走旧节点 | 长连接(websocket 等)不切换，`down && up` 断掉旧连接；先 `./scripts/reload-nodes.sh` 看组内节点是否已更新 |
| 国内网站也变慢 | 全局 PAC 下国内流量绕行网关由 mihomo 判 DIRECT，属预期；介意可用选择式插件 |

**Q：AI 组为空怎么办？**
A：`AI-US-STICKY` 按节点名自动聚合——机场节点名含「美国/US/USA/United States/America」
才会入组。为空时：给美国节点名补「美国」字样（如 `IX精品专线-美国01`；要美国住宅出口
可建 `美国-住宅-01`），然后 `./scripts/build-config.sh` → `./scripts/reload-nodes.sh`；
同时检查 `config-ai.yaml` 里美国组的 filter 正则。

**Q：插件端口切换过渡期，10800 是什么语义？**
A：迁移期内 AI 实例额外监听 10800（旧插件 PAC 硬编码的端口），**旧插件零改动继续工作**。
⚠ **过渡期内 10800 = 全流量美国出口**：凡到达 10800 的流量（不止 AI 域名）一律走美国
节点。受影响：① 旧插件用户中把 `google.com` 裸域等宽泛域名配进个人清单的用户（这些
域名的流量会全部走美国）；② macOS 手动代理旧用户（旧默认端口 10800 是全量系统代理，
新版默认已改 7891，已打开的系统代理设置需手动切换）。插件侧端口切换完成后，10800
过渡监听将在后续小版本移除。
