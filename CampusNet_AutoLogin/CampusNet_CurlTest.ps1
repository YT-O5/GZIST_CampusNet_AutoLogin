<#
  CampusNet_CurlTest.ps1 —— 用 curl.exe 做一次“端到端”登录请求（排障用）

  它做什么：复用 CampusNet.Common.ps1 的函数拼出真实登录 URL，交给 Windows 自带的
            curl.exe 发出去，然后只打印服务器原始响应。
  为什么有用：证明这套协议不依赖 PowerShell 的 HTTP 客户端——换成 curl 也能被门户接受，
            因此也可以照搬到路由器 / Linux 上。
  安全性  ：**URL 与密码一律不打印**（URL 里带着混淆后的账号密码，等于明文），
            只输出服务器返回的 JSONP 文本。

  用法   ：离线（未认证）时双击本文件，或在脚本目录执行
              powershell -ExecutionPolicy Bypass -File .\CampusNet_CurlTest.ps1
  退出码 ：0 = 通道正常（含“本终端已在网”）　1 = 无配置　3 = 无可用网卡　4 = 门户拒绝或 curl 缺失
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 编码设置要在最前面（与其它入口脚本一致）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'CampusNet_Config.json'
$LogDir     = Join-Path $ScriptDir 'logs'
$LogFile    = Join-Path $LogDir 'CampusNet_CurlTest.log'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

. (Join-Path $ScriptDir 'CampusNet.Common.ps1')

Write-Host '=== curl 端到端登录测试 ===' -ForegroundColor Cyan
Write-Host ''

$config = Load-CampusConfig -ConfigFile $ConfigFile -LogFile $LogFile
if (-not $config) {
    Write-Host '没有可用配置：请先双击 FirstTimeSetup.bat 录入账号密码。' -ForegroundColor Red
    exit 1
}

$adapter = Get-CampusAdapter -Settings $config.Settings -LogFile $LogFile
if (-not $adapter) {
    Write-Host '没有可用网卡：请先插好网线 / 连上校园 WiFi。' -ForegroundColor Red
    exit 3
}

$endpoint = Get-LoginEndpoint -Adapter $adapter -Settings $config.Settings -LogFile $LogFile
Write-Host ("使用 IP={0}  MAC={1}" -f $endpoint.IP, $endpoint.MAC) -ForegroundColor DarkGray

$pageInfo = Get-DrappallPageIndex -PortalHost ([string]$config.Settings.PortalHost) -Port ([int]$config.Settings.PortalPort) `
    -IP $endpoint.IP -AcIp ([string]$config.Settings.WlanAcIp) -LogFile $LogFile
Write-Host ("loadConfig: Ok={0}  program_index={1}  page_index={2}" -f $pageInfo.Ok, $pageInfo.ProgramIndex, $pageInfo.PageIndex) -ForegroundColor DarkGray
Write-Host ''

$url = New-DrappallLoginUrl -PortalHost ([string]$config.Settings.PortalHost) -Port ([int]$config.Settings.PortalPort) `
    -Account $config.Account -Password $config.Password -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings `
    -ProgramIndex $pageInfo.ProgramIndex -PageIndex $pageInfo.PageIndex

$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlCmd) {
    Write-Host '找不到 curl.exe：Windows 10 1803 及以上自带，请确认系统版本。' -ForegroundColor Yellow
    exit 4
}

Write-Host '正在用 curl.exe 发送登录请求（URL 不打印，密码不会上屏）...' -ForegroundColor Cyan
$raw = & $curlCmd.Source -s -m 20 $url 2>&1 | Out-String
$text = $raw.Trim()

Write-Host '--- 服务器原始响应 ---' -ForegroundColor DarkGray
Write-Host $text
Write-Host '----------------------' -ForegroundColor DarkGray
Write-Host ''

if ($text -match '"result"\s*:\s*1') {
    Write-Host 'curl 端到端：成功（result:1）——curl 通道能完成认证。' -ForegroundColor Green
    exit 0
}
if ($text -match '"ret_code"\s*:\s*2') {
    Write-Host 'curl 端到端：通道正常，但本终端已在网（ret_code:2 / AC999）。' -ForegroundColor Yellow
    Write-Host '想验证“真能登进去”，请在未认证（掉线）状态下再跑一次本脚本。' -ForegroundColor Yellow
    exit 0
}
Write-Host 'curl 端到端：门户拒绝了请求，请把上面的原始响应发我。' -ForegroundColor Red
exit 4
