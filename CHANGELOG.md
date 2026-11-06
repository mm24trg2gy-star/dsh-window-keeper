# Changelog

## 0.1.2 — 2026-11-06

- 修复：守护进程改为经 WMI 创建（`Win32_Process.Create`）。`child_process.spawn` 带 `detached: true` 时，Windows 上的 powershell 会立刻退出且不留日志——0.1.1 里守护仍然起不来就是这个原因。
- 修复：宿主卸载（DSH 重启）时不再停守护进程。之前每次重启都会 `stop pid`，窗口记忆在重启后必然失效。
- 修复：读取 `window-state.json` 时去掉 BOM，设置页不会再显示「还没有记录」。

## 0.1.1 — 2026-11-06

- 修复：主窗口识别改为「标题以 `DeepSeek Harness` 结尾、面积最大、且不小于 800×600」。启动画面和小窗口不再被当成主窗口（0.1.0 里会把窗口缩回默认尺寸）。
- 修复：自启从 `.vbs` 换成 `.lnk`。用户目录名含中文时，WScript 按 ANSI 读取无 BOM 的 `.vbs` 会得到乱码路径，守护进程实际上从未启动。
- 修复：`window-keeper.ps1` 改为纯 ASCII，避免 Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 解析而报语法错误。
- 改进：安装器的 `Stop-Keeper` 清理所有旧的守护进程，避免新旧两个同时抢窗口。

## 0.1.0 — 2026-11-06

首个版本，双轨发布：

- 脚本轨：`assets/window-keeper.ps1` + `scripts/install.ps1`
  - 记住窗口位置、大小、最大化状态，重开 DSH 时恢复
  - 越界/改分辨率时自动回退，不把窗口丢到屏幕外
  - 单实例锁、日志、`-Apply` 手动触发
- 插件壳：`dsh-window-keeper`
  - 设置页「窗口记忆」：启用开关、自启开关、立即恢复、重启守护、重装脚本、打开目录、日志
  - 只做安装与开关，窗口逻辑仍由脚本承担，不随客户端版本失效
