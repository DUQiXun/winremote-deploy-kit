# 故障排查

按「症状」查。每条都给出**先测什么**，不要凭猜。

---

## 0. 先分层：到底哪一层断了

从工作站（客户端那台）依次跑：

```powershell
# 1) 目标机活着吗
Test-Connection <目标主机名或IP> -Count 2 -Quiet

# 2) 目标机 Windows 网络栈正常吗（445 开着说明系统起来了）
Test-NetConnection <目标主机名> -Port 445 -WarningAction SilentlyContinue

# 3) MCP 服务在监听吗
Test-NetConnection <目标主机名> -Port 8090 -WarningAction SilentlyContinue
Test-NetConnection <目标主机名> -Port 8095 -WarningAction SilentlyContinue

# 4) 认证通吗（/health 是免认证的公开路径）
Invoke-RestMethod "http://<目标主机名>:8090/health"

# 5) 中继活着吗
Invoke-RestMethod "http://127.0.0.1:8091/health"
```

对照结果定位：

| 1 ping | 2 445 | 3 端口 | 结论 |
|---|---|---|---|
| ✗ | ✗ | ✗ | 机器关机 / 断网 / 睡死 → 见 §4 |
| ✓ | ✓ | ✗ | 机器活着但服务没跑 → 见 §2 |
| ✓ | ✓ | ✓ | 服务在，问题在认证或客户端 → 见 §3、§5 |

---

## 1. `Session not found`

```
Streamable HTTP error: Error POSTing to endpoint:
{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Session not found"}}
```

**含义**：目标服务重启过（或换了目标），客户端还拿着老 `mcp-session-id`。

**为什么不会自愈**：HTTP 层返回的是 400 而不是连接断开，客户端挂在 `onclose` 上的重连
逻辑不会触发，于是既不重连也不重新 `initialize`。

**处理**：
- 用本仓库的 relay（自动重建 session + 重放请求）→ 根治
- 临时办法：重启客户端宿主程序（治标，每次服务重启都要来一遍）

---

## 2. 机器活着，但端口不监听

`445` 通、`8090/8095` 都不通。

### 2.1 先看是不是「停在登录界面」

```powershell
# 需要在目标机上，或通过别的通道
query user
```

- 有 `Active` 会话 → 有人登录，交互实例应该在跑 → 查 §2.2
- 没有活动会话（只有登录界面）→ **交互实例本来就不会跑** → 8095（SYSTEM）应该在跑；
  如果 8095 也不通，说明开机任务没生效 → 见 §2.3

### 2.2 进程在不在

```powershell
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like '*winremote*' } |
  Select-Object ProcessId, CreationDate, CommandLine

Get-NetTCPConnection -LocalPort 8090,8095 -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

有进程但没监听 → 端口被占 / 启动参数错 → 看日志：

```
C:\ProgramData\winremote\interactive.err.log
C:\ProgramData\winremote\interactive.out.log
C:\ProgramData\winremote\watchdog.log
```

### 2.3 任务和自启项在不在

```powershell
schtasks /Query /TN winremote-boot     /FO LIST
schtasks /Query /TN winremote-watchdog /FO LIST
Get-ScheduledTaskInfo -TaskName winremote-watchdog | Select LastRunTime,LastTaskResult

Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
```

`LastTaskResult` 非 0 就是它跑失败了。

**注意**：交互自启走的是 Startup 文件夹里的 `winremote.vbs`。如果那个文件被删/被安全软件
隔离，登录时就不会起。手工触发一次：

```powershell
Start-Process wscript.exe -ArgumentList '//B "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\winremote.vbs"'
```

---

## 3. 401 Unauthorized

认证头不匹配。

```powershell
# 目标机上读真实 key
Get-Content C:\ProgramData\winremote\authkey.txt
```

手动验一次（本机就能跑）：

```powershell
$k = '<key>'
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
Invoke-WebRequest "http://<host>:8090/mcp" -Method POST -Body $body `
  -ContentType "application/json" `
  -Headers @{ Accept = 'application/json, text/event-stream'; Authorization = "Bearer $k" } `
  -UseBasicParsing | Select-Object StatusCode
```

`200` = key 对；`401` = key 错，改客户端或中继的配置。

---

## 4. ping / 445 都不通

### 4.1 IP 变了

```powershell
Resolve-DnsName <目标主机名> -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notmatch ':' } | Select IPAddress

# 更直接：用主机名连，看它解析到哪
Test-NetConnection <目标主机名> -Port 8095 -WarningAction SilentlyContinue |
  Select RemoteAddress, TcpTestSucceeded
```

**根治**：relay 的 target 用主机名；再给目标机做一个 DHCP 静态保留或固定 IP。

### 4.2 机器睡了 / 网卡省电断了

```powershell
# 目标机上
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off
```

网卡节能也要关：设备管理器 → 网卡 → 属性 → 电源管理 → 取消
「允许计算机关闭此设备以节约电源」。

### 4.3 断电/蓝屏后没自动开

BIOS 里把 **AC Power Loss / Restore on AC Power Loss** 设成 **Power On**。

---

## 5. 工具消失：`unknown tool "mcp__winremote__Shell"`

客户端**把工具注销了**，通常是因为重连次数用尽。

多数 MCP 客户端的重连策略：指数退避，默认 `maxAttempts` 只有 5~10 次，约 1~2 分钟就
放弃，然后把整组工具注销。服务端只要停机超过这个窗口，工具就"消失"。

**处理**：
1. 把 `reconnect.maxAttempts` 调大（例如 100000），让它一直等
2. 或者把客户端指向 relay —— relay 一直在线，客户端根本不会看到上游抖动

DSH / `@deepseek-ai/dsh-mcp-client` 的写法示例：

```yaml
- id: mcp-winremote
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: winremote
    transport: streamable-http
    url: 'http://127.0.0.1:8091/mcp'
    headers:
      Authorization: 'Bearer <key>'
    toolCallTimeoutMs: 180000
    failOnStartupError: false
    reconnect:
      enabled: true
      initialDelayMs: 1000
      maxDelayMs: 30000
      maxAttempts: 100000
```

---

## 6. 能连，但截图黑屏 / 点击没反应

连到 **SYSTEM 实例（8095 / session 0）** 了，那个实例看不到用户桌面。

```powershell
# 目标机上确认谁在监听
Get-NetTCPConnection -LocalPort 8090,8095 -State Listen | Select LocalPort, OwningProcess
Get-Process -Id <pid> | Select Id, SessionId
```

`SessionId = 0` 就是 SYSTEM 实例。GUI 类工具必须走 `SessionId = 1` 的交互实例。

**处理**：relay 的 target 顺序把 8090 放前面；另确认确实有人登录着。

---

## 7. 长命令超时：`relay: all targets unreachable (timeout)`

relay 默认单请求超时 60s。装软件、编译、大文件哈希这类会超过。

```powershell
node winremote-relay.js ... --timeout 600000
```

或者把重活拆成「先起后台任务、再轮询」两步（推荐，避免单次调用被超时切断）。

---

## 8. 重装/回滚

```powershell
# 完全移除目标机上的东西
.\deploy\uninstall-target.ps1

# 保留 pip 包
.\deploy\uninstall-target.ps1 -RemovePackage:$false
```

注意：**睡眠/休眠设置不会自动还原**（那是机器级电源策略），需要手动：

```powershell
powercfg /change standby-timeout-ac 30
powercfg /change hibernate-timeout-ac 180
```
