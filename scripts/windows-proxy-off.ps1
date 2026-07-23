# 关闭 Windows 系统级自动代理(PAC)。
# 用法: powershell -ExecutionPolicy Bypass -File windows-proxy-off.ps1
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Remove-ItemProperty -Path $reg -Name AutoConfigURL -ErrorAction SilentlyContinue
Write-Host "已关闭自动代理。"
