---
name: winremote-remote-pc
description: 通过 winremote-mcp 操作另一台 Windows 主机（远程桌面控制、跨机执行）。当用户说「那台电脑」「另一台机器」「远程那台」「连过去」「在我另一台电脑上打开/看看/跑个命令」，或需要跨机器执行命令、读写文件、看屏幕、GUI 自动化时使用。给出目标身份核对、45 个工具的分层清单、常用操作配方、断连与 IP 漂移的排障步骤。
---

# 远程 Windows 主机操作规范（winremote-mcp）

> 部署见仓库 `deploy/` 与 `relay/`；本文件是**操作侧**的 Agent 规范。

## 一、先核对目标身份（不要假设）

任何跨机器操作的第一个动作：

```
winremote__Shell  command="hostname; whoami; ipconfig | Select-String IPv4"
```

期望看到目标机名、其上的账户、以及预期网段。
若返回的是本机名 → 工具指向了本地，停下排查。

## 二、工具分层（45 个）

**tier1 只读（随便调）**
`Snapshot` `AnnotatedSnapshot` `GetClipboard` `GetSystemInfo` `ListProcesses`
`FileList` `FileSearch` `RegRead` `ServiceList` `TaskList` `EventLog` `Ping`
`PortCheck` `NetConnections` `OCR` `ScreenRecord` `Notification` `Wait`
`GetTaskStatus` `GetRunningTasks`

**tier2 交互（改变屏幕状态，用户会看见）**
`Click` `Type` `Move` `Scroll` `Shortcut` `FocusWindow` `MinimizeAll` `Scrape`
`CancelTask` `ReconnectSession`

**tier3 高危（改系统/数据，动手前讲清后果与回滚）**
`Shell` `App` `FileRead` `FileWrite` `FileDownload` `FileUpload` `KillProcess`
`RegWrite` `ServiceStart` `ServiceStop` `TaskCreate` `TaskDelete` `SetClipboard`
`LockScreen` `PlaySound`

## 三、通道选择（决定哪些工具能用）

| 端口（默认） | 会话 | 可用工具 |
|---|---|---|
| 8090 交互实例 | 已登录用户（session 1） | 全部，含截图/点击 |
| 8095 SYSTEM 实例 | 开机常驻（session 0） | 除 GUI 外全部 |

- 要**看屏幕 / 点鼠标** → 必须落在交互实例，且目标机确实有人登录着
- 只要**命令 / 文件 / 注册表 / 服务 / 进程** → 哪个通道都行

截图黑屏或点击无效 = 连到了 session 0 的 SYSTEM 实例。

## 四、常用配方

**看屏幕**
```
Snapshot(use_vision=true, max_width=1600)
AnnotatedSnapshot(max_elements=30)     # 带红框编号，编号直接对应 Click 坐标
```

**点击 / 输入 / 快捷键**
```
Click(x,y, action="click"|"double", button="left")
Type(text="...", clear=true, press_enter=true)
Shortcut(keys="ctrl+s")                # win+e / alt+tab / ctrl+shift+esc
```

**跑命令**
```
Shell(command="...", cwd="C:\\path", timeout=60)
```

**程序**
```
App(action="launch", name="notepad.exe")
ListProcesses(filter="chrome", limit=20)
KillProcess(pid=1234)                  # 或 name="xxx"
```

**文件（双向）**
```
FileRead(path=..., encoding="utf-8")
FileDownload(path=...)                 # 二进制 → base64
FileUpload(path="C:\\dst", data_base64="...")
```
大文件不要走 base64（会吃掉大量上下文）：改用 SMB 管理共享
`\\<host>\C$`，或先 `Shell` 算 `Get-FileHash` 校验。

**系统 / 网络 / 服务 / 计划任务 / 注册表 / 事件日志**
```
GetSystemInfo()
NetConnections(filter="LISTENING", limit=50)
ServiceList(filter="wuauserv")
TaskList(filter="Update")
RegRead(key="HKLM\\SOFTWARE\\...", value_name="X")
EventLog(log_name="System", level="error", count=20)
```

**OCR / 录屏（要"读汉字"而非像素时）**
```
OCR(lang="eng")            # 或 left/top/right/bottom 指定区域
ScreenRecord(duration=3, fps=5)
```

## 五、排障顺序（一次只改一个变量）

1. **端口在不在**：`Test-NetConnection <host> -Port 8090/8095`
2. **机器活着吗**：`ping` + `445`（445 通但端口不通 = 服务没跑）
3. **日志**：目标机 `C:\ProgramData\winremote\{interactive,watchdog}.*.log`
4. **认证**：`/health` 免认证；401 就是 key 不匹配
5. **IP 漂了**：用主机名连，看 `RemoteAddress` 落到哪
6. **`Session not found`**：走 relay（自动重建 session）；否则只能重启客户端宿主
7. **工具消失 `unknown tool`**：客户端重连次数用尽被注销 → 调大 `reconnect.maxAttempts` 或改连 relay

## 六、安全边界

- 这套等于把一台 Windows 的完整控制权挂在网络上；`--enable-tier3` 是全权限
- auth key 是唯一凭据，别外传、别贴公网、别提交进仓库
- 不做公网端口映射；跨网用虚拟内网 + `--ip-allowlist`
- **锁屏不是安全边界**：会话内的实例能截图能点锁屏；只有 UAC 提权框和
  `Ctrl+Alt+Del` 安全桌面拦得住
- 服务端 `pyautogui.FAILSAFE` 被写死为 `False` —— 鼠标甩左上角不会中断自动操作；
  失控时用 `KillProcess(name="python")` 掐掉对应实例
- 破坏性操作（`RegWrite` `KillProcess` `ServiceStop` `TaskDelete` `FileWrite`）之前，
  先说清「改什么、改完什么效果、怎么还原」

## 七、与本地工具的分工

- 本机的事用本地 shell / 文件工具
- 那台机器的事一律走远程工具，不要用本地路径去访问它的文件
- 跨机搬数据优先 SMB `\\<host>\C$`，其次再考虑 MCP 上传下载
