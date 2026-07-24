# 开启 Windows 系统级自动代理(PAC)。遵循系统代理的 app(含多数 Electron 桌面版)会生效。
#
# 运行方式(下载的 .ps1 默认被禁止直接双击，用下面命令)：
#   powershell -ExecutionPolicy Bypass -File .\windows-proxy-on.ps1
# 分发给他人时，务必把 PacUrl 改成你的真实网关，或让对方传参：
#   .\windows-proxy-on.ps1 -PacUrl "http://9.135.113.95:19000/proxy.pac"
param(
    [string]$PacUrl = "http://gateway.corp.example.com:19000/proxy.pac"   # ← 改成你的真实网关地址
)

$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $reg -Name AutoConfigURL -Value $PacUrl

# 通知 WinINET 立即刷新，使设置无需重启即生效
try {
  $sig = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
  $w = Add-Type -MemberDefinition $sig -Name WinInet -Namespace PInvoke -PassThru
  [void]$w::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # SETTINGS_CHANGED
  [void]$w::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # REFRESH
} catch {}

Write-Host "已设置自动代理 PAC: $PacUrl"
if ($PacUrl -like "*gateway.corp.example.com*") {
  Write-Host "⚠ 你还在用占位地址！请改成真实网关，例如 -PacUrl http://9.135.113.95:19000/proxy.pac" -ForegroundColor Yellow
}
Write-Host "如个别 app 未生效，请完全重启该 app。"
