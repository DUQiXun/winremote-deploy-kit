# DSH（DeepSeek Harness）接入示例

DSH 通过 `@deepseek-ai/dsh-mcp-client` 插件接入 MCP 服务，配置写在 **agent preset**
里，一个 preset 一个文件：

```
%USERPROFILE%\.dsh\.agent-presets\<preset名>\agent.cordis.yml
```

> preset 是你启动会话时选的那个 profile（`flagship` / `aaa` / 自定义……）。
> **不确定用哪个就每个都加一遍** —— 各 preset 独立加载，`serverName` 相同不冲突。

---

## 1. 加这一段

放在插件列表里，跟已有的 `mcp-*` 条目同级（YAML 列表项，注意缩进两格）：

```yaml
# --- winremote：远程 Windows 控制（经 relay）---
- id: mcp-winremote
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: winremote
    transport: streamable-http
    url: 'http://127.0.0.1:8091/mcp'
    headers:
      Authorization: 'Bearer <你的 auth key>'
    toolCallTimeoutMs: 180000
    failOnStartupError: false
    reconnect:
      enabled: true
      initialDelayMs: 1000
      maxDelayMs: 30000
      maxAttempts: 100000
```

### 每个字段为什么这么写

| 字段 | 值 | 理由 |
|---|---|---|
| `serverName` | `winremote` | 必须匹配 `[A-Za-z0-9_-]{1,32}`，且**全局唯一**（重名会让插件启动时报错） |
| `transport` | `streamable-http` | winremote-mcp 的默认传输方式 |
| `url` | relay 的地址 | **关键**：指向 relay，不是直连目标机。这样目标 IP 变化、目标服务重启都不需要改这里 |
| `headers.Authorization` | `Bearer <key>` | 直连时必需；走 relay 时 relay 会自己加，但带上便于将来切回直连 |
| `toolCallTimeoutMs` | `180000` | 默认只有 60000，装软件 / 编译 / 长命令会被截断 |
| `failOnStartupError` | `false` | 目标机关机时不拖垮 DSH 启动，等它自己重连 |
| `reconnect.maxAttempts` | `100000` | **默认只有 10 次**（约 2 分钟就放弃并注销全部工具）。调到很大，让它一直等 |

---

## 2. 重启 DSH

配置只在启动时读取。**完全退出 DSH Desktop（不是最小化）再打开。**

重开后工具会以 `mcp__winremote__*` 出现在工具列表里，共 45 个。

---

## 3. 验证

让 Agent 跑一句：

```
winremote__Shell  command="hostname; whoami"
```

应当返回目标机的主机名和账户。若返回的是本机名，说明连到了错误的端点。

---

## 4. 常见问题

### 工具整组消失：`unknown tool "mcp__winremote__Shell"`

**原因**：客户端重连次数用尽（默认 10 次 ≈ 2 分钟），把工具注销了。此时服务恢复也不会
自动回来。

**处理**：
1. 确认 `reconnect.maxAttempts` 已调到 100000
2. 重启一次 DSH 让它重新注册
3. **根治**：指向 relay（relay 一直在线，DSH 根本看不到上游抖动）

### `Session not found`

目标服务重启过，DSH 拿着旧 `mcp-session-id`。HTTP 返回 400 而非断开，所以 DSH 的重连
（挂在 `onclose` 上）不触发 → 卡死。

**根治**：走 relay。临时办法：重启 DSH。

### 401 Unauthorized

`Authorization` 里的 key 与目标机 `C:\ProgramData\winremote\authkey.txt` 不一致。

### 截图黑屏 / 点击无效

落到了 SYSTEM 实例（session 0）。把 relay 的 target 顺序改成**交互实例在前**：

```
--target DESKTOP-ABC:8090,DESKTOP-ABC:8095
```

---

## 5. 多目标的写法

一台 DSH 连多台机器 → 加多个 `mcp-client` 条目，**`serverName` 不能重复**：

```yaml
- id: mcp-pc-office
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: pc_office
    transport: streamable-http
    url: 'http://127.0.0.1:8091/mcp'
    headers: { Authorization: 'Bearer <key-A>' }
    toolCallTimeoutMs: 180000
    failOnStartupError: false
    reconnect: { enabled: true, initialDelayMs: 1000, maxDelayMs: 30000, maxAttempts: 100000 }

- id: mcp-pc-lab
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: pc_lab
    transport: streamable-http
    url: 'http://127.0.0.1:8092/mcp'
    headers: { Authorization: 'Bearer <key-B>' }
    toolCallTimeoutMs: 180000
    failOnStartupError: false
    reconnect: { enabled: true, initialDelayMs: 1000, maxDelayMs: 30000, maxAttempts: 100000 }
```

每台机器在工作站上各跑一个 relay 实例（不同端口），互不干扰。

---

## 6. 顺便：DSH 也支持 stdio 方式

不想跑 relay、也不怕重启时手动处理，可以走 stdio 直连目标（需要目标提供 stdio 入口，
通常配合 SSH）：

```yaml
- id: mcp-winremote-stdio
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: winremote
    transport: stdio
    command: 'ssh'
    args: ['user@DESKTOP-ABC', 'py', '-m', 'winremote', '--transport', 'stdio']
    toolCallTimeoutMs: 180000
    failOnStartupError: false
```

缺点：GUI 类工具依赖 SSH 会话的桌面上下文，通常拿不到；且每次 SSH 断开都要重连。
**长期服务场景还是推荐 HTTP + relay。**
