# dsh-window-keeper

记住 DeepSeek Harness 桌面窗口的**位置、大小和最大化状态**，下次启动回到你上次离开的地方。

DSH 桌面端的建窗代码里写死了 `width: 1280, height: 820`，没有任何持久化逻辑——所以每次重启窗口都会缩回默认大小。这个项目补上这件事。

## 双轨设计

| | 脚本轨（主线） | 插件壳（可选） |
| --- | --- | --- |
| 是什么 | 一个 PowerShell 守护 + 安装脚本 | DSH 插件，负责安装、自启、开关 |
| 依赖 | 只用 Win32，**不依赖 DSH 版本** | 跟插件生态约定走 |
| 适合 | 想一劳永逸、不在乎多一个后台进程 | 想一键装、有设置页开关 |

插件壳里不含窗口逻辑：它把脚本铺到 `%LOCALAPPDATA%\dsh-window-keeper`，管开机自启，再给设置页一个开关。所以 **DSH 怎么升级，窗口记忆本身都不受影响**。

## 和同类插件的区别

| 能力 | 本插件 | myxiyues/dsh-window-size | flying4055/dsh-window-bounds |
| --- | --- | --- | --- |
| 关窗自动记住 | ✅ | ❌ 手动保存 | ✅ |
| 还原最大化 | ✅ | ✅ | ❌ |
| 越界/断屏回退 | ✅ | 仅最小尺寸 | ✅ |
| 不绑客户端版本 | ✅ | ❌ | ❌ |

## 安装

### 脚本轨

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install.ps1
```

装到 `%LOCALAPPDATA%\dsh-window-keeper`，并在「启动」文件夹放入自启项。卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install.ps1 -Uninstall
```

### 插件壳

```
dsh plugin --profile desktop add dsh-window-keeper
```

装完重启客户端，在「设置 → 窗口记忆」里开关。

## 配置

`%LOCALAPPDATA%\dsh-window-keeper\config.json`

```json
{ "enabled": true, "autostart": true }
```

`enabled: false` 时守护启动即退出，不会动窗口。

## 工作原理

1. 常驻脚本每 ~0.9 秒读一次窗口状态（`GetWindowPlacement`）；
2. 尺寸/位置/最大化有变化就写进 `window-state.json`；
3. 检测到 DSH 重新开窗，等 1.2 秒把上次的几何套回去（`MoveWindow` + `ShowWindow(SW_MAXIMIZE)`）；
4. 保存的位置若跑出当前虚拟屏，直接作废回退默认，不会把窗口放到看不见的地方。

只认标题以 `DeepSeek Harness` 结尾的窗口，不碰其它程序。

## 已知限制

- **仅 Windows**（Win32）。
- 启动时会有约 1.2 秒的跳变：脚本要等窗口显示后才动手。想彻底无跳变需要改壳的显示时机，插件做不到。
- 插件壳的设置页依赖 DSH 插件生态约定（`slots` / `webServer`），客户端大版本换代时可能需要更新；脚本轨不受影响。

## 开发

```
lib/index.js     Host 半部：装/卸载脚本、自启、HTTP 接口
lib/client.js    设置页「窗口记忆」
assets/window-keeper.ps1   真正的窗口逻辑
scripts/install.ps1        独立安装器（脚本轨）
```

## 致谢

- **大肥鱼**：这个项目从头到尾是她动的手——从翻 `app.asar` 确认 `createWindow()` 里写死的 `1280×820`，到守护脚本、插件外壳、npm 发布、市场收录 PR。她坚持的两条也留在了代码里：窗口逻辑必须独立于客户端版本；每次 apply 都要留日志。

## License

MIT
