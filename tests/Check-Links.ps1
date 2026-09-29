# ============================================================
#  Check-Links.ps1 —— Markdown 链接自检
#
#  作用：扫描仓库里所有 .md（以及 NOTICE / LICENSE 这类无扩展名文件），
#        检查里面引用的相对路径是否真实存在。
#        改过文件名/搬过目录后跑一次，能立刻发现“文档指向空气”的问题。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File tests\Check-Links.ps1
#     npm run check:links
#
#  判定：
#     · Markdown 链接  ](...)     不存在 → 记为「断链」（会让脚本以非 0 退出）
#     · 反引号里的路径 `...`      不存在 → 记为「提示」（不算失败：很多是
#                                  .gitignore 示例、通配符或协议里的 URL）
#
#  会跳过：http/https/ftp/mailto、纯锚点 #xxx、含 < > * ? 的占位符与通配符。
#  会对 %20、%E4%BD%BF… 这类百分号编码先解码再判断（中文文件名常见）。
# ============================================================
[CmdletBinding()]
param(
    # 要检查的根目录，默认取本脚本所在目录的上一级（即仓库根）
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host "[错误] 目录不存在：$Root" -ForegroundColor Red
    exit 2
}

$broken  = New-Object System.Collections.ArrayList   # 断链（算失败）
$hints   = New-Object System.Collections.ArrayList   # 提示（不算失败）
$mdCount = 0
$linkCount = 0

# 判断一个目标是不是"没必要/不能按文件路径检查"的
function Test-SkippableTarget {
    param([string]$t)
    if ([string]::IsNullOrWhiteSpace($t)) { return $true }
    if ($t -match '^(https?|ftp|mailto):') { return $true }
    if ($t.StartsWith('#')) { return $true }
    if ($t -match '[<>*?…]') { return $true }       # 占位符、通配符、省略号缩写（… 或 ...）
    if ($t -match '^(\.\.\.|…{1,2}/)') { return $true }   # 以缩写开头，如 …/annotated/xx.js
    if ($t -match '^[A-Za-z]:') { return $true }   # 绝对路径
    return $false
}

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object {
               $_.FullName -notmatch '[\\/]\.git[\\/]' -and
               ($_.Extension -eq '.md' -or $_.Name -in @('NOTICE', 'LICENSE', 'LICENCE', 'COPYING'))
           })

foreach ($f in $files) {
    $mdCount++
    $dir = $f.DirectoryName
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8

    # ① Markdown 链接 ](target)
    foreach ($m in [regex]::Matches($text, '\]\(([^)]+)\)')) {
        $raw = $m.Groups[1].Value.Trim()
        # 去掉可选的标题：](path "标题")
        $raw = ($raw -split '\s+"')[0]
        $target = $raw
        if ($target.Contains('#')) { $target = $target.Substring(0, $target.IndexOf('#')) }
        if (Test-SkippableTarget $target) { continue }

        $decoded = $target
        try { $decoded = [uri]::UnescapeDataString($target) } catch { }

        $linkCount++
        $p = Join-Path $dir $decoded
        if (-not (Test-Path -LiteralPath $p)) {
            [void]$broken.Add([pscustomobject]@{
                File   = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
                Target = $decoded
            })
        }
    }

    # ② 反引号里的路径（仅提示）：形如 `a/b/c.md`
    #    逐行扫，方便跳过"改写名对照表"的行（含 → 的行本来就是列旧名，不是失效引用）
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Contains([char]0x2192)) { continue }   # → 行：改名对照，跳过
        foreach ($m in [regex]::Matches($line, '`([^`]*[/\\][^`]*\.(md|ps1|psm1|bat|cmd|json|har|js|txt|css|htm|html|png|ico))`')) {
            $target = $m.Groups[1].Value.Trim()
            if (Test-SkippableTarget $target) { continue }
            if ($target -match '^[/\\]') { continue }     # /CampusNet_Log.txt 这类 .gitignore 规则

            $decoded = $target
            try { $decoded = [uri]::UnescapeDataString($target) } catch { }

            # 相对当前文件、相对仓库根，两处都找不到才提示
            if (-not (Test-Path -LiteralPath (Join-Path $dir $decoded)) -and
                -not (Test-Path -LiteralPath (Join-Path $Root $decoded))) {
                [void]$hints.Add([pscustomobject]@{
                    File   = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
                    Target = $decoded
                })
            }
        }
    }
}

Write-Host ""
Write-Host "检查 $mdCount 个文档，Markdown 链接 $linkCount 条" -ForegroundColor Cyan

if ($hints.Count -gt 0) {
    Write-Host ""
    Write-Host "[提示] 反引号里的路径可能已失效（$($hints.Count) 处，请人工看一眼）：" -ForegroundColor Yellow
    foreach ($h in $hints) { Write-Host "   ? $($h.File)  ->  $($h.Target)" -ForegroundColor DarkYellow }
}

if ($broken.Count -gt 0) {
    Write-Host ""
    Write-Host "[失败] 断链 $($broken.Count) 处：" -ForegroundColor Red
    foreach ($b in $broken) { Write-Host "   X $($b.File)  ->  $($b.Target)" -ForegroundColor Red }
    Write-Host ""
    Write-Host "断链 $($broken.Count) 处" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "断链 0 处" -ForegroundColor Green
exit 0
