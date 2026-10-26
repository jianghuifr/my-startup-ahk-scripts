# my-startup-ahk-scripts

个人用的 AutoHotkey v2 启动脚本集合：**一个托盘管理器 + 一组互不依赖的小脚本**。

## 快速开始

1. 安装 [AutoHotkey v2.0+](https://www.autohotkey.com/)（所有脚本都带 `#Requires AutoHotkey v2.0`，v1 会拒绝运行）。
2. 把 `startup.ahk` 的快捷方式放进 `shell:startup`（Win+R 输入 `shell:startup`），或直接双击。
3. 托盘图标右键是菜单：点脚本名开/关，另有 Start All / Stop All / Restart All / Open Folder / Rescan Scripts / Reload / Exit。

## 目录结构

```
startup.ahk             管理器：发现脚本、托盘菜单、启动/停止、状态记忆
state.ini               "哪几个脚本该开着"（git 忽略，删掉=下次全部启动）
error.log               运行日志（git 忽略；只追加不轮转，偶尔可以删掉）
startup/                被管理的脚本目录
  HotKeys.ahk
  HotStrings.ahk
  ...
  lib/                  共享代码，不会被当成脚本启动
  SpecificPrograms/     建议"每个程序一个脚本"，显示为子菜单
  Mask/                 目录名与脚本同名 -> 显示为顶层项
tools/                  独立小工具（不被管理器启动）
```

发现规则（`startup.ahk` 的 `DiscoverScripts`）：

- `startup\` 下**每个子目录**是一个子菜单；
- 例外：`lib\` 不扫描；
- 例外：目录中存在与目录**同名**的 `.ahk`（如 `Mask\Mask.ahk`）时，该脚本作为**顶层**菜单项显示；
- 新增/删除脚本后点托盘里的 **Rescan Scripts**（或 Reload）即可刷新菜单，无需重启管理器。

脚本与托盘菜单项重名（`Exit.ahk`、`Reload.ahk` …）时会自动显示为 `Exit (script)`，不会与内置项冲突。

## 状态记忆

- 每次在菜单里开/关脚本都会**立刻**写 `state.ini`，记录的是"用户意图"，不是"当前进程恰好还在不在"。
- 关机时也按这份意图保存。旧版本在 `OnExit` 里现场探测进程，而关机时子脚本已先退出，会把所有脚本记成关，导致下次开机一个都不启动；现在不会了。
- 删掉 `state.ini` 等于恢复默认：下次全部启动。

## `.cli` 参数

与脚本同名的 `.cli` 文件（如 `startup\Foo\Foo.cli`）的第一行会作为命令行参数传给脚本。脚本一律通过 `A_AhkPath` 启动，不依赖 `.ahk` 文件关联。

## 脚本清单

| 脚本 | 功能 |
| --- | --- |
| `HotKeys.ahk` | Ctrl+Win+C 在当前目录开 cmd（+Shift 管理员）；Ctrl+Win+P 开 PowerShell；Ctrl+Shift+Z 所有设置；Ctrl+Shift+E 启动/激活 Everything；媒体控制；屏幕亮度；`` #` `` 在同类窗口间切换；右键+滚轮 → Shift+滚轮 |
| `HotStrings.ahk` | 常见拼写纠正（`retrun`→`return` 之类） |
| `WinMove.ahk` | 按住左键再按右键拖动窗口；未移动即点击 = 最大化/还原；Esc 取消 |
| `OnePixel.ahk` | 按住左键时 WASD 逐像素移动鼠标 |
| `ClipBoardMonitor.ahk` | 复制时提示字符数；`cache\` 存在时归档前 300 个字符（默认不建目录） |
| `Mask/Mask.ahk` | 全屏半透明遮罩，`Mask.ahk 000000`（可传颜色或图片） |
| `WinAlwaysOnTop/` | Ctrl+Space 给当前窗口加/去置顶彩色边框；系统菜单里也有 "📌 Always On Top" |
| `SpecificPrograms/ahk_class CabinetWClass.ahk` | Ctrl+H 显示/隐藏隐藏文件；Ctrl+Shift+M 新建空文件 |
| `SpecificPrograms/ahk_class EVERYTHING.ahk` | Ctrl+L 聚焦搜索框；Alt+Enter 在 cmd 里执行搜索框内容 |
| `SpecificPrograms/ahk_class Shell_TrayWnd.ahk` | 任务栏空白处：双击 = 任务视图，滚轮 = 切换窗口 |
| `SpecificPrograms/ahk_class WeChatMainWndForPC.ahk` | Ctrl+K 点击搜索框 |
| `SpecificPrograms/DeepSeekHarness.ahk` | 把 DeepSeek Harness 主窗口固定在屏幕中央 3/4 |
| `SpecificPrograms/ExplorerPlace.ahk` | Explorer 窗口固定位置并级联，多窗口不重叠 |
| `SpecificPrograms/EverythingCenter.ahk` | Everything 窗口始终居中于所在屏幕，尺寸取该屏幕工作区的 1/2（`RATIO`）；拖动/Win+←→ 后会被拉回 |
| `SpecificPrograms/DeepSeekHarnessAttension.ahk` | 监听 `~\.dsh\attention-signal.json`，需要确认/回合结束时发高优先级 Toast（用 DSH 自己的 AUMID），点击 Toast 激活 DSH 窗口（不再自动置顶） |

`lib/winplace.ahk` 是上面三个"窗口固定"脚本共用的引擎（窗口事件钩子 + 轮询 + 强制归位 + 槽位分配），规则脚本只需要提供 `target(hwnd, slot, state)` 返回一个矩形。
`lib/dshwin.ahk` 负责找到/激活 DSH 主窗口（含最小化和托盘隐藏状态），attention 脚本与 `tools/DSHActivate.ahk` 共用。`tools/DSHToast.ps1` 用 WinRT `ToastNotification` 发通知（`Priority = High`，AUMID 为 `com.deepseek.dsh`），`tools/DSHActivate.ahk` 是 `dsh-attention:` 协议的处理器：attention 脚本启动时自动注册该协议，点击 Toast 时由 Windows 调用它把 DSH 拉到前台。
`lib/everything.ahk` 在 `HotKeys.ahk` 启动时定位 `Everything.exe`，按顺序取第一个可用的：① 仓库根目录的 `everything.path`（一行写 exe 路径或安装目录，`;` 开头是注释；`.gitignore` 已忽略，属**本机配置**）② Windows 服务 `Everything` 的二进制路径（即 `sc qc Everything` 里的 `BINARY_PATH_NAME`，Everything 界面没开也能查到）③ 注册表里的安装位置 ④ 开始菜单 / 桌面快捷方式（便携版常见）⑤ 运行中的 Everything 进程 ⑥ PATH ⑦ 常见安装目录。换电脑一般不用改脚本；便携版又没建快捷方式时，在仓库根目录写一行 `everything.path` 即可。

## 已知限制 / 注意事项

- **固定位置会覆盖手动摆放**：`ExplorerPlace` / `DeepSeekHarness` / `EverythingCenter` 默认 `ENFORCE_ALWAYS := true`，手动拖动、Win+←/→ 贴边都会被拉回。想自由摆放就把它设为 `false`。
- `WinMove.ahk` 的拖拽手势在"被固定"的窗口上只保留点击切换最大化：拖动会被归位，所以直接跳过拖动（窗口属性 `AHK_WinPlace_Owner` 由 winplace 写入，值为归属脚本 PID）。
- `WinAlwaysOnTop` 为拦截系统菜单项装了**全局** `WH_GETMESSAGE`/`WH_CALLWNDPROC` 钩子（DLL 在仓库里）：会被注入所有同位数进程（部分杀软会关注），且对**不同位数**的程序无效——64 位构建下，32 位程序的菜单项点了没反应。DLL 的重建命令见 `WinAlwaysOnTop_hook.c` 头部注释。
- attention 的 Toast 要突破「请勿打扰」，需在 设置 → 通知 → 设置优先级通知 → 添加应用 里加入 DeepSeek Harness；否则通知只进通知中心，不会弹横幅。`tools/DSHToast.ps1` 里已设置 `Priority = High`。
- 剪贴板归档是**明文**；`cache\` 已被 `.gitignore` 排除，但不要把它提交或同步到云端。
- 托盘菜单的勾选状态在开/关、Rescan、Reload 时刷新；在管理器之外手动启动的脚本，勾选不会自动更新。
