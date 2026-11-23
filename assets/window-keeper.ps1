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

# Minimum geometry of the real main window. The Electron shell allows 520x600;
# anything smaller is a splash / toast / helper window.
$MinWidth  = 520
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
  [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
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
  public static bool Restore(IntPtr h, int x, int y, int w, int hh, bool maximized) {
    WINDOWPLACEMENT p = new WINDOWPLACEMENT();
    p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    p.flags = 0;
    p.showCmd = maximized ? 3 : 1;
    p.rcNormalPosition.Left = x;
    p.rcNormalPosition.Top = y;
    p.rcNormalPosition.Right = x + w;
    p.rcNormalPosition.Bottom = y + hh;
    return SetWindowPlacement(h, ref p);
  }
  public static bool Verify(IntPtr h, int x, int y, int w, int hh, bool maximized) {
    WINDOWPLACEMENT p = Placement(h);
    if ((p.showCmd == 3) != maximized) return false;
    int dx = Math.Abs(p.rcNormalPosition.Left - x) + Math.Abs(p.rcNormalPosition.Top - y);
    int dw = Math.Abs((p.rcNormalPosition.Right - p.rcNormalPosition.Left) - w) + Math.Abs((p.rcNormalPosition.Bottom - p.rcNormalPosition.Top) - hh);
    return dx <= 2 && dw <= 2;
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
  # Pair GetWindowPlacement/SetWindowPlacement: rcNormalPosition is the same coordinate
  # space both ways, so multi-monitor / taskbar-position changes cannot skew the restore.
  $x = [int]$s.x
  $y = [int]$s.y
  $w = [int]$s.width
  $h = [int]$s.height
  $max = [bool]$s.maximized
  if (-not [DshWin]::IsWindow($hwnd)) { Write-Log 'apply: window gone before restore'; return $false }
  $ok = [DshWin]::Restore($hwnd, $x, $y, $w, $h, $max)
  Write-Log ("apply {0}x{1} @ {2},{3} max={4} -> SetWindowPlacement={5}" -f $w, $h, $x, $y, $max, $ok)
  if (-not $ok) { return $false }
  Start-Sleep -Milliseconds 150
  if (-not [DshWin]::Verify($hwnd, $x, $y, $w, $h, $max)) {
    Write-Log 'apply: verification failed (geometry or show state did not match)'
    return $false
  }
  return $true
}

Add-Type -AssemblyName System.Windows.Forms

if ($Apply) {
  $hwnd = [DshWin]::Find($MinWidth, $MinHeight)
  if ($hwnd -eq [IntPtr]::Zero) { Write-Log 'apply: window not found'; exit 1 }
  $s = Read-State
  if (-not (State-Valid $s)) { Write-Log 'apply: no valid state'; exit 2 }
  $applied = Apply-State $hwnd $s
  if (-not $applied) { Write-Log 'apply: MoveWindow failed'; exit 3 }
  exit 0
}

# single instance: the pid file is JSON (pid + startedAt + script) and the command
# line is checked, so a recycled PID never counts as "keeper still alive".
function Test-KeeperPid($rec) {
  if (-not ($rec -and $rec.pid)) { return $false }
  $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$rec.pid) -ErrorAction SilentlyContinue
  if (-not $proc) { return $false }
  if ($proc.CommandLine -notlike '*window-keeper.ps1*') { return $false }
  if ($null -ne $rec.startedAt) {
    try {
      $want = [int64]$rec.startedAt
      $procEpoch = [int64]([DateTimeOffset]$proc.CreationDate).ToUnixTimeSeconds()
      if ([math]::Abs($procEpoch - $want) -gt 3) { return $false }
    } catch {
      # Legacy records store an ISO string; the command line above already matched.
    }
  }
  return $true
}

$existing = $null
if (Test-Path $PidFile) {
  try { $existing = Get-Content $PidFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existing = $null }
  if ($null -ne $existing -and -not ($existing -is [pscustomobject])) { $existing = [ordered]@{ pid = [int]$existing } }
}
if (Test-KeeperPid $existing) {
  Write-Log ("keeper already running (pid " + $existing.pid + "), exit")
  exit 0
}

$startedAt = [int64]([DateTimeOffset](Get-Process -Id $PID).StartTime).ToUnixTimeSeconds()
$record = [ordered]@{ pid = $PID; startedAt = $startedAt; script = $PSCommandPath }
($record | ConvertTo-Json) | Set-Content -Path $PidFile -Encoding UTF8
Write-Log ("keeper started (pid $PID)")

$currentHwnd = [IntPtr]::Zero
$appliedHwnd = [IntPtr]::Zero
$lastRect = ''
$lastMax = $null
# First sight of a window only records a baseline; it never writes state, or the
# default-size first frame would overwrite the size the user actually chose.
$baselineRect = $null
$baselineMax = $null

while ($true) {
  try {
    $hwnd = [DshWin]::Find($MinWidth, $MinHeight)
    if ($hwnd -eq [IntPtr]::Zero) {
      if ($currentHwnd -ne [IntPtr]::Zero) { Write-Log 'window closed' }
      $currentHwnd = [IntPtr]::Zero
      $appliedHwnd = [IntPtr]::Zero
      $baselineRect = $null
      $baselineMax = $null
      Start-Sleep -Milliseconds 900
      continue
    }

    if ($hwnd -ne $currentHwnd) {
      $currentHwnd = $hwnd
      $baselineRect = $null
      $baselineMax = $null
      Start-Sleep -Milliseconds 1200
      $s = Read-State
      if ((State-Valid $s) -and ($hwnd -ne $appliedHwnd)) {
        if (Apply-State $hwnd $s) { $appliedHwnd = $hwnd }
        else { Write-Log 'apply failed; retry on next window event' }
      }
    }

    # The handle may die between two calls (drag/close/recreate); verify it first.
    if (-not [DshWin]::IsWindow($hwnd)) { $currentHwnd = [IntPtr]::Zero; continue }

    $p = [DshWin]::Placement($hwnd)
    if ($p.showCmd -ne 2) {
      $rect = ('{0},{1},{2},{3}' -f $p.rcNormalPosition.Left, $p.rcNormalPosition.Top, $p.rcNormalPosition.Right, $p.rcNormalPosition.Bottom)
      $max = ($p.showCmd -eq 3)
      if ($null -eq $baselineRect) {
        $baselineRect = $rect
        $baselineMax = $max
        $lastRect = $rect
        $lastMax = $max
      } elseif ($rect -ne $baselineRect -or $max -ne $baselineMax) {
        Save-State $p
        $baselineRect = $rect
        $baselineMax = $max
        $lastRect = $rect
        $lastMax = $max
      }
    }
  } catch {
    Write-Log ("loop error: " + $_.Exception.Message)
    $currentHwnd = [IntPtr]::Zero
    Start-Sleep -Milliseconds 1500
  }
  Start-Sleep -Milliseconds 900
}
