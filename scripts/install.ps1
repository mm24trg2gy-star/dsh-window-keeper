# install.ps1 — 安装/卸载 DSH 窗口记忆（脚本轨，不依赖 DSH 插件）
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoAutostart
param(
  [string]$Dir = (Join-Path $env:LOCALAPPDATA 'dsh-window-keeper'),
  [switch]$NoAutostart,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$VbsPath = Join-Path $StartupDir 'dsh-window-keeper.vbs'

function Stop-Keeper {
  if (Test-Path (Join-Path $Dir 'keeper.pid')) {
    try {
      $old = [int](Get-Content (Join-Path $Dir 'keeper.pid') -Raw)
      if ($old -gt 0) { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue }
    } catch {}
  }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$Dir*window-keeper.ps1*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
  Stop-Keeper
  if (Test-Path $VbsPath) { Remove-Item $VbsPath -Force }
  Write-Host "已卸载：守护进程已停、启动项已移除。目录保留在 $Dir（确认无误后可手动删除）。" -ForegroundColor Yellow
  return
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\assets\window-keeper.ps1') (Join-Path $Dir 'window-keeper.ps1') -Force

$cfgPath = Join-Path $Dir 'config.json'
if (-not (Test-Path $cfgPath)) {
  '{ "enabled": true }' | Set-Content $cfgPath -Encoding UTF8
}

$vbs = @"
' 由 dsh-window-keeper 自动生成，请勿手改
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$Dir\window-keeper.ps1""", 0, False
"@
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $Dir 'start-hidden.vbs'), $vbs, $utf8NoBom)

if (-not $NoAutostart) {
  New-Item -ItemType Directory -Force -Path $StartupDir | Out-Null
  [System.IO.File]::WriteAllText($VbsPath, $vbs, $utf8NoBom)
}

Stop-Keeper
Start-Process wscript.exe -ArgumentList "`"$(Join-Path $Dir 'start-hidden.vbs')`"" -WindowStyle Hidden

Write-Host ""
Write-Host "安装完成：" -ForegroundColor Green
Write-Host "  程序目录 : $Dir"
Write-Host "  自启项   : $(if ($NoAutostart) { '未安装（-NoAutostart）' } else { $VbsPath })"
Write-Host "  配置     : $cfgPath  （enabled: false 可停用）"
Write-Host "  日志     : $(Join-Path $Dir 'keeper.log')"
Write-Host ""
Write-Host "现在把 DSH 窗口拖到你想要的大小，下次启动就会回到这个尺寸。" -ForegroundColor Cyan
