# install.ps1 - install / uninstall dsh-window-keeper (script track, no DSH plugin needed)
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoAutostart
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

param(
  [string]$Dir = (Join-Path $env:LOCALAPPDATA 'dsh-window-keeper'),
  [switch]$NoAutostart,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$LnkPath    = Join-Path $StartupDir 'dsh-window-keeper.lnk'
$OldVbs     = Join-Path $StartupDir 'dsh-window-keeper.vbs'
$PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'

function Stop-Keeper {
  $pidFile = Join-Path $Dir 'keeper.pid'
  if (Test-Path $pidFile) {
    try {
      $old = [int](Get-Content $pidFile -Raw)
      if ($old -gt 0) { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue }
    } catch {}
  }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*window-keeper.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
  Stop-Keeper
  Remove-Item $LnkPath -Force -ErrorAction SilentlyContinue
  Remove-Item $OldVbs -Force -ErrorAction SilentlyContinue
  Write-Host "Uninstalled: keeper stopped, autostart entry removed. Files kept in $Dir." -ForegroundColor Yellow
  return
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\assets\window-keeper.ps1') (Join-Path $Dir 'window-keeper.ps1') -Force

$cfgPath = Join-Path $Dir 'config.json'
if (-not (Test-Path $cfgPath)) {
  '{ "enabled": true, "autostart": true }' | Set-Content $cfgPath -Encoding UTF8
}

# Launch through wscript + a UTF-16 .vbs: wscript is a GUI subsystem process, so
# no console window flashes; UTF-16 BOM keeps a non-ASCII user name intact
# (WScript reads BOM-less .vbs as ANSI and would mangle the path).
Remove-Item $OldVbs -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $Dir 'start-hidden.vbs') -Force -ErrorAction SilentlyContinue

$vbsPath = Join-Path $Dir 'launch-hidden.vbs'
$vbs = "' dsh-window-keeper launcher - generated, do not edit`r`n" +
       "CreateObject(`"WScript.Shell`").Run `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$Dir\window-keeper.ps1`"`"`", 0, False`r`n"
# Encoding.Unicode = UTF-16LE with BOM, which WScript understands
[System.IO.File]::WriteAllText($vbsPath, $vbs, [System.Text.Encoding]::Unicode)

if (-not $NoAutostart) {
  New-Item -ItemType Directory -Force -Path $StartupDir | Out-Null
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($LnkPath)
  $sc.TargetPath = $WscriptExe
  $sc.Arguments = "`"$vbsPath`""
  $sc.WindowStyle = 7
  $sc.Save()
}

Stop-Keeper
Start-Process $WscriptExe -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden

Write-Host ""
Write-Host "Installed:" -ForegroundColor Green
Write-Host "  program dir : $Dir"
Write-Host "  autostart   : $(if ($NoAutostart) { 'skipped (-NoAutostart)' } else { $LnkPath })"
Write-Host "  config      : $cfgPath  (set enabled:false to pause)"
Write-Host "  log         : $(Join-Path $Dir 'keeper.log')"
Write-Host ""
Write-Host "Resize the DSH window now; the next launch will restore this size." -ForegroundColor Cyan
