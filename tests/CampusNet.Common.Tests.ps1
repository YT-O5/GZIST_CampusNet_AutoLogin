<#
  CampusNet.Common.Tests.ps1
  CampusNet.Common.ps1 的最小单元测试。

  运行：
    powershell -NoProfile -File .\tests\Run-Tests.ps1
  或
    Invoke-Pester .\tests\CampusNet.Common.Tests.ps1

  兼容 Windows 自带的 Pester 3.4（也适用于 Pester 4/5 的常见断言）。

  ── 维护须知 ───────────────────────────────────────────────
  · 这里大多是**纯函数**测试，离线可跑、很快（约 2 秒），不依赖真的联网。
  · 需要发请求的用例（Send-CampusLoginRequest 的策略链）用 Mock 掉
    Invoke-WebRequest —— 注意 Mock 必须带上与生产一致的参数形态
    （含 -ErrorAction），否则参数绑定失败会误报。
  · 改协议相关代码后，请优先跑这两类用例：
      - “编解码向量”（用**合成值**断言编解码，能挡住 key/规则写错）
      - “登录 URL 逐字段”（能挡住参数名/顺序/编码改错）
  · 新增用例请放在对应的 Describe 里，命名用中文短句说明"保证什么"。
  · **不要**把真实学号/密码/本机 MAC/IP 写进测试——一律用合成值（如 135790、10.20.30.40）。
    协议向量要改时，请用合成 IP 重新算一遍，**不要**从历史提交里抄回真值。
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path (Split-Path -Parent $here) 'CampusNet_AutoLogin\CampusNet.Common.ps1'
. $modulePath

Describe 'New-CampusLoginUrl' {
    It '对含特殊字符的密码做 URL 编码' {
        $url = New-CampusLoginUrl -Account '2024' -Password 'a&b=c+d#e f中' -IP '10.0.0.2' -MAC 'AABBCCDDEEFF'
        $url | Should Match 'user_password=a%26b%3Dc%2Bd%23e%20f%E4%B8%AD'
        $url | Should Not Match 'user_password=a&b'
    }
    It '账号编码为 %2C0%2C 前缀' {
        (New-CampusLoginUrl -Account 'X&Y' -Password 'p' -IP '1.1.1.1' -MAC 'M') | Should Match 'user_account=%2C0%2CX%26Y'
    }
}

Describe 'ConvertFrom-PortalResponse' {
    It 'JSONP 且 result=1 视为成功' {
        (ConvertFrom-PortalResponse -Content 'dr1003({"result":"1","msg":"ok"})').Success | Should Be $true
    }
    It '带引号的 "ret_code":8 能解析' {
        (ConvertFrom-PortalResponse -Content 'dr1003({"result":"0","ret_code":8})').ErrorCode | Should Be 8
    }
    It '无引号的 ret_code:2 能解析' {
        (ConvertFrom-PortalResponse -Content '{"result":0,ret_code:2}').ErrorCode | Should Be 2
    }
    It '空响应返回 -1' {
        (ConvertFrom-PortalResponse -Content '').ErrorCode | Should Be -1
    }
}

Describe 'DPAPI 密码保护' {
    It '加解密往返一致' {
        $cipher = Protect-CampusPassword -PlainText 'p@ss 中+#'
        (Unprotect-CampusPassword -Cipher $cipher) | Should Be 'p@ss 中+#'
    }
    It '密文不是可逆的 Base64' {
        $cipher = Protect-CampusPassword -PlainText 'secret'
        $cipher | Should Not Be ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('secret')))
    }
}

Describe '配置读写与 Settings 覆盖' {
    It '保存后能读回，且 Settings 覆盖默认值' {
        $tmp = Join-Path $env:TEMP ('cnt_' + [guid]::NewGuid().ToString('N') + '.json')
        $s = Get-DefaultSettings
        $s.BaseURL = 'http://9.9.9.9/x/'
        Save-CampusConfig -ConfigFile $tmp -Account 'u' -Password 'p' -Settings $s -LogFile $null | Out-Null
        $cfg = Load-CampusConfig -ConfigFile $tmp -LogFile $null
        $cfg.Account | Should Be 'u'
        $cfg.Password | Should Be 'p'
        $cfg.Settings.BaseURL | Should Be 'http://9.9.9.9/x/'
        Remove-Item $tmp -Force
    }
    It '旧 Base64 配置自动迁移为 DPAPI' {
        $tmp = Join-Path $env:TEMP ('cnt_' + [guid]::NewGuid().ToString('N') + '.json')
        $legacy = [ordered]@{ Account = 'old'; Password = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('oldpw')) }
        $legacy | ConvertTo-Json | Out-File -LiteralPath $tmp -Encoding UTF8
        $cfg = Load-CampusConfig -ConfigFile $tmp -LogFile $null
        $cfg.Password | Should Be 'oldpw'
        ((Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json).PasswordFormat) | Should Be 'DPAPI'
        Remove-Item $tmp -Force
    }
}

# ------------------------------------------------------------
# 伪登录回归：为便于测试，这里覆盖网络相关依赖（只影响本文件后续用例）
#   Test-CampusInternet 第一次调用（登录前预检）返回 $false，
#   之后返回 $script:internetAfterLogin。
# ------------------------------------------------------------
$script:preCheckDone = $false
$script:internetAfterLogin = $false
$script:mockAdapter = [pscustomobject]@{ Name = 'mock'; Description = 'mock'; Type = '以太网'; IP = '10.0.0.9'; MAC = 'AABBCCDDEEFF'; SSID = $null; HasGateway = $true; IsWired = $true }
$script:adapterResult = $script:mockAdapter

function Test-CampusInternet {
    param([int]$TimeoutSec = 5)
    if (-not $script:preCheckDone) { $script:preCheckDone = $true; return $false }
    return [bool]$script:internetAfterLogin
}
function Get-CampusAdapter {
    param($Settings, $LogFile)
    return $script:adapterResult
}
# 让 portal 探针不真的打网络（单元测试保持离线、快速、确定）
$script:probeText = $null
function Get-CampusPortalProbe {
    param([int]$TimeoutSec = 6, [string]$LogFile)
    return $script:probeText
}

# 记录 Start-Process（浏览器兜底），避免单元测试真的弹窗
$script:started = @()
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, $WindowStyle)
    $script:started += $FilePath
}
$script:attempted = @()
$script:v4Response = 'dr1003({"result":"1","msg":"ok"})'
$script:legacyResponse = 'dr1003({"result":"1","msg":"ok"})'

function Invoke-WebRequest {
    param($Uri, $Method, $TimeoutSec, [switch]$UseBasicParsing, $MaximumRedirection, $Headers)
    $script:attempted += $Uri
    if ($Uri -match 'loadConfig') {
        # dr1001 响应的字段形状（值取自当时的抓包，抓包已按隐私要求移除）
        return [pscustomobject]@{ StatusCode = 200; Content = 'dr1001({"code":1,"msg":"加载页面设置信息成功!","data":{"program_index":"vDRn3i1789461695","page_index":"wfIsOK1789465453","page_name":"gzlg1"}})' }
    }
    if ($Uri -match 'portal/login') {
        return [pscustomobject]@{ StatusCode = 200; Content = $script:v4Response }
    }
    return [pscustomobject]@{ StatusCode = 200; Content = $script:legacyResponse }
}

Describe '伪登录防护（接口说成功但实际无网）' {
    $configPath = Join-Path $env:TEMP ('cnfl_' + [guid]::NewGuid().ToString('N') + '.json')
    Save-CampusConfig -ConfigFile $configPath -Account 'u' -Password 'p' -LogFile $null | Out-Null

    It '接口成功 + 实际无网 -> 静默返回 4（不再谎报成功）' {
        $script:preCheckDone = $false
        $script:internetAfterLogin = $false
        (Invoke-CampusSilentLogin -ConfigFile $configPath -LogFile $null -VerifyTimeoutSec 0) | Should Be 4
    }

    It '接口成功 + 确认真实联网 -> 静默返回 0' {
        $script:preCheckDone = $false
        $script:internetAfterLogin = $true
        (Invoke-CampusSilentLogin -ConfigFile $configPath -LogFile $null -VerifyTimeoutSec 0) | Should Be 0
    }

    Remove-Item $configPath -Force
}

Describe 'ConvertFrom-PortalLocation（门户参数解析）' {
    It 'Dr.COM a79 风格' {
        $p = ConvertFrom-PortalLocation -Text 'http://10.0.10.252/a79.htm?wlanuserip=10.20.30.41&wlanacname=AC-1&wlanacip=10.128.1.1'
        # a79 入口页只说明“门户在哪”，不得拿去当 BaseURL（否则会把回退接口的 :801/eportal/ 覆盖掉）
        $p.PortalHost | Should Be '10.0.10.252'
        $p.BaseURL | Should Be $null
        $p.WlanAcIp | Should Be '10.128.1.1'
        $p.WlanAcName | Should Be 'AC-1'
        $p.UserIp | Should Be '10.20.30.41'
    }
    It 'eportal 风格（含 jsVersion/v）' {
        $p = ConvertFrom-PortalLocation -Text 'http://10.0.10.252:801/eportal/?wlan_ac_ip=10.9.9.9&jsVersion=4.1&v=1234'
        $p.BaseURL | Should Be 'http://10.0.10.252:801/eportal/'
        $p.WlanAcIp | Should Be '10.9.9.9'
        $p.JsVersion | Should Be '4.1'
        $p.PortalVersion | Should Be '1234'
    }
    It 'HTML 内嵌地址（nasip）' {
        $p = ConvertFrom-PortalLocation -Text '<script>top.location.href="http://10.1.2.3:8080/eportal/index.jsp?nasip=10.1.2.3";</script>'
        $p.BaseURL | Should Be 'http://10.1.2.3:8080/eportal/'
        $p.WlanAcIp | Should Be '10.1.2.3'
    }
    It '空输入 -> 全空' {
        $p = ConvertFrom-PortalLocation -Text ''
        $p.BaseURL | Should Be $null
        $p.WlanAcIp | Should Be $null
    }
}

Describe 'Get-MaskedUrl（日志脱敏）' {
    It '掩盖 user_password' {
        (Get-MaskedUrl -Url 'http://x/?a=1&user_password=secret&b=2') | Should Be 'http://x/?a=1&user_password=***&b=2'
    }
    It '掩盖 user_account，并把密码一起盖掉（凭据一律不进日志）' {
        (Get-MaskedUrl -Url 'http://x/?user_account=0c100c1&user_password=101315&lang=zh') |
            Should Be 'http://x/?user_account=***&user_password=***&lang=zh'
    }
    It '对不含凭据的文本（如异常信息）保持原样' {
        (Get-MaskedUrl -Url 'The remote server returned an error: (500) Internal Server Error.') |
            Should Be 'The remote server returned an error: (500) Internal Server Error.'
    }
}

Describe '静默登录退出码映射' {
    $script:silentCfg = Join-Path $env:TEMP ('cnsc_' + [guid]::NewGuid().ToString('N') + '.json')
    Save-CampusConfig -ConfigFile $script:silentCfg -Account 'u' -Password 'p' -LogFile $null | Out-Null

    It '没有配置文件 -> 1' {
        (Invoke-CampusSilentLogin -ConfigFile (Join-Path $env:TEMP 'no_such_cfg_xyz_12345.json') -LogFile $null) | Should Be 1
    }
    It '已联网 -> 0' {
        $script:preCheckDone = $true
        $script:internetAfterLogin = $true
        $script:adapterResult = $script:mockAdapter
        (Invoke-CampusSilentLogin -ConfigFile $script:silentCfg -LogFile $null) | Should Be 0
    }
    It '没有可用网卡 -> 3' {
        $script:preCheckDone = $true
        $script:internetAfterLogin = $false
        $script:adapterResult = $null
        (Invoke-CampusSilentLogin -ConfigFile $script:silentCfg -LogFile $null) | Should Be 3
        $script:adapterResult = $script:mockAdapter
    }

    Remove-Item $script:silentCfg -Force
}

Describe '哆点 v4 参数混淆（逐字符 XOR + hex）' {
    # 向量用**合成值**（真正的抓包已按隐私要求从仓库移除）。
    # 账号/密码/MAC/IP 均为假值；唯一保留的真实值是校园公共地址 10.128.255.129（AC）。
    $vectors = [ordered]@{
        # 注意：下列密文均按默认 key 0x20 计算，只是演示“密文↔明文”的对应关系
        '111315171910'                       = '135790'
        '11100e1112180e1215150e111219'       = '10.128.255.129'
        '445211101013'                       = 'dr1003'
        '5a480d434e'                         = 'zh-cn'
        '0c100c1210121410101010101010101010' = ',0,20240000000000'
        '11100e12100e13100e1410'             = '10.20.30.40'
        '101011111212131314141515'           = '001122334455'
        '140e150e11'                         = '4.5.1'
        '504f5254414c7f4c4f47494e'           = 'portal_login'
        '5664724e134911171819141611161915'   = 'vDRn3i1789461695'
        '574669536f6b11171819141615141513'   = 'wfIsOK1789465453'
        '11'                                 = '1'
        '10'                                 = '0'
    }

    It '向量表解码正确' {
        foreach ($k in $vectors.Keys) {
            (ConvertFrom-DrappallValue -Hex $k) | Should Be $vectors[$k]
        }
    }
    It '编码往返一致' {
        foreach ($k in $vectors.Keys) {
            (ConvertTo-DrappallValue -Text $vectors[$k]) | Should Be $k
        }
    }
    It '完整 User-Agent 长串解码正确' {
        $uaHex = '6d4f5a494c4c410f150e10000877494e444f5753006e740011100e101b0077494e16141b0058161409006150504c457745426b49540f1513170e131600086b68746d6c0c004c494b45006745434b4f09006348524f4d450f1115140e100e100e10007341464152490f1513170e1316006544470f1115140e100e100e10'
        (ConvertFrom-DrappallValue -Hex $uaHex) | Should Be 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36 Edg/154.0.0.0'
    }
    It '空串与非法输入安全处理' {
        (ConvertTo-DrappallValue -Text '') | Should Be ''
        (ConvertFrom-DrappallValue -Hex '') | Should Be ''
        (ConvertFrom-DrappallValue -Hex 'abc') | Should Be $null
        (ConvertFrom-DrappallValue -Hex 'zz') | Should Be $null
    }
}

Describe '哆点 v4 的 XOR key 由客户端 IP 推导（门户 a41.js util.getkey）' {
    It '三个合成 IP 各自推导出预期 key（key 随 IP 变化，不是常量）' {
        (Get-DrappallKey -IP '10.20.30.40') | Should Be 0x2A   # 有线样例
        (Get-DrappallKey -IP '10.20.30.41') | Should Be 0x2B   # 2.4G 样例
        (Get-DrappallKey -IP '10.20.30.42') | Should Be 0x28   # 5G 样例
    }
    It '用推导出的 key 能复现有线样例的密文' {
        $k = Get-DrappallKey -IP '10.20.30.40'
        (ConvertTo-DrappallValue -Text 'dr1003' -Key $k) | Should Be '4e581b1a1a19'
        (ConvertTo-DrappallValue -Text '10.128.255.129' -Key $k) | Should Be '1b1a041b181204181f1f041b1813'
        (ConvertFrom-DrappallValue -Hex '4e581b1a1a19' -Key $k) | Should Be 'dr1003'
    }
    It '用推导出的 key 能复现 2.4G 样例的密文' {
        $k = Get-DrappallKey -IP '10.20.30.41'
        (ConvertTo-DrappallValue -Text 'dr1003' -Key $k) | Should Be '4f591a1b1b18'
        (ConvertTo-DrappallValue -Text '4.5.1' -Key $k) | Should Be '1f051e051a'
        (ConvertTo-DrappallValue -Text 'zh-cn' -Key $k) | Should Be '5143064845'
    }
    It '用推导出的 key 能复现 5G 样例的密文' {
        $k = Get-DrappallKey -IP '10.20.30.42'
        (ConvertTo-DrappallValue -Text 'dr1003' -Key $k) | Should Be '4c5a1918181b'
        (ConvertTo-DrappallValue -Text '4.5.1' -Key $k) | Should Be '1c061d0619'
        (ConvertTo-DrappallValue -Text 'zh-cn' -Key $k) | Should Be '5240054b46'
    }
    It '登录 URL 会随 IP 自动换 key（不再写死 0x20）' {
        $u1 = New-DrappallLoginUrl -PortalHost '10.0.10.252' -Port 803 -Account 'u' -Password 'p' `
            -IP '10.20.30.40' -MAC '001122334455' -Settings (Get-DefaultSettings) -Callback 'dr1003'
        $u2 = New-DrappallLoginUrl -PortalHost '10.0.10.252' -Port 803 -Account 'u' -Password 'p' `
            -IP '10.20.30.41' -MAC 'AABBCCDDEEFF' -Settings (Get-DefaultSettings) -Callback 'dr1003'
        ($u1 -match 'callback=4e581b1a1a19') | Should Be $true
        ($u2 -match 'callback=4f591a1b1b18') | Should Be $true
    }
}

Describe 'New-DrappallLoginUrl（哆点 v4 登录 URL）' {
    $harUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36 Edg/154.0.0.0'
    $url = New-DrappallLoginUrl -PortalHost '10.0.10.252' -Port 803 `
        -Account '20240000000000' -Password '135790' `
        -IP '10.20.30.40' -MAC '00-11-22-33-44-55' -Settings (Get-DefaultSettings) `
        -ProgramIndex 'vDRn3i1789461695' -PageIndex 'wfIsOK1789465453' `
        -UserAgent $harUa -Callback 'dr1003'

    It '主机 / 端口 / 路径与门户实际接口一致' {
        $url | Should Match '^http://10\.0\.10\.252:803/eportal/portal/login\?'
    }
    It '尾部为 encrypt=1&v=<4位数字>&lang=zh' {
        $url | Should Match '&encrypt=1&v=\d{4}&lang=zh$'
    }
    It '逐字段编码值与预期一致（全部为合成值）' {
        $expect = [ordered]@{
            callback        = '4e581b1a1a19'
            login_method    = '1b'
            is_base64encode = '1a'
            user_account    = '061a06181a181e1a1a1a1a1a1a1a1a1a1a'
            user_password   = '1b191f1d131a'
            wlan_user_ip    = '1b1a04181a04191a041e1a'
            wlan_user_ipv6  = ''
            wlan_user_mac   = '1a1a1b1b181819191e1e1f1f'
            wlan_vlan_id    = '1a'
            wlan_ac_ip      = '1b1a041b181204181f1f041b1813'
            wlan_ac_name    = ''
            authex_enable   = ''
            jsVersion       = '1e041f041b'
            uuid            = ''
            terminal_type   = '1b'
            lang            = '5042074944'
            user_agent      = '6745504346464b051f041a0a027d43444e455d590a647e0a1b1a041a110a7d43441c1e110a521c1e030a6b5a5a464f7d4f4861435e051f191d04191c0a0261627e6766060a4643414f0a6d4f494145030a69425845474f051b1f1e041a041a041a0a794b4c4b5843051f191d04191c0a6f4e4d051b1f1e041a041a041a'
            enable_r3       = '1a'
            mac_type        = '1a'
            rcn             = ''
            operate         = '5a45585e4b467546454d4344'
            business_type   = '1b'
            program_index   = '5c6e784419431b1d12131e1c1b1c131f'
            page_index      = '5d4c635965611b1d12131e1c1f1e1f19'
        }
        $qs = $url.Split('?')[1]
        $actual = @{}
        foreach ($pair in $qs.Split('&')) {
            $i = $pair.IndexOf('=')
            $k = $pair.Substring(0, $i)
            if (-not $actual.ContainsKey($k)) { $actual[$k] = $pair.Substring($i + 1) }
        }
        foreach ($k in $expect.Keys) {
            "$k" | Should Be "$k"          # 占位断言，保证失败时能定位
            $actual[$k] | Should Be $expect[$k]
        }
    }
    It 'Referer 为门户根地址' {
        (Get-DrappallReferer -PortalHost '10.0.10.252') | Should Be 'http://10.0.10.252/'
    }
}

Describe 'New-DrappallLoadConfigUrl / Get-DrappallPageIndex' {
    It '路径与 base64 编码格式正确' {
        $u = New-DrappallLoadConfigUrl -PortalHost '10.0.10.252' -Port 803 -IP '10.20.30.40' -AcIp '10.128.255.129'
        $u | Should Match '^http://10\.0\.10\.252:803/eportal/portal/page/loadConfig\?callback=dr1001&program_index=&wlan_vlan_id=0&'
        $u | Should Match 'wlan_user_ip=MTAuMjAuMzAuNDA%3D'
        $u | Should Match 'wlan_ac_ip=MTAuMTI4LjI1NS4xMjk%3D'
        $u | Should Match 'wlan_ap_mac=000000000000&gw_id=000000000000&page_index='
        $u | Should Match '&jsVersion=4\.X&v=\d{4}&lang=zh$'
    }
    It '能从 dr1001 响应里解析出 index（用真实报文）' {
        $r = Get-DrappallPageIndex -PortalHost '10.0.10.252' -Port 803 -IP '10.20.30.40' -AcIp '10.128.255.129' -LogFile $null
        $r.Ok | Should Be $true
        $r.ProgramIndex | Should Be 'vDRn3i1789461695'
        $r.PageIndex | Should Be 'wfIsOK1789465453'
        $r.PageName | Should Be 'gzlg1'
    }
}

Describe 'Send-CampusLoginRequest 协议策略链' {
    It 'mock 的 Invoke-WebRequest 能接受真实调用用到的全部参数（含 -ErrorAction）' {
        $r = Invoke-WebRequest -Uri 'http://example.invalid/' -Method Get -TimeoutSec 1 -UseBasicParsing `
            -MaximumRedirection 2 -Headers @{ } -ErrorAction Stop
        $r.StatusCode | Should Be 200
    }
    It '哆点 v4 成功时不再走旧接口' {
        $script:attempted = @()
        $script:v4Response = 'dr1003({"result":1,"msg":"Portal协议认证成功！"})'
        $r = Send-CampusLoginRequest -Account 'a' -Password 'p' -IP '10.0.0.9' -MAC 'AABBCCDDEEFF' `
            -Settings (Get-DefaultSettings) -Protocol auto -LogFile $null
        $r.Success | Should Be $true
        (($script:attempted -match 'portal/login').Count -gt 0) | Should Be $true
        (($script:attempted -match 'c=Portal&a=login').Count -eq 0) | Should Be $true
    }
    It 'v4 响应不可识别时回退旧接口' {
        $script:attempted = @()
        $script:v4Response = '<html>系统发生错误</html>'
        $script:legacyResponse = 'dr1003({"result":1,"msg":"ok"})'
        $r = Send-CampusLoginRequest -Account 'a' -Password 'p' -IP '10.0.0.9' -MAC 'AABBCCDDEEFF' `
            -Settings (Get-DefaultSettings) -Protocol auto -LogFile $null
        $r.Success | Should Be $true
        (($script:attempted -match 'c=Portal&a=login').Count -gt 0) | Should Be $true
    }
    It 'v4 返回凭证类错误时立即返回，不换协议' {        $script:attempted = @()
        $script:v4Response = 'dr1003({"result":0,"ret_code":8,"msg":"bad"})'
        $r = Send-CampusLoginRequest -Account 'a' -Password 'p' -IP '10.0.0.9' -MAC 'AABBCCDDEEFF' `
            -Settings (Get-DefaultSettings) -Protocol auto -LogFile $null
        $r.Success | Should Be $false
        $r.ErrorCode | Should Be 8
        (($script:attempted -match 'c=Portal&a=login').Count -eq 0) | Should Be $true
    }
}

Describe '门户发现：a79 参数 / 探针黑名单 / 登录端点' {
    It '解析 a79 跳转的 wlanusermac / wlanuserip / wlanacip' {
        $p = ConvertFrom-PortalLocation -Text 'http://10.0.10.252/a79.htm?wlanusermac=00-11-22-33-44-55&wlanuserip=10.20.30.40&wlanacip=10%2E128%2E255%2E129'
        $p.PortalHost | Should Be '10.0.10.252'
        $p.UserMac | Should Be '00-11-22-33-44-55'
        $p.UserIp | Should Be '10.20.30.40'
        $p.WlanAcIp | Should Be '10.128.255.129'
        $p.BaseURL | Should Be $null
    }
    It 'eportal 路径规范化到 :803/eportal/' {
        $p = ConvertFrom-PortalLocation -Text 'http://10.0.10.252:803/eportal/?c=ACSetting&a=Index'
        $p.BaseURL | Should Be 'http://10.0.10.252:803/eportal/'
        $p.PortalHost | Should Be '10.0.10.252'
        $p.PortalPort | Should Be '803'
    }
    It '默认探针避开门户 visit_blacklist（含 generate_204 / 1.1.1.1）' {
        $u = Get-PortalProbeUrls
        ($u -contains 'http://9.9.9.9/') | Should Be $true
        (@($u | Where-Object { $_ -like '*generate_204*' }).Count) | Should Be 0
        (@($u | Where-Object { $_ -like '*1.1.1.1*' }).Count) | Should Be 0
    }
    It '自定义黑名单可把任意探针过滤掉' {
        $u = Get-PortalProbeUrls -Blacklist @('9.9.9.9')
        ($u -contains 'http://9.9.9.9/') | Should Be $false
    }
    It '探测不到门户时沿用网卡 IP/MAC' {
        $script:probeText = $null
        $ep = Get-LoginEndpoint -Adapter $script:mockAdapter -Settings (Get-DefaultSettings) -LogFile $null
        $ep.IP | Should Be '10.0.0.9'
        $ep.MAC | Should Be 'AABBCCDDEEFF'
    }
    It '探测到门户时以门户看到的 IP/MAC 为准' {
        $script:probeText = 'http://10.0.10.252/a79.htm?wlanusermac=00-11-22-33-44-55&wlanuserip=10.20.30.40&wlanacip=10%2E128%2E255%2E129'
        $ep = Get-LoginEndpoint -Adapter $script:mockAdapter -Settings (Get-DefaultSettings) -LogFile $null
        $ep.IP | Should Be '10.20.30.40'
        $ep.MAC | Should Be '001122334455'
        $script:probeText = $null
    }
}

Describe '联网判定与网卡选择（P0 类缺陷回归）' {
    It 'HTTP 204 不算联网（generate_204 是免认证豁免域名，离线也通）' {
        (Test-InternetProbeResponse -StatusCode 204 -Content '' -Match '') | Should Be $false
    }
    It '200 + 门户劫持页不算联网（哪怕页里含期望关键字）' {
        (Test-InternetProbeResponse -StatusCode 200 -Content '<html>eportal 请登录 baidu.com</html>' -Match 'baidu') | Should Be $false
        (Test-InternetProbeResponse -StatusCode 200 -Content '欢迎使用哆点认证 baidu' -Match 'baidu') | Should Be $false
        (Test-InternetProbeResponse -StatusCode 200 -Content '系统发生错误 baidu' -Match 'baidu') | Should Be $false
    }
    It '200 + 正常页面才算联网' {
        (Test-InternetProbeResponse -StatusCode 200 -Content '<html><title>百度一下</title>baidu</html>' -Match 'baidu') | Should Be $true
    }
    It '内容不含期望关键字 / 空内容都不算联网' {
        (Test-InternetProbeResponse -StatusCode 200 -Content '<html>other</html>' -Match 'baidu') | Should Be $false
        (Test-InternetProbeResponse -StatusCode 200 -Content '' -Match 'baidu') | Should Be $false
    }
    It '探针列表不含任何免认证豁免域名' {
        $urls = (Get-InternetProbeList | ForEach-Object { $_.Url }) -join ' '
        $urls | Should Not Match 'generate_204'
        $urls | Should Not Match 'ncsi\.txt'
        $urls | Should Not Match 'msftncsi'
        $urls | Should Not Match '1\.1\.1\.1'
        $urls | Should Match 'baidu'
    }
    It '豁免名单可配置：剔掉谁就不再用谁' {
        $urls = (Get-InternetProbeList -ExemptBlacklist @('baidu') | ForEach-Object { $_.Url }) -join ' '
        $urls | Should Not Match 'baidu'
        $urls | Should Match 'qq'
    }
    It '网卡按“去往门户的路由”选，不会被“有线优先”带偏' {
        $wired = [pscustomobject]@{ Name = 'eth'; Type = '以太网'; IP = '192.168.1.10'; IsWired = $true;  HasGateway = $true;  SSID = $null }
        $wifi  = [pscustomobject]@{ Name = 'wlan'; Type = 'WiFi';  IP = '10.20.30.41';  IsWired = $false; HasGateway = $true;  SSID = 'CampusWiFi' }
        $cands = @($wired, $wifi)
        (Select-CampusAdapterByRoute -Candidates $cands -RouteSourceIp '10.20.30.41').Name | Should Be 'wlan'
        (Select-CampusAdapterByRoute -Candidates $cands -RouteSourceIp '192.168.1.10').Name | Should Be 'eth'
    }
    It '路由源 IP 匹配不到时返回空，交给调用方回退' {
        $c = @([pscustomobject]@{ Name = 'eth'; IP = '192.168.1.10' })
        (Select-CampusAdapterByRoute -Candidates $c -RouteSourceIp '10.0.0.1') | Should BeNullOrEmpty
        (Select-CampusAdapterByRoute -Candidates $c -RouteSourceIp '') | Should BeNullOrEmpty
        (Select-CampusAdapterByRoute -Candidates @() -RouteSourceIp '1.1.1.1') | Should BeNullOrEmpty
    }
}

Describe '失败判定与退出码边界（代码审查回归）' {
    It '失败报文里出现"认证成功"字样不算成功' {
        $r = ConvertFrom-PortalResponse -Content 'dr1003({"result":0,"ret_code":2,"msg":"认证成功前需先下线其他设备"})'
        $r.Success | Should Be $false
        $r.ErrorCode | Should Be 2
    }
    It '用成功字样兜底时必须真的没有 result/ret_code' {
        (ConvertFrom-PortalResponse -Content 'dr1003({"msg":"Portal协议认证成功！"})').Success | Should Be $true
        (ConvertFrom-PortalResponse -Content 'dr1003({"result":0,"ret_code":8,"msg":"Portal协议认证成功"})').Success | Should Be $false
    }
    It '配置损坏 -> 退出码 2；配置缺失 -> 退出码 1' {
        $bad = Join-Path $env:TEMP ('cnbad_' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $bad -Value '{ this is not valid json' -Encoding UTF8
        (Invoke-CampusSilentLogin -ConfigFile $bad -LogFile $null -VerifyTimeoutSec 0) | Should Be 2
        Remove-Item -LiteralPath $bad -Force
        (Invoke-CampusSilentLogin -ConfigFile (Join-Path $env:TEMP 'cn_definitely_missing.json') -LogFile $null -VerifyTimeoutSec 0) | Should Be 1
    }
}

Describe '示例配置不漂移' {
    $exPath = Join-Path (Split-Path -Parent $here) 'CampusNet_AutoLogin\CampusNet_Config.example.json'

    It '示例文件存在且是合法 JSON' {
        (Test-Path $exPath) | Should Be $true
        $ex = Get-Content -Raw -Encoding UTF8 $exPath | ConvertFrom-Json
        $ex.Account | Should Not BeNullOrEmpty
        $ex.PasswordFormat | Should Be 'DPAPI'
    }
    It '示例 Settings 的每个键都被代码接受（否则写了也不生效）' {
        $ex = Get-Content -Raw -Encoding UTF8 $exPath | ConvertFrom-Json
        $accepted = Get-DefaultSettings
        foreach ($p in $ex.Settings.PSObject.Properties) {
            $accepted.Contains($p.Name) | Should Be $true
        }
    }
    It '示例里的新配置项真的会生效' {
        $ex = Get-Content -Raw -Encoding UTF8 $exPath | ConvertFrom-Json
        $merged = Merge-CampusSettings -RawSettings $ex.Settings
        $merged['PortalHost'] | Should Be '10.0.10.252'
        $merged['PortalPort'] | Should Be '803'
        $merged['JsVersion'] | Should Be '4.5.1'
        $merged['OpenPortalOnFailure'] | Should Be '1'
        (Test-CampusSettingEnabled -Settings $merged -Key 'OpenPortalOnFailure') | Should Be $true
    }
}

Describe '失败兜底：门户页 URL / 开关 / 静默不弹窗' {
    It '门户页 URL 的形态与门户实际跳转一致' {
        (Get-CampusPortalPageUrl -Settings (Get-DefaultSettings) -UserIp '10.20.30.40' -UserMac '00-11-22-33-44-55') |
            Should Be 'http://10.0.10.252/a79.htm?wlanusermac=00-11-22-33-44-55&wlanuserip=10.20.30.40&wlanacip=10.128.255.129'
    }
    It 'OpenPortalOnFailure 开关默认开启、且用 "0" 可关闭' {
        $s = Get-DefaultSettings
        (Test-CampusSettingEnabled -Settings $s -Key 'OpenPortalOnFailure') | Should Be $true
        $s['OpenPortalOnFailure'] = '0'
        (Test-CampusSettingEnabled -Settings $s -Key 'OpenPortalOnFailure') | Should Be $false
        (Test-CampusSettingEnabled -Settings $s -Key 'NotExist') | Should Be $true
        (Test-CampusSettingEnabled -Settings $s -Key 'NotExist' -Default $false) | Should Be $false
    }
    It 'Open-CampusPortalPage 能调起浏览器并返回真' {
        $script:started = @()
        (Open-CampusPortalPage -Settings (Get-DefaultSettings) -UserIp '10.20.30.40' -UserMac '00-11-22-33-44-55' -LogFile $null) | Should Be $true
        ($script:started.Count) | Should Be 1
    }
    It '静默登录失败时不打开浏览器' {
        $script:started = @()
        $cfg = Join-Path $env:TEMP ('cnfb_' + [guid]::NewGuid().ToString('N') + '.json')
        Save-CampusConfig -ConfigFile $cfg -Account 'u' -Password 'p' -LogFile $null | Out-Null
        $script:internetAfterLogin = $false
        $script:v4Response = 'dr1003({"result":0,"ret_code":1,"msg":"bad"})'
        $script:legacyResponse = 'dr1003({"result":0,"ret_code":1,"msg":"bad"})'
        (Invoke-CampusSilentLogin -ConfigFile $cfg -LogFile $null -VerifyTimeoutSec 0) | Should Be 4
        ($script:started.Count) | Should Be 0
        Remove-Item $cfg -Force
    }
}

Describe '错误密码的响应判定（响应形状取自当时的抓包，抓包已按隐私要求移除）' {
    $bad = 'dr1003({"result":0,"msg":"密码错误","ret_code":1})'

    It 'ret_code=1 + msg=密码错误 被判为凭证错误' {
        $r = ConvertFrom-PortalResponse -Content $bad
        $r.Success | Should Be $false
        $r.Recognized | Should Be $true
        $r.ErrorCode | Should Be 1
        $r.Message | Should Be '密码错误'
    }
    It '文案把 ret_code=1 解释为密码错误，并带上门户提示' {
        (Get-PortalErrorText -Code 1 -Message '密码错误') | Should Match '密码错误'
        (Get-PortalErrorText -Code 1 -Message '密码错误') | Should Match '门户提示'
    }
    It 'AC999 这类内部码不会被当成可读提示' {
        (Get-PortalErrorText -Code 2 -Message 'AC999') | Should Not Match 'AC999'
    }
    It '凭证错误时只试一次、不重试也不切换协议' {
        $script:attempted = @()
        $script:v4Response = $bad
        $r = Send-CampusLoginRequest -Account 'u' -Password 'bad' -IP '10.0.0.9' -MAC 'AABBCCDDEEFF' `
            -Settings (Get-DefaultSettings) -Protocol auto -LogFile $null
        $r.ErrorCode | Should Be 1
        (($script:attempted -match 'portal/login').Count) | Should Be 1
        (($script:attempted -match 'c=Portal&a=login').Count -eq 0) | Should Be $true
    }
    It '成功后 callback 会递增（dr1003 → dr1004），两者都应被识别' {
        (ConvertFrom-PortalResponse -Content 'dr1003({"result":1,"msg":"Portal协议认证成功！"})').Success | Should Be $true
        (ConvertFrom-PortalResponse -Content 'dr1004({"result":1,"msg":"Portal协议认证成功！"})').Success | Should Be $true
    }
    It '失败/成功是成对出现：先密码错误、改正后成功' {
        $fail = ConvertFrom-PortalResponse -Content $bad
        $ok = ConvertFrom-PortalResponse -Content 'dr1004({"result":1,"msg":"Portal协议认证成功！"})'
        $fail.Success | Should Be $false
        $fail.ErrorCode | Should Be 1
        $ok.Success | Should Be $true
    }
    It '已在线响应真值（本机有线实测拿到）' {
        $r = ConvertFrom-PortalResponse -Content 'dr1003({"result":0,"msg":"AC999","ret_code":2})'
        $r.Success | Should Be $false
        $r.Recognized | Should Be $true
        $r.ErrorCode | Should Be 2
        (Get-PortalErrorText -Code 2 -Message 'AC999') | Should Match '已'
    }
    It 'key 写错时门户回 403「非法内容」——不再渲染成登录成功，且不空转重试' {
        $badKey = 'dr0001({"code":403,"result":0,"msg":"请求参数包含非法内容，请检查后重试","data":{"violations_count":6}})'
        $r = ConvertFrom-PortalResponse -Content $badKey
        $r.Success | Should Be $false
        (Get-PortalErrorText -Code $r.ErrorCode -Message $r.Message) | Should Match '非法内容'
        (Get-PortalErrorText -Code $r.ErrorCode -Message $r.Message) | Should Not Match '登录成功'

        # 真实 v4 + 错误 key：只试一次就换策略，不反复重试
        $script:attempted = @()
        $script:v4Response = $badKey
        $script:legacyResponse = 'dr1003({"result":0,"ret_code":8,"msg":"x"})'
        $null = Send-CampusLoginRequest -Account 'u' -Password 'p' -IP '10.0.0.9' -MAC 'AABBCCDDEEFF' `
            -Settings (Get-DefaultSettings) -Protocol drappall -MaxAttempts 3 -LogFile $null
        (($script:attempted -match 'portal/login').Count) | Should Be 1
    }
}

Describe '网卡为什么被排除（Get-CampusAdapterRejectReason）' {
    It '正常网卡：没有排除原因' {
        (Get-CampusAdapterRejectReason -Description 'Intel(R) Ethernet Connection (19) I219-V' `
                -Type '以太网' -Status 'Up' -IP '10.20.30.40') | Should Be ''
    }
    It '只有 APIPA 的网卡 → 明确指出没拿到 DHCP 租约' {
        $r = Get-CampusAdapterRejectReason -Description 'Intel(R) Ethernet Connection (19) I219-V' `
            -Type '以太网' -Status 'Up' -IP '169.254.91.27'
        $r | Should Match 'APIPA'
        $r | Should Match 'DHCP'
        $r | Should Match '169\.254\.91\.27'
    }
    It 'Up 但没有 IPv4 → 也是 DHCP 没租约' {
        (Get-CampusAdapterRejectReason -Description 'Realtek PCIe GbE Family Controller' -Status 'Up' -IP '') |
            Should Match '没有 IPv4'
    }
    It '链路未连接：有线/无线给不同提示' {
        (Get-CampusAdapterRejectReason -Description 'Intel(R) Ethernet Connection (19) I219-V' -Type '以太网' -Status 'Disconnected' -IP '') |
            Should Match '网线'
        (Get-CampusAdapterRejectReason -Description 'Intel(R) Wi-Fi 6 AX101' -Type 'WiFi' -Status 'Disconnected' -IP '') |
            Should Match 'WiFi|无线'
    }
    It '虚拟/蓝牙网卡按规则排除' {
        (Get-CampusAdapterRejectReason -Description 'Bluetooth Device (Personal Area Network)' -Status 'Up' -IP '169.254.66.142') |
            Should Match '虚拟|蓝牙'
    }
}

Describe '免重启修复计划（Get-CampusRepairPlan）' {
    It '只修“在用但没租约”的物理网卡，跳过虚拟网卡与正常的网卡' {
        $report = @(
            [pscustomobject]@{ Name = '以太网'; IsVirtual = $false; IsApipa = $true;  Status = 'Up';         IP = '169.254.91.27'; Usable = $false; HasGateway = $false }
            [pscustomobject]@{ Name = 'WLAN';   IsVirtual = $false; IsApipa = $false; Status = 'Disconnected'; IP = $null;         Usable = $false; HasGateway = $false }
            [pscustomobject]@{ Name = '蓝牙';   IsVirtual = $true;  IsApipa = $true;  Status = 'Up';         IP = '169.254.66.1';  Usable = $false; HasGateway = $false }
            [pscustomobject]@{ Name = '正常口'; IsVirtual = $false; IsApipa = $false; Status = 'Up';         IP = '10.20.30.40';   Usable = $true;  HasGateway = $true }
        )
        $plan = @(Get-CampusRepairPlan -Report $report)
        ($plan.Count) | Should Be 1
        $plan[0].Name | Should Be '以太网'
    }
    It 'Up 有 IP 但没网关 → 也要修（属于拿到地址却不通）' {
        $report = @(
            [pscustomobject]@{ Name = '以太网'; IsVirtual = $false; IsApipa = $false; Status = 'Up'; IP = '10.20.30.50'; Usable = $true; HasGateway = $false }
        )
        (@(Get-CampusRepairPlan -Report $report)).Count | Should Be 1
    }
    It '已断开但残留 APIPA 的网卡不该修（真机踩过的坑）' {
        $report = @(
            [pscustomobject]@{ Name = 'WLAN'; IsVirtual = $false; IsApipa = $true; Status = 'Disconnected'; IP = '169.254.142.113'; Usable = $false; HasGateway = $false }
        )
        (@(Get-CampusRepairPlan -Report $report)).Count | Should Be 0
    }
    It '空输入安全返回空' {
        (@(Get-CampusRepairPlan -Report $null)).Count | Should Be 0
    }
}

Describe '失败该不该自动开浏览器（Get-CampusFailureAction）' {
    It '密码错误(ret_code=1) → 不开浏览器，引导改密码' {
        (Get-CampusFailureAction -ErrorCode 1 -Message '密码错误' -OpenPortalOnFailure $true) | Should Be 'credentials'
    }
    It '账号类错误(3/4/11) → 同样走凭证分支' {
        (Get-CampusFailureAction -ErrorCode 3 -OpenPortalOnFailure $true) | Should Be 'credentials'
        (Get-CampusFailureAction -ErrorCode 4 -OpenPortalOnFailure $true) | Should Be 'credentials'
        (Get-CampusFailureAction -ErrorCode 11 -OpenPortalOnFailure $true) | Should Be 'credentials'
    }
    It '已在线(ret_code=2) → 引导去自助服务下线，不开浏览器' {
        (Get-CampusFailureAction -ErrorCode 2 -Message 'AC999' -OpenPortalOnFailure $true) | Should Be 'online'
    }
    It '协议/网络类失败 → 开浏览器兜底' {
        (Get-CampusFailureAction -ErrorCode -1 -Message 'portal 响应不可识别' -OpenPortalOnFailure $true) | Should Be 'browser'
        (Get-CampusFailureAction -ErrorCode -1 -Message '登录请求异常' -OpenPortalOnFailure $true) | Should Be 'browser'
    }
    It '开关关闭时一律不动浏览器' {
        (Get-CampusFailureAction -ErrorCode -1 -Message 'x' -OpenPortalOnFailure $false) | Should Be 'none'
        (Get-CampusFailureAction -ErrorCode 1 -Message '密码错误' -OpenPortalOnFailure $false) | Should Be 'none'
    }
    It '没有错误码时按文案兜底判断' {
        (Get-CampusFailureAction -ErrorCode -1 -Message '门户提示：密码错误' -OpenPortalOnFailure $true) | Should Be 'credentials'
    }
}

Describe 'DNS 缓存清理是独立功能（不在 -Repair 里点击执行）' {
    It '默认不在“网络修复”里顺带清 DNS' {
        (Test-CampusShouldFlushDnsOnRepair -Settings (Get-DefaultSettings)) | Should Be $false
    }
    It '把 FlushDnsOnRepair 设为 1 才会顺带清' {
        $s = Get-DefaultSettings
        $s['FlushDnsOnRepair'] = '1'
        (Test-CampusShouldFlushDnsOnRepair -Settings $s) | Should Be $true
    }
    It 'DryRun 不真的清理，但要报告当前条数' {
        $before = Get-CampusDnsCacheCount
        $r = Clear-CampusDnsCache -DryRun -LogFile $null
        $r.Ok | Should Be $true
        $r.Reason | Should Be 'DryRun'
        $r.Before | Should Be $before
        # 真实的缓存条数应为 0 或正数（取不到才是 -1）
        ($r.Before -ge -1) | Should Be $true
    }
    It '能取到 DNS 缓存条数（不可用时返回 -1，不抛异常）' {
        $n = Get-CampusDnsCacheCount
        ($n -ge -1) | Should Be $true
    }
}

Describe '日志归档（logs\<日期>\）' {
    It '按日期算出日志目录：<脚本目录>\logs\<yyyy-MM-dd>' {
        $d = Get-CampusLogDir -ScriptDir 'C:\x' -Date ([datetime]'2026-09-28')
        $d | Should Be 'C:\x\logs\2026-09-28'
    }
    It 'LogDirName 是空白时回落到 logs' {
        $d = Get-CampusLogDir -ScriptDir 'C:\x' -LogDirName '   ' -Date ([datetime]'2026-09-28')
        (Split-Path -Leaf (Split-Path -Parent $d)) | Should Be 'logs'
    }
    It '四种日志种类各自对应固定文件名（每天最多 4 个文件）' {
        $sd = 'C:\x'; $dt = [datetime]'2026-09-28'
        (Split-Path -Leaf (Get-CampusLogFile -ScriptDir $sd -Kind main     -Date $dt)) | Should Be 'CampusNet_Log.txt'
        (Split-Path -Leaf (Get-CampusLogFile -ScriptDir $sd -Kind launcher -Date $dt)) | Should Be 'CampusNet_Launcher.log'
        (Split-Path -Leaf (Get-CampusLogFile -ScriptDir $sd -Kind silent   -Date $dt)) | Should Be 'CampusNet_Silent.log'
        (Split-Path -Leaf (Get-CampusLogFile -ScriptDir $sd -Kind fatal    -Date $dt)) | Should Be 'CampusNet_Fatal.log'
    }
    It '保留天数设 0 时永不清理' {
        (Get-ExpiredLogDirs -ScriptDir 'C:\x' -RetentionDays 0).Dirs.Count | Should Be 0
    }
    It '日志根目录还不存在时返回空列表，不报错' {
        $none = Join-Path $env:TEMP ('campusnet-nope-' + [guid]::NewGuid().ToString('N'))
        (Get-ExpiredLogDirs -ScriptDir $none -RetentionDays 30).Dirs.Count | Should Be 0
    }
    It '只挑超期目录：当天不删、未超期不删、非日期名一律不碰' {
        $root = Join-Path $env:TEMP ('campusnet-logtest-' + [guid]::NewGuid().ToString('N'))
        $logRoot = Join-Path $root 'logs'
        $null = New-Item -ItemType Directory -Path $logRoot -Force
        $today  = Get-Date
        $old    = $today.AddDays(-100).ToString('yyyy-MM-dd')
        $recent = $today.AddDays(-3).ToString('yyyy-MM-dd')
        foreach ($n in @($old, $recent, 'not-a-date')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $logRoot $n) -Force
        }
        try {
            $r = Get-ExpiredLogDirs -ScriptDir $root -RetentionDays 30
            $r.Dirs.Count | Should Be 1
            (Split-Path -Leaf $r.Dirs[0]) | Should Be $old
            # 目录都还在（Get-ExpiredLogDirs 只算不删）
            (Test-Path -LiteralPath (Join-Path $logRoot $recent)) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $logRoot 'not-a-date')) | Should Be $true
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It '启动时建好当天目录，并只删掉超期目录' {
        $root = Join-Path $env:TEMP ('campusnet-clear-' + [guid]::NewGuid().ToString('N'))
        $logRoot = Join-Path $root 'logs'
        $null = New-Item -ItemType Directory -Path $logRoot -Force
        $today = Get-Date
        $old   = $today.AddDays(-100).ToString('yyyy-MM-dd')
        $recent= $today.AddDays(-3).ToString('yyyy-MM-dd')
        foreach ($n in @($old, $recent)) { $null = New-Item -ItemType Directory -Path (Join-Path $logRoot $n) -Force }
        try {
            $r = Clear-ExpiredCampusLogs -ScriptDir $root -RetentionDays 30
            (Split-Path -Leaf $r.Dir) | Should Be $today.ToString('yyyy-MM-dd')
            $r.Removed | Should Be 1
            (Test-Path -LiteralPath (Join-Path $logRoot $old))    | Should Be $false   # 超期 → 已删
            (Test-Path -LiteralPath (Join-Path $logRoot $recent)) | Should Be $true    # 未超期 → 保留
            (Test-Path -LiteralPath $r.Dir)                      | Should Be $true    # 当天目录 → 已建好
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It '清理失败也不会抛异常（路径不存在时返回 0 个已删）' {
        $none = Join-Path $env:TEMP ('campusnet-clear2-' + [guid]::NewGuid().ToString('N'))
        $r = Clear-ExpiredCampusLogs -ScriptDir $none -RetentionDays 30
        $r.Removed | Should Be 0
    }
}

Describe '日志路径安全与配置解析（防回归）' {
    It 'Resolve-CampusLogDirName 放行正常名字' {
        (Resolve-CampusLogDirName -LogDirName 'logs')      | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'my-logs')   | Should Be 'my-logs'
        (Resolve-CampusLogDirName -LogDirName '  logs  ')  | Should Be 'logs'
    }
    It 'Resolve-CampusLogDirName 拒绝越界名：.. / 绝对路径 / 分隔符 / 通配符' {
        (Resolve-CampusLogDirName -LogDirName '')        | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName '..')      | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName '..\..')   | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'a\b')     | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'a/b')     | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'C:\temp') | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'lo*gs')   | Should Be 'logs'
        (Resolve-CampusLogDirName -LogDirName 'lo[g]s')  | Should Be 'logs'
    }
    It '越界的 LogDir 不会把关照范围移出脚本目录' {
        $d = Get-CampusLogDir -ScriptDir 'C:\x' -LogDirName '..\..' -Date ([datetime]'2026-09-28')
        $d | Should Be 'C:\x\logs\2026-09-28'
    }

    # 下面两条是**源码级回归守卫**：这两个入口脚本的配置解析发生在 `. Common` 之前，
    # 没法 dot-source 后调用，所以只能读源码断言"没写回老坑 / 名字没漂移"。
    $entryDir = Join-Path (Split-Path -Parent $here) 'CampusNet_AutoLogin'
    It '入口脚本解析 LogRetentionDays=0 时不会当成“没配”（0 是 falsy 的老坑）' {
        foreach ($n in @('CampusNet_Login.ps1', 'CampusNet_Silent.ps1')) {
            $t = Get-Content -LiteralPath (Join-Path $entryDir $n) -Raw -Encoding UTF8
            # 反面：不能再用 if ($rawCfg.Settings.X) 这种把 0 当 false 的写法
            ($t -match 'if\s*\(\s*\$rawCfg\.Settings\.LogRetentionDays\s*\)') | Should Be $false
            # 正面：必须用 $null -ne 判断
            ($t -match '\$null -ne \$rawCfg\.Settings\.LogRetentionDays') | Should Be $true
        }
    }
    It '入口脚本写死的日志文件名与 Get-CampusLogFile 一致（防两处漂移）' {
        $expect = @{
            'CampusNet_Login.ps1'  = @{ main = 'CampusNet_Log.txt'; launcher = 'CampusNet_Launcher.log'; fatal = 'CampusNet_Fatal.log' }
            'CampusNet_Silent.ps1' = @{ main = 'CampusNet_Log.txt'; silent   = 'CampusNet_Silent.log';   fatal = 'CampusNet_Fatal.log' }
        }
        foreach ($n in $expect.Keys) {
            $t = Get-Content -LiteralPath (Join-Path $entryDir $n) -Raw -Encoding UTF8
            foreach ($kind in $expect[$n].Keys) {
                $want = $expect[$n][$kind]
                (Split-Path -Leaf (Get-CampusLogFile -ScriptDir 'C:\x' -Kind $kind)) | Should Be $want
                ($t.Contains($want)) | Should Be $true
            }
        }
    }
}
