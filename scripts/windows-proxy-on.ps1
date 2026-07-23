# 开启 Windows 系统级自动代理(PAC)。遵循系统代理的 app(含多数 Electron 桌面版)会生效。
# 用法: 右键 PowerShell 运行，或:  powershell -ExecutionPolicy Bypass -File windows-proxy-on.ps1
# 可传入自定义 PAC 地址:  .\windows-proxy-on.ps1 -PacUrl "http://你的网关:19000/proxy.pac"
param(
    [string]$PacUrl = "http://gateway.corp.example.com:19000/proxy.pac"
)

$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $reg -Name AutoConfigURL -Value $PacUrl
Write-Host "已设置自动代理 PAC: $PacUrl"
Write-Host "如个别 app 未生效，请重启该 app 或注销重登。"
