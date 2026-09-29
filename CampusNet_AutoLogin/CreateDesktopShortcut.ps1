#Requires -Version 5.1
<#
  CreateDesktopShortcut.ps1
  在桌面创建指向 CampusNet.bat 的快捷方式（自动定位脚本所在目录）。
#>
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$batchFile = Join-Path $scriptDir 'CampusNet.bat'

if (-not (Test-Path -LiteralPath $batchFile)) {
    Write-Host "找不到 CampusNet.bat：$batchFile" -ForegroundColor Red
    Write-Host '请确认本脚本与 CampusNet.bat 在同一文件夹。' -ForegroundColor Yellow
    exit 1
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath '校园网登录.lnk'

try {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $batchFile
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.Description = '校园网自动登录'
    $shortcut.IconLocation = 'shell32.dll,13'
    $shortcut.Save()

    Write-Host '桌面快捷方式创建成功！' -ForegroundColor Green
    Write-Host "位置: $shortcutPath" -ForegroundColor Cyan
}
catch {
    Write-Host "创建快捷方式失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '按任意键退出...' -ForegroundColor Gray
try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
