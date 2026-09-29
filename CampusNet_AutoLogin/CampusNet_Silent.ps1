#Requires -Version 5.1
<#
  CampusNet_Silent.ps1
  校园网自动登录 —— 静默版（用于开机自启 / 计划任务 / 看门狗）

  真正的登录逻辑在 CampusNet.Common.ps1 的 Invoke-CampusSilentLogin，
  本文件只是薄封装，避免与交互版重复实现。

  用法：
    CampusNet_Silent.ps1              登录一次后退出（默认等网卡最多 60s）
    CampusNet_Silent.ps1 -Watch       常驻：未联网时反复尝试
    CampusNet_Silent.ps1 -MaxAttempts 5
    CampusNet_Silent.ps1 -AdapterWaitSec 0   不等网卡，立即返回

  退出码（计划任务/看门狗按这个判断；与 README 一致）：
    0 成功/已在线　1 无配置　2 配置损坏　3 无可用网卡　4 登录失败（含“伪登录”）

  ⚠️ 维护须知（改这里之前先读）：
    · 本路径**绝对不能弹窗**：不要加 Read-Host / Pause / Start-Process，
      也不要调 Open-CampusPortalPage —— 否则开机自启会被人机界面卡住。
      失败时只写日志并返回非 0 退出码。
    · 真正的逻辑都在 Common 的 Invoke-CampusSilentLogin，本文件只做参数透传。

  退出码：
    0 登录成功 / 当前已在线
    1 没有配置文件
    2 配置无法解析（请重新运行 FirstTimeSetup.bat）
    3 没有可用网卡（已按 AdapterWaitSec 等待过）
    4 登录失败
#>
[CmdletBinding()]
param(
    [int]$MaxAttempts = 3,
    [int]$AdapterWaitSec = 60,
    [switch]$Watch
)

$ErrorActionPreference = 'Stop'

# 编码要放在最前面：trap 在 Common 加载之前就可能触发
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'CampusNet_Config.json'

# ============================================================
# 日志归档：统一放到 <脚本目录>\<LogDir>\<yyyy-MM-dd>\ 下
# （与交互版同一套目录，但文件名不同：静默版写 CampusNet_Silent.log）
#
# ⚠️ 同交互版：这段必须写在最前面、且不能依赖 CampusNet.Common.ps1，
#    因为 trap 与 Start-Transcript 都发生在 `. Common` 之前。
#    配置里的 Settings.LogDir 优先，读不到则回落到默认 'logs'。
# ============================================================
$LogDirName       = 'logs'
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

$LogDir    = Join-Path (Join-Path $ScriptDir $LogDirName) (Get-Date -Format 'yyyy-MM-dd')
$LogFile   = Join-Path $LogDir 'CampusNet_Log.txt'        # 登录记录（追加）
$LogSilent = Join-Path $LogDir 'CampusNet_Silent.log'     # 静默版完整屏幕输出（每次覆盖）
$LogFatal  = Join-Path $LogDir 'CampusNet_Fatal.log'      # 仅崩溃时生成（追加）
try { if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force } }
catch { }

# 顶层异常兜底：记录到 CampusNet_Fatal.log 并以退出码 1 结束（不静默退出）
trap {
    $err = $_
    try {
        Add-Content -LiteralPath $LogFatal -Encoding UTF8 -Value (
            "[{0}] CampusNet_Silent.ps1 FATAL`r`n  Message={1}`r`n  StackTrace:`r`n{2}`r`n" -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $err.Exception.Message, $err.ScriptStackTrace)
    }
    catch { }
    Write-Host "[CampusNet] 静默登录失败: $($err.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 完整屏幕输出落盘（与交互版分开一个文件，避免互相覆盖）
try {
    Start-Transcript -LiteralPath $LogSilent -Force | Out-Null
}
catch { }

. (Join-Path $ScriptDir 'CampusNet.Common.ps1')

# 日志归档：确保今天的目录存在，并清掉超期目录（当天绝不删、非日期目录不碰）
#   放在 `. Common` 之后是因为要用它的 Get-CampusLogDir / Get-ExpiredLogDirs；
#   函数内部已包 try/catch 且不抛异常，且只写文件不向屏幕输出——
#   **静默版绝不因日志清理而弹窗或改变退出码**。
$logInfo = Clear-ExpiredCampusLogs -ScriptDir $ScriptDir -LogDirName $LogDirName -RetentionDays $LogRetentionDays -LogFile $LogFile

# 日志目录：静默版没有交互界面，但仍打一行到标准输出
#   （Task Scheduler 下会进任务历史；手动跑时也能直接看到去哪找日志）
#   注意：只是 Write-Host 一行文字，**不是弹窗**，不影响静默语义
Write-Host "日志目录：$($logInfo.Dir)" -ForegroundColor DarkGray

$code = Invoke-CampusSilentLogin `
    -ConfigFile $ConfigFile `
    -LogFile $LogFile `
    -MaxAttempts $MaxAttempts `
    -AdapterWaitSec $AdapterWaitSec `
    -Watch:$Watch

exit $code
