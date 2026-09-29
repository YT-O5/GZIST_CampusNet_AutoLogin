# ============================================================
#  Check-Syntax.ps1 —— 语法自检（交接/提交前必跑）
#
#  作用：把项目里所有 .ps1 / .psm1 交给 PowerShell 解析器做**纯语法检查**，
#        不执行任何逻辑、不碰网络、不改文件。
#  为什么要单独有这一关：
#        .ps1 存成无 BOM 的 UTF-8 时，Windows PowerShell 5.1 会按 ANSI 读，
#        中文注释会变成乱码并引发语法错误；字符串引号写错、括号不配也在这里暴露。
#        这类错误往往要到运行时才炸，提前查最省事。
#
#  用法：
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Check-Syntax.ps1
#      npm run check                      （等价写法）
#      由 npm test 自动调用（package.json 的 pretest）
#
#  退出码：0 = 全部通过；非 0 = 有文件解析失败（数量即失败文件数）
# ============================================================
[CmdletBinding()]
param(
    # 要检查的根目录；留空则默认项目根（本文件在 tests\ 下，上一级即项目根）
    [string]$Root,

    # 跳过这些子目录（默认跳过依赖与版本库目录）
    [string[]]$ExcludeDir = @('node_modules', '.git')
)

$ErrorActionPreference = 'Stop'

# 注意：不能用 $MyInvocation 写在 param 默认值里——那时它还没初始化（真实踩过）
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$errors = 0
$checked = 0

Write-Host ''
Write-Host '=== 语法自检 ===' -ForegroundColor Cyan

$files = Get-ChildItem -Path $Root -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $path = $_.FullName
        -not ($ExcludeDir | Where-Object { $path -like "*\$_\*" })
    } | Sort-Object FullName

foreach ($f in $files) {
    $checked++
    $tokens = $null
    $parseErrors = $null

    # 只解析、不执行
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $errors++
        Write-Host ("  [失败] " + $f.Name) -ForegroundColor Red
        foreach ($e in $parseErrors) {
            Write-Host ("         L{0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor DarkRed
        }
    }
    else {
        Write-Host ("  [通过] " + $f.Name) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host ("检查 {0} 个文件，失败 {1} 个" -f $checked, $errors) -ForegroundColor $(if ($errors -eq 0) { 'Green' } else { 'Red' })

# 一个文件都没扫到，说明 -Root 指错了（而不是"全都通过"）——不能静默当成功
if ($checked -eq 0) {
    Write-Host ("未找到任何 .ps1/.psm1，请检查 -Root 是否指对：{0}" -f $Root) -ForegroundColor Red
    exit 1
}

if ($errors -gt 0) {
    Write-Host '提示：若报的是中文乱码类语法错，请把该 .ps1 另存为 UTF-8 with BOM。' -ForegroundColor Yellow
}

exit $errors
