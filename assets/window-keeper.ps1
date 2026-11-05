# window-keeper.ps1 — 记住并恢复 DSH 桌面窗口的位置、大小、最大化状态
# 设计原则：只依赖 Win32 + 文件系统，不依赖 DSH 版本、不调用任何 DSH 内部接口。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File window-keeper.ps1          # 常驻看守
#   powershell -NoProfile -ExecutionPolicy Bypass -File window-keeper.ps1 -Apply   # 只应用一次后退出
# 同目录：config.json（enabled）、window-state.json、keeper.pid、keeper.log

param([switch]$Apply)

$ErrorActionPreference = 'SilentlyContinue'
$Root      = $PSScriptRoot
$StateFile = Join-Path $Root 'window-state.json'
$ConfigFile= Join-Path $Root 'config.json'
$PidFile   = Join-Path $Root 'keeper.pid'
$LogFile   = Join-Path $Root 'keeper.log'

function Write-Log($msg) {
  $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ---- 配置：enabled=false 时直接退出（插件壳的开关就是改这里）----
$enabled = $true
if (Test-Path $ConfigFile) {
  try { $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $cfg.enabled) { $enabled = [bool]$cfg.enabled } } catch {}
}
if (-not $Apply -and -not $enabled) { exit 0 }

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DshWin {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }
  public static IntPtr Find() {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 2);
      GetWindowText(h, sb, sb.Capacity);
      if (sb.ToString().EndsWith("DeepSeek Harness")) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static WINDOWPLACEMENT Placement(IntPtr h) {
    WINDOWPLACEMENT p = new WINDOWPLACEMENT();
    p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    GetWindowPlacement(h, ref p);
    return p;
  }
}
"@

function Read-State {
  if (-not (Test-Path $StateFile)) { return $null }
  try { return Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function State-Valid($s) {
  if ($null -eq $s) { return $false }
  if ($s.width -lt 520 -or $s.height -lt 600) { return $false }
  if ($s.width -gt 10000 -or $s.height -gt 10000) { return $false }
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($s.x -lt ($vs.Left - 100) -or $s.y -lt ($vs.Top - 100)) { return $false }
    if ($s.x -gt ($vs.Right - 200) -or $s.y -gt ($vs.Bottom - 200)) { return $false }
  } catch { return $true }
  return $true
}

function Save-State($p) {
  $obj = [ordered]@{
    x         = [int]$p.rcNormalPosition.Left
    y         = [int]$p.rcNormalPosition.Top
    width     = [int]($p.rcNormalPosition.Right - $p.rcNormalPosition.Left)
    height    = [int]($p.rcNormalPosition.Bottom - $p.rcNormalPosition.Top)
    maximized = ($p.showCmd -eq 3)
    updated   = (Get-Date).ToString('o')
  }
  $tmp = "$StateFile.tmp"
  ($obj | ConvertTo-Json) | Set-Content -Path $tmp -Encoding UTF8
  Move-Item -Force $tmp $StateFile
  Write-Log ("saved {0}x{1} @ {2},{3} max={4}" -f $obj.width, $obj.height, $obj.x, $obj.y, $obj.maximized)
}

function Apply-State($hwnd, $s) {
  $ok = [DshWin]::MoveWindow($hwnd, [int]$s.x, [int]$s.y, [int]$s.width, [int]$s.height, $true)
  Write-Log ("apply {0}x{1} @ {2},{3} -> MoveWindow={4}" -f $s.width, $s.height, $s.x, $s.y, $ok)
  if ($s.maximized) { Start-Sleep -Milliseconds 120; [void][DshWin]::ShowWindow($hwnd, 3) }
}

Add-Type -AssemblyName System.Windows.Forms

if ($Apply) {
  $hwnd = [DshWin]::Find()
  if ($hwnd -eq [IntPtr]::Zero) { Write-Log 'apply: window not found'; exit 1 }
  $s = Read-State
  if (-not (State-Valid $s)) { Write-Log 'apply: no valid state'; exit 2 }
  Apply-State $hwnd $s
  exit 0
}

# 单实例：已有 keeper 在跑就退出
if (Test-Path $PidFile) {
  try {
    $old = [int](Get-Content $PidFile -Raw)
    if ($old -gt 0 -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
      Write-Log "keeper already running (pid $old), exit"
      exit 0
    }
  } catch {}
}
Set-Content -Path $PidFile -Value $PID -Encoding ASCII
Write-Log "keeper started (pid $PID)"

$currentHwnd = [IntPtr]::Zero
$appliedHwnd = [IntPtr]::Zero
$lastRect = ''
$lastMax = $null

while ($true) {
  $hwnd = [DshWin]::Find()
  if ($hwnd -eq [IntPtr]::Zero) {
    if ($currentHwnd -ne [IntPtr]::Zero) { Write-Log 'window closed'; $currentHwnd = [IntPtr]::Zero }
    Start-Sleep -Milliseconds 900
    continue
  }

  if ($hwnd -ne $currentHwnd) {
    $currentHwnd = $hwnd
    Start-Sleep -Milliseconds 1200
    $s = Read-State
    if ((State-Valid $s) -and ($hwnd -ne $appliedHwnd)) {
      Apply-State $hwnd $s
      $appliedHwnd = $hwnd
    }
  }

  $p = [DshWin]::Placement($hwnd)
  if ($p.showCmd -ne 2) {
    $rect = ('{0},{1},{2},{3}' -f $p.rcNormalPosition.Left, $p.rcNormalPosition.Top, $p.rcNormalPosition.Right, $p.rcNormalPosition.Bottom)
    $max = ($p.showCmd -eq 3)
    if ($rect -ne $lastRect -or $max -ne $lastMax) {
      Save-State $p
      $lastRect = $rect
      $lastMax = $max
    }
  }
  Start-Sleep -Milliseconds 900
}
