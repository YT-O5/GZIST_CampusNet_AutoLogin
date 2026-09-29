# ============================================================
#  CampusNet.Common.ps1
#  广州理工学院校园网自动登录 —— 公共模块
#  由 CampusNet_Login.ps1 / CampusNet_Silent.ps1 通过
#      . (Join-Path $ScriptDir 'CampusNet.Common.ps1')
#  加载，避免登录逻辑在多处重复实现。
#  兼容 Windows PowerShell 5.1 与 PowerShell 7+。
#
#  ─── 整体数据流（读代码请按这个顺序）──────────────────────
#    Load-CampusConfig ──► 拿到 $Account/$Password/$Settings（密码是 DPAPI 密文，这里解成明文）
#            │
#            ▼
#    Get-CampusAdapter ──► 选一张能上网的网卡（内部用 Get-CampusAdapterReport 做体检）
#            │
#            ▼
#    Wait-CampusInternet ─► 已经能上网就直接收工（返回 0），否则：
#            │
#            ▼
#    Get-LoginEndpoint ──► 自动发现门户参数 + 决定登录用哪个 IP/MAC
#            │                 （Resolve-CampusPortal → Get-CampusPortalProbe → ConvertFrom-PortalLocation）
#            ▼
#    Send-CampusLoginRequest ─► 协议策略链：哆点 v4(:803 portal/login) → 旧接口(:801)
#            │                    URL 由 New-DrappallLoginUrl 构造，key 由 Get-DrappallKey 从 IP 推导
#            ▼
#    Wait-CampusInternet ──► 【底线】只有真实联网成功才算登录成功，否则一律算失败（防"伪登录"）
#
#  ─── 函数索引（按职责分组；括号内为关键依赖）──────────────
#   A. 基础 / 日志
#      Get-CampusNetVersion / Get-DefaultSettings / Merge-CampusSettings
#      Write-CampusLog（所有函数都通过它写日志）/ Get-TextPreview（日志截断）
#   B. 凭据与配置
#      Protect-CampusPassword / Unprotect-CampusPassword（DPAPI）
#      Save-CampusConfig / Load-CampusConfig（含旧 Base64 配置一次性迁移）
#   C. 联网判定
#      Get-InternetProbeList / Test-InternetProbeResponse / Test-CampusInternet / Wait-CampusInternet
#   D. 哆点协议：参数编解码
#      Get-DrappallKey（key = IP 各字符 ASCII 逐位异或）
#      ConvertTo-DrappallValue / ConvertFrom-DrappallValue（逐字符 XOR key → 2 位 hex）
#      Get-MaskedUrl（打日志/上屏前把密码脱敏）
#   E. 门户自动发现
#      ConvertFrom-PortalLocation（解析 a79.htm / eportal 跳转里的参数）
#      Get-DefaultProbeBlacklist / Get-PortalProbeUrls（避开 portal 不劫持的探针地址）
#      Get-CampusPortalProbe（发 HTTP 探针，拿回跳转页或 Location）
#      Resolve-CampusPortal（探针 → 解析 → 合并进 Settings）
#      Get-LoginEndpoint（决定登录用哪个 IP/MAC：以门户看到的为准）
#   F. 失败兜底（仅交互模式）
#      Test-CampusSettingEnabled（读布尔型配置）/ Get-CampusFailureAction（决定要不要开浏览器）
#      Get-CampusPortalPageUrl / Open-CampusPortalPage
#   G. 网卡体检与选择
#      Get-CampusAdapterType / Select-CampusAdapterByRoute
#      Get-CampusAdapterRejectReason（纯函数：这张卡为什么不能用）
#      Get-CampusAdapterReport（全量体检表）/ Get-CampusAdapter（挑一张可用的）
#      Test-CampusIsAdmin
#   H. 网络修复与 DNS（免重启）
#      Get-CampusRepairPlan（纯函数：哪些卡需要修）/ Invoke-CampusDhcpRenew
#      Invoke-CampusNetworkRepair（清缓存 → Release/Renew → 必要时重启网卡）
#      Get-CampusDnsCacheCount / Test-CampusShouldFlushDnsOnRepair / Clear-CampusDnsCache
#   I. 请求 URL 构造
#      New-DrappallLoginUrl（主路径）/ Get-DrappallReferer
#      New-DrappallLoadConfigUrl / Get-DrappallPageIndex
#      New-CampusLoginUrl（回退用旧接口）
#   J. 响应解析与发送
#      ConvertFrom-PortalResponse / Send-CampusLoginRequest
#   K. 静默流程
#      Invoke-CampusSilentLogin（供 CampusNet_Silent.ps1 与 -Silent 共用）
#
#  ─── 改代码前请先记住的几条"坑"────────────────────────────
#   1. XOR key 不是常量，而是由本机 IP 推导（Get-DrappallKey）。写死会在别的网段
#      被门户判定"请求参数包含非法内容"（dr0001 code=403）。
#   2. "协议层成功(result:1)" ≠ "能上网"。判定成功必须过 Wait-CampusInternet。
#   3. 密码出现在任何 URL 时，上屏/写日志前必须过 Get-MaskedUrl。
#   4. .ps1 必须存成 UTF-8 with BOM，否则 Windows PowerShell 5.1 会把中文读成乱码
#      并引发语法错误。
#   5. 单引号字符串里不能直接嵌单引号；双引号里 "$var?" 会被解析成变量名 var?
#      （详见 Get-CampusPortalPageUrl 的注释）。
# ============================================================

# 统一控制台输出编码，避免中文乱码（重定向/无控制台时静默失败）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------
# 版本 / 默认参数
# ------------------------------------------------------------
function Get-CampusNetVersion { return '4.0' }

# portal 默认参数；可在配置文件 Settings 中按校区覆盖
function Get-DefaultSettings {
    return [ordered]@{
        # 哆点 v4 / eportal portal 接口（当前校园网实际使用，端口 803）
        PortalHost    = '10.0.10.252'
        PortalPort    = '803'
        JsVersion     = '4.5.1'
        # 旧接口（回退用，端口 801）
        BaseURL       = 'http://10.0.10.252:801/eportal/'
        WlanAcIp      = '10.128.255.129'
        WlanAcName    = ''
        PortalVersion = '8366'
        LoginMethod   = '1'
        Callback      = 'dr1003'
        # 失败时是否自动用浏览器打开门户页（交互模式；静默模式永远不弹窗）
        OpenPortalOnFailure = '1'
        # -Repair 是否顺带清 DNS 缓存（默认关：DNS 清理是独立功能，不在“点一下修复”里顺手执行）
        FlushDnsOnRepair    = '0'
        # 日志归档：统一放到 <脚本目录>\<LogDir>\<yyyy-MM-dd>\ 下（每天一个目录、最多 4 个文件）
        LogDir              = 'logs'
        # 日志保留天数（含今天）；设为 0 表示永不清理
        LogRetentionDays    = '30'
    }
}

# 把配置文件里的 Settings 合并到默认值之上（只接受已知键）
function Merge-CampusSettings {
    param($RawSettings)

    $settings = Get-DefaultSettings
    if ($RawSettings) {
        foreach ($p in $RawSettings.PSObject.Properties) {
            if ($p.Name -and $null -ne $p.Value -and $settings.Contains($p.Name)) {
                $settings[$p.Name] = [string]$p.Value
            }
        }
    }
    return $settings
}

# portal 错误码 → 中文说明
function Get-PortalErrorText {
    param([int]$Code, [string]$Message)

    $text = switch ($Code) {
        0       { '门户未给出明确错误码（result=0）' }
        1       { '密码错误（账号或密码不正确）' }
        2       { '该账号已在其他设备登录，请先下线其他设备' }
        3       { '账号或密码错误' }
        4       { '账号不存在或已被停用' }
        8       { 'IP/MAC 地址不匹配，或凭证无效（可试 ipconfig /release 后 /renew）' }
        11      { '账号已欠费或被限制' }
        default { "未知错误码 $Code" }
    }

    # 门户自带的中文提示更准确，就一并显示（AC999 这类内部码没有信息量，忽略）
    if ($Message -and ($Message -match '[\u4e00-\u9fa5]') -and ($Message -notmatch '认证成功')) {
        return "$text（门户提示：$Message）"
    }
    return $text
}

# ============================================================
# 日志归档（纯函数，便于单测）
# ============================================================
# ------------------------------------------------------------
# Resolve-CampusLogDirName —— 纯函数：把配置里的 LogDir 归一成一个**安全的**相对目录名
#   入参：$LogDirName 用户配置值（可能为空；也可能被写成 `..\..`、绝对路径或带通配符）
#   返回：安全的名字；任何非法值一律回落成 'logs'
#   规则：不允许路径分隔符、盘符/非法字符、`.` / `..`；也不允许 `* ? [ ]`（通配符）
#   为什么这一步必须做：这个名字会参与 `Join-Path` + `Remove-Item -Recurse -Force` 的
#     路径构造（超期日志清理）。若允许 `..\..`，就能把日志根移到项目外，
#     从而误删别人的“日期名”目录。
#   调用方：Get-CampusLogDir、Get-ExpiredLogDirs、Clear-ExpiredCampusLogs
# ------------------------------------------------------------
function Resolve-CampusLogDirName {
    param([string]$LogDirName)

    if ([string]::IsNullOrWhiteSpace($LogDirName)) { return 'logs' }
    $n = $LogDirName.Trim()
    if ($n -eq '.' -or $n -eq '..')     { return 'logs' }
    if ($n -match '[\\/]')             { return 'logs' }   # 路径分隔符（含绝对路径）
    if ($n -match '[:*?"<>|\[\]]')  { return 'logs' }   # 盘符 / 通配符 / 文件系统非法字符
    return $n
}

# ------------------------------------------------------------
# Get-CampusLogDir —— 纯函数：算出“某一天”的日志目录
#   入参：$ScriptDir 脚本目录（日志根就放在它下面）
#         $LogDirName 日志文件夹名，默认 'logs'
#         $Date 取哪一天的目录（默认今天；显式传入便于测试与回溯查询）
#   返回：完整路径，形如 <ScriptDir>\logs\2026-09-28
#   设计：**每天一个目录**——一天最多 4 个文件（登录记录/交互输出/静默输出/崩溃记录），
#         既能按天回溯，又不会像旧版那样堆出一堆散落在脚本目录里的 log
#   调用方：Get-CampusLogFile、Clear-ExpiredCampusLogs
# ------------------------------------------------------------
function Get-CampusLogDir {
    param(
        [Parameter(Mandatory)][string]$ScriptDir,
        [string]$LogDirName = 'logs',
        [datetime]$Date = (Get-Date)
    )

    $LogDirName = Resolve-CampusLogDirName -LogDirName $LogDirName
    return (Join-Path (Join-Path $ScriptDir $LogDirName) $Date.ToString('yyyy-MM-dd'))
}

# ------------------------------------------------------------
# Get-CampusLogFile —— 纯函数：算出某个日志文件的完整路径
#   入参：$ScriptDir 脚本目录；$Kind 日志种类；$LogDirName / $Date 同上
#   种类：'main'（登录记录，追加）| 'launcher'（交互版屏幕输出，覆盖）
#         | 'silent'（静默版屏幕输出，覆盖）| 'fatal'（仅崩溃，追加）
#   返回：完整文件路径；$Kind 不认识时返回 $null
#   调用方：CampusNet_Login.ps1、CampusNet_Silent.ps1
# ------------------------------------------------------------
function Get-CampusLogFile {
    param(
        [Parameter(Mandatory)][string]$ScriptDir,
        [Parameter(Mandatory)][ValidateSet('main', 'launcher', 'silent', 'fatal')][string]$Kind,
        [string]$LogDirName = 'logs',
        [datetime]$Date = (Get-Date)
    )

    $dir = Get-CampusLogDir -ScriptDir $ScriptDir -LogDirName $LogDirName -Date $Date
    $name = switch ($Kind) {
        'main'     { 'CampusNet_Log.txt' }
        'launcher' { 'CampusNet_Launcher.log' }
        'silent'   { 'CampusNet_Silent.log' }
        'fatal'    { 'CampusNet_Fatal.log' }
    }
    return (Join-Path $dir $name)
}

# ------------------------------------------------------------
# Get-ExpiredLogDirs —— 纯函数：算出哪些日期目录该被清理
#   入参：$ScriptDir 脚本目录；$LogDirName 日志文件夹名
#         $RetentionDays 保留天数（含今天）；<=0 表示永不清理
#         $Now 以哪一刻为基准（默认现在；显式传入便于测试）
#   返回：[pscustomobject] @{ Root; Dirs } —— Root 是日志根目录，Dirs 是待删除的日期目录完整路径
#   规则：只认形如 `yyyy-MM-dd` 的目录名（其它一律不碰）；**当天及未来目录永不入选**；
#         按目录名日期比较，不看文件 mtime（避免拷来拷去把时间戳弄乱）
#   调用方：Clear-ExpiredCampusLogs
# ------------------------------------------------------------
function Get-ExpiredLogDirs {
    param(
        [Parameter(Mandatory)][string]$ScriptDir,
        [string]$LogDirName = 'logs',
        [int]$RetentionDays = 30,
        [datetime]$Now = (Get-Date)
    )

    $LogDirName = Resolve-CampusLogDirName -LogDirName $LogDirName
    $root   = Join-Path $ScriptDir $LogDirName
    $result = [pscustomobject]@{ Root = $root; Dirs = @() }

    if ($RetentionDays -le 0) { return $result }                       # 0 或负数 = 永不清理
    if (-not (Test-Path -LiteralPath $root)) { return $result }

    # 保留“最近 N 天（含今天）”→ 早于 today-(N-1) 的目录才算超期
    $cutoff = $Now.Date.AddDays(-1 * ($RetentionDays - 1))
    $expired = New-Object System.Collections.ArrayList

    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact(
            $d.Name, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)
        if (-not $ok) { continue }                    # 不是日期目录名 → 不动它
        if ($parsed.Date -ge $Now.Date) { continue }  # 当天/未来 → 永不删
        if ($parsed.Date -lt $cutoff) { [void]$expired.Add($d.FullName) }
    }

    $result.Dirs = @($expired)
    return $result
}

# ------------------------------------------------------------
# Clear-ExpiredCampusLogs —— 建好今天的日志目录，并清掉超期目录（执行动作）
#   入参：$ScriptDir 脚本目录；$LogDirName 日志文件夹名；$RetentionDays 保留天数（<=0 = 不清理）
#         $LogFile 记一条清理结果到该文件（可空；只写文件，**不向屏幕输出**）
#   返回：[pscustomobject] @{ Dir; Removed } —— Dir 是今天的日志目录，Removed 是实际删掉的目录数
#   行为：① 建 <ScriptDir>\<LogDirName>\<今天>\（幂等，已存在就跳过）
#         ② 删超期日期目录（当天绝不删、非日期目录绝不碰，判定见 Get-ExpiredLogDirs）
#   调用方：CampusNet_Login.ps1（交互版）、CampusNet_Silent.ps1（静默版）——各自在 `. Common` 之后调一次
#   坑：整个函数体包在 try/catch 里且**只记日志不抛异常**——
#       清理历史日志是顺带的事，绝不能成为登录失败的原因；
#       静默路径下更不得因此弹窗或改变退出码
# ------------------------------------------------------------
function Clear-ExpiredCampusLogs {
    param(
        [Parameter(Mandatory)][string]$ScriptDir,
        [string]$LogDirName = 'logs',
        [int]$RetentionDays = 30,
        [string]$LogFile
    )

    $result = [pscustomobject]@{ Dir = $null; Removed = 0 }
    try {
        $LogDirName = Resolve-CampusLogDirName -LogDirName $LogDirName

        # ① 今天的目录
        #    注：New-Item **没有** -LiteralPath 参数（只有 -Path），所以这里只能用 -Path；
        #    通配符顾虑已在源头挡掉——Resolve-CampusLogDirName 不接受 `* ? [ ]`。
        $today = Get-CampusLogDir -ScriptDir $ScriptDir -LogDirName $LogDirName
        if (-not (Test-Path -LiteralPath $today)) { $null = New-Item -ItemType Directory -Path $today -Force }
        $result.Dir = $today

        # ② 超期目录
        $expired = Get-ExpiredLogDirs -ScriptDir $ScriptDir -LogDirName $LogDirName -RetentionDays $RetentionDays
        foreach ($d in @($expired.Dirs)) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                $result.Removed++
            }
            catch { }   # 单个目录删不掉（被占用/权限）不影响其它目录
        }

        if ($result.Removed -gt 0 -and $LogFile) {
            Write-CampusLog -Message "已清理 $($result.Removed) 个超期日志目录（保留最近 $RetentionDays 天）" -LogFile $LogFile -Level Info
        }
    }
    catch { }
    return $result
}

# ------------------------------------------------------------
# 日志（带简单轮转：超过 1MB 时保留后一半）
# ------------------------------------------------------------
function Write-CampusLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS', 'DEBUG')][string]$Level = 'INFO',
        [string]$LogFile
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($LogFile) {
        try {
            if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
                $lines = @(Get-Content -LiteralPath $LogFile)
                $keep = [Math]::Max(1, [int]($lines.Count / 2))
                $lines | Select-Object -Last $keep | Set-Content -LiteralPath $LogFile -Encoding UTF8
            }
            Add-Content -LiteralPath $LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
    }

    switch ($Level) {
        'ERROR'   { Write-Host $logEntry -ForegroundColor Red }
        'WARNING' { Write-Host $logEntry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logEntry -ForegroundColor Green }
        'DEBUG'   { Write-Host $logEntry -ForegroundColor DarkGray }
        default   { Write-Host $logEntry -ForegroundColor Cyan }
    }
}

# ------------------------------------------------------------
# 密码保护：Windows DPAPI（ConvertFrom-SecureString）
#   仅“当前 Windows 用户 + 本机”可解密，密文无法在别处还原。
#   —— 这是加密，不是 Base64 编码。
# ------------------------------------------------------------
function Protect-CampusPassword {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PlainText)

    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}

# ------------------------------------------------------------
# Unprotect-CampusPassword —— 把 DPAPI 密文解成明文
#   入参：$Cipher 密文字符串（即配置里的 Password 字段原值）
#   返回：明文密码；密文与本机 + 当前 Windows 用户绑定，跨机器/跨用户解不开
#   调用方：Load-CampusConfig
#   坑：本函数自身不 catch——解密失败由调用方判定为“配置损坏”（退出码 2）
# ------------------------------------------------------------
function Unprotect-CampusPassword {
    param([Parameter(Mandatory)][string]$Cipher)

    $secure = ConvertTo-SecureString -String $Cipher
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ------------------------------------------------------------
# 配置文件读写
# ------------------------------------------------------------
function Save-CampusConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigFile,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [System.Collections.IDictionary]$Settings,
        [string]$LogFile
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    $config = [ordered]@{
        Account        = $Account
        Password       = (Protect-CampusPassword -PlainText $Password)
        PasswordFormat = 'DPAPI'
        LastUpdate     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        CreatedBy      = "校园网自动登录系统 v$(Get-CampusNetVersion)"
        Settings       = $Settings
    }

    try {
        $config | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $ConfigFile -Encoding UTF8 -Force
        # 收窄文件权限，仅当前用户可读写
        try { & icacls $ConfigFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" *> $null } catch { }
        Write-CampusLog -Message '配置保存成功' -Level SUCCESS -LogFile $LogFile
        return $true
    }
    catch {
        Write-CampusLog -Message "配置保存失败: $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
        return $false
    }
}

# 最近一次 Load-CampusConfig 的失败原因：'missing'（文件不存在）/ 'corrupt'（解析、解密失败或字段缺失）
#   供静默模式区分退出码 1（无配置）与 2（配置坏了，需重跑 FirstTimeSetup）
$script:LastConfigLoadError = $null

# ------------------------------------------------------------
# Load-CampusConfig —— 读取配置（含一次性迁移）
#   入参：$Path 配置文件路径
#   返回：配置对象；失败返回 $null，并把原因写到 $script:LastConfigLoadError
#   容错：旧版 Base64 密码配置会自动迁移为 DPAPI（只做一次，成功后重写文件）
#   失败原因：'missing'（文件不存在）/'corrupt'（解析、解密失败或字段缺失）
#   调用方：Interactive 与静默两条路径都会先调它
#   坑：失败时不要直接 exit——静默模式要靠 $script:LastConfigLoadError 区分 1 与 2
# ------------------------------------------------------------
function Load-CampusConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigFile,
        [string]$LogFile
    )

    $script:LastConfigLoadError = $null

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        $script:LastConfigLoadError = 'missing'
        Write-CampusLog -Message "配置文件不存在: $ConfigFile" -Level WARNING -LogFile $LogFile
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $script:LastConfigLoadError = 'corrupt'
        Write-CampusLog -Message "配置文件解析失败: $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
        return $null
    }

    $account = [string]$raw.Account
    $settings = Merge-CampusSettings $raw.Settings
    $format = $null
    if ($raw.PSObject.Properties.Name -contains 'PasswordFormat') { $format = [string]$raw.PasswordFormat }

    $password = $null
    if ($format -eq 'DPAPI') {
        try {
            $password = Unprotect-CampusPassword -Cipher ([string]$raw.Password)
        }
        catch {
            $script:LastConfigLoadError = 'corrupt'
            Write-CampusLog -Message '密码解密失败：配置可能来自其他 Windows 用户或另一台电脑。请重新运行 FirstTimeSetup.bat。' -Level ERROR -LogFile $LogFile
            return $null
        }
    }
    else {
        # 兼容 v3.0 旧配置：Password 为 Base64 编码
        try {
            $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$raw.Password))
            Write-CampusLog -Message '检测到旧版 Base64 密码，正在迁移为 DPAPI 加密...' -Level WARNING -LogFile $LogFile
            if (Save-CampusConfig -ConfigFile $ConfigFile -Account $account -Password $password -Settings $settings -LogFile $LogFile) {
                Write-CampusLog -Message '旧配置已迁移为 DPAPI 加密' -Level SUCCESS -LogFile $LogFile
            }
        }
        catch {
            $script:LastConfigLoadError = 'corrupt'
            Write-CampusLog -Message '无法解析旧版密码，请重新运行 FirstTimeSetup.bat 设置。' -Level ERROR -LogFile $LogFile
            return $null
        }
    }

    if ([string]::IsNullOrEmpty($account) -or [string]::IsNullOrEmpty($password)) {
        $script:LastConfigLoadError = 'corrupt'
        Write-CampusLog -Message '配置缺少账号或密码，请重新运行 FirstTimeSetup.bat。' -Level ERROR -LogFile $LogFile
        return $null
    }

    return [pscustomobject]@{
        Account  = $account
        Password = $password
        Settings = $settings
    }
}

# ------------------------------------------------------------
# 联网判定
#   用 HTTPS + 内容校验：校园网 portal 一般只劫持 HTTP，
#   若被劫持会返回 200 但内容不含期望关键字，因此不会被误判为“已在线”。
#
#   ⚠️ 绝对不能拿门户 visit_blacklist 里的地址（generate_204 / ncsi.txt /
#      msftncsi 等）判断是否已联网 —— 那些域名是“免认证豁免”的，
#      未登录时也会正常返回 204，会把离线误判成在线（伪登录漏判）。
# ------------------------------------------------------------
function Get-InternetProbeList {
    param([string[]]$ExemptBlacklist)

    if (-not $ExemptBlacklist -or $ExemptBlacklist.Count -eq 0) { $ExemptBlacklist = Get-DefaultProbeBlacklist }

    $candidates = @(
        @{ Url = 'https://www.baidu.com'; Match = 'baidu' }
        @{ Url = 'https://www.qq.com'; Match = 'qq' }
        @{ Url = 'https://www.bing.com'; Match = 'bing' }
    )

    return @($candidates | Where-Object {
        $u = $_.Url
        (@($ExemptBlacklist | Where-Object { $_ -and ($u -like "*$_*") }).Count -eq 0)
    })
}

# ------------------------------------------------------------
# Test-CampusInternet —— 【核心底线】真实联网校验
#   入参：$TimeoutSec 单个探针超时；$Probes 探针列表（默认见 Get-InternetProbeList）
#   返回：$true 表示真的能上外网
#   为什么不用 ping：校园网门户会劫持 DNS/HTTP，必须**下载到预期内容**才算数
#   判定：响应内容能匹配各探针的预期关键字，或命中 generate_204 这类空响应特征
#   调用方：Wait-CampusInternet；**所有“登录成功”的结论都必须经过它**
#   坑：别把“门户返回登录页(HTTP 200)”当成通网——那正是“伪登录”的来源
# ------------------------------------------------------------
function Test-CampusInternet {
    param([int]$TimeoutSec = 5)

    foreach ($p in (Get-InternetProbeList)) {
        try {
            $resp = Invoke-WebRequest -Uri $p.Url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -MaximumRedirection 2 -ErrorAction Stop
            if (Test-InternetProbeResponse -StatusCode ([int]$resp.StatusCode) -Content ([string]$resp.Content) -Match $p.Match) {
                return $true
            }
        }
        catch { }
    }
    return $false
}

# 纯函数：一次探测响应能不能证明“真的在互联网上”
#   光看状态码不够 —— 门户劫持时会返回 200 + 登录页，必须同时验内容
function Test-InternetProbeResponse {
    param(
        [int]$StatusCode,
        [AllowEmptyString()][string]$Content,
        [string]$Match
    )

    if ($StatusCode -ne 200) { return $false }
    if ([string]::IsNullOrEmpty($Content)) { return $false }
    if ($Match -and ($Content -notmatch $Match)) { return $false }
    if ($Content -match '(?i)eportal|portal_login|drcom|哆点|上网登录|请登录|系统发生错误') { return $false }
    return $true
}

# 轮询等待互联网恢复（登录后确认真实联网，防止“伪登录”）
function Wait-CampusInternet {
    param([int]$TimeoutSec = 15, [int]$IntervalSec = 3)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if (Test-CampusInternet) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $IntervalSec
    }
}

# ------------------------------------------------------------
# 文本预览：把 portal 原始响应压成一行，便于打日志 / 屏幕
# ------------------------------------------------------------
function Get-TextPreview {
    param([string]$Text, [int]$Max = 200)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '(空)' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + ' ...' }
    return $t
}

# ------------------------------------------------------------
# Get-DrappallKey —— 推导哆点 v4 的 XOR key（**不是固定值**）
#   入参：$IP 客户端 IPv4 字符串，必须与请求里的 wlan_user_ip 完全一致
#   返回：0..255 的整数，作为后续 XOR 混淆的 key
#   原理：key = IP 字符串每个字符的 ASCII 码逐位异或；来源是门户自带 JS
#         a41.js 的 util.getkey(term.ip)：
#         getkey: function (ip){ var ret=0; for(var i=0;i<ip.length;i++) ret^=ip.charCodeAt(i); return ret; }
#   实测（与四份抓包逐字节对得上）：
#       10.20.30.40 -> 0x2A   10.20.30.41 -> 0x2B   10.20.30.42 -> 0x28
#   调用方：New-DrappallLoginUrl
#   坑：IP 变了 key 就变。写死某个 key（例如 0x20）在别的网段会被门户拒绝：
#       dr0001({"code":403,...,"msg":"请求参数包含非法内容"})
# ------------------------------------------------------------
function Get-DrappallKey {
    param([Parameter(Mandatory)][string]$IP)

    $ret = 0
    foreach ($c in $IP.ToCharArray()) { $ret = $ret -bxor [int][char]$c }
    return ($ret -band 0xFF)
}

# ------------------------------------------------------------
# 参数混淆：每字符 XOR key 后写成 2 位十六进制（对应 a41.js 的 util.enc_pwd）
#   向量用假账号/假密码，真凭据不写进仓库：
#     111315171910                     -> "135790"
#     11100e1112180e1215150e111219     -> "10.128.255.129"
#     445211101013                     -> "dr1003"
#     5a480d434e                       -> "zh-cn"
# ------------------------------------------------------------
function ConvertTo-DrappallValue {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Key = 0x20
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $mask = $Key -band 0xFF
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $b = (([int][char]$ch) -band 0xFF) -bxor $mask
        [void]$sb.Append($b.ToString('x2'))
    }
    return $sb.ToString()
}

# ------------------------------------------------------------
# ConvertFrom-DrappallValue —— 把哆点混淆值解回明文（ConvertTo-DrappallValue 的逆运算）
#   入参：$Hex 十六进制串（每 2 位一个字节）；$Key 同 ConvertTo-DrappallValue
#   返回：明文；输入为空返回 ''；**奇数长度或含非 hex 字符返回 $null**（用 $null 区分“解不了”）
#   用途：测试与人工排障（生产路径只编码不解码）；对照抓包时用它还原字段
#   调用方：tests\CampusNet.Common.Tests.ps1
# ------------------------------------------------------------
function ConvertFrom-DrappallValue {
    param(
        [AllowEmptyString()][string]$Hex,
        [int]$Key = 0x20
    )

    if ([string]::IsNullOrWhiteSpace($Hex)) { return '' }
    $h = $Hex.Trim()
    if ($h.Length % 2 -ne 0) { return $null }

    $mask = $Key -band 0xFF
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $h.Length; $i += 2) {
        try { $byte = [Convert]::ToInt32($h.Substring($i, 2), 16) } catch { return $null }
        [void]$sb.Append([char]($byte -bxor $mask))
    }
    return $sb.ToString()
}

# ------------------------------------------------------------
# URL 脱敏：展示/写日志时把 user_password 换成 ***（密码本身仍会用于真实请求）
# ------------------------------------------------------------
function Get-MaskedUrl {
    param([string]$Url)

    if ([string]::IsNullOrEmpty($Url)) { return $Url }

    # 密码与学号都要盖：本项目要求"日志/屏幕上不出现明文凭据"。
    # 注意 user_account 的真实形式是 ",0,<学号>"，整个值一并替换掉。
    $masked = $Url -replace '(?i)(user_password=)[^&]*', '$1***'
    $masked = $masked -replace '(?i)(user_account=)[^&]*', '$1***'
    return $masked
}

# ------------------------------------------------------------
# ConvertFrom-PortalLocation —— 从跳转地址/页面解析门户与 AC 参数（纯函数，便于单测）
#   入参：$Url 跳转地址或 a79.htm 页面 URL；$Html 可选的页面正文（用于抓表单里藏的字段）
#   返回：含 PortalHost/PortalPort/UserIp/UserMac/WlanAcIp/WlanAcName/BaseURL 等的对象
#         解析不到的字段为 $null（调用方靠“只合并非空值”保留原有配置）
#   两种形态：
#     · a79.htm 入口页：http://<host>/a79.htm?wlanusermac=..&wlanuserip=..&wlanacip=..
#       → 只用来知道“门户在哪”和 AC 看到的 IP/MAC；**不要拿它覆盖 BaseURL**
#     · eportal 形态：http://<host>:803/eportal/... → 此时才把 BaseURL 规范化为
#       http://<host>:803/eportal/
#   调用方：Resolve-CampusPortal
# ------------------------------------------------------------
function ConvertFrom-PortalLocation {
    param([string]$Text)

    $out = [ordered]@{
        BaseURL       = $null
        PortalHost    = $null
        PortalPort    = $null
        WlanAcIp      = $null
        WlanAcName    = $null
        JsVersion     = $null
        PortalVersion = $null
        UserIp        = $null
        UserMac       = $null
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $out }

    $getParam = {
        param([string]$t, [string[]]$names)
        foreach ($n in $names) {
            $m = [regex]::Match($t, "(?i)(?<![A-Za-z0-9_])$n=([^&\s""'<>]+)")
            if ($m.Success) { return [uri]::UnescapeDataString($m.Groups[1].Value) }
        }
        return $null
    }

    if ($Text -match '(?i)(https?://[0-9]{1,3}(?:\.[0-9]{1,3}){3})(?::(\d+))?(/[^\s"''<>]*)') {
        $origin = $matches[1]
        $port = $matches[2]
        $path = $matches[3]

        if ($origin -match '^https?://(.+)$') { $out.PortalHost = $matches[1] }
        if ($port) { $out.PortalPort = $port }

        if ($path -match '(?i)/eportal') {
            $p = if ($port) { $port } else { '803' }
            $out.BaseURL = "${origin}:${p}/eportal/"
        }
        # 入口页（a79.htm 等）只能说“门户在哪”，不能拿来当 BaseURL，
        # 否则会把回退接口的 http://<host>:801/eportal/ 覆盖掉（真实踩过）。
    }

    $out.WlanAcIp   = & $getParam $Text @('wlan_ac_ip', 'wlanacip', 'wlanAcIp', 'nasip', 'nas_ip')
    $out.WlanAcName = & $getParam $Text @('wlan_ac_name', 'wlanacname', 'wlanAcName', 'nasname', 'nas_name')
    $out.UserIp     = & $getParam $Text @('wlan_user_ip', 'wlanuserip', 'wlanUserIp', 'userip')
    $out.UserMac    = & $getParam $Text @('wlanusermac', 'wlan_user_mac', 'wlanUserMac', 'usermac')

    $jsv = & $getParam $Text @('jsVersion', 'jsversion')
    if ($jsv) {
        $out.JsVersion = $jsv
        $out.PortalVersion = & $getParam $Text @('v')
    }

    return $out
}

# ------------------------------------------------------------
# 门户下发的 visit_blacklist（取自真实抓包 loadConfig 响应）
#   这些地址门户不会劫持，拿来做"未认证探针"永远得不到跳转
# ------------------------------------------------------------
function Get-DefaultProbeBlacklist {
    return @(
        '1.1.1.1', 'www.msftncsi.com', 'land.xiaomi.net', 'detectportal.firefox.com',
        'www.airport.us', 'www.thinkdifferent.us', 'www.ibook.info', 'www.itools.info',
        'www.appleiphonecell.com', 'captive.apple.com', 'www.apple.com', 'gspe21.ls.apple.com',
        'generate_204', 'ncsi.txt', 'success.txt'
    )
}

# 过滤掉被门户拉黑的探针地址（子串匹配，与门户行为一致）
function Get-PortalProbeUrls {
    param([string[]]$Blacklist)

    if (-not $Blacklist -or $Blacklist.Count -eq 0) { $Blacklist = Get-DefaultProbeBlacklist }

    $candidates = @(
        'http://9.9.9.9/',
        'http://www.baidu.com/',
        'http://www.qq.com/'
    )

    return @($candidates | Where-Object {
        $u = $_
        (@($Blacklist | Where-Object { $_ -and ($u -like "*$_*") }).Count -eq 0)
    })
}

# ------------------------------------------------------------
# 未认证时做一次 HTTP 探针，取回被劫持/跳转的页面或 Location
#   （校园网 portal 一般只劫持 HTTP，所以用 http:// 探针即可）
# ------------------------------------------------------------
function Get-CampusPortalProbe {
    param([int]$TimeoutSec = 6, [string]$LogFile)

    $probes = Get-PortalProbeUrls
    Write-CampusLog -Message "portal 探针候选（已避开门户黑名单）：$($probes -join ', ')" -Level DEBUG -LogFile $LogFile

    foreach ($probe in $probes) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($probe)
            $req.AllowAutoRedirect = $false
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.UserAgent = 'Mozilla/5.0 (CampusNetAutoLogin)'

            $resp = $null
            try { $resp = $req.GetResponse() }
            catch [System.Net.WebException] { $resp = $_.Exception.Response }
            if (-not $resp) {
                Write-CampusLog -Message "portal 探针 $probe 无响应（超时或被丢弃），换下一个" -Level DEBUG -LogFile $LogFile
                continue
            }

            $status = [int]$resp.StatusCode
            $location = ''
            try { $location = [string]$resp.Headers['Location'] } catch { }
            $body = ''
            try {
                $stream = $resp.GetResponseStream()
                if ($stream) { $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd() }
            }
            catch { }
            try { $resp.Close() } catch { }

            Write-CampusLog -Message "portal 探针 $probe -> HTTP $status; Location=$location" -Level DEBUG -LogFile $LogFile

            $looksLikePortal =
                (($status -ge 300) -and ($location -match '\d+\.\d+\.\d+\.\d+')) -or
                ($body -match '(?i)eportal|wlan_user_ip|wlanacname|a79\.htm|dr1003')
            if ($looksLikePortal) { return "$location`r`n$body" }
        }
        catch {
            Write-CampusLog -Message "portal 探针 $probe 异常：$($_.Exception.Message)" -Level DEBUG -LogFile $LogFile
        }
    }
    return $null
}

# ------------------------------------------------------------
# Resolve-CampusPortal —— portal 自动发现：探测并把识别到的参数合并进 Settings
#   入参：$Settings 配置集合（默认值 + 用户配置）；$Adapter 当前网卡；$TimeoutSec 探针超时
#   返回：[pscustomobject] @{ Settings; Probed; Changed } —— 改了什么、探到了什么
#   流程：Get-PortalProbeUrls（跳过 visit_blacklist）→ Get-CampusPortalProbe 发探针
#         → ConvertFrom-PortalLocation 解析 → 只把非空值合并回 Settings
#   ⚠️ 副作用（有意为之）：会**就地修改**传入的 $Settings 字典。
#      调用方若不想被改，请先自己复制一份；
#      发现结果同时通过返回对象的 .Settings / .Probed / .Changed 暴露。
#   调用方：Get-LoginEndpoint、-Diagnose、-TestLogin
# ------------------------------------------------------------
function Resolve-CampusPortal {
    param(
        [System.Collections.IDictionary]$Settings,
        [int]$TimeoutSec = 6,
        [string]$LogFile
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    $res = [pscustomobject]@{ Probed = $false; Found = $false; Changed = $false; Settings = $Settings; Raw = $null; UserIp = $null; UserMac = $null; PortalHost = $null }

    $text = Get-CampusPortalProbe -TimeoutSec $TimeoutSec -LogFile $LogFile
    if (-not $text) {
        Write-CampusLog -Message 'portal 自动发现：未探测到跳转（可能已联网或不在校园网内）' -Level INFO -LogFile $LogFile
        return $res
    }
    $res.Raw = $text
    $res.Probed = $true

    $found = ConvertFrom-PortalLocation -Text $text
    $res.UserIp = $found.UserIp
    $res.UserMac = $found.UserMac
    $res.PortalHost = $found.PortalHost

    $changed = $false
    foreach ($k in @('PortalHost', 'PortalPort', 'BaseURL', 'WlanAcIp', 'WlanAcName', 'JsVersion', 'PortalVersion')) {
        $v = $found[$k]
        if ($v -and (([string]$Settings[$k]) -ne ([string]$v))) {
            $Settings[$k] = $v
            $changed = $true
        }
    }
    $res.Settings = $Settings
    if ($changed) {
        $res.Found = $true
        $res.Changed = $true
        Write-CampusLog -Message "portal 自动发现：PortalHost=$($Settings.PortalHost):$($Settings.PortalPort) WlanAcIp=$($Settings.WlanAcIp) WlanAcName=$($Settings.WlanAcName)" -Level SUCCESS -LogFile $LogFile
    }
    else {
        Write-CampusLog -Message "portal 自动发现：已探测到门户（Host=$($res.PortalHost)，UserIp=$($res.UserIp)，UserMac=$($res.UserMac)），参数与配置一致" -Level INFO -LogFile $LogFile
    }
    return $res
}

# ------------------------------------------------------------
# Get-LoginEndpoint —— 决定登录用哪个 IP/MAC
#   入参：$Adapter 当前网卡；$Settings 配置集合；$LogFile 日志
#   返回：[pscustomobject] @{ IP; MAC; Discovered } —— Discovered 是自动发现的中间结果
#   关键：优先用门户探测（a79 跳转）里的值——那才是 AC 眼中真实的 IP/MAC；
#         与当前网卡不一致时告警但**以门户为准**（因为 XOR key 要用同一个 IP 推导）
#   调用方：CampusNet_Login.ps1、Invoke-CampusSilentLogin、Invoke-TestLogin
#   坑：这里返回的 IP 会同时决定 wlan_user_ip 与 XOR key，两者必须同源
# ------------------------------------------------------------
function Get-LoginEndpoint {
    param(
        [Parameter(Mandatory)]$Adapter,
        [System.Collections.IDictionary]$Settings,
        [string]$LogFile
    )

    $disc = Resolve-CampusPortal -Settings $Settings -LogFile $LogFile

    $ip = [string]$Adapter.IP
    $mac = [string]$Adapter.MAC

    if ($disc.Probed) {
        if ($disc.UserIp) {
            if ($disc.UserIp -ne $ip) {
                Write-CampusLog -Message "门户探测到的 IP($($disc.UserIp)) 与网卡 IP($ip) 不一致，以门户为准" -Level WARNING -LogFile $LogFile
            }
            $ip = $disc.UserIp
        }
        if ($disc.UserMac) {
            $portalMac = ($disc.UserMac -replace '[-:]', '').ToUpper()
            if ($portalMac -ne $mac) {
                Write-CampusLog -Message "门户探测到的 MAC($portalMac) 与网卡 MAC($mac) 不一致，以门户为准" -Level WARNING -LogFile $LogFile
            }
            $mac = $portalMac
        }
    }

    return [pscustomobject]@{ IP = $ip; MAC = $mac; Discovered = $disc }
}

# ------------------------------------------------------------
# 读取布尔型配置（'1'/'0'、'true'/'false'。缺省时用 $Default）
# ------------------------------------------------------------
function Test-CampusSettingEnabled {
    param(
        [System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$Key,
        [bool]$Default = $true
    )

    if (-not $Settings -or -not $Settings.Contains($Key)) { return $Default }

    $v = [string]$Settings[$Key]
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v.Trim().ToLower() -in @('1', 'true', 'yes', 'on', 'enable', 'enabled'))
}

# ------------------------------------------------------------
# Get-CampusPortalPageUrl —— 拼出“用户可以手动完成登录”的门户入口页 URL
#   入参：$Settings 配置集合；$IP/$MAC 当前端点（可选，不传就从 Settings/配置取）
#   返回：a79.htm 入口页完整 URL（带 wlanusermac / wlanuserip / wlanacip）
#   调用方：Open-CampusPortalPage（失败兜底开浏览器）
#   坑：本函数用字符串拼接而不是 "$base?..."——PowerShell 会把 "$base?" 解析成
#       变量 $base?，导致前缀整段丢失（曾经真实踩过，现有回归测试锁定）
# ------------------------------------------------------------
function Get-CampusPortalPageUrl {
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$UserIp,
        [string]$UserMac
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    $portalHost = [string]$Settings.PortalHost
    if ([string]::IsNullOrWhiteSpace($portalHost)) {
        # 从 BaseURL 里回导主机名
        if (([string]$Settings.BaseURL) -match '(?i)https?://([^/:]+)') { $portalHost = $matches[1] }
    }

    $mac = ($UserMac -replace '[-:]', '').ToUpper()
    if ($mac.Length -eq 12) {
        $mac = ($mac -split '(.{2})' | Where-Object { $_ } ) -join '-'
    }
    else {
        $mac = ''
    }

    $q = @()
    if ($mac) { $q += 'wlanusermac=' + $mac }
    if ($UserIp) { $q += 'wlanuserip=' + [uri]::EscapeDataString($UserIp) }
    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.WlanAcIp)) {
        $q += 'wlanacip=' + [uri]::EscapeDataString([string]$Settings.WlanAcIp)
    }

    $base = "http://${portalHost}/a79.htm"
    # 注意：不能写成 "$base?" —— PowerShell 会把 `?` 当成变量名的一部分
    if ($q.Count -gt 0) { return ($base + '?' + ($q -join '&')) }
    return $base
}

# ------------------------------------------------------------
# ------------------------------------------------------------
# Get-CampusFailureAction —— 纯函数：登录失败后该采取什么交互动作
#   入参：$ErrorCode 门户 ret_code（-1 表示“伪登录”：协议说成功但真实联网没过）；
#         $Settings 配置集合（读 OpenPortalOnFailure 开关）
#   返回：'credentials' | 'online' | 'browser' | 'none'
#     credentials = 账号/密码类错误(1/3/4/11) → 不开浏览器，应引导去改密码
#     online      = 账号已在线上(ret_code=2, msg AC999) → 不开浏览器，引导去自助服务下线
#     browser     = 协议/网络/伪登录类 → 开浏览器门户页兜底
#     none        = 开关关闭（OpenPortalOnFailure=0）
#   调用方：CampusNet_Login.ps1 的 Invoke-PortalFallbackIfNeeded
#   坑：这里只决定“做什么”，真正的 Start-Process 在 Open-CampusPortalPage
# ------------------------------------------------------------
function Get-CampusFailureAction {
    param(
        [int]$ErrorCode = -1,
        [AllowEmptyString()][string]$Message = '',
        [bool]$OpenPortalOnFailure = $true
    )

    if (-not $OpenPortalOnFailure) { return 'none' }

    # 凭证类：1=密码错误 3/4=账号问题 11=欠费/被限制
    if ($ErrorCode -in @(1, 3, 4, 11)) { return 'credentials' }
    if ($ErrorCode -eq 2) { return 'online' }

    # 没给出码时按文案兜底判断
    if ($Message -match '密码错误|账号或密码|密码不正确') { return 'credentials' }
    if ($Message -match '已在其他设备登录|已在线') { return 'online' }

    return 'browser'
}

# 用默认浏览器打开门户页（仅交互模式用；静默模式不得调用）
function Open-CampusPortalPage {
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$UserIp,
        [string]$UserMac,
        [string]$LogFile
    )

    $url = Get-CampusPortalPageUrl -Settings $Settings -UserIp $UserIp -UserMac $UserMac
    Write-CampusLog -Message "门户页面（可手动完成登录）：$url" -Level INFO -LogFile $LogFile

    try {
        Start-Process $url | Out-Null
        Write-CampusLog -Message '已尝试用默认浏览器打开门户页面' -Level INFO -LogFile $LogFile
        return $true
    }
    catch {
        Write-CampusLog -Message "打开浏览器失败：$($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        return $false
    }
}

# ------------------------------------------------------------
# 网卡选择
#   1) 只取 Up 且带 IPv4（非 169.254）的物理网卡，排除虚拟/蓝牙等
#   2) 优先“有默认网关”的网卡，其次有线优先
#   3) 无线网卡附带当前 SSID，便于判断是否连着校园 WiFi
# ------------------------------------------------------------
function Get-CampusAdapterType {
    param($Adapter)

    $media = ''
    try { $media = [string]$Adapter.MediaType } catch { }
    $pmedia = ''
    try { $pmedia = [string]$Adapter.PhysicalMediaType } catch { }

    if ($media -match '802\.11' -or $pmedia -match 'Wireless|802\.11') { return 'WiFi' }
    if ($media -match '802\.3' -or $pmedia -match '802\.3|Ethernet') { return '以太网' }
    if ($Adapter.InterfaceDescription -match '无线|Wi-?Fi|WLAN|Wireless') { return 'WiFi' }
    return '以太网'
}

# 纯函数：按“去往门户的源 IP”挑网卡（比“优先有线”更准）
function Select-CampusAdapterByRoute {
    param(
        [object[]]$Candidates,
        [string]$RouteSourceIp
    )

    if (-not $Candidates -or [string]::IsNullOrWhiteSpace($RouteSourceIp)) { return $null }
    return ($Candidates | Where-Object { $_.IP -eq $RouteSourceIp } | Select-Object -First 1)
}

# ------------------------------------------------------------
# 是否以管理员身份运行（重置网卡 / 清 ARP 缓存需要）
# ------------------------------------------------------------
function Test-CampusIsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# ------------------------------------------------------------
# 纯函数：根据网卡关键属性得出“不可用原因”（空串 = 可用）
#   判定顺序即诊断顺序：非物理 → 链路未连 → 无 IP → 只有 APIPA
# ------------------------------------------------------------
function Get-CampusAdapterRejectReason {
    param(
        [string]$Description = '',
        [string]$Type = '以太网',
        [string]$Status = 'Up',
        [AllowEmptyString()][string]$IP = ''
    )

    if ($Description -match 'Virtual|VMware|Hyper-V|VirtualBox|Bluetooth|Loopback|TAP-|VPN|WAN Miniport|Npcap') {
        return '虚拟/蓝牙等非物理链路，按规则排除'
    }
    if ($Status -ne 'Up') {
        if ($Type -eq 'WiFi') { return "无线未连接（$Status）：先连上校园 WiFi" }
        return "链路未连接（$Status）：网线没插好 / 对端口没通电"
    }
    if ([string]::IsNullOrEmpty($IP)) {
        return '没有 IPv4 地址：没拿到 DHCP 租约（跑 -Repair 通常可免重启恢复）'
    }
    if ($IP -match '^169\.254\.') {
        return "只有 APIPA($IP)：DHCP 没拿到租约，没网关也没路由（跑 -Repair 通常可免重启恢复）"
    }
    return ''
}

# ------------------------------------------------------------
# Get-CampusAdapterReport —— 网卡体检表（每一张物理网卡都有一条）
#   入参：无
#   返回：对象数组，每项含 Name/IfIndex/Description/Status/IP/PrefixLength/
#         Gateway/MAC/Type/SSID/Usable/Reason/IsWired/IsVirtual
#   设计原则：**绝不静默跳过**。不能用也要把原因写在 Reason 里，
#             解决“插了网线却只说没有可用网卡、看不到原因”的老毛病
#   原因判定委派给纯函数 Get-CampusAdapterRejectReason（方便单测）
#   调用方：Get-CampusAdapter、-Diagnose、Invoke-CampusNetworkRepair
# ------------------------------------------------------------
function Get-CampusAdapterReport {
    $report = @()
    $virtualPattern = 'Virtual|VMware|Hyper-V|VirtualBox|Bluetooth|Loopback|TAP-|VPN|WAN Miniport|Npcap'

    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $type = Get-CampusAdapterType -Adapter $a

        $ip = $null
        $isApipa = $false
        $ipObj = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^127\.' } |
            Select-Object -First 1
        if ($ipObj) {
            $ip = [string]$ipObj.IPAddress
            $isApipa = ($ip -match '^169\.254\.')
        }

        $hasGateway = $false
        $cfg = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        if ($cfg -and $cfg.IPv4DefaultGateway) { $hasGateway = $true }

        $ssid = $null
        if ($type -eq 'WiFi' -and $a.Status -eq 'Up') {
            $profile = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
            if ($profile) { $ssid = [string]$profile.Name }
        }

        # 判定顺序即“从最外层到最内层”的诊断顺序
        $reason = Get-CampusAdapterRejectReason -Description $a.InterfaceDescription -Type $type `
            -Status ([string]$a.Status) -IP $(if ($ip) { $ip } else { '' })

        $report += [pscustomobject]@{
            Name                 = $a.Name
            IfIndex              = $a.ifIndex
            Description          = $a.InterfaceDescription
            Type                 = $type
            Status               = [string]$a.Status
            MediaConnectionState = [string]$a.MediaConnectionState
            IP                   = $ip
            IsApipa              = $isApipa
            HasGateway           = $hasGateway
            SSID                 = $ssid
            MAC                  = (($a.MacAddress -replace '[-:]', '')).ToUpper()
            Usable               = [string]::IsNullOrEmpty($reason)
            Reason               = $reason
            IsWired              = ($type -ne 'WiFi')
            IsVirtual            = ($a.InterfaceDescription -match $virtualPattern)
        }
    }

    return @($report)
}

# ------------------------------------------------------------
# Get-CampusAdapter —— 挑一张“能用来登录”的网卡
#   入参：无（内部调 Get-CampusAdapterReport 拿到体检表）
#   返回：单个网卡对象（含 Name/IfIndex/IP/MAC/Gateway/Type/SSID 等）；
#         一张可用的都没有则返回 $null（调用方需按“没有可用网卡”处理）
#   挑选顺序：① 先按路由选中“实际在上网”的那张（Select-CampusAdapterByRoute）
#             ② 否则优先有线，再无线；③ 能上网的优先于不能上网的
#   调用方：CampusNet_Login.ps1、Invoke-CampusSilentLogin、-Diagnose/-Repair
#   坑：不要在这里静默丢弃网卡——排障要靠 Get-CampusAdapterReport 的 Reason
# ------------------------------------------------------------
function Get-CampusAdapter {
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$LogFile,
        [switch]$Quiet
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    # 全量体检后再挑候选：每张网卡都能说出“不能用是为什么”
    $report = @(Get-CampusAdapterReport)
    $candidates = @($report | Where-Object { $_.Usable })

    if ($candidates.Count -eq 0) {
        if (-not $Quiet) {
            if ($report.Count -eq 0) {
                Write-CampusLog -Message '未找到已连接的网络适配器' -Level ERROR -LogFile $LogFile
            }
            else {
                Write-CampusLog -Message '未找到具有有效 IPv4 地址的可用适配器。各网卡情况：' -Level ERROR -LogFile $LogFile
                foreach ($r in $report) {
                    $shown = if ($r.IP) { $r.IP } else { '(无)' }
                    Write-CampusLog -Message ("  · {0} [{1}] 状态={2} IP={3} → {4}" -f $r.Name, $r.Type, $r.Status, $shown, $r.Reason) -Level WARNING -LogFile $LogFile
                }
                Write-CampusLog -Message '提示：网卡只有 169.254.x.x（APIPA）表示没拿到 DHCP 租约，跑 `CampusNet_Login.ps1 -Repair` 通常可免重启恢复。' -Level INFO -LogFile $LogFile
            }
        }
        return $null
    }

    # 首选：去往门户服务器实际会走哪张网卡（多网卡 / 插扩展坞时最可靠）
    #   比“优先有线”更准：插着网线但网线不通、或 WiFi 才是在校园网里的，都能选对
    $preferredIp = $null
    $portalHost = [string]$Settings.PortalHost
    if (-not [string]::IsNullOrWhiteSpace($portalHost)) {
        try {
            $route = Find-NetRoute -RemoteIPAddress $portalHost -ErrorAction Stop |
                Where-Object { $_.IPAddress -match '^\d+\.' } |
                Select-Object -First 1
            if ($route) { $preferredIp = [string]$route.IPAddress }
        }
        catch { }
    }

    if ($preferredIp) {
        $byRoute = Select-CampusAdapterByRoute -Candidates $candidates -RouteSourceIp $preferredIp
        if ($byRoute) {
            Write-CampusLog -Message "按路由选网卡：去往门户 $portalHost 走的源 IP 是 $preferredIp → $($byRoute.Name) [$($byRoute.Type)]" -Level INFO -LogFile $LogFile
            return $byRoute
        }
        Write-CampusLog -Message "去往门户 $portalHost 的源 IP($preferredIp) 不在候选网卡里，回退到“有网关 + 有线优先”" -Level WARNING -LogFile $LogFile
    }

    $selected = $candidates |
        Sort-Object @{ Expression = 'HasGateway'; Descending = $true },
                    @{ Expression = 'IsWired'; Descending = $true } |
        Select-Object -First 1

    if (-not $Quiet) {
        Write-CampusLog -Message "按优先级选网卡：$($selected.Name) [$($selected.Type)] IP=$($selected.IP)" -Level INFO -LogFile $LogFile
    }
    return $selected
}

# ------------------------------------------------------------
# Get-CampusRepairPlan —— 纯函数：根据体检结果算出“需要修哪些网卡”
#   入参：$Report Get-CampusAdapterReport 的结果
#   返回：需要修复的网卡对象数组（空数组 = 不用修）
#   需要修的 = 非虚拟 && 链路 Up && (拿到 APIPA / 没 IP / 有 IP 但没网关)
#   已断开(Disconnected)的网卡即使残留 APIPA 也不算——它没在用，
#   去 renew 只会白等（这是真实踩过的坑，并有回归测试锁定）
#   调用方：Invoke-CampusNetworkRepair、-Repair 的 DryRun 预览
# ------------------------------------------------------------
function Get-CampusRepairPlan {
    param([object[]]$Report)

    if (-not $Report) { return @() }
    return @($Report | Where-Object {
            (-not $_.IsVirtual) -and
            ($_.Status -eq 'Up') -and (
                $_.IsApipa -or
                (-not $_.IP) -or
                ($_.Usable -and -not $_.HasGateway)
            )
        })
}

# 用 CIM 重拿 DHCP 租约（不经过外部命令，避免中文网卡名的编码问题）
function Invoke-CampusDhcpRenew {
    param([Parameter(Mandatory)][int]$IfIndex)

    $q = "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE InterfaceIndex=$IfIndex"
    try { Invoke-CimMethod -Query $q -MethodName ReleaseDHCPLease -ErrorAction SilentlyContinue | Out-Null } catch { }
    Start-Sleep -Milliseconds 600
    try { Invoke-CimMethod -Query $q -MethodName RenewDHCPLease -ErrorAction SilentlyContinue | Out-Null } catch { }
}

# ------------------------------------------------------------
# ------------------------------------------------------------
# Invoke-CampusNetworkRepair —— 免重启网络修复（“重启一次就好”的自动化）
#   把重启能恢复的事按顺序做一遍：
#     1) 清 DNS 缓存（+ 管理员时清 ARP/邻居缓存）
#     2) 对目标网卡 release + renew，重拿 DHCP 租约
#     3) 仍只有 APIPA 时重启网卡（等价于重启后重新初始化驱动），再 renew
#   入参：$Report 体检结果（可选，不传自己取）；$DryRun 只预览；$LogFile 日志
#   返回：$true = 已修好或无需修；$false = 修完仍未恢复（调用方映射为退出码 5）
#   全部动作写日志；没有管理员权限时只做 1+2 并明确提示需要管理员
#   调用方：菜单 6、-Repair
# ------------------------------------------------------------
function Invoke-CampusNetworkRepair {
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$LogFile,
        [switch]$DryRun
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    $isAdmin = Test-CampusIsAdmin
    Write-CampusLog -Message ("网络修复开始（管理员={0}{1}）" -f $isAdmin, $(if ($DryRun) { '，DryRun' } else { '' })) -Level INFO -LogFile $LogFile

    $report = @(Get-CampusAdapterReport)
    if ($report.Count -eq 0) {
        Write-CampusLog -Message '没找到任何物理网卡，无法修复。' -Level ERROR -LogFile $LogFile
        return $false
    }

    Write-CampusLog -Message '网卡体检：' -Level INFO -LogFile $LogFile
    foreach ($r in $report) {
        $shown = if ($r.IP) { $r.IP } else { '(无)' }
        $tail = if ($r.Usable) { '可用' } else { '→ ' + $r.Reason }
        Write-CampusLog -Message ("  · {0} [{1}] 状态={2} IP={3} 网关={4} {5}" -f $r.Name, $r.Type, $r.Status, $shown, $r.HasGateway, $tail) -Level INFO -LogFile $LogFile
    }

    $targets = @(Get-CampusRepairPlan -Report $report)
    if ($targets.Count -eq 0) {
        if (@($report | Where-Object { $_.Usable }).Count -gt 0) {
            Write-CampusLog -Message '没有需要修复的物理网卡：已经有一张网卡拿到了有效 IPv4 与网关。' -Level SUCCESS -LogFile $LogFile
            return $true
        }
        Write-CampusLog -Message '没有可修复的物理网卡（网卡都没在用，或都是虚拟链路）。' -Level WARNING -LogFile $LogFile
        return $false
    }

    # DryRun 必须是纯空操作：连清缓存也不能做（它也是“改动”）
    if ($DryRun) {
        foreach ($t in $targets) {
            Write-CampusLog -Message ("  [DryRun] 将修复「{0}」：Release/Renew DHCP（IfIndex={1}）{2}" -f $t.Name, $t.IfIndex, $(if ($isAdmin) { ' + 必要时重启网卡' } else { '（无管理员权限，跳过重启网卡）' })) -Level INFO -LogFile $LogFile
        }
        Write-CampusLog -Message '（DryRun：以上仅为计划，未做任何改动）' -Level INFO -LogFile $LogFile
        return $true
    }

    # --- 1) 清缓存 ---
    # DNS 清理是独立功能（-FlushDns / 菜单），默认不在修复里顺手执行；
    # 想要“修复时顺便清一下”就把配置 Settings.FlushDnsOnRepair 设为 1
    if (Test-CampusShouldFlushDnsOnRepair -Settings $Settings) {
        Clear-CampusDnsCache -LogFile $LogFile | Out-Null
    }
    else {
        Write-CampusLog -Message '已跳过 DNS 缓存清理（独立功能：需要时用 -FlushDns，或把 Settings.FlushDnsOnRepair 设为 1）' -Level INFO -LogFile $LogFile
    }
    if ($isAdmin) {
        & netsh interface ip delete arpcache 2>$null | Out-Null
        Write-CampusLog -Message '已清空 ARP/邻居缓存' -Level INFO -LogFile $LogFile
    }
    else {
        Write-CampusLog -Message '非管理员：跳过 ARP 缓存清理（不影响主流程）' -Level WARNING -LogFile $LogFile
    }

    $fixed = $false
    foreach ($t in $targets) {
        Write-CampusLog -Message ("修复网卡「{0}」..." -f $t.Name) -Level INFO -LogFile $LogFile

        Invoke-CampusDhcpRenew -IfIndex $t.IfIndex
        Start-Sleep -Seconds 3

        $after = @(Get-CampusAdapterReport) | Where-Object { $_.Name -eq $t.Name } | Select-Object -First 1
        if ($after -and $after.Usable) {
            Write-CampusLog -Message ("  「{0}」已恢复：IP={1} 网关={2}" -f $t.Name, $after.IP, $after.HasGateway) -Level SUCCESS -LogFile $LogFile
            $fixed = $true
            continue
        }

        # 仍然没有租约 → 重启网卡（等价于“重启电脑后网卡重新初始化”）
        if ($isAdmin) {
            Write-CampusLog -Message ("  「{0}」仍未拿到租约，正在重启网卡（约 10 秒）..." -f $t.Name) -Level WARNING -LogFile $LogFile
            try {
                Restart-NetAdapter -Name $t.Name -Confirm:$false -ErrorAction Stop
            }
            catch {
                Write-CampusLog -Message ("  重启网卡失败：{0}" -f $_.Exception.Message) -Level WARNING -LogFile $LogFile
            }
            Start-Sleep -Seconds 5
            Invoke-CampusDhcpRenew -IfIndex $t.IfIndex
            Start-Sleep -Seconds 3

            $after2 = @(Get-CampusAdapterReport) | Where-Object { $_.Name -eq $t.Name } | Select-Object -First 1
            if ($after2 -and $after2.Usable) {
                Write-CampusLog -Message ("  「{0}」重启网卡后已恢复：IP={1} 网关={2}" -f $t.Name, $after2.IP, $after2.HasGateway) -Level SUCCESS -LogFile $LogFile
                $fixed = $true
            }
            else {
                Write-CampusLog -Message ("  「{0}」重启网卡后仍未拿到 IPv4。这通常不是本机问题，而是网络侧没放行 DHCP（端口/MAC 绑定、需重新认证，或该口不在校园网）。建议：换一个网口 / 稍等几分钟 / 找网络中心。" -f $t.Name) -Level ERROR -LogFile $LogFile
            }
        }
        else {
            Write-CampusLog -Message ("  「{0}」仍未拿到 IPv4。重启网卡需要管理员权限：请右键 `CampusNet.bat` → 以管理员身份运行，再跑一次 -Repair。" -f $t.Name) -Level WARNING -LogFile $LogFile
        }
    }

    if ($fixed) { Write-CampusLog -Message '网络修复完成：已至少恢复一张网卡。' -Level SUCCESS -LogFile $LogFile }
    else { Write-CampusLog -Message '网络修复结束：仍未恢复可用 IPv4。' -Level ERROR -LogFile $LogFile }
    return $fixed
}

# ------------------------------------------------------------
# DNS 缓存清理：独立功能（不挂在 -Repair 的点击流程里，需显式调用）
#   返回 @{ Ok; Before; After; Reason }
# ------------------------------------------------------------
function Get-CampusDnsCacheCount {
    try { return @(Get-DnsClientCache -ErrorAction Stop).Count }
    catch { return -1 }
}

# 纯函数：-Repair 要不要顺带清 DNS（默认不清，避免“点一下就顺手改系统”）
function Test-CampusShouldFlushDnsOnRepair {
    param([System.Collections.IDictionary]$Settings)
    return (Test-CampusSettingEnabled -Settings $Settings -Key 'FlushDnsOnRepair' -Default $false)
}

# ------------------------------------------------------------
# ﻿Clear-CampusDnsCache —— 清空本机 DNS 客户端缓存（独立功能，不需管理员）
#   入参：$DryRun 只预览不执行；$LogFile 日志
#   返回：[pscustomobject] @{ Ok; Before; After; Reason }
#         Ok=$true 表示指令已执行（$DryRun 时也返回 Ok=$true，Reason='DryRun'）
#   背景：这是从“修网”里拆出来的独立能力——很多“域名解析不对”的场景
#         只需要清 DNS，不必动 DHCP；菜单 7 / -FlushDns 直接调它
#   调用方：菜单 7、-FlushDns、Invoke-CampusNetworkRepair（仅当配置开启时）
#   坑：本机读不到缓存条数（Get-DnsClientCache 恒为 0），所以 Before/After 只是参考值，
#       不得当成“清了几条”的结论
# ------------------------------------------------------------
function Clear-CampusDnsCache {
    param(
        [string]$LogFile,
        [switch]$DryRun
    )

    $before = Get-CampusDnsCacheCount
    $result = [pscustomobject]@{
        Ok     = $false
        Before = $before
        After  = $before
        Reason = ''
    }
    $beforeText = if ($before -ge 0) { "$before" } else { '未知' }

    if ($DryRun) {
        Write-CampusLog -Message "[DryRun] 将执行 DNS 客户端缓存清理（当前读到的条数：$beforeText），不实际执行" -Level INFO -LogFile $LogFile
        $result.Ok = $true
        $result.Reason = 'DryRun'
        return $result
    }

    try {
        Clear-DnsClientCache -ErrorAction Stop
    }
    catch {
        $result.Reason = "DNS 缓存清理失败：$($_.Exception.Message)"
        if (-not (Test-CampusIsAdmin)) {
            $result.Reason += ' —— 该操作需要管理员权限：请右键 CampusNet.bat → 以管理员身份运行'
        }
        Write-CampusLog -Message $result.Reason -Level ERROR -LogFile $LogFile
        return $result
    }

    # 缓存条数可能很快被系统重建，所以只作为“参考信息”展示，不作为成败判据
    $result.After = Get-CampusDnsCacheCount
    $result.Ok = $true
    $afterText = if ($result.After -ge 0) { "$($result.After)" } else { '未知' }
    if ($before -ge 1 -or $result.After -ge 1) {
        Write-CampusLog -Message "DNS 客户端缓存已清理（清理前 $beforeText 条 → 清理后 $afterText 条）" -Level SUCCESS -LogFile $LogFile
    }
    else {
        Write-CampusLog -Message "DNS 客户端缓存清理指令已执行（本机读不到缓存条数：Get-DnsClientCache 返回 $beforeText 条）" -Level SUCCESS -LogFile $LogFile
    }
    return $result
}

# ------------------------------------------------------------
# New-DrappallLoginUrl —— 构造哆点 v4 登录 URL（当前校园网的主路径）
#   入参：$PortalHost/$Port 门户地址（当前为 10.0.10.252:803）
#         $Account/$Password 凭证
#         $IP/$MAC 登录端点（来自 Get-LoginEndpoint；MAC 会自动去横线并大写）
#         $Settings 配置集合
#         $ProgramIndex/$PageIndex 来自 Get-DrappallPageIndex（取不到就传空字符串）
#         $UserAgent/$Callback 可覆盖
#   返回：完整 URL 字符串
#   形态：GET http://<host>:<port>/eportal/portal/login?<encoded...>&encrypt=1&v=<4位随机>&lang=zh
#         $fields 里的**每个值**都做 XOR 混淆（key = Get-DrappallKey -IP $IP）；
#         尾部 encrypt/v/lang 不参与混淆；空值保留 “key=” 形式
#   调用方：Send-CampusLoginRequest、Invoke-TestLogin（-TestLogin）
#   坑：$IP 必须与实际请求里的 wlan_user_ip 一致，否则 key 不对 → 403；
#       参数顺序按真实抓包排列，改顺序前先确认门户不敏感
# ------------------------------------------------------------
function New-DrappallLoginUrl {
    param(
        [Parameter(Mandatory)][string]$PortalHost,
        [int]$Port = 803,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$MAC,
        [System.Collections.IDictionary]$Settings,
        [string]$ProgramIndex = '',
        [string]$PageIndex = '',
        [string]$UserAgent = '',
        [string]$Callback = 'dr1003'
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }
    if (-not $UserAgent) {
        $UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    # 顺序与抓包一致；空字符串保持为空（与门户行为一致）
    $fields = [ordered]@{
        callback        = $Callback
        login_method    = '1'
        is_base64encode = '0'
        user_account    = ",0,$Account"
        user_password   = $Password
        wlan_user_ip    = $IP
        wlan_user_ipv6  = ''
        wlan_user_mac   = (($MAC -replace '[-:]', '').ToUpper())
        wlan_vlan_id    = '0'
        wlan_ac_ip      = [string]$Settings.WlanAcIp
        wlan_ac_name    = [string]$Settings.WlanAcName
        authex_enable   = ''
        jsVersion       = [string]$Settings.JsVersion
        uuid            = ''
        terminal_type   = '1'
        lang            = 'zh-cn'
        user_agent      = $UserAgent
        enable_r3       = '0'
        mac_type        = '0'
        rcn             = ''
        operate         = 'portal_login'
        business_type   = '1'
        program_index   = $ProgramIndex
        page_index      = $PageIndex
    }

    # XOR key 由客户端 IP 推导（与门户 JS util.getkey 一致），不是固定值
    $xorKey = Get-DrappallKey -IP $IP

    $pairs = foreach ($k in $fields.Keys) {
        "$k=$(ConvertTo-DrappallValue -Text ([string]$fields[$k]) -Key $xorKey)"
    }
    $v = Get-Random -Minimum 1000 -Maximum 9999

    return "http://${PortalHost}:${Port}/eportal/portal/login?" + (($pairs -join '&') + "&encrypt=1&v=$v&lang=zh")
}

# 哆点 v4 请求要带的 Referer（抓包中为门户根地址，端口 80）
function Get-DrappallReferer {
    param([Parameter(Mandatory)][string]$PortalHost)
    return "http://${PortalHost}/"
}

# ------------------------------------------------------------
# 构造 page/loadConfig URL
#   注意：该接口用的是「URL 编码的 base64」，而不是 XOR 混淆（与 portal/login 不同）
# ------------------------------------------------------------
function New-DrappallLoadConfigUrl {
    param(
        [Parameter(Mandatory)][string]$PortalHost,
        [int]$Port = 803,
        [Parameter(Mandatory)][AllowEmptyString()][string]$IP,
        [string]$AcIp = '',
        [string]$Callback = 'dr1001',
        [string]$JsVersion = '4.X'
    )

    $toB64 = {
        param([string]$s)
        return [uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$s)))
    }

    $pairs = [ordered]@{
        callback         = $Callback
        program_index    = ''
        wlan_vlan_id     = '0'
        wlan_user_ip     = (& $toB64 $IP)
        wlan_user_ipv6   = ''
        wlan_user_ssid   = ''
        wlan_user_areaid = ''
        wlan_ac_ip       = (& $toB64 $AcIp)
        wlan_ap_mac      = '000000000000'
        gw_id            = '000000000000'
        page_index       = ''
        jsVersion        = $JsVersion
    }

    $query = ($pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
    $v = Get-Random -Minimum 1000 -Maximum 9999
    return "http://${PortalHost}:${Port}/eportal/portal/page/loadConfig?" + ($query + "&v=$v&lang=zh")
}

# ------------------------------------------------------------
# 取 program_index / page_index（登录请求需要带上；取不到就留空继续）
# ------------------------------------------------------------
function Get-DrappallPageIndex {
    param(
        [Parameter(Mandatory)][string]$PortalHost,
        [int]$Port = 803,
        [Parameter(Mandatory)][string]$IP,
        [string]$AcIp = '',
        [int]$TimeoutSec = 8,
        [string]$LogFile
    )

    $result = [pscustomobject]@{ Ok = $false; ProgramIndex = ''; PageIndex = ''; PageName = ''; Raw = '' }

    $url = New-DrappallLoadConfigUrl -PortalHost $PortalHost -Port $Port -IP $IP -AcIp $AcIp
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing `
            -Headers @{ Referer = (Get-DrappallReferer -PortalHost $PortalHost) } -ErrorAction Stop
        $result.Raw = [string]$resp.Content

        if ($result.Raw -match '"program_index"\s*:\s*"([^"]*)"') { $result.ProgramIndex = $matches[1] }
        if ($result.Raw -match '"page_index"\s*:\s*"([^"]*)"') { $result.PageIndex = $matches[1] }
        if ($result.Raw -match '"page_name"\s*:\s*"([^"]*)"') { $result.PageName = $matches[1] }

        $result.Ok = -not [string]::IsNullOrEmpty($result.ProgramIndex)
        if ($result.Ok) {
            Write-CampusLog -Message "loadConfig 成功：program_index=$($result.ProgramIndex) page_index=$($result.PageIndex) page_name=$($result.PageName)" -Level INFO -LogFile $LogFile
        }
        else {
            Write-CampusLog -Message 'loadConfig 响应里没有 program_index（继续用空值尝试登录）' -Level WARNING -LogFile $LogFile
        }
    }
    catch {
        Write-CampusLog -Message "loadConfig 请求失败：$($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }
    return $result
}

# ------------------------------------------------------------
# 构造登录 URL（account / password 等全部 URL 编码）
# ------------------------------------------------------------
function New-CampusLoginUrl {
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$MAC,
        [System.Collections.IDictionary]$Settings
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }

    $base = [string]$Settings.BaseURL
    if (-not $base.EndsWith('/')) { $base += '/' }

    $pairs = [ordered]@{
        c              = 'Portal'
        a              = 'login'
        callback       = [string]$Settings.Callback
        login_method   = [string]$Settings.LoginMethod
        user_account   = [uri]::EscapeDataString(",0,$Account")
        user_password  = [uri]::EscapeDataString($Password)
        wlan_user_ip   = [uri]::EscapeDataString($IP)
        wlan_user_ipv6 = ''
        wlan_user_mac  = [uri]::EscapeDataString($MAC)
        wlan_ac_ip     = [uri]::EscapeDataString([string]$Settings.WlanAcIp)
        wlan_ac_name   = [uri]::EscapeDataString([string]$Settings.WlanAcName)
        jsVersion      = [uri]::EscapeDataString([string]$Settings.JsVersion)
        v              = [uri]::EscapeDataString([string]$Settings.PortalVersion)
    }

    $query = ($pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&'
    return "${base}?${query}"
}

# ------------------------------------------------------------
# ConvertFrom-PortalResponse —— 解析门户响应
#   入参：$Content 原始响应文本（可能是纯 JSON，也可能是 JSONP：dr1003({...})）
#   返回：[pscustomobject] @{ Success; Recognized; ErrorCode; Message; Raw; Preview }
#         正则刻意写得宽松：兼容带/不带引号的 result / ret_code / msg，
#         因为不同门户版本的响应格式并不统一
#   判定：result=1 或（无 result 且 ret_code=0）或 msg 含“认证成功” → Success
#         Recognized = 是否解析出了 result/ret_code（没解析出来说明响应不属于这一套）
#   调用方：Send-CampusLoginRequest
#   坑：不要把 Success 当作“能上网”，它只说明门户这一层认可了
# ------------------------------------------------------------
function ConvertFrom-PortalResponse {
    param([AllowEmptyString()][string]$Content)

    $result = [pscustomobject]@{
        Success    = $false
        Recognized = $false
        ErrorCode  = -1
        Message    = ''
        Raw        = [string]$Content
        Preview    = ''
    }
    $result.Preview = Get-TextPreview -Text ([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $result }

    $resultCode = $null
    if ($Content -match '"result"\s*:\s*"?(\d+)"?') { $resultCode = [int]$matches[1] }

    $retCode = $null
    if ($Content -match '"?ret_code"?\s*:\s*"?(-?\d+)"?') { $retCode = [int]$matches[1] }

    $msg = ''
    if ($Content -match '"?msg"?\s*:\s*"([^"]*)"') { $msg = $matches[1] }

    # 能认出 result / ret_code 才算“可识别的 portal 响应”
    if ($null -ne $resultCode -or $null -ne $retCode) { $result.Recognized = $true }

    $isSuccess = $false
    if ($resultCode -eq 1) { $isSuccess = $true }
    elseif ($null -eq $resultCode -and $retCode -eq 0) { $isSuccess = $true }
    # 哆点 v4 成功报文：{"result":1,"msg":"Portal协议认证成功！"}
    #   仅在没有任何显式 result/ret_code 时才用它兜底，并且要求是整句开头，
    #   否则“认证成功前需先下线其他设备”这类失败报文会被误判成成功
    if ($null -eq $resultCode -and $null -eq $retCode -and $msg -match '^\s*Portal协议认证成功') { $isSuccess = $true }

    if ($isSuccess) {
        $result.Success = $true
        $result.ErrorCode = 0
        $result.Message = if ($msg) { $msg } else { '登录成功' }
    }
    else {
        if ($null -ne $retCode) { $result.ErrorCode = $retCode }
        elseif ($null -ne $resultCode) { $result.ErrorCode = $resultCode }
        if ($result.Recognized) {
            $result.Message = if ($msg) { $msg } else { (Get-PortalErrorText -Code $result.ErrorCode) }
        }
        else {
            $result.Message = 'portal 响应不可识别（可能未连校园网 / 门户地址不对 / 被重定向）'
        }
    }
    return $result
}

# ------------------------------------------------------------
# Send-CampusLoginRequest —— 发登录请求（协议策略链 + 超时/重试/退避）
#   入参：$Account/$Password 凭证；$IP/$MAC 登录端点（见 Get-LoginEndpoint）
#         $Settings 配置集合；$MaxAttempts/$TimeoutSec/$RetryDelaySec 重试策略
#         $Protocol auto|drappall|legacy 限定协议（排障用）；$LogFile 日志
#   返回：[pscustomobject] @{ Success; Recognized; ErrorCode; Message; Raw; Preview }
#         · Success 只代表“协议层成功”，**能否上网由调用方再跑 Wait-CampusInternet 决定**
#         · Recognized=$false 表示响应不是预期的 JSON/JSONP（多半接口形态不对）
#   流程：① 先取 program_index/page_index（loadConfig，失败就留空继续）
#         ② 按 $Protocol 顺序尝试：drappall(:803 portal/login) → legacy(:801 ?c=Portal&a=login)
#         ③ 凭证类错误(1/2/3/4/8/11)立即返回；响应不可识别或 403(key 错) → 换下一种协议
#         ④ 其余情况按 RetryDelaySec × 已试次数 线性退避重试
#   调用方：Invoke-CampusSilentLogin、Invoke-TestLogin、菜单 1/2
#   坑：打日志的 URL 必须过 Get-MaskedUrl，否则明文密码进日志
# ------------------------------------------------------------
function Send-CampusLoginRequest {
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$MAC,
        [System.Collections.IDictionary]$Settings,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 10,
        [int]$RetryDelaySec = 3,
        [ValidateSet('auto', 'drappall', 'legacy')][string]$Protocol = 'auto',
        [string]$LogFile
    )

    if (-not $Settings) { $Settings = Get-DefaultSettings }
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }

    # ---- 协议策略链：先试哆点 v4（本校园网实际使用），失败再回退旧 801 接口 ----
    $strategies = @()
    if ($Protocol -in @('auto', 'drappall')) { $strategies += 'drappall' }
    if ($Protocol -in @('auto', 'legacy')) { $strategies += 'legacy' }

    # 哆点 v4 登录需要先拿 program_index / page_index（取不到就留空继续）
    $programIndex = ''; $pageIndex = ''
    if ($strategies -contains 'drappall') {
        $pageInfo = Get-DrappallPageIndex -PortalHost ([string]$Settings.PortalHost) -Port ([int]$Settings.PortalPort) `
            -IP $IP -AcIp ([string]$Settings.WlanAcIp) -TimeoutSec $TimeoutSec -LogFile $LogFile
        if ($pageInfo.Ok) { $programIndex = $pageInfo.ProgramIndex; $pageIndex = $pageInfo.PageIndex }
    }

    $lastResult = $null

    foreach ($mode in $strategies) {
        if ($mode -eq 'drappall') {
            $url = New-DrappallLoginUrl -PortalHost ([string]$Settings.PortalHost) -Port ([int]$Settings.PortalPort) `
                -Account $Account -Password $Password -IP $IP -MAC $MAC -Settings $Settings `
                -ProgramIndex $programIndex -PageIndex $pageIndex
            $headers = @{ Referer = (Get-DrappallReferer -PortalHost ([string]$Settings.PortalHost)) }
        }
        else {
            $url = New-CampusLoginUrl -Account $Account -Password $Password -IP $IP -MAC $MAC -Settings $Settings
            $headers = @{ }
        }

        Write-CampusLog -Message "[$mode] 登录 URL: $(Get-MaskedUrl -Url $url)" -Level DEBUG -LogFile $LogFile

        $attempt = 0
        while ($attempt -lt $MaxAttempts) {
            $attempt++
            try {
                $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing `
                    -MaximumRedirection 2 -Headers $headers -ErrorAction Stop
                $parsed = ConvertFrom-PortalResponse -Content $resp.Content
                $lastResult = $parsed

                if ($parsed.Success) {
                    Write-CampusLog -Message "[$mode] 登录成功（第 $attempt 次尝试）：$($parsed.Message)" -Level SUCCESS -LogFile $LogFile
                    return $parsed
                }

                if (-not $parsed.Recognized) {
                    Write-CampusLog -Message "[$mode] portal 响应不可识别（HTTP 200）。原始响应预览：$($parsed.Preview)" -Level WARNING -LogFile $LogFile
                    break
                }
                # 403「请求参数包含非法内容」= 参数形态/key 不对（真实踩过：key 写死）
                # 重试同一形态没意义，直接换下一种协议
                if (($parsed.Raw -match '"code"\s*:\s*403') -or ($parsed.Message -match '非法内容')) {
                    Write-CampusLog -Message "[$mode] 门户判定请求参数非法（$($parsed.Message)）——XOR key 或参数形态不对，改走下一策略" -Level WARNING -LogFile $LogFile
                    break
                }
                if ($parsed.ErrorCode -in @(1, 2, 3, 4, 8, 11)) {
                    Write-CampusLog -Message "[$mode] 登录失败：$(Get-PortalErrorText -Code $parsed.ErrorCode -Message $parsed.Message)（ret_code=$($parsed.ErrorCode)）" -Level ERROR -LogFile $LogFile
                    return $parsed
                }
                Write-CampusLog -Message "[$mode] 登录未成功（第 $attempt/$MaxAttempts 次）：$(Get-PortalErrorText -Code $parsed.ErrorCode -Message $parsed.Message)" -Level WARNING -LogFile $LogFile
            }
            catch {
                $status = $null; $body = $null
                try {
                    $webResp = $_.Exception.Response
                    if ($webResp) {
                        $status = [int]$webResp.StatusCode
                        try {
                            $st = $webResp.GetResponseStream()
                            if ($st) { $body = (New-Object System.IO.StreamReader($st)).ReadToEnd() }
                        }
                        catch { }
                    }
                }
                catch { }

                if ($status) {
                    $preview = Get-TextPreview -Text $body
                    Write-CampusLog -Message "[$mode] portal 拒绝登录请求：HTTP $status。响应预览：$preview" -Level ERROR -LogFile $LogFile
                    $lastResult = [pscustomobject]@{
                        Success    = $false
                        Recognized = $false
                        ErrorCode  = -1
                        Message    = "portal 返回 HTTP $status"
                        Raw        = $body
                        Preview    = $preview
                    }
                    break
                }

                # 异常信息里可能带上完整请求 URI（含 user_password / user_account），
                # 所以同样过一遍 脱敏（Get-MaskedUrl 本身就是正则替换，对任意文本都适用）
                Write-CampusLog -Message "[$mode] 登录请求异常（第 $attempt/$MaxAttempts 次）：$(Get-MaskedUrl -Url $_.Exception.Message)" -Level WARNING -LogFile $LogFile
            }

            if ($attempt -lt $MaxAttempts) {
                $delay = $RetryDelaySec * $attempt
                Write-CampusLog -Message "等待 ${delay}s 后退避重试..." -Level INFO -LogFile $LogFile
                Start-Sleep -Seconds $delay
            }
        }
    }

    if (-not $lastResult) {
        $lastResult = [pscustomobject]@{
            Success    = $false
            Recognized = $false
            ErrorCode  = -1
            Message    = '网络异常，未取得服务器响应'
            Raw        = ''
            Preview    = '(空)'
        }
    }
    return $lastResult
}

# ------------------------------------------------------------
# Invoke-CampusSilentLogin —— 静默登录（供 CampusNet_Silent.ps1 与 -Silent 共用）
#   入参：$ConfigFile 配置文件路径；$LogFile 日志
#   返回（退出码，与 README 一致）：
#     0 成功/已在线　1 无配置　2 配置解析/解密失败　3 无可用网卡　4 登录失败（含“伪登录”）
#   特点：**全程不弹窗、不等按键、不开浏览器**——基本用于计划任务/开机自启
#   流程：Load-CampusConfig → Get-CampusAdapter → Wait-CampusInternet（已在线就直接 0）
#         → Get-LoginEndpoint → Send-CampusLoginRequest → Wait-CampusInternet（底线）
#   调用方：CampusNet_Silent.ps1、CampusNet_Login.ps1 -Silent
# ------------------------------------------------------------
function Invoke-CampusSilentLogin {
    param(
        [Parameter(Mandatory)][string]$ConfigFile,
        [string]$LogFile,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 10,
        [int]$VerifyTimeoutSec = 15,
        [int]$AdapterWaitSec = 0,
        [switch]$Watch
    )

    do {
        $config = Load-CampusConfig -ConfigFile $ConfigFile -LogFile $LogFile
        if (-not $config) {
            # 1 = 没配置；2 = 配置坏了（解析/解密失败、字段缺失）
            if ($script:LastConfigLoadError -eq 'corrupt') { return 2 }
            return 1
        }

        if (Test-CampusInternet) {
            Write-CampusLog -Message '当前已联网，无需登录' -Level SUCCESS -LogFile $LogFile
            return 0
        }

        $adapter = Get-CampusAdapter -Settings $config.Settings -LogFile $LogFile
        if (-not $adapter -and $AdapterWaitSec -gt 0) {
            # 开机瞬间网卡可能还没拿到 DHCP 地址：等一会儿再试，别直接判“没有网卡”
            Write-CampusLog -Message "暂时没有可用网卡，等待网卡就绪（最多 $AdapterWaitSec 秒）..." -Level INFO -LogFile $LogFile
            $adapterDeadline = (Get-Date).AddSeconds($AdapterWaitSec)
            while ((Get-Date) -lt $adapterDeadline) {
                Start-Sleep -Seconds 5
                if (Test-CampusInternet) {
                    Write-CampusLog -Message '等待期间已联网，无需登录' -Level SUCCESS -LogFile $LogFile
                    return 0
                }
                $adapter = Get-CampusAdapter -Settings $config.Settings -LogFile $LogFile -Quiet
                if ($adapter) { break }
            }
        }
        if (-not $adapter) { return 3 }
        Write-CampusLog -Message "使用网卡：$($adapter.Name) [$($adapter.Type)] IP=$($adapter.IP) MAC=$($adapter.MAC)" -Level INFO -LogFile $LogFile

        if ($adapter.Type -eq 'WiFi' -and -not $adapter.SSID) {
            # 拿不到 SSID 不代表没连上（部分系统/驱动查不到 ConnectionProfile），
            # 所以只提醒不拦下；后续门户探针拿到的 IP/MAC 才是准的
            Write-CampusLog -Message '无线网卡查不到当前 SSID（不一定代表没连上），继续尝试登录' -Level WARNING -LogFile $LogFile
        }

        # 未认证时先自动发现真实 portal / AC 参数，并以门户看到的 IP/MAC 为准
        $endpoint = Get-LoginEndpoint -Adapter $adapter -Settings $config.Settings -LogFile $LogFile
        $disc = $endpoint.Discovered
        if ($disc.Changed) {
            Save-CampusConfig -ConfigFile $ConfigFile -Account $config.Account -Password $config.Password -Settings $disc.Settings -LogFile $LogFile | Out-Null
        }

        $res = Send-CampusLoginRequest -Account $config.Account -Password $config.Password `
            -IP $endpoint.IP -MAC $endpoint.MAC -Settings $config.Settings `
            -MaxAttempts $MaxAttempts -TimeoutSec $TimeoutSec -RetryDelaySec 3 -LogFile $LogFile

        if ($res.Success) {
            Write-CampusLog -Message '登录接口返回成功，正在确认是否真正联网...' -Level INFO -LogFile $LogFile
            if (Wait-CampusInternet -TimeoutSec $VerifyTimeoutSec) {
                Write-CampusLog -Message '已确认真实联网，登录成功' -Level SUCCESS -LogFile $LogFile
                return 0
            }
            Write-CampusLog -Message '伪登录：登录接口返回成功，但实际仍无法访问互联网。请检查：账号是否被其它设备占用、IP/MAC 是否匹配、是否连错网络。' -Level ERROR -LogFile $LogFile
            return 4
        }
        if ($res.ErrorCode -in @(1, 2, 3, 4, 8, 11)) { return 4 }

        if ($Watch) { Start-Sleep -Seconds 15 }
    } while ($Watch)

    return 4
}
