# 部署文档（一步步操作 + 验证）

面向管理员：把网关部署到一台服务器，全公司连它访问 AI 服务。全程约 10 分钟。

---

## 0. 前置条件

- **一台服务器**（Linux，devcloud/云主机均可），装好 **Docker** 与 **Docker Compose v2**。
  ```bash
  docker --version && docker compose version   # 确认可用
  ```
- 该服务器**能连到你的机场节点**，且**能访问 `gh-proxy.com`**（用于拉取 rule-providers 规则集）。
- 你手上有 **clash 格式的节点 YAML**（订阅式或完整配置都行，只取其中 `proxies:` 段）。
- 员工机器与服务器**网络可达**（同内网/VPN），能访问服务器的 `10800` 和 `19000` 端口。
- 验证阶段服务器上装了 `jq`、`curl`：`apt install -y jq curl` 或 `yum install -y jq curl`。

---

## 1. 获取代码

```bash
git clone git@github.com:fxdgg/ai-proxy-gateway.git
cd ai-proxy-gateway
```

## 2. 放入节点（两个文件都必须有）

```bash
# 通用/全量池：普通海外站轮询用
cp /你的/clash订阅.yaml  ./nodes/clash.yaml

# AI 专用池：AI 站固定出口 IP 用，把要专门给 AI 的节点粘进去
cp nodes/ai.example.yaml ./nodes/ai.yaml
vim ./nodes/ai.yaml      # 编辑，填入 AI 专用节点(任意机场/命名皆可)
```

> - 两个文件缺一不可，否则 mihomo 起不来。
> - 出口已在 `config.yaml` 里用 filter **锁定美国**：节点名需含地区标识（🇺🇸/美国/洛杉矶/US…），
>   否则会被过滤掉。想换地区改 `config.yaml` 里 `filter` 正则。
> - 真实节点文件已被 `.gitignore` 忽略，不会误提交。

## 3. 设置网关地址

```bash
cp .env.example .env
vim .env
```
把 `GATEWAY_ADDR` 改成**员工能访问到的服务器地址**（内网 IP 或主机名）+ 端口 `10800`：
```
GATEWAY_ADDR=10.0.0.8:10800
```
这个地址会被写进 PAC，员工的系统代理据此连网关。

> ⚠ **只填 `host:port`，不要带 `http://`**（PAC 的 `PROXY` 指令只认 host:port，带 scheme 会失效）。
> 即使误加了前缀，容器也会自动剥掉（`www/15-sanitize-gateway.envsh`）。渲染结果可核对：
> `curl -s http://127.0.0.1:19000/proxy.pac | grep PROXY_STR` 应为 `PROXY 主机:10800; DIRECT`。

## 4. 启动

```bash
docker compose up -d
docker compose ps          # 两个容器 ai-proxy-gateway / ai-proxy-pac 应为 running
docker compose logs -f gateway   # 看 mihomo 日志，确认节点/规则加载无报错（Ctrl+C 退出）
```

启动后对外提供：

| 端口 | 服务 | 用途 |
|------|------|------|
| `10800` | 代理入口（http+socks5） | PAC/CLI 指向它 |
| `19000` | PAC 文件 `http://服务器:19000/proxy.pac` | 员工系统代理指向它 |
| `9090`（仅本机） | 管理 API | 验证/热重载 |

---

## 5. 验证（关键，务必执行）

在**服务器上**跑验证脚本：

```bash
./scripts/verify.sh
# 若网关地址非默认：./scripts/verify.sh http://127.0.0.1:9090 127.0.0.1:10800
```

逐项确认输出：

1. **节点池**：`airport` / `ai_airport` 节点数 > 0。
2. **各组 filter 命中**：`AI-FIXED` / `GEN-ROTATE` / `AI-STICKY` 都**非空**。
   - 若为空 → 节点名不含地区标识，filter 没匹配到。改 `nodes/ai.yaml` 节点名或 `config.yaml` 的 filter，
     然后 `./scripts/reload-nodes.sh`。
3. **终端出口是否住宅 IP**：打印出口 IP/地区/ISP，确认地区是**美国**、ISP 类型符合预期。
4. **Claude 出口是否住宅 IP**：`claude.ai/cdn-cgi/trace` 的 `ip=`/`loc=`，并反查该 IP 归属。

也可手动单查某组筛出的节点：
```bash
curl -s http://127.0.0.1:9090/proxies/AI-FIXED | jq '.all'
```

PAC 是否正常吐出：
```bash
curl -s http://127.0.0.1:19000/proxy.pac | head    # 应看到 FindProxyForURL + 你的网关地址
```

---

## 6. 员工接入（客户端零域名配置）

把下面的 `服务器` 换成 `.env` 里的 `GATEWAY_ADDR` 主机部分。

> **⚠ 两个地址别搞混（常见坑）：**
> - **PAC 文件的 URL** 要带 `http://`：`http://服务器:19000/proxy.pac` —— 这是「去哪下载 PAC 文件」。
> - **PAC 文件内部的 `PROXY host:port`** 不带 scheme：`服务器:10800` —— 这是 PAC 语法，由 `.env` 的 `GATEWAY_ADDR` 决定，带了 `http://` 会失效（容器已自动剥掉）。
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
export HTTP_PROXY=http://服务器:10800
export HTTPS_PROXY=http://服务器:10800
```

员工侧验证：浏览器打开 https://claude.ai 能正常访问即成功；或 `curl -x http://服务器:10800 https://claude.ai/cdn-cgi/trace`。

> **⚠ 如何确认系统 PAC 真的生效（尤其公司网络本来就能出海时）：**
> - `curl` **默认不走系统 PAC**，只认 `-x`/`HTTP(S)_PROXY`。所以裸 `curl ipinfo.io` 是直连，测不出网关。
>   只有浏览器等 GUI 应用才走系统 PAC。
> - **对比直连 vs 网关出口**（cloudflare trace 不限流）：
>   ```bash
>   echo "直连:"; curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|loc)='
>   echo "网关:"; curl -s -x http://服务器:10800 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|loc)='
>   ```
>   两组 `colo`/`ip` 不同即证明网关走了不同出口。
> - **浏览器验证**：打开 `https://www.cloudflare.com/cdn-cgi/trace`，其 `ip/colo` 应与上面「网关」一致。
> - **服务器铁证**：网关上 `docker compose logs -f gateway | grep -i claude`，客户端浏览器访问 claude.ai，
>   日志出现 `客户端IP --> claude.ai ... using AI-FIXED` 即生效。

---

## 7. 日常维护（员工无感）

**加/删节点**：改 `nodes/clash.yaml` 或 `nodes/ai.yaml` 后热重载：
```bash
./scripts/reload-nodes.sh
curl -s http://127.0.0.1:9090/providers/proxies/ai_airport | jq   # 看健康
```

**更新规则集**：rule-providers 每天自动更新，无需手动。手动强刷可 `docker compose restart gateway`。

**改配置**（策略/filter/端口）：改 `config.yaml` 后 `docker compose restart gateway`。

**看日志**：`docker compose logs -f gateway`

---

## 8. 常见问题

| 现象 | 排查 |
|------|------|
| 容器起不来 | `docker compose logs gateway`；多半是 `nodes/*.yaml` 缺失或 YAML 格式错 |
| 某个组节点为空 | filter 没匹配到 → 检查节点命名/正则（第 5 步第 2 项）|
| 访问 AI 失败 | 节点是否可用（verify 第 3/4 项）；claude.ai 是否走了代理 |
| 出口不是美国 | filter 正则与节点名不匹配，或 `nodes/ai.yaml` 放了非美国节点 |
| 拉不到规则集 | 服务器是否能访问 `gh-proxy.com`；内联兜底可保证核心 AI 站不受影响 |
| 国内网站也变慢 | 全局 PAC 下国内流量绕行网关由 mihomo 判 DIRECT，属预期；介意可用选择式插件 |
