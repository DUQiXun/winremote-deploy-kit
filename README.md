# winremote-deploy-kit

> 把 [winremote-mcp](https://github.com/dddabtc/winremote-mcp) 从「跑起来能玩」变成
> 「7×24 一直在、客户端永远不用重启」的一套部署工具与中继。

A production-oriented deployment kit for `winremote-mcp`: two-channel target
install, a session-stable relay, and the failure modes it fixes.

---

## 它解决什么问题

`winremote-mcp` 本身很好用（45 个工具：截图、点击、输入、Shell、文件、注册表、服务、
进程、网络、OCR……），但直接拿它当长期服务用，会连着撞上三个坑。这个仓库就是把这三个坑
一次性填掉。

### 坑 1：窗口一关，服务就死

用 `python -m winremote` 前台跑，控制台窗口被关掉、被 `Ctrl+C`、或者 SSH 会话断掉，
服务就没了。

**→ 本仓库**：换成「登录时隐藏启动 + 隐藏的 SYSTEM 开机实例」，无窗口、无控制台可误关。

### 坑 2：机器一重启 / 一停在登录界面，就连不上

交互式实例必须在**已登录的桌面会话**里才有意义（截图和鼠标依赖它）。机器重启后停在
登录界面时，没人登录 → 服务不存在 → 客户端报连接失败。

**→ 本仓库**：双通道。命令类工具走 **开机即起的 SYSTEM 实例**（不依赖登录），GUI 类工具
走**登录后的交互实例**。两者都在时优先交互实例。

### 坑 3（最阴的）：服务重启后，客户端"看起来连着但一个工具都调不动"

`winremote-mcp` 用 MCP 的 *streamable HTTP*。服务端每次重启，内存里的 MCP session 全部
失效。标准 MCP 客户端会继续拿旧的 `mcp-session-id` 发请求，服务端返回：

```
HTTP 400  {"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Session not found"}}
```

而 HTTP transport **没有断开**，所以客户端的 `onclose` 不会触发 → 不会重连 → 不会重新
`initialize`。结果是：连接"正常"，工具全部失效，只能重启客户端宿主程序。

**→ 本仓库**：`relay/winremote-relay.js`。它给客户端一个**永远不变的本地地址**，在内部：

- 每次请求重新解析主机名 → 目标机 DHCP / 桥接换 IP 无感
- 上游返回 `Session not found` 时**自动重新 `initialize` 并重放请求一次**
- 目标列表按顺序故障转移（交互实例 → 常驻实例 → IP 兜底）

---

## 架构

```
┌─────────────┐        ┌──────────────────────────┐        ┌─────────────────────────┐
│ MCP 客户端   │        │  relay（工作站）          │        │  目标 Windows 主机        │
│ (Claude /   │  HTTP  │  127.0.0.1:8091          │  HTTP  │                         │
│  Cursor /   │ ─────► │  ├ 重解析主机名            │ ─────► │  8090 交互实例           │
│  DSH / ...) │ 固定   │  ├ 自动补 session         │        │       （登录后启动）      │
└─────────────┘ 地址   │  └ 故障转移               │        │  8095 SYSTEM 实例        │
                        └──────────────────────────┘        │       （开机即起）        │
                                                             └─────────────────────────┘
```

| 通道 | 端口（默认） | 谁启动 | 何时可用 | 能做什么 |
|---|---|---|---|---|
| 交互实例 | 8090 | 登录时（隐藏 VBS） | 有人登录着 | 全部 45 个工具，含截图 / 点击 / 输入 |
| SYSTEM 实例 | 8095 | 开机时（计划任务） | 只要通电 | 命令 / 文件 / 注册表 / 服务 / 进程 / 网络，**不含** GUI |

> GUI 工具需要「已登录的桌面会话」，这是 Windows 的会话机制决定的，任何实现都一样。
> 想在无人登录时也能截屏，只能配置自动登录。

---

## 快速开始

### 1. 目标机（要被控制的那台）

以**管理员** PowerShell 运行：

```powershell
cd deploy
.\install-target.ps1
```

它会：装/校验 `winremote-mcp` → 生成 auth key → 开防火墙（8090 + 8095）→
建开机 SYSTEM 任务（8095）→ 建登录隐藏自启（8090）→ 建 5 分钟看护任务 →
关掉睡眠/休眠 → 打印全部信息。

结尾会打印类似：

```
  host        : DESKTOP-ABC (192.168.1.50)
  interactive : http://DESKTOP-ABC:8090/mcp     (logon session, GUI tools)
  always-on   : http://DESKTOP-ABC:8095/mcp     (boot/SYSTEM, command tools)
  auth key    : 3fQ9...zK
  key file    : C:\ProgramData\winremote\authkey.txt
```

可选项：

```powershell
.\install-target.ps1 -Port 9000 -SystemPort 9005      # 换端口
.\install-target.ps1 -NoSystemChannel                 # 只要交互通道
.\install-target.ps1 -NoPowerTweaks                   # 不动电源设置
```

### 2. 工作站（跑 MCP 客户端的那台）

```powershell
cd relay
.\install-relay.ps1 -Targets 'DESKTOP-ABC:8090,DESKTOP-ABC:8095' -AuthKey '<上一步的 key>'
```

`Targets` 是**有序**故障转移列表，建议交互实例在前、SYSTEM 实例在后。

### 3. 客户端配置

MCP 客户端只需要一个固定地址 —— 之后再也不用改：

```json
{
  "mcpServers": {
    "winremote": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:8091/mcp",
      "headers": { "Authorization": "Bearer <auth key>" }
    }
  }
}
```

> relay 会自己给上游加 `Authorization` 头。客户端带不带都行，带上便于将来直连。

---

## 目录结构

```
deploy/
  install-target.ps1            目标机一键安装（双通道 + 防火墙 + 看护 + 电源）
  uninstall-target.ps1          完整回滚
relay/
  winremote-relay.js            会话稳定的 HTTP 中继（零依赖，Node >= 18）
  install-relay.ps1             中继自启 + 5 分钟看护
docs/
  ARCHITECTURE.md               设计取舍：为什么是两个通道、中继为什么需要
  TROUBLESHOOTING.md            我们实际踩过的坑和定位方法
agent-skill/
  SKILL.md                      给 AI Agent 用的操作规范（可直接放进 skills 目录）
```

---

## 客户端配置示例

| 客户端 | 文件 | 说明 |
|---|---|---|
| DSH / DeepSeek Harness | [xamples/dsh.md](examples/dsh.md) | agent preset 的完整写法、字段逐个解释、多目标配置、常见问题 |
| Claude Desktop | [xamples/claude-desktop.json](examples/claude-desktop.json) | 放进 `claude_desktop_config.json` |
| Cursor | [xamples/cursor-mcp.json](examples/cursor-mcp.json) | 放进项目或全局 `.cursor/mcp.json` |

三个示例都指向同一个地址：`http://127.0.0.1:8091/mcp`（relay）。
**客户端永远只认这一个地址。**

---
## 常见故障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Session not found` | 目标服务重启过，客户端拿着老 session | 用本仓库的 relay；或重启客户端宿主 |
| `unknown tool "mcp__x__Y"` | 客户端重连次数用尽，工具被注销 | 提高客户端的 `reconnect.maxAttempts`，或重启宿主 |
| 连不上，但 `ping` 通、445 通 | 目标机停在登录界面，交互实例没起 | 部署 SYSTEM 通道（8095） |
| 连不上，`ping` 也不通 | IP 变了 / 机器睡死 | relay 用主机名；关睡眠 |
| 能连但截图是黑屏 | 连到了 SYSTEM 实例（session 0） | 故障转移顺序把交互实例放前面 |
| 401 Unauthorized | auth key 不一致 | 目标机 `C:\ProgramData\winremote\authkey.txt` 对一遍 |

更详细的定位步骤见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)。

---

## 安全须知（务必读）

这套东西等价于**把一台 Windows 的完整控制权挂在网络上**（SYSTEM 实例是全权限）。

1. **auth key 是唯一凭据**。它存在于 `C:\ProgramData\winremote\authkey.txt`（ACL 已限制为
   管理员 + SYSTEM），以及客户端配置里。泄露 = 那台机器被完全接管。
2. **绝不要做公网端口映射**。跨网络请用 Tailscale / ZeroTier / WireGuard 之类的虚拟内网，
   并用 `--ip-allowlist` 限定来源网段。
3. **锁屏不是安全边界**。交互实例跑在用户 session 里，能截图、能点击锁屏界面；
   只有 UAC 提升框和 `Ctrl+Alt+Del` 安全桌面拦得住。
4. **`--enable-tier3` 打开的是高危工具**（Shell、文件写、杀进程、改注册表、启停服务）。
   不需要就别开；需要就用 `--tools` 精确白名单，例如
   `--tools "Snapshot,Click,Type,Shell"`。
5. 卸载或临时停用：跑 `deploy\uninstall-target.ps1`，或直接删任务
   `winremote-boot` / `winremote-watchdog` 并停进程。

---

## 依赖与许可

- Python 3.10+（目标机）
- Node.js 18+（工作站，只有 relay 需要）
- [`winremote-mcp`](https://github.com/dddabtc/winremote-mcp)（MIT）
- 本仓库：MIT，见 [LICENSE](LICENSE)

> 本项目是 `winremote-mcp` 的**独立配套部署工具**，不修改其源码，也不是它的官方子项目。
