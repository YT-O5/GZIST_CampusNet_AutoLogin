#Requires -Version 5.1
<#
  CampusNet_Login.ps1
  广州理工学院校园网自动登录 —— 交互式入口（设置向导 / 主菜单 / 诊断）

  用法：
    CampusNet_Login.ps1              打开主菜单（默认）
    CampusNet_Login.ps1 -Setup       只运行首次设置向导
    CampusNet_Login.ps1 -Silent      静默登录（等价于 CampusNet_Silent.ps1）
    CampusNet_Login.ps1 -Diagnose    打印网络诊断信息
    CampusNet_Login.ps1 -TestLogin   打印（已脱敏的）登录 URL 与门户原始响应，排障用
    CampusNet_Login.ps1 -Repair      免重启网络修复（DHCP release/renew）
    CampusNet_Login.ps1 -FlushDns    只清 DNS 客户端缓存（独立功能，不需管理员）

  公共逻辑全部在 CampusNet.Common.ps1 中，本文件只负责交互。
  想看函数级说明与整体数据流，请先读 CampusNet.Common.ps1 的文件头索引。

  ── 本文件函数索引 ─────────────────────────────────────────
    Show-Header              屏幕标题
    Wait-ForKeyPress         统一的“按任意键继续”（注意：本函数只有 -Message 参数，没有 -NoPause 开关；
                             非交互/管道环境下 ReadKey 会失败并被 catch 吞掉，所以能直接跑过去）
    Read-PlainPassword       读明文密码（不回显，两次输入校验）
    Write-AdapterInfo        打印当前网卡信息
    Show-SetupWizard         首次设置向导：账号/密码/测试/保存 → 返回是否成功（供 -Setup 决定退出码）
    Show-RecentLog           显示最近日志
    Show-Diagnostics         网络体检：网卡表 / 门户探测 / 最终接口形态
    Invoke-PortalFallbackIfNeeded
                             登录失败后的兜底提示与开浏览器（策略来自 Common 的
                             Get-CampusFailureAction：凭证/在线类不开，协议/网络类才开）
    Invoke-TestLogin         -TestLogin：打印脱敏登录 URL 与门户原始响应
    Invoke-CampusRepairMenu  菜单 6：网络修复（调 Invoke-CampusNetworkRepair）
    Invoke-CampusDnsFlushMenu 菜单 7：清 DNS 缓存（调 Clear-CampusDnsCache）
    Show-MainMenu            主菜单主循环（1-8）

  ── 参数路由（文件末尾的 if/elseif 链）──────────────────────
    -Setup→向导  -Silent→静默  -Diagnose→诊断  -TestLogin→测试登录
    -Repair→修复  -FlushDns→清 DNS  都不传 → Show-MainMenu

  ── 退出码（与 README / NOTICE 一致，改这里要同步改文档）────
    0 成功/已在线　1 无配置　2 配置损坏　3 无可用网卡
    4 登录失败（含“伪登录”）　5 网络修复未成功　6 DNS 清理未成功
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Silent,
    [switch]$Diagnose,
    [switch]$TestLogin,
    [switch]$Repair,
    [switch]$FlushDns
)

$ErrorActionPreference = 'Stop'

# 编码要放在最前面：trap 在 Common 加载之前就可能触发
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'CampusNet_Config.json'

# ============================================================
# 日志归档：统一放到 <脚本目录>\<LogDir>\<yyyy-MM-dd>\ 下
#   （每天一个目录、最多 4 个文件；旧版那种"散落一堆 log"的写法已废弃）
#
# ⚠️ 这段必须写在最前面、且**不能依赖 CampusNet.Common.ps1**：
#    trap 与 Start-Transcript 都发生在 `. Common` 之前（Common 自己也可能加载失败），
#    所以这里用最朴素的方式自己算一遍日志路径。
#    配置里的 Settings.LogDir 优先；首次运行或配置损坏时回落到默认 'logs'。
# ============================================================
$LogDirName      = 'logs'
$LogRetentionDays = 30
try {
    if (Test-Path -LiteralPath $ConfigFile) {
        $rawCfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rawCfg.Settings) {
            # ⚠️ 不能用 `if ($rawCfg.Settings.X)` 判存在：PowerShell 里数字 0 是 falsy，
            #    而 LogRetentionDays=0 正是文档写明的“永不清理”，那样会被当成“没配”而回落成 30。
            if ($null -ne $rawCfg.Settings.LogDir -and "$($rawCfg.Settings.LogDir)" -ne '') {
                $LogDirName = [string]$rawCfg.Settings.LogDir
            }
            if ($null -ne $rawCfg.Settings.LogRetentionDays -and "$($rawCfg.Settings.LogRetentionDays)" -ne '') {
                $LogRetentionDays = [int]$rawCfg.Settings.LogRetentionDays
            }
        }
    }
}
catch { }
if ([string]::IsNullOrWhiteSpace($LogDirName)) { $LogDirName = 'logs' }

$LogDir      = Join-Path (Join-Path $ScriptDir $LogDirName) (Get-Date -Format 'yyyy-MM-dd')
$LogFile     = Join-Path $LogDir 'CampusNet_Log.txt'          # 登录记录（追加）
$LogLauncher = Join-Path $LogDir 'CampusNet_Launcher.log'     # 交互版完整屏幕输出（每次覆盖）
$LogFatal    = Join-Path $LogDir 'CampusNet_Fatal.log'        # 仅崩溃时生成（追加）
try { if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force } }
catch { }

# ============================================================
# 顶层异常兜底：任何未捕获错误都把详细信息打到控制台
# （启动器会 tee 进 CampusNet_Launcher.log），并另存一份 CampusNet_Fatal.log，
# 然后以退出码 1 结束——绝不静默退出。
# ============================================================
trap {
    $err = $_
    Write-Host ''
    Write-Host '=============== 启动 / 运行失败 ===============' -ForegroundColor Red
    Write-Host "时间      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)   Host: $($Host.Name)"
    Write-Host "脚本目录  : $ScriptDir"
    Write-Host "错误信息  : $($err.Exception.Message)" -ForegroundColor Red
    Write-Host "错误类别  : $($err.CategoryInfo.Category)"
    Write-Host '调用堆栈  :'
    Write-Host ([string]$err.ScriptStackTrace)
    Write-Host '==============================================' -ForegroundColor Red
    try {
        $fatal = $LogFatal
        Add-Content -LiteralPath $fatal -Encoding UTF8 -Value (
            "[{0}] CampusNet_Login.ps1 FATAL`r`n  PS={1} Host={2}`r`n  Message={3}`r`n  StackTrace:`r`n{4}`r`n" -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PSVersionTable.PSVersion, $Host.Name,
            $err.Exception.Message, $err.ScriptStackTrace)
    }
    catch { }
    exit 1
}

# ============================================================
# 完整屏幕输出落盘：用 Start-Transcript，而不是启动器里的 Tee 管道。
#   原因：`& script *>&1 | Tee-Object -File ...` 会把任何非零的 exit N
#   压成 1，退出码就失真了（实测：exit 7 → 1）。
#   脚本自己开 transcript 既记全了屏幕，启动器又能拿到真实退出码。
# ============================================================
try {
    Start-Transcript -LiteralPath $LogLauncher -Force | Out-Null
}
catch { }

. (Join-Path $ScriptDir 'CampusNet.Common.ps1')

# 日志归档：确保今天的目录存在，并清掉超期目录（当天绝不删、非日期目录不碰）
#   放在 `. Common` 之后是因为要用它的 Get-CampusLogDir / Get-ExpiredLogDirs；
#   函数内部已包 try/catch 且不抛异常，清理历史日志绝不会影响登录。
$logInfo = Clear-ExpiredCampusLogs -ScriptDir $ScriptDir -LogDirName $LogDirName -RetentionDays $LogRetentionDays -LogFile $LogFile

# 启动标记（会随启动器日志落盘，用来确认脚本到底有没有跑起来）
Write-Host "[CampusNet] 启动 v$(Get-CampusNetVersion)  PS=$($PSVersionTable.PSVersion)  Host=$($Host.Name)  Dir=$ScriptDir" -ForegroundColor DarkGray
# 日志目录：直接打出来，用户不必去翻文件夹就知道去哪找日志
Write-Host "           日志目录：$($logInfo.Dir)" -ForegroundColor DarkGray
if ($logInfo.Removed -gt 0) {
    Write-Host "           已自动清理 $($logInfo.Removed) 个超期日志目录（保留最近 $LogRetentionDays 天）" -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# 交互辅助
# ------------------------------------------------------------
function Show-Header {
    param([switch]$NoClear)
    if (-not $NoClear) { try { Clear-Host } catch { } }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '          广州理工学院 校园网自动登录系统' -ForegroundColor Green
    Write-Host "                       v$(Get-CampusNetVersion)" -ForegroundColor DarkGray
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Wait-ForKeyPress {
    param([string]$Message = '按任意键继续...')
    Write-Host ''
    Write-Host $Message -ForegroundColor Gray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
}

function Read-PlainPassword {
    param([string]$Prompt = '请输入您的校园网密码')
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Write-AdapterInfo {
    param($Adapter)
    Write-Host "适配器 : $($Adapter.Name)  [$($Adapter.Type)]" -ForegroundColor Cyan
    Write-Host "IP 地址: $($Adapter.IP)" -ForegroundColor Cyan
    Write-Host "MAC地址: $($Adapter.MAC)" -ForegroundColor Cyan
    if ($Adapter.Type -eq 'WiFi') { Write-Host "Wi-Fi  : $($Adapter.SSID)" -ForegroundColor Cyan }
}

# ------------------------------------------------------------
# 首次设置向导
# ------------------------------------------------------------
function Show-SetupWizard {
    Show-Header
    Write-Host '=== 首次使用设置向导 ===' -ForegroundColor Yellow
    Write-Host ''

    $account = ''
    while ([string]::IsNullOrWhiteSpace($account)) {
        $account = (Read-Host '请输入您的学号').Trim()
        if ([string]::IsNullOrWhiteSpace($account)) { Write-Host '学号不能为空！' -ForegroundColor Red }
    }

    $password = Read-PlainPassword -Prompt '请输入您的校园网密码'
    while ([string]::IsNullOrEmpty($password)) {
        Write-Host '密码不能为空！' -ForegroundColor Red
        $password = Read-PlainPassword -Prompt '请输入您的校园网密码'
    }

    $settings = Get-DefaultSettings
    Write-Host ''
    Write-Host "服务器地址（直接回车使用默认值 $($settings.BaseURL)）" -ForegroundColor Cyan
    $base = (Read-Host '服务器地址').Trim()
    if (-not [string]::IsNullOrWhiteSpace($base)) { $settings.BaseURL = $base }

    Write-Host ''
    Write-Host '正在检测网络适配器...' -ForegroundColor Cyan
    $adapter = Get-CampusAdapter -LogFile $LogFile
    if ($adapter) {
        Write-AdapterInfo -Adapter $adapter
    }
    else {
        Write-Host '警告：暂时未检测到可用网络适配器，配置仍会保存。' -ForegroundColor Yellow
        Write-Host '请先插网线或连接校园 Wi-Fi，再运行 CampusNet.bat 登录。' -ForegroundColor Yellow
    }

    Write-Host ''
    $saved = Save-CampusConfig -ConfigFile $ConfigFile -Account $account -Password $password -Settings $settings -LogFile $LogFile
    if ($saved) {
        Write-Host '=== 配置已保存 ===' -ForegroundColor Green
        Write-Host '密码已用 Windows DPAPI 加密保存（仅本机、本 Windows 用户可解密）。' -ForegroundColor Green
        Write-Host '换电脑或换 Windows 账号后需要重新运行本向导。' -ForegroundColor Gray
        Write-Host ''
        Write-Host '注意：本向导只保存、不校验账号密码是否正确。' -ForegroundColor Yellow
        Write-Host '若当前已经能上网，脚本不会把凭据发给门户，所以即使密码写错也看不出异常；' -ForegroundColor Yellow
        Write-Host '要等哪天真掉线了才会报"密码错误"。想提前确认，请在没网的时候双击' -ForegroundColor Yellow
        Write-Host 'CampusNet.bat 选 5（登录联调），看服务器原始响应里的结果。' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '现在可以双击 CampusNet.bat 自动登录了。' -ForegroundColor Green
    }
    else {
        Write-Host '配置保存失败！' -ForegroundColor Red
    }
    Wait-ForKeyPress
    return [bool]$saved
}

# ------------------------------------------------------------
# 一次性登录（检测网卡 → 发请求）
# ------------------------------------------------------------
function Show-RecentLog {
    if (Test-Path -LiteralPath $LogFile) {
        Write-Host '=== 最近日志（最后 20 行）===' -ForegroundColor Cyan
        Get-Content -LiteralPath $LogFile -Tail 20
    }
    else {
        Write-Host '暂无日志。' -ForegroundColor Yellow
    }
    Wait-ForKeyPress
}

# ------------------------------------------------------------
# 网络诊断
# ------------------------------------------------------------
function Show-Diagnostics {
    Show-Header
    Write-Host '=== 网络诊断 ===' -ForegroundColor Cyan

    # 全量网卡体检：把“被排除的网卡 + 原因”也打出来（插网线没反应时最关键）
    $report = @(Get-CampusAdapterReport)
    Write-Host ("物理网卡数量: {0}（✔=可用，✘=不可用并附原因）" -f $report.Count)
    foreach ($r in $report) {
        $shown = if ($r.IP) { $r.IP } else { '(无 IP)' }
        $ssidPart = if ($r.SSID) { "  SSID=$($r.SSID)" } else { '' }
        $mark = if ($r.Usable) { 'OK' } else { '!!' }
        $color = if ($r.Usable) { 'Gray' } else { 'DarkYellow' }
        Write-Host ("  [{0}] {1,-18} [{2}] 状态={3} IP={4}{5} 网关={6}" -f $mark, $r.Name, $r.Type, $r.Status, $shown, $ssidPart, $r.HasGateway) -ForegroundColor $color
        if (-not $r.Usable) { Write-Host ("        → {0}" -f $r.Reason) -ForegroundColor DarkYellow }
    }

    $sel = Get-CampusAdapter -LogFile $LogFile
    if ($sel) {
        Write-Host ''
        Write-Host '选中网卡（优先有网关、有线优先）：' -ForegroundColor Green
        Write-AdapterInfo -Adapter $sel
    }
    else {
        Write-Host '没有选出可用网卡。' -ForegroundColor Red
    }

    $online = Test-CampusInternet
    $color = if ($online) { 'Green' } else { 'Yellow' }
    Write-Host ''
    Write-Host ("互联网连通: {0}" -f $online) -ForegroundColor $color
    Write-Host ("配置文件  : {0} ({1})" -f $ConfigFile, $(if (Test-Path -LiteralPath $ConfigFile) { '存在' } else { '不存在' }))
    Write-Host ("日志文件  : {0}" -f $LogFile)

    Write-Host ''
    Write-Host '正在探测校园网门户（HTTP 探针，已避开门户黑名单）...' -ForegroundColor Cyan
    Write-Host ('探针候选: ' + ((Get-PortalProbeUrls) -join ', ')) -ForegroundColor DarkGray
    $disc = Resolve-CampusPortal -Settings (Get-DefaultSettings) -TimeoutSec 6 -LogFile $LogFile
    if ($disc.Raw) {
        Write-Host ('探针原始返回: ' + (Get-TextPreview -Text $disc.Raw -Max 200)) -ForegroundColor DarkGray
    }
    $diagSettings = if ($disc.Probed) { $disc.Settings } else { Get-DefaultSettings }
    if ($disc.Probed) {
        Write-Host ("门户 Host      : {0}:{1}" -f $diagSettings.PortalHost, $diagSettings.PortalPort) -ForegroundColor Green
        Write-Host ("门户看到的 IP  : {0}" -f $disc.UserIp) -ForegroundColor Green
        Write-Host ("门户看到的 MAC : {0}" -f $disc.UserMac) -ForegroundColor Green
        Write-Host ("WlanAcIp       : {0}   WlanAcName: {1}" -f $diagSettings.WlanAcIp, $diagSettings.WlanAcName) -ForegroundColor Green
    }
    else {
        Write-Host '未探测到门户跳转（已联网时属正常）' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '接口形态:' -ForegroundColor Cyan
    Write-Host ("  主路径 : GET http://{0}:{1}/eportal/portal/login  (哆点 v4)" -f $diagSettings.PortalHost, $diagSettings.PortalPort)
    Write-Host ("  回退   : GET {0}?c=Portal&a=login" -f $diagSettings.BaseURL)
    if ($sel) {
        $pi = Get-DrappallPageIndex -PortalHost ([string]$diagSettings.PortalHost) -Port ([int]$diagSettings.PortalPort) `
            -IP $sel.IP -AcIp ([string]$diagSettings.WlanAcIp) -TimeoutSec 6 -LogFile $LogFile
        $piColor = if ($pi.Ok) { 'Green' } else { 'Yellow' }
        Write-Host ("  loadConfig: Ok={0}  program_index={1}  page_index={2}  page_name={3}" -f $pi.Ok, $pi.ProgramIndex, $pi.PageIndex, $pi.PageName) -ForegroundColor $piColor
    }
    Wait-ForKeyPress
}

# ------------------------------------------------------------
# 登录联调：打印 URL、服务器原始响应与真实联网校验
#   专治“伪登录”——一眼看出接口到底回了什么、是否真的联网。
# ------------------------------------------------------------
# ------------------------------------------------------------
# 登录没成时：在交互模式里把门户页用浏览器打开，方便手动完成登录
#   （静默模式不调用这里，保证计划任务不会弹窗）
# ------------------------------------------------------------
function Invoke-PortalFallbackIfNeeded {
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$UserIp,
        [string]$UserMac,
        [string]$Reason,
        [int]$ErrorCode = -1,
        [string]$LogFile
    )

    $enabled = Test-CampusSettingEnabled -Settings $Settings -Key 'OpenPortalOnFailure' -Default $true
    $action = Get-CampusFailureAction -ErrorCode $ErrorCode -Message $Reason -OpenPortalOnFailure $enabled

    Write-Host ''
    Write-Host "登录未成功（$Reason）。" -ForegroundColor Yellow

    switch ($action) {
        'credentials' {
            Write-Host '这是账号/密码类错误，打开浏览器也帮不上忙，所以这次不弹浏览器。' -ForegroundColor Yellow
            Write-Host '建议：① 重跑 FirstTimeSetup.bat 重新保存密码；' -ForegroundColor Cyan
            Write-Host '      ② 或去自助服务确认密码/账号状态：http://10.0.8.81:8080/Self/login/?302=LI' -ForegroundColor Cyan
        }
        'online' {
            Write-Host '这个账号已经在线上（可能还占着别的设备/会话）。' -ForegroundColor Yellow
            Write-Host '建议：去自助服务把其他设备下线后重试：http://10.0.8.81:8080/Self/login/?302=LI' -ForegroundColor Cyan
        }
        'browser' {
            $url = Get-CampusPortalPageUrl -Settings $Settings -UserIp $UserIp -UserMac $UserMac
            Write-Host "门户地址: $url" -ForegroundColor Cyan
            Write-Host '正在用默认浏览器打开门户页面，你可以在里面手动点一下登录（页面上的按钮或回车即可）。' -ForegroundColor Yellow
            Open-CampusPortalPage -Settings $Settings -UserIp $UserIp -UserMac $UserMac -LogFile $LogFile | Out-Null
        }
        default {
            Write-Host '（已关闭 OpenPortalOnFailure，不自动打开浏览器）' -ForegroundColor DarkGray
        }
    }
}

function Invoke-TestLogin {
    Show-Header
    Write-Host '=== 登录联调（原始响应）===' -ForegroundColor Cyan
    Write-Host ''

    $config = Load-CampusConfig -ConfigFile $ConfigFile -LogFile $LogFile
    if (-not $config) {
        Write-Host '没有可用配置，请先运行 -Setup 或菜单 3。' -ForegroundColor Red
        Wait-ForKeyPress
        return
    }

    $adapter = Get-CampusAdapter -Settings $config.Settings -LogFile $LogFile
    if (-not $adapter) {
        Write-Host '未找到可用网卡（请先插网线 / 连 Wi-Fi）。' -ForegroundColor Red
        Wait-ForKeyPress
        return
    }
    Write-AdapterInfo -Adapter $adapter
    Write-Host ''

    Write-Host '尝试自动发现校园网门户（HTTP 探针，已避开黑名单）...' -ForegroundColor Cyan
    $endpoint = Get-LoginEndpoint -Adapter $adapter -Settings $config.Settings -LogFile $LogFile
    $disc = $endpoint.Discovered
    if ($disc.Raw) {
        Write-Host ('探针返回预览: ' + (Get-TextPreview -Text $disc.Raw -Max 200)) -ForegroundColor DarkGray
    }
    if ($disc.Probed) {
        Write-Host ("门户: {0}:{1}   登录使用 IP={2}  MAC={3}" -f $config.Settings.PortalHost, $config.Settings.PortalPort, $endpoint.IP, $endpoint.MAC) -ForegroundColor Green
    }
    else {
        Write-Host '未探测到门户跳转（已联网时属正常，仍用配置里的参数）' -ForegroundColor DarkGray
        Write-Host ("登录使用 IP={0}  MAC={1}" -f $endpoint.IP, $endpoint.MAC) -ForegroundColor DarkGray
    }
    Write-Host ''

    $pageInfo = Get-DrappallPageIndex -PortalHost ([string]$config.Settings.PortalHost) -Port ([int]$config.Settings.PortalPort) `
        -IP $endpoint.IP -AcIp ([string]$config.Settings.WlanAcIp) -LogFile $LogFile
    $piColor = if ($pageInfo.Ok) { 'Green' } else { 'Yellow' }
    Write-Host ("loadConfig: Ok={0}  program_index={1}  page_index={2}  page_name={3}" -f $pageInfo.Ok, $pageInfo.ProgramIndex, $pageInfo.PageIndex, $pageInfo.PageName) -ForegroundColor $piColor
    Write-Host ''

    $url = New-DrappallLoginUrl -PortalHost ([string]$config.Settings.PortalHost) -Port ([int]$config.Settings.PortalPort) `
        -Account $config.Account -Password $config.Password -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings `
        -ProgramIndex $pageInfo.ProgramIndex -PageIndex $pageInfo.PageIndex
    Write-Host '登录 URL（哆点 v4，密码已脱敏）:' -ForegroundColor DarkGray
    Write-Host (Get-MaskedUrl -Url $url) -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '发送登录请求（策略链：哆点 v4 → 旧 801，不重试）...' -ForegroundColor Cyan
    $res = Send-CampusLoginRequest -Account $config.Account -Password $config.Password `
        -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings `
        -MaxAttempts 1 -TimeoutSec 10 -LogFile $LogFile

    Write-Host ''
    Write-Host '--- 服务器原始响应 ---' -ForegroundColor Cyan
    $rawText = [string]$res.Raw
    if ([string]::IsNullOrWhiteSpace($rawText)) { $rawText = '(响应体为空) 预览: ' + $res.Preview }
    Write-Host $rawText
    Write-Host '-----------------------' -ForegroundColor Cyan
    Write-Host ("解析: Success={0}  Recognized={1}  ErrorCode={2}  Message={3}" -f $res.Success, $res.Recognized, $res.ErrorCode, $res.Message)

    Write-Host ''
    Write-Host '真实联网校验（HTTPS + 内容匹配，portal 劫持不算通过）...' -ForegroundColor Cyan
    $online = Wait-CampusInternet -TimeoutSec 12
    Write-Host ("实际可上网: {0}" -f $online) -ForegroundColor $(if ($online) { 'Green' } else { 'Red' })
    if ($res.Success -and -not $online) {
        Write-Host '这就是“伪登录”：接口返回成功，但并未真正联网。' -ForegroundColor Yellow
    }
    Wait-ForKeyPress
}

# ------------------------------------------------------------
# 主菜单（循环，不再递归）
# ------------------------------------------------------------
# ------------------------------------------------------------
# 菜单 6：网络修复（免重启）
# ------------------------------------------------------------
function Invoke-CampusRepairMenu {
    param([System.Collections.IDictionary]$Settings)

    Write-Host '=== 网络修复（免重启）===' -ForegroundColor Yellow
    Write-Host '顺序：重拿 DHCP 租约 → 仍不行则重启网卡（需要管理员）' -ForegroundColor DarkGray
    Write-Host '（DNS 缓存清理是独立功能，在菜单 7；需要“修复时顺便清”可把配置里 FlushDnsOnRepair 设为 1）' -ForegroundColor DarkGray
    Write-Host ''
    $ok = Invoke-CampusNetworkRepair -Settings $Settings -LogFile $LogFile
    Write-Host ''
    if ($ok) { Write-Host '✔ 已至少恢复一张网卡，可以回菜单选 1 再试。' -ForegroundColor Green }
    else { Write-Host '✘ 仍未恢复。请看上面的“网卡体检”与日志（菜单 4）；若提示需要管理员权限，请右键 CampusNet.bat → 以管理员身份运行。' -ForegroundColor Red }
    Wait-ForKeyPress
}

# ------------------------------------------------------------
# 菜单 7：清理 DNS 缓存（独立功能）
# ------------------------------------------------------------
function Invoke-CampusDnsFlushMenu {
    Write-Host '=== 清理 DNS 缓存 ===' -ForegroundColor Yellow
    Write-Host '只清本机 DNS 客户端缓存：不改网卡、不碰登录配置。' -ForegroundColor DarkGray
    Write-Host ''
    $r = Clear-CampusDnsCache -LogFile $LogFile
    Write-Host ''
    if ($r.Ok) {
        if ($r.Before -ge 1 -or $r.After -ge 1) {
            Write-Host ("✔ DNS 缓存已清理（清理前 {0} 条 → 清理后 {1} 条）" -f $r.Before, $r.After) -ForegroundColor Green
        }
        else {
            Write-Host '✔ DNS 缓存清理指令已执行。' -ForegroundColor Green
            Write-Host '  （本机 Get-DnsClientCache 读不到缓存条数，因此不显示前后统计；清理本身已成功执行）' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host ("✘ " + $r.Reason) -ForegroundColor Red
    }
    Wait-ForKeyPress
}

function Show-MainMenu {
    $exitMenu = $false
    $emptyStreak = 0

    # 只在进入菜单时清屏一次；循环内不再清屏，避免整屏反复闪烁
    Show-Header

    while (-not $exitMenu) {
        Write-Host ''
        Write-Host ('-' * 60) -ForegroundColor DarkGray

        $config = Load-CampusConfig -ConfigFile $ConfigFile -LogFile $LogFile
        if (-not $config) {
            Write-Host '未找到可用配置，进入设置向导...' -ForegroundColor Yellow
            Write-Host ''
            # 向导会返回保存结果，这里用不到，显式丢掉以免被当成输出打印
            $null = Show-SetupWizard
            continue
        }

        Write-Host "当前账号: $($config.Account)" -ForegroundColor Green
        Write-Host "服务器  : $($config.Settings.BaseURL)" -ForegroundColor DarkGray
        Write-Host ''

        $adapter = Get-CampusAdapter -Settings $config.Settings -LogFile $LogFile
        if (-not $adapter) {
            Write-Host '未检测到可用网络连接（请插网线或连接校园 Wi-Fi 后重试）。' -ForegroundColor Red
        }
        else {
            Write-Host '=== 网络信息 ===' -ForegroundColor Cyan
            Write-AdapterInfo -Adapter $adapter
            Write-Host ''

            Write-Host '=== 自动登录 ===' -ForegroundColor Yellow
            if (Test-CampusInternet) {
                Write-Host '当前已联网，无需登录。' -ForegroundColor Green
            }
            else {
                Write-Host '未联网，正在探测校园网门户并登录...' -ForegroundColor Yellow
                $endpoint = Get-LoginEndpoint -Adapter $adapter -Settings $config.Settings -LogFile $LogFile
                if ($endpoint.Discovered.Changed) {
                    Save-CampusConfig -ConfigFile $ConfigFile -Account $config.Account -Password $config.Password -Settings $config.Settings -LogFile $LogFile | Out-Null
                }
                $res = Send-CampusLoginRequest -Account $config.Account -Password $config.Password `
                    -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings `
                    -MaxAttempts 3 -LogFile $LogFile
                if ($res.Success) {
                    Write-Host '登录接口返回成功，正在确认真实联网...' -ForegroundColor Cyan
                    if (Wait-CampusInternet -TimeoutSec 15) {
                        Write-Host '✔ 已确认可以上网，登录成功。' -ForegroundColor Green
                    }
                    else {
                        Write-Host '✘ 服务器说成功，但实际仍上不了网（伪登录）。请看菜单 4 日志或运行 -TestLogin 看原始响应。' -ForegroundColor Red
                        Invoke-PortalFallbackIfNeeded -Settings $config.Settings -UserIp $endpoint.IP -UserMac $endpoint.MAC -Reason '伪登录：接口说成功但无法上网' -LogFile $LogFile
                    }
                }
                else {
                    Write-Host "登录失败：$(Get-PortalErrorText -Code $res.ErrorCode -Message $res.Message)" -ForegroundColor Red
                    Invoke-PortalFallbackIfNeeded -Settings $config.Settings -UserIp $endpoint.IP -UserMac $endpoint.MAC -Reason $res.Message -ErrorCode $res.ErrorCode -LogFile $LogFile
                }
            }
        }

        Write-Host ''
        Write-Host '=== 主菜单 ===' -ForegroundColor Cyan
        Write-Host '1. 重新测试网络连接'
        Write-Host '2. 手动登录尝试'
        Write-Host '3. 修改账号 / 服务器设置'
        Write-Host '4. 查看最近日志'
        Write-Host '5. 登录联调（打印服务器原始响应）'
        Write-Host '6. 网络修复（免重启：重拿 DHCP / 必要时重启网卡）'
        Write-Host '7. 清理 DNS 缓存'
        Write-Host '8. 退出'
        Write-Host ''
        $choice = Read-Host '请输入您的选择 (1-8)'
        if ($null -ne $choice) { $choice = $choice.Trim() }

        if ([string]::IsNullOrEmpty($choice)) {
            $emptyStreak++
            Write-Host '没有收到输入，请输入 1-8（或按 Ctrl+C 退出）。' -ForegroundColor Yellow
            if ($emptyStreak -ge 3) {
                Write-Host '连续 3 次没有输入，已退出。若在无控制台环境运行，请改用 CampusNet_Silent.ps1。' -ForegroundColor Yellow
                $exitMenu = $true
            }
            else { Start-Sleep -Milliseconds 300 }
            continue
        }
        $emptyStreak = 0

        switch ($choice) {
            '1' {
                if (Test-CampusInternet) { Write-Host '网络连接正常！' -ForegroundColor Green }
                else { Write-Host '未检测到互联网连接。' -ForegroundColor Red }
                Wait-ForKeyPress
            }
            '2' {
                if (-not $adapter) { Write-Host '没有可用网卡，无法登录。' -ForegroundColor Red; Wait-ForKeyPress; continue }
                $endpoint = Get-LoginEndpoint -Adapter $adapter -Settings $config.Settings -LogFile $LogFile
                $res = Send-CampusLoginRequest -Account $config.Account -Password $config.Password `
                    -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings -MaxAttempts 3 -LogFile $LogFile
                if ($res.Success) {
                    Write-Host '登录接口返回成功，正在确认真实联网...' -ForegroundColor Cyan
                    if (Wait-CampusInternet -TimeoutSec 15) { Write-Host '✔ 已确认可以上网。' -ForegroundColor Green }
                    else {
                        Write-Host '✘ 仍是伪登录：接口成功但无法上网。' -ForegroundColor Red
                        Invoke-PortalFallbackIfNeeded -Settings $config.Settings -UserIp $endpoint.IP -UserMac $endpoint.MAC -Reason '伪登录：接口说成功但无法上网' -LogFile $LogFile
                    }
                }
                else {
                    Write-Host "手动登录失败：$(Get-PortalErrorText -Code $res.ErrorCode -Message $res.Message)" -ForegroundColor Red
                    Invoke-PortalFallbackIfNeeded -Settings $config.Settings -UserIp $endpoint.IP -UserMac $endpoint.MAC -Reason $res.Message -ErrorCode $res.ErrorCode -LogFile $LogFile
                }
                Wait-ForKeyPress
            }
            '3' { $null = Show-SetupWizard }
            '4' { Show-RecentLog }
            '5' { Invoke-TestLogin }
            '6' { Invoke-CampusRepairMenu -Settings $config.Settings }
            '7' { Invoke-CampusDnsFlushMenu }
            '8' { $exitMenu = $true }
            default {
                Write-Host '无效选择！' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }

    Write-Host '再见！' -ForegroundColor Green
    Start-Sleep -Seconds 1
}

# ------------------------------------------------------------
# 入口分发
# ------------------------------------------------------------
if ($Setup) {
    if (Show-SetupWizard) { exit 0 } else { exit 1 }
}
elseif ($Silent) {
    exit (Invoke-CampusSilentLogin -ConfigFile $ConfigFile -LogFile $LogFile)
}
elseif ($Diagnose) {
    Show-Diagnostics
    exit 0
}
elseif ($TestLogin) {
    Invoke-TestLogin
    exit 0
}
elseif ($Repair) {
    $repairSettings = Get-DefaultSettings
    try {
        $rc = Load-CampusConfig -ConfigFile $ConfigFile -LogFile $null
        if ($rc -and $rc.Settings) { $repairSettings = $rc.Settings }
    }
    catch { }
    if (Invoke-CampusNetworkRepair -Settings $repairSettings -LogFile $LogFile) { exit 0 } else { exit 5 }
}
elseif ($FlushDns) {
    if ((Clear-CampusDnsCache -LogFile $LogFile).Ok) { exit 0 } else { exit 6 }
}
else {
    Show-MainMenu
    exit 0
}
