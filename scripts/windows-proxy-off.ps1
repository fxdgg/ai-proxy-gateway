# 关闭 Windows 系统级自动代理(PAC)。
# 运行: powershell -ExecutionPolicy Bypass -File .\windows-proxy-off.ps1
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Remove-ItemProperty -Path $reg -Name AutoConfigURL -ErrorAction SilentlyContinue

# 通知 WinINET 立即刷新
try {
  $sig = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
  $w = Add-Type -MemberDefinition $sig -Name WinInet -Namespace PInvoke -PassThru
  [void]$w::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
  [void]$w::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
} catch {}

Write-Host "已关闭自动代理。"
