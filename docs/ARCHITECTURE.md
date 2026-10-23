# 架构与设计取舍

## 一句话

目标机上跑**两个不同生命周期**的 winremote-mcp 实例，工作站上跑一个**会话稳定**的中继，
客户端只认中继那个永不变化的本地地址。

---

## 为什么是「两个实例」

`winremote-mcp` 的工具分两类，对运行环境的要求完全不同：

| 工具 | 依赖 | 例 |
|---|---|---|
| 命令类 | 只需要进程活着 | `Shell` `FileRead` `FileWrite` `RegRead` `RegWrite` `ServiceList` `ListProcesses` `NetConnections` `EventLog` |
| GUI 类 | 需要**已登录的交互式桌面会话** | `Snapshot` `AnnotatedSnapshot` `Click` `Type` `Scroll` `Shortcut` `FocusWindow` `OCR` `ScreenRecord` |

Windows 的会话隔离决定了：

- **session 0（服务 / SYSTEM / 开机任务）** 看不到也点不到用户的桌面 → GUI 类全废
- **session 1（登录后的用户会话）** 才能截图和注入输入事件 → 但**没人登录就没有**

所以两个诉求天然冲突，只能用两个实例覆盖：

```
8095  SYSTEM / ONSTART    → 只要通电就在，命令类 100% 可用
8090  用户 / ONLOGON      → 有人登录就在，GUI 类可用
```

中继按顺序探测，**先试 8090（功能全），不行退 8095（至少能干活）**。

> 想让无人登录时也有 GUI，唯一办法是配置自动登录（Autologon / Sysinternals Autologon），
> 让 session 1 始终存在。这是取舍，不是 bug。

---

## 为什么需要中继：`Session not found` 到底怎么来的

MCP 的 streamable HTTP，服务端为每个客户端维护一个 session，用响应头
`mcp-session-id` 下发，客户端后续每个请求都要带回来。

服务端进程重启 → 内存中的 session 表清空 → 客户端再带老 id 来，得到：

```
HTTP 400
{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Session not found"}}
```

问题在于**这不算连接失败**：

- HTTP 层是成功的（服务端正常响应了 400）
- transport 没有 close 事件
- 客户端重连逻辑挂在 `onclose` 上 → **永远不会触发**
- 于是客户端既不重连、也不重新 `initialize`

用户的观感是：**"连着呢，但所有工具都调不动"**，唯一的解法是重启客户端宿主程序。
如果你一天重启几次目标机，这一天就废了。

中继把这个状态机接过来：

```
client ──► relay ──► upstream
          │
          ├─ 收到 "Session not found"
          ├─ 自己重新 initialize 拿新 session
          └─ 重放原请求一次，把结果原样回给 client
```

客户端永远看到的是一个健康的 session（它对着中继的那一份），所以永远不会卡死。

### 中继还顺手修了 IP 漂移

目标地址写 IP（`192.168.1.50`）时，一旦 DHCP 换租约、或者网络拓扑变了（桥接、双网卡、
换路由器），客户端就连不上，而配置改完还得重启客户端宿主。

中继的 target 列表**优先用主机名**，Node 每次请求重新解析 → IP 变了自动跟上。
IP 只作为最后的兜底项。

---

## 状态与顺序

中继内部有两个游标：

- `upstreamSession` —— 当前上游 session id（失效时置空并重建）
- `activeTarget` —— 当前目标索引（请求失败时轮转到下一个）

请求路径：

```
POST /mcp
 ├─ 解析 body 判断是否是 initialize
 ├─ 非 initialize 且无 session → bootstrap()
 ├─ 发往 TARGETS[activeTarget]
 │   ├─ 网络错误 → 轮转目标、清 session、重试一次
 │   ├─ 4xx 且命中 /session not found/i → 重建 session、重试一次
 │   └─ 其它 → 原样透传
 └─ 成功 → 透传 status / content-type / mcp-session-id
```

`GET /mcp`（服务器→客户端 SSE 流）和 `DELETE /mcp`（会话拆解）走尽力转发：
上游出错时干净关闭，绝不把客户端挂死。

---

## 为什么不用现成的

| 方案 | 能不能解决 `Session not found` |
|---|---|
| `mcp-remote`（npm） | 不能，它是协议转换/OAuth 代理，不重写 session 生命周期 |
| `supergateway` / `mcpo` | 不能，只做 stdio ↔ HTTP 桥接 |
| NSSM 包成服务 | 不能，解决的是"进程不死"，不是"session 失效" |
| SSH 隧道 | 不能，隧道只搬字节 |
| 重启客户端宿主 | 能，但代价是每次都手动 |

中继只有 ~250 行、零依赖，就是为了把这件事做对且能被审计。

---

## 为什么目标机不走 NSSM 服务

NSSM 是好东西（开机自启、崩溃重启、无控制台），但它跑在 **session 0**：

- 命令类工具：完全正常
- GUI 类工具：截图黑屏 / 点击无效

所以本项目用「SYSTEM 计划任务」实现同样的常驻效果（session 0，命令类），
同时保留「登录时隐藏 VBS」给 GUI（session 1）。要 NSSM 的话把
`install-target.ps1` 里的 `winremote-boot` 任务换成 NSSM 服务即可，语义一致。
