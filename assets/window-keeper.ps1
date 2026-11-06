# window-keeper.ps1 - remember and restore the DSH desktop window geometry.
# Design: Win32 + filesystem only. No dependency on the DSH client version.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File window-keeper.ps1        # watch loop
#   powershell -NoProfile -ExecutionPolicy Bypass -File window-keeper.ps1 -Apply # apply once, exit
# Files beside this script: config.json, window-state.json, keeper.pid, keeper.log
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

param([switch]$Apply)

$ErrorActionPreference = 'SilentlyContinue'
$Root      = $PSScriptRoot
$StateFile = Join-Path $Root 'window-state.json'
$ConfigFile= Join-Path $Root 'config.json'
$PidFile   = Join-Path $Root 'keeper.pid'
$LogFile   = Join-Path $Root 'keeper.log'

# Minimum geometry of the real main window. Splash / toast / helper windows are
# much smaller and must never be treated as "the window".
$MinWidth  = 800
$MinHeight = 600

function Write-Log($msg) {
  $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

$enabled = $true
if (Test-Path $ConfigFile) {
  try { $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $cfg.enabled) { $enabled = [bool]$cfg.enabled } } catch {}
}
if (-not $Apply -and -not $enabled) { exit 0 }

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
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
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }
  /** Largest visible window whose title ends with "DeepSeek Harness". */
  public static IntPtr Find(int minW, int minH) {
    IntPtr best = IntPtr.Zero;
    long bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h);
      if (len == 0) return true;
      StringBuilder sb = new StringBuilder(len + 2);
      GetWindowText(h, sb, sb.Capacity);
      if (!sb.ToString().EndsWith("DeepSeek Harness")) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      int w = r.Right - r.Left;
      int hh = r.Bottom - r.Top;
      if (w < minW || hh < minH) return true;
      long area = (long)w * hh;
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
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
  $hwnd = [DshWin]::Find($MinWidth, $MinHeight)
  if ($hwnd -eq [IntPtr]::Zero) { Write-Log 'apply: window not found'; exit 1 }
  $s = Read-State
  if (-not (State-Valid $s)) { Write-Log 'apply: no valid state'; exit 2 }
  Apply-State $hwnd $s
  exit 0
}

# single instance
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
  $hwnd = [DshWin]::Find($MinWidth, $MinHeight)
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
