<#
  Run-Tests.ps1 —— 运行 CampusNet 的 Pester 单元测试。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

  退出码：0 = 全部通过；1 = 有失败；2 = 未安装 Pester。
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$testFile = Join-Path $here 'CampusNet.Common.Tests.ps1'

if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host '未找到 Pester 模块。Windows 10/11 通常自带 Pester 3.4；' -ForegroundColor Yellow
    Write-Host '如缺失可运行： Install-Module Pester -Scope CurrentUser -Force' -ForegroundColor Yellow
    exit 2
}

Import-Module Pester -ErrorAction SilentlyContinue

# Pester 3.4 会重置控制台编码，这里再设一次以免中文测试名乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$result = Invoke-Pester -Path $testFile -PassThru

Write-Host ''
Write-Host ("通过 {0} / 失败 {1} / 跳过 {2}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount) -ForegroundColor Cyan

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
